extends RefCounted
class_name WorldEventEngine

# 功能：世界与事件引擎（MVP）。
# 说明：单一主循环推进，forcedNextEventId 优先级最高，链式通过 chainContext 塑形分布。
const POLICY_RETURN := "ReturnToScheduler"
const POLICY_CHAIN := "ChainContinue"
const POLICY_CHAIN_FORCED := "ChainContinueWithForcedNext"
const TASK_BIAS_ADVANCE_DEFAULT := 6
const TASK_BIAS_RISK_DEFAULT := -4
const ConfigRuntime := preload("res://scripts/systems/config_runtime.gd")
const LocationGraph := preload("res://scripts/models/location_graph.gd")
# 说明：RuleEngine 已通过 class_name 全局注册，无需 preload。
const AffinityMapClass := preload("res://scripts/models/affinity_map.gd")
const ReflectionStateMachine := preload("res://scripts/systems/reflection_state_machine.gd")
const CreationStateMachine := preload("res://scripts/systems/creation_state_machine.gd")
# Line B S2: 资源标记池 (单值→卡+标记数; 满容量丢弃多余; 详见 [[前端骨架_LineB_实施]] §3.5-§3.12)
const ResourceMarkerPool := preload("res://scripts/systems/resource_marker_pool.gd")

var world_state: Dictionary = {}
var events: Array = []
var choice_points: Array = []
var task_defs: Array = []
var task_evaluation: Dictionary = {}
var _event_map: Dictionary = {}
var _choice_point_map: Dictionary = {}
var _task_def_map: Dictionary = {}
var _task_eval_index_by_task: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _pending_turn_context: Dictionary = {}
var _location_graph: LocationGraph
# 玩家 RoleState 引用，作为玩家能力与状态的运行时权威数据源。
var player_role_state: Variant = null
# 鉴定阶段阈值。本阶段以常量形式集中定义，后续可拆为配置文件。
var _assessment_thresholds: Array = [0, 3, 7, 12]
# 关系数据运行时权威数据源。
var _affinity_map: AffinityMapClass = null
# 关系五档阈值配置（从 world_seed affinityConfig 读取）。
var _affinity_thresholds: Dictionary = {}
# 最近一次结算的鉴定结果缓存，供 payload 透传给 UI 消费。
var _last_check_result: Dictionary = {}
# 最近一次结算的关系变化记录，供 payload 透传给 UI 消费。
var _last_affinity_changes: Array = []
# 周期级累积关系变动记录，跨事件保留，仅在自省结算后清空。
var _cycle_affinity_changes: Array = []
# 叙事包系统配置（默认回合容量），从 world_seed packConfig 加载。
var _pack_config: Dictionary = {}
# 自省系统配置（操作限额、调整刻度、推荐数量），从 world_seed reflectionConfig 加载。
var _reflection_config: Dictionary = {}
# demo 期临时收紧的开关（心性 UI 隐藏 / 心性接入路径禁用等），从 world_seed demoModeConfig 加载。
# 重构期审视清单见 [[代码重构_预启动]] §4.3 demo_mode_config 开关清单；规约见 [[鉴定 demo 期表现规约]]。
var _demo_mode_config: Dictionary = {}
# 自省操作已使用次数，自省开始时重置为0。
var _reflection_ops_used: int = 0
# 自省状态机实例，管理自省事件的完整交互流程。
var _reflection_sm: ReflectionStateMachine = ReflectionStateMachine.new()
# 开局选择状态机实例，管理角色创建的逐题交互流程。
var _creation_sm: CreationStateMachine = CreationStateMachine.new()
# 开局选择配置数据，从 CSV 加载后暂存，供 start_creation() 使用。
var _creation_config: Array = []
# 最近一次心性转移记录（{old_value, new_value}），无转移时为空字典。
var _last_xinxing_transition: Dictionary = {}
# 主动押注全局默认配置：cost 为额外代价（叠加在选项 cost 之上），bias 为鉴定加骰。
var _preemptive_bet_defaults: Dictionary = {
	"cost": {"energy": 5},
	"bias": {"successBias": 1}
}

# 功能：初始化随机源。
# 说明：seed=0 使用随机种子；指定 seed 可复现结果，便于测试回归。
func _init(random_seed: int = 0) -> void:
	if random_seed == 0:
		_rng.randomize()
	else:
		_rng.seed = random_seed

# 功能：从 JSON 文件加载 world_state、events、choice_points。
# 说明：返回统一结构 {"ok": bool, "error": String?}。
func load_from_files(
	world_state_path: String,
	events_path: String,
	choice_points_path: String = ""
) -> Dictionary:
	var world_text := FileAccess.get_file_as_string(world_state_path)
	if world_text.is_empty():
		return {"ok": false, "error": "world state file is empty or missing: %s" % world_state_path}

	var events_text := FileAccess.get_file_as_string(events_path)
	if events_text.is_empty():
		return {"ok": false, "error": "events file is empty or missing: %s" % events_path}

	var choice_points_text := ""
	if not choice_points_path.strip_edges().is_empty():
		choice_points_text = FileAccess.get_file_as_string(choice_points_path)
		if choice_points_text.is_empty():
			return {"ok": false, "error": "choice points file is empty or missing: %s" % choice_points_path}

	return load_from_json_text(world_text, events_text, choice_points_text)

# 功能：从 CSV 配置目录加载 world_state、events、choice_points。
# 说明：统一通过 ConfigRuntime 管理配置加载与缓存，避免引擎层直接编译 CSV。
func load_from_csv_dir(csv_dir_path: String) -> Dictionary:
	var runtime := ConfigRuntime.shared()
	var load_result := runtime.ensure_loaded({"world_event_csv_dir": csv_dir_path})
	if not load_result.get("ok", false):
		return load_result
	var context_result := runtime.build_context()
	if context_result.get("ok", false):
		_location_graph = context_result.get("graph", null)
	else:
		_location_graph = null
	var world_event_data := runtime.get_world_event_data()
	if world_event_data.is_empty():
		return {"ok": false, "error": "world event config is empty in config runtime"}
	# 从 ConfigRuntime 获取玩家 RoleState，传入 load_from_data 统一处理注入与同步。
	var p_role_state: Variant = null
	var roles: Array = runtime.get_roles()
	for role_variant in roles:
		if role_variant != null and role_variant.role_type == "player":
			p_role_state = role_variant
			break
	var load_result_final := load_from_data(world_event_data, _location_graph, p_role_state)
	if not load_result_final.get("ok", false):
		return load_result_final
	# 加载开局选择配置（可选，文件不存在时静默跳过）。
	_load_creation_config(csv_dir_path)
	return load_result_final

# 功能：从 JSON 文本加载数据。
# 说明：适合测试与热重载，成功后会重建事件与选择点索引。
func load_from_json_text(
	world_state_json: String,
	events_json: String,
	choice_points_json: String = ""
) -> Dictionary:
	var parsed_world: Variant = JSON.parse_string(world_state_json)
	if typeof(parsed_world) != TYPE_DICTIONARY:
		return {"ok": false, "error": "invalid world state json"}

	var parsed_events: Variant = JSON.parse_string(events_json)
	if typeof(parsed_events) != TYPE_ARRAY:
		return {"ok": false, "error": "invalid events json"}

	var parsed_choice_points: Variant = []
	if not choice_points_json.strip_edges().is_empty():
		parsed_choice_points = JSON.parse_string(choice_points_json)
		if typeof(parsed_choice_points) != TYPE_ARRAY:
			return {"ok": false, "error": "invalid choice points json"}

	world_state = (parsed_world as Dictionary).duplicate(true)
	events = (parsed_events as Array).duplicate(true)
	choice_points = (parsed_choice_points as Array).duplicate(true)
	task_defs = []
	task_evaluation = {}
	# JSON 路径不携带 RoleState，清空避免上一轮残留脏状态。
	player_role_state = null
	# 清空开局选择配置，避免上一轮残留。
	_creation_config = []
	_ensure_run_state()
	_ensure_task_runtime_state()
	_rebuild_event_map()
	_rebuild_choice_point_map()
	_rebuild_task_def_map()
	_rebuild_task_evaluation_index()
	_ensure_xinxing_tracker()
	# 功能：初始化关系系统和自省系统配置。
	# 说明：JSON 路径也需要加载这些配置，否则自省事件的 reflectionConfig 不会被读取。
	_init_affinity_system()
	_init_reflection_config()
	_init_demo_mode_config()
	return {"ok": true}

# 功能：从内存对象加载数据。
# 说明：用于承接 CSV 编译结果，避免二次 JSON 序列化产生歧义。
func load_from_data(data: Dictionary, location_graph: Variant = null, role_state: Variant = null) -> Dictionary:
	if data.is_empty():
		return {"ok": false, "error": "compiled data is empty"}
	var raw_world: Variant = data.get("world_state", null)
	var raw_events: Variant = data.get("events", null)
	var raw_choice_points: Variant = data.get("choice_points", [])
	var raw_task_defs: Variant = data.get("task_defs", [])
	var raw_task_evaluation: Variant = data.get("task_evaluation", {})

	if typeof(raw_world) != TYPE_DICTIONARY:
		return {"ok": false, "error": "compiled world_state is invalid"}
	if typeof(raw_events) != TYPE_ARRAY:
		return {"ok": false, "error": "compiled events is invalid"}
	if typeof(raw_choice_points) != TYPE_ARRAY:
		return {"ok": false, "error": "compiled choice_points is invalid"}
	if typeof(raw_task_defs) != TYPE_ARRAY:
		return {"ok": false, "error": "compiled task_defs is invalid"}
	if typeof(raw_task_evaluation) != TYPE_DICTIONARY:
		return {"ok": false, "error": "compiled task_evaluation is invalid"}

	world_state = (raw_world as Dictionary).duplicate(true)
	events = (raw_events as Array).duplicate(true)
	choice_points = (raw_choice_points as Array).duplicate(true)
	task_defs = (raw_task_defs as Array).duplicate(true)
	task_evaluation = (raw_task_evaluation as Dictionary).duplicate(true)
	_ensure_run_state()
	_ensure_task_runtime_state()
	_set_location_graph(location_graph)
	_rebuild_event_map()
	_rebuild_choice_point_map()
	_rebuild_task_def_map()
	_rebuild_task_evaluation_index()
	# 每次加载时无条件重置 player_role_state，避免上一轮残留脏状态。
	# 若传入了 role_state 则注入并同步到 world_state。
	player_role_state = role_state
	# 清空开局选择配置，避免上一轮残留。由 load_from_csv_dir 或外部调用方负责重新加载。
	_creation_config = []
	if player_role_state != null:
		_sync_role_to_world_state()
	# 初始化心性 tracker，记录孤注一掷使用次数与稳健连续回合数。
	_ensure_xinxing_tracker()
	# 初始化关系系统：加载五档阈值配置和初始关系分值。
	_init_affinity_system()
	# 初始化自省系统配置。
	_init_reflection_config()
	# 初始化叙事包系统配置。
	_init_pack_config()
	# 初始化 demo 期临时收紧开关（心性 UI 隐藏 / 心性接入路径禁用等）。
	_init_demo_mode_config()
	# 确保 packContext 存在（首次加载时初始化为空包状态）。
	_ensure_pack_context()
	return {"ok": true}

# 功能：预览下一回合事件，但不立即结算。
# 说明：叙事包联动——根据包状态路由到地点选择、自省或正常事件调度。
#       若已有待处理事件，直接复用当前上下文。
func preview_next_turn() -> Dictionary:
	# 预览阶段清空上次结算缓存，避免 UI 显示过期数据。
	_last_check_result = {}
	_last_affinity_changes = []
	_last_xinxing_transition = {}
	if events.is_empty():
		return {"ok": false, "error": "event pool is empty"}
	if _is_world_ended():
		return _build_world_ended_response()

	if not _pending_turn_context.is_empty():
		return _build_pending_turn_response(_pending_turn_context)

	# Phase A 修复：forcedNextEventId 优先级高于"包未建立 → 询问地点"默认 fallback。
	# 当 forced 指向无地点限制事件且 packContext 为空时，用 currentLocationId 自动启动隐式包，
	# 避免开局选择 SETTLED → IntroSequence 注入 forced=sys_opening_reflection 时被默认地点选择 UI 拦截。
	# 设计基线：本文件首行说明"forcedNextEventId 优先级最高，链式通过 chainContext 塑形分布"。
	var pending_forced_pre: String = str(world_state.get("forcedNextEventId", "")).strip_edges()
	if not pending_forced_pre.is_empty() and _is_pack_awaiting_location():
		var forced_def_pre: Dictionary = _event_map.get(pending_forced_pre, {})
		if not forced_def_pre.is_empty():
			var forced_eligibility_pre: Dictionary = forced_def_pre.get("eligibility", {})
			var forced_locations_pre: Array = forced_eligibility_pre.get("requiredLocations", [])
			if forced_locations_pre.is_empty():
				var initial_location: String = str(world_state.get("currentLocationId", "")).strip_edges()
				if not initial_location.is_empty():
					_start_new_pack(initial_location)
					print("[叙事包] 无地点 forced=%s + 包未建立，用 %s 启动隐式包绕过默认地点选择" % [
						pending_forced_pre, initial_location
					])

	# 叙事包联动：检查是否需要进入地点选择。
	if _is_pack_awaiting_location():
		var loc_event: Dictionary = _build_location_select_event()
		return {
			"ok": true,
			"phase": "location_select",
			"event_id": "_location_select",
			"title": str(loc_event.get("title", "")),
			"type": "location_select",
			"options": loc_event.get("options", []),
			"awaiting_input": true
		}

	# 叙事包联动：检查包是否已结束，需要触发自省 / 收口 / 普通地点选择。
	if _is_pack_finished():
		# Step 2 P1-2：末位池消费完后 _apply_event_effects 已写入收口 forced（如拜师 chain 入口），
		# 此处不应再注入中段自省 / location_select fallback 覆盖，否则会绕过 Step 1 的
		# "消耗完立即触发收口"语义。让出条件：forcedNextEventId 非空且不指向 sys_reflection 自身。
		# 让出后清空 packContext + fall through 到下方 _select_next_event，由 forced 路径处理。
		var forced_id_pre_reflect: String = str(world_state.get("forcedNextEventId", ""))
		var forced_takeover: bool = (
			not forced_id_pre_reflect.is_empty()
			and forced_id_pre_reflect != "sys_reflection"
		)
		if forced_takeover:
			print("[叙事包] 包结束时检测到收口 forced=%s，让出 forced 路径" % forced_id_pre_reflect)
			_clear_pack_context()
			# 不 return，fall through 到下方 _check_auto_accept_tasks + _select_next_event。
		else:
			var pack_ctx: Dictionary = _dict_or_empty(world_state.get("packContext", {}))
			var should_reflect := not bool(pack_ctx.get("interrupted", false))
			# chain 打断后，检查是否有 pendingReflectionAfterChain 标记。
			if bool(pack_ctx.get("interrupted", false)) and bool(world_state.get("pendingReflectionAfterChain", false)):
				should_reflect = true
				world_state.erase("pendingReflectionAfterChain")
			if should_reflect:
				# 强制插入自省事件。
				var reflection_def: Dictionary = _event_map.get("sys_reflection", {})
				if not reflection_def.is_empty():
					_pending_turn_context = _create_pending_turn_context(
						"sys_reflection", "pack_end_reflection", "", reflection_def
					)
					return _build_pending_turn_response(_pending_turn_context)
			# 不触发自省（chain 打断且无 triggerReflection），直接清空包进入地点选择。
			_clear_pack_context()
			# 清空后进入地点选择（_is_pack_awaiting_location 此时必定为 true），内联构建返回值避免递归。
			var loc_event_fallback: Dictionary = _build_location_select_event()
			return {
				"ok": true,
				"phase": "location_select",
				"event_id": "_location_select",
				"title": str(loc_event_fallback.get("title", "")),
				"type": "location_select",
				"options": loc_event_fallback.get("options", []),
				"awaiting_input": true
			}

	# 说明：先自动接取任务，确保本回合事件选择能立即吃到 task_links 权重。
	_check_auto_accept_tasks()

	var next_event_result := _select_next_event()
	if not next_event_result.get("ok", false):
		return next_event_result

	var event_def: Dictionary = next_event_result.get("event_def", {})
	var next_event_id := str(next_event_result.get("event_id", ""))
	var route := str(next_event_result.get("route", "scheduler"))
	var expected_forced := str(next_event_result.get("expected_forced", ""))
	_pending_turn_context = _create_pending_turn_context(next_event_id, route, expected_forced, event_def)
	return _build_pending_turn_response(_pending_turn_context)

# 功能：确认并结算当前待处理事件。
# 说明：无选项事件传空字符串即可；有选项事件必须传入可选 option_id。
func confirm_pending_turn(selected_option_id: String = "") -> Dictionary:
	if _is_world_ended():
		return _build_world_ended_response()
	if _pending_turn_context.is_empty():
		return {"ok": false, "error": "no pending turn to confirm"}
	return _resolve_pending_turn(selected_option_id)


# 功能：取消 pending 回合（不结算、不推 turn、不记历史），让下次 preview_next_turn 重新选事件。
# 说明：zhengdao-cards 卡牌前端"重抽"语义 — 玩家在结果前点新事件牌库时调用，
#       释放 _pending_turn_context 使 preview 不再返回旧事件。
#       回合 / 任务推进未发生（未走 _resolve_pending_turn），世界状态零副作用。
func cancel_pending_turn() -> Dictionary:
	if _pending_turn_context.is_empty():
		return {"ok": true, "cancelled": false}
	var cancelled_event_id := str(_pending_turn_context.get("event_id", ""))
	_pending_turn_context.clear()
	return {"ok": true, "cancelled": true, "event_id": cancelled_event_id}


# 功能：用外部传入的 tier 强制覆盖鉴定结果，结算 pending 选项。
# 说明：zhengdao-cards Line B S8 桥接接口 —— 前端 MarkerCheckResolver 算出 tier 后注入引擎，
#       引擎跳过 vibe-test 骰池 _is_check_pass、跳过心性风险入口（preemptive_bet / desperate_gamble），
#       直接按 tier 选择 onCriticalSuccessResolution / onFailResolution / onCriticalFailResolution / 基础 resolution。
#       原 confirm_pending_turn 路径完全保留，供 vibe-test 外场景沿用。
#       tier 取值: great_success / success / fail / great_fail（与 [[卡牌前端交互设计]] §3.2 stub 对齐）。
func confirm_pending_turn_with_forced_tier(selected_option_id: String, tier: String) -> Dictionary:
	if _is_world_ended():
		return _build_world_ended_response()
	if _pending_turn_context.is_empty():
		return {"ok": false, "error": "no pending turn to confirm"}
	var result_type := _tier_to_vibe_test_result_type(tier)
	_pending_turn_context["forced_check_result"] = {
		"pass": result_type == "success" or result_type == "critical_success",
		"result_type": result_type
	}
	return _resolve_pending_turn(selected_option_id)


# 功能：tier (zhengdao-cards 四档) → result_type (vibe-test 鉴定 result_type) 映射。
# 说明：great_success ↔ critical_success / fail ↔ fail / great_fail ↔ critical_fail / 其他 ↔ success。
static func _tier_to_vibe_test_result_type(tier: String) -> String:
	match tier:
		"great_success": return "critical_success"
		"fail": return "fail"
		"great_fail": return "critical_fail"
		_: return "success"


# 功能：确认地点选择，初始化新的叙事包。
# 说明：由 UI 层在玩家选定地点后调用。location_id 必须是 _build_location_select_event 返回的合法选项。
#       该操作不消耗回合、不推进任务、不记入历史。
func confirm_location_select(location_id: String) -> Dictionary:
	if _is_world_ended():
		return _build_world_ended_response()
	if location_id.strip_edges().is_empty():
		return {"ok": false, "error": "location_id is empty"}
	if not _is_pack_awaiting_location():
		return {"ok": false, "error": "not in location select phase"}

	# 验证地点合法性：必须是当前地点或其邻居。
	var current_location := str(world_state.get("currentLocationId", ""))
	var valid := (location_id == current_location)
	if not valid and _location_graph != null:
		var neighbors: Array = _location_graph.get_neighbors(current_location)
		valid = location_id in neighbors
	if not valid:
		return {"ok": false, "error": "location %s is not reachable from %s" % [location_id, current_location]}

	_start_new_pack(location_id)
	return {
		"ok": true,
		"location_id": location_id,
		"pack_capacity": int(_pack_config.get("defaultCapacity", 3))
	}


# 功能：自省末屏地点选择确认（Step 2 新增）。
# 说明：处理 reflection 事件 presents=location_select 末屏的玩家地点选择。流程：
#       1. 校验当前确实处于自省末屏 + 地点合法（邻居或当前地点）；
#       2. 写入 visited_locations 跨自省持久状态 + 切换 currentLocationId；
#       3. 按 transition_text_pool[reflection_transition][location_id] 抽过渡叙事文本组，
#          作为 _dynamic=true 的虚拟 presentation 行追加到当前事件 presentation 数组；
#       4. 推进 presentation_index 到下一行（即过渡叙事第 1 屏，或末屏完成时切 confirm）。
#       新包启动延迟到事件结算后（见 _resolve_pending_turn 处理 reflection 事件结算）。
#       设计基线见 [[当前版本完整主路径_MVP设计]] §三·节点 2 "Step 2 实施落地细节"。
func confirm_reflection_location_select(location_id: String) -> Dictionary:
	if _is_world_ended():
		return _build_world_ended_response()
	var loc_id: String = location_id.strip_edges()
	if loc_id.is_empty():
		return {"ok": false, "error": "location_id is empty"}
	if _pending_turn_context.is_empty():
		return {"ok": false, "error": "no pending reflection event"}

	var phase: String = str(_pending_turn_context.get("phase", ""))
	if phase != "presentation":
		return {"ok": false, "error": "reflection location select requires presentation phase, current=%s" % phase}

	var event_id: String = str(_pending_turn_context.get("event_id", ""))
	var event_def: Dictionary = _event_map.get(event_id, {})
	if event_def.is_empty():
		return {"ok": false, "error": "pending event not found: %s" % event_id}
	if str(event_def.get("type", "")) != "reflection":
		return {"ok": false, "error": "current event is not reflection: %s" % event_id}

	# 需求 2：使用过滤后的列表（按 condition 过滤），与渲染侧的 presentation_index 对齐。
	var presentation_items: Array = _get_event_presentation_filtered(event_def)
	var current_index: int = int(_pending_turn_context.get("presentation_index", 0))
	if current_index < 0 or current_index >= presentation_items.size():
		return {"ok": false, "error": "presentation index out of range: %d" % current_index}
	var current_item: Dictionary = presentation_items[current_index]
	if str(current_item.get("presents", "text")) != "location_select":
		return {"ok": false, "error": "current presentation row is not location_select"}

	# Step 2 P2-2：校验地点合法 = 必须在 get_reflection_location_options() 当前候选集合内。
	# 不再复用 confirm_location_select 的"邻居图"语义——intro 模式候选来自全量地点（按
	# reflection_mode + visited_locations 过滤），与 UI 渲染按钮的来源一致，避免"UI 显示
	# 全量地点但确认按邻居拒绝"的状态错位。regular 模式 get_reflection_location_options
	# 内部仍用邻居图，行为不变。
	var allowed_options: Array = get_reflection_location_options()
	var valid: bool = false
	for opt_variant in allowed_options:
		var opt_dict: Dictionary = opt_variant
		if str(opt_dict.get("location_id", "")) == loc_id:
			valid = true
			break
	if not valid:
		var current_location: String = str(world_state.get("currentLocationId", ""))
		return {"ok": false, "error": "location %s is not in reflection options (current=%s, mode=%s)" % [
			loc_id, current_location, str(world_state.get("reflection_mode", ""))
		]}

	# 写 visited_locations（去重）+ 切 currentLocationId。
	var visited: Array = _array_or_empty(world_state.get("visited_locations", []))
	if not (loc_id in visited):
		visited.append(loc_id)
	world_state["visited_locations"] = visited
	world_state["currentLocationId"] = loc_id

	# 按 transition_text_pool 抽过渡叙事，追加为虚拟 presentation 行（_dynamic=true）。
	# 关键：追加目标是 raw event_def.presentation（含全部条件分支），而不是 presentation_items（已过滤）。
	# 历史 BUG：曾用 event_def["presentation"] = presentation_items 写回，把过滤后只剩命中 + fallback
	#       的列表覆盖了原 raw，导致下一次 sys_reflection 触发时 last_consumed_skeleton_event_id 切换到
	#       别的骨架，被丢失的 4 个 condition 差分行无可命中、又无 fallback → 整个 order=1 组静默跳过、
	#       p1 屏在 UI 上消失。修复后 raw 保留全部差分行，过滤每次重跑，跨次自省的 condition 差分稳定。
	var pool: Dictionary = _dict_or_empty(world_state.get("transitionTextPool", {}))
	var by_location: Dictionary = _dict_or_empty(pool.get("reflection_transition", {}))
	var transition_texts: Array = _array_or_empty(by_location.get(loc_id, []))
	if not transition_texts.is_empty():
		var max_seq: int = 0
		for it_var in presentation_items:
			var it: Dictionary = it_var
			max_seq = max(max_seq, int(it.get("order", 0)))
		# raw_presentation 是 event_def.presentation 的引用（GDScript Array 引用语义），
		# 直接 append 即原地修改 event_def，无需手动写回。
		var raw_presentation: Array = _get_event_presentation(event_def)
		for i in range(transition_texts.size()):
			var transition_row: Dictionary = {
				"id": "%s_transition_%d" % [event_id, i + 1],
				"order": max_seq + i + 1,
				"type": "text",
				"speaker": "",
				"text": str(transition_texts[i]),
				"presents": "text",
				"_dynamic": true
			}
			raw_presentation.append(transition_row)
			# 同步追加到本地 filtered 列表，让后续 next_index >= size 判断走对路径。
			# transition 行 condition 为空，下次 _get_event_presentation_filtered 重过滤时一定保留。
			presentation_items.append(transition_row)
		print("[自省] 末屏地点选择 %s → 追加过渡叙事 %d 条" % [loc_id, transition_texts.size()])
	else:
		print("[自省] 末屏地点选择 %s → 无对应过渡叙事池（pool=reflection_transition）" % loc_id)

	# 推进 presentation_index 到下一行；若已到末尾切 confirm phase。
	var next_index: int = current_index + 1
	_pending_turn_context["presentation_index"] = next_index
	if next_index >= presentation_items.size():
		_advance_pending_phase_after_presentation(event_def)

	return _build_pending_turn_response(_pending_turn_context)


# 功能：执行一个回合。
# 说明：若已有待处理事件，则继续推进当前阶段；否则先选出事件，再通过统一的待处理上下文完成展示、选择或确认。
func run_turn(selected_option_id: String = "") -> Dictionary:
	if events.is_empty():
		return {"ok": false, "error": "event pool is empty"}

	# 说明：若上一回合停在选择点，本回合只允许继续完成该待处理事件。
	if not _pending_turn_context.is_empty():
		return _resolve_pending_turn(selected_option_id)
	if _is_world_ended():
		return _build_world_ended_response()

	# 叙事包联动：run_turn 也需要检查包状态，防止绕过 preview_next_turn 时跳过地点选择和自省。
	if _is_pack_awaiting_location():
		return {"ok": false, "error": "pack awaiting location select, call confirm_location_select() first"}
	if _is_pack_finished():
		# 包已结束但尚未自省/清空，需要先经过 preview_next_turn 路由。
		return {"ok": false, "error": "pack finished, call preview_next_turn() to trigger reflection"}

	# 说明：执行回合前先自动接取任务，保证调度阶段读取到最新任务状态。
	_check_auto_accept_tasks()

	var next_event_result := _select_next_event()
	if not next_event_result.get("ok", false):
		return next_event_result

	var expected_forced := str(next_event_result.get("expected_forced", ""))
	var next_event_id := str(next_event_result.get("event_id", ""))
	var route := str(next_event_result.get("route", "scheduler"))
	var event_def: Dictionary = next_event_result.get("event_def", {})
	_pending_turn_context = _create_pending_turn_context(next_event_id, route, expected_forced, event_def)
	return _resolve_pending_turn(selected_option_id)

# 功能：处理待处理事件。
# 说明：根据 phase 推进展示阶段、选择阶段或确认阶段，并只在真正结算完成后推进 world_state 与回合数。
func _resolve_pending_turn(selected_option_id: String) -> Dictionary:
	var event_id := str(_pending_turn_context.get("event_id", ""))
	var route := str(_pending_turn_context.get("route", "scheduler"))
	var expected_forced := str(_pending_turn_context.get("expected_forced", ""))
	var phase := str(_pending_turn_context.get("phase", "confirm"))
	var resolution_mode := str(_pending_turn_context.get("resolution_mode", "event_effects"))
	var pending_has_choice := bool(_pending_turn_context.get("has_choice", false))
	var pending_choice: Dictionary = _dict_or_empty(_pending_turn_context.get("choice", {}))
	var event_def: Dictionary = _event_map.get(event_id, {})
	if event_def.is_empty():
		_pending_turn_context.clear()
		return {"ok": false, "error": "pending event not found: %s" % event_id}

	if phase == "presentation":
		# 说明：展示阶段只负责逐条推进展示文本，不执行事件效果，也不推进回合。
		# Step 2 P1-1：当前 presentation 行 presents=location_select 时拒绝普通 confirm，
		# 防止外部 Consumer 绕过 confirm_reflection_location_select 跳过地点选择 →
		# visited_locations 不写但后续仍启动新包的状态机错位。强制走专用 API。
		# 需求 2：使用过滤后的列表，与渲染侧的 presentation_index 对齐。
		var presentation_items := _get_event_presentation_filtered(event_def)
		var current_index: int = int(_pending_turn_context.get("presentation_index", 0))
		if current_index >= 0 and current_index < presentation_items.size():
			var current_pres_item: Dictionary = presentation_items[current_index]
			if str(current_pres_item.get("presents", "text")) == "location_select":
				return {
					"ok": false,
					"error": "current presentation is location_select; use confirm_reflection_location_select() instead",
					"phase": "presentation",
					"event_id": event_id
				}
		var next_index := current_index + 1
		if next_index < presentation_items.size():
			_pending_turn_context["presentation_index"] = next_index
		else:
			_advance_pending_phase_after_presentation(event_def)
			# Phase A 调优 1：reflection 事件含 location_select 行时，末屏推完自动结算，
			# 跳过 phase=confirm 多余等待玩家点击（玩家在末屏已选定地点，过渡叙事翻完后
			# 流程应自然衔接到下一包，不该再要求玩家点"确认结算"）。
			# sys_final_reflection 不含 location_select，保留 phase=confirm 等玩家确认结束 demo。
			if str(event_def.get("type", "")) == "reflection":
				var has_location_select := false
				for it_var in presentation_items:
					var it: Dictionary = it_var
					if str(it.get("presents", "")) == "location_select":
						has_location_select = true
						break
				if has_location_select:
					return _resolve_pending_turn(selected_option_id)
			# Phase A 调优 1（outcome 屏对称修复）：选项 outcome 屏推完后，选项结算已发生
			# （_apply_option_resolution + _apply_event_effects 在追加 outcome 前已执行），
			# outcome 屏只是世界对玩家选择的"叙事反馈"展示。末屏推完应自动结算进入下一事件，
			# 不该再要求玩家点"确认结算"——与 reflection 末屏自动结算逻辑对称。
			if bool(_pending_turn_context.get("_outcome_pending", false)):
				return _resolve_pending_turn(selected_option_id)
		return _build_pending_turn_response(_pending_turn_context)

	# 说明：处理心性风险入口挂起阶段。
	if phase == "preemptive_bet":
		return _resolve_preemptive_bet_phase(selected_option_id)
	if phase == "desperate_gamble":
		return _resolve_desperate_gamble_phase(selected_option_id)

	# 事件叙事反馈 MVP A：outcome 屏翻完后回到 phase=confirm 时，选项结算实际已发生
	# （_apply_option_resolution + _apply_event_effects 在追加 outcome 前已执行），此处
	# 直接走结算尾段，不重复跑选项结算流程。设计基线见 [[事件叙事反馈_MVP设计]]。
	if phase == "confirm" and bool(_pending_turn_context.get("_outcome_pending", false)):
		return _finalize_post_outcome_settlement(event_id, route, expected_forced, event_def)

	# P0-1 修复：在任何 _apply_*（可能触发链退出清空 chainContext）之前缓存 deferred 状态，
	# 供后续结算代码判断是否跳过 turn 推进和任务 tick。
	_pending_turn_context["_was_in_deferred_chain"] = _is_in_deferred_chain()

	# 功能：自省事件分支——将 confirm_pending_turn 的调用转发给自省状态机。
	# 说明：自省期间持续占据 pending_turn，每次 confirm 推进一步；SETTLED 后清除并推进回合。
	if phase == "reflection":
		return _resolve_reflection_phase(selected_option_id, event_id, route, expected_forced, event_def)

	var choice_result := pending_choice.duplicate(true)
	if resolution_mode == "choice_resolution":
		var choice_point_id := str(event_def.get("choicePointId", "")).strip_edges()
		if choice_point_id.is_empty():
			_pending_turn_context.clear()
			return {"ok": false, "error": "pending event has no choice point: %s" % event_id}

		var choice_point_def: Dictionary = _choice_point_map.get(choice_point_id, {})
		if choice_point_def.is_empty():
			_pending_turn_context.clear()
			return {"ok": false, "error": "pending choice point not found: %s" % choice_point_id}

		var options_eval := _build_option_set(choice_point_def)
		choice_result["options"] = _option_public_states(options_eval)

		if selected_option_id.strip_edges().is_empty():
			choice_result["resolved_by"] = "pending_external_selection"
			return _build_result_payload(
				route,
				event_id,
				event_def,
				expected_forced,
				true,
				true,
				choice_result
			)

		var selected := _select_option_by_id(options_eval, selected_option_id)
		if selected.is_empty():
			return {
				"ok": false,
				"error": "selected option is not selectable: %s" % selected_option_id,
				"event_id": event_id,
				"choice_point_id": choice_point_id,
				"options": choice_result["options"]
			}

		# 说明：与 run_turn 保持一致，只有在真正落地选项结果时才消费 forcedNextEventId。
		world_state["forcedNextEventId"] = ""
		choice_result["selected_option_id"] = str(selected.get("id", ""))
		choice_result["resolved_by"] = "option_resolution"
		# 事件叙事反馈 MVP A：缓存 selected option 用于结算后抽取 outcome 文本。
		_pending_turn_context["_settled_option"] = selected.duplicate(true)
		_apply_option_resolution(selected, event_def)
		# 说明：如果 _apply_option_resolution 挂起到风险入口阶段，直接返回等待决策。
		var post_phase := str(_pending_turn_context.get("phase", ""))
		if post_phase == "preemptive_bet" or post_phase == "desperate_gamble":
			return _build_pending_turn_response(_pending_turn_context)
		# 说明：正常选项路径不经过 _finalize_option_turn，需在此执行事件级 effects。
		_apply_event_effects(event_def)
		# 事件叙事反馈 MVP A：选项结算 + event_effects 应用完成后，尝试追加 outcome 叙事屏。
		# 若 selected option 配了 outcomes 文本，引擎将其作为 _dynamic=true 虚拟 presentation
		# 行追加到 event_def.presentation，切 phase=presentation 让玩家翻完后再走结算尾段。
		# 设计基线见 [[事件叙事反馈_MVP设计]]。
		if _try_append_option_outcomes_and_redirect(selected, event_def):
			return _build_pending_turn_response(_pending_turn_context)
	else:
		# 说明：普通事件、缺失选择点或无可选项事件，都在这里统一按事件默认效果结算。
		world_state["forcedNextEventId"] = ""
		_apply_event_effects(event_def)
		_apply_continuation_policy(event_def)

	# 说明：任务自动完成判定必须发生在"本回合结算动作完成后、任务到期推进前"。
	_eval_complete_when_after_settlement()
	_record_history(event_id)
	# 叙事包联动：使用缓存的 deferred 状态，避免链退出后 chainContext 被清空导致误判。
	var was_deferred := bool(_pending_turn_context.get("_was_in_deferred_chain", false))
	# Step 2：reflection 事件不算包内回合，不应推进 world turn / tick tasks / 推 packContext.turnsElapsed。
	# 走 _resolve_pending_turn confirm 分支的 reflection 事件即 demo 期 resolution_mode=event_effects
	# 的自省（presentation 全程驱动，无状态机）。老 resolution_mode=reflection 路径不经过此分支。
	var is_reflection: bool = str(event_def.get("type", "")) == "reflection"
	if not was_deferred and not is_reflection:
		_tick_tasks_after_turn()
	var ended_this_turn := false
	if bool(event_def.get("isEndingEvent", false)):
		_finalize_world(event_id)
		ended_this_turn = true
	if not ended_this_turn:
		if is_reflection:
			# 自省事件结算特化（Step 2 新增）：不推 turn，不推包内回合。
			# 若 presentation 含 presents=location_select 行 → 玩家在末屏已选定地点（由
			# confirm_reflection_location_select 写入 currentLocationId 与 visited_locations）→
			# 启动新包；否则（如最终自省）不启动新包，由调用方按 isEndingEvent 等机制收口。
			var triggers_new_pack: bool = false
			var pres_check: Array = _get_event_presentation(event_def)
			for it_var in pres_check:
				var it: Dictionary = it_var
				if str(it.get("presents", "")) == "location_select":
					triggers_new_pack = true
					break
			if triggers_new_pack:
				_clear_pack_context()
				_start_new_pack(str(world_state.get("currentLocationId", "")))
				print("[自省] 末屏地点选择闭环 → 启动新包 location=%s" % str(world_state.get("currentLocationId", "")))
		elif not was_deferred:
			world_state["turn"] = int(world_state.get("turn", 0)) + 1
			# 叙事包联动：推进包内回合计数。
			_advance_pack_turn()
		_pending_turn_context.clear()

	return _build_result_payload(
		route,
		event_id,
		event_def,
		expected_forced,
		false,
		pending_has_choice,
		choice_result
	)

# 功能：选择下一条事件路由并返回事件定义。
# 说明：该步骤只做选路，不产生副作用，便于"预览"和"直接执行"共用。
func _select_next_event() -> Dictionary:
	var expected_forced := str(world_state.get("forcedNextEventId", ""))
	var next_event_id := ""
	var route := "scheduler"

	# 第 1 段：消费外部 forcedNextEventId（如有）。
	# missing_event_def 视为配置错误，立即显式失败（避免事件被普通调度静默吞掉，参见行
	# 441/453 的"事件结算时清空 forcedNextEventId"逻辑）；location_mismatch 保留原行为
	# （forcedNextEventId 字段不动，落入下方普通调度——这条延迟语义在 demo 期由外部 forced
	# 的配置者自我约束）。
	if not expected_forced.is_empty():
		var resolved: Dictionary = _try_resolve_forced(expected_forced)
		if bool(resolved.get("eligible", false)):
			next_event_id = str(resolved.get("event_id", ""))
			route = "forced"
		elif str(resolved.get("reason", "")) == "missing_event_def":
			return {
				"ok": false,
				"error": "forcedNextEventId points to missing event: %s" % expected_forced
			}

	# 第 2 段：末尾位池抽取（设计基线见 [[当前版本完整主路径_MVP设计]] §三·节点 3）。
	# 触发条件：无外部 forced（不论延迟与否）+ 处于包末位 + packConfig 配置了池 tag。
	# 外部 forced 已存在（即便地点不匹配延迟）时不进入末位池，避免覆盖外部 forced 安排。
	# 池空时通过统一 forced 路径处理（地点校验 / 无地点容量 +1 复用）。
	# 收口事件命名建议：使用无 requiredLocations 的事件（如 chain 入口），避免落入"配地点
	# 但玩家不在该地点 → forced 字段无法保留"的脆弱路径。
	if next_event_id.is_empty() and expected_forced.is_empty():
		var pool_tag: String = str(_pack_config.get("final_event_pool_tag", "")).strip_edges()
		if not pool_tag.is_empty() and _is_at_pack_final_turn():
			if _is_final_pool_exhausted(pool_tag):
				var exhausted_id: String = str(_pack_config.get("final_event_pool_exhausted_forced_id", "")).strip_edges()
				if not exhausted_id.is_empty():
					# 先校验 eligibility 再 commit forcedNextEventId，避免无意义写入随后被
					# 普通事件结算清空（行 441/453）。
					var resolved_exhaust: Dictionary = _try_resolve_forced(exhausted_id)
					if bool(resolved_exhaust.get("eligible", false)):
						world_state["forcedNextEventId"] = exhausted_id
						next_event_id = str(resolved_exhaust.get("event_id", ""))
						route = "final_pool_exhausted_forced"
						print("[叙事包] 末尾位池 %s 已耗尽，切换 forced=%s" % [pool_tag, exhausted_id])
					elif str(resolved_exhaust.get("reason", "")) == "missing_event_def":
						return {
							"ok": false,
							"error": "final_event_pool_exhausted_forced_id points to missing event: %s" % exhausted_id
						}
					# location_mismatch：本回合让出走普通调度，下次进入末位再尝试匹配
			else:
				var location_boost: int = int(_pack_config.get("final_event_location_boost", 0))
				var pool_candidates: Array = _build_final_pool_candidates(pool_tag, location_boost)
				if not pool_candidates.is_empty():
					next_event_id = _weighted_pick(pool_candidates)
					route = "final_pool"
					print("[叙事包] 末尾位池 %s 抽取: %s（候选 %d 个）" % [
						pool_tag, next_event_id, pool_candidates.size()
					])

	if next_event_id.is_empty():
		var candidates := _build_candidates()
		if candidates.is_empty():
			next_event_id = _fallback_event_id()
			if next_event_id.is_empty():
				return {"ok": false, "error": "no eligible event and no fallback event"}
			route = "fallback"
		else:
			next_event_id = _weighted_pick(candidates)

	var event_def: Dictionary = _event_map.get(next_event_id, {})
	if event_def.is_empty():
		return {"ok": false, "error": "event not found: %s" % next_event_id}

	# Phase A 诊断日志：打印每个事件被选中的 ID 与路径，便于跑测时还原调度序列。
	# 普通调度（scheduler / fallback）此前无日志，导致第 2 包以后事件序列难以还原。
	var pack_ctx_dbg: Dictionary = _dict_or_empty(world_state.get("packContext", {}))
	var elapsed_dbg := int(pack_ctx_dbg.get("turnsElapsed", 0))
	var capacity_dbg := int(pack_ctx_dbg.get("turnCapacity", 0))
	var location_dbg := str(pack_ctx_dbg.get("locationId", ""))
	print("[调度] 选事件: %s | route=%s | location=%s | turn=%d/%d" % [
		next_event_id, route, location_dbg, elapsed_dbg + 1, capacity_dbg
	])

	return {
		"ok": true,
		"expected_forced": expected_forced,
		"event_id": next_event_id,
		"route": route,
		"event_def": event_def
	}


# 功能：尝试消费指定 forced 事件 ID，复用地点校验与无地点 forced 包容量 +1 联动。
# 说明：抽出原 _select_next_event 顶部的 forced 处理逻辑，供"外部 forcedNextEventId"
#       与"末尾位池空收口"两个入口共享。返回结构：
#         { eligible: bool, event_id: String, reason: String? }
#       eligible=false 时调用方应保留 forcedNextEventId 字段等待下回合再尝试，
#       不会触发包容量 +1（仅在事件实际进入处理时才推进容量）。
func _try_resolve_forced(forced_id: String) -> Dictionary:
	if forced_id.is_empty():
		return {"eligible": false, "reason": "empty_id"}
	var forced_def: Dictionary = _event_map.get(forced_id, {})
	if forced_def.is_empty():
		# 事件定义缺失：保留 forced 字段，由上层决定是否清空（避免静默丢失）。
		return {"eligible": false, "reason": "missing_event_def"}

	var forced_eligibility: Dictionary = forced_def.get("eligibility", {})
	var forced_locations: Array = forced_eligibility.get("requiredLocations", [])
	var current_loc: String = str(world_state.get("currentLocationId", ""))
	if not forced_locations.is_empty() and not (current_loc in forced_locations):
		print("[叙事包] forcedNext %s 地点不匹配（需要 %s，当前 %s），延迟触发" % [
			forced_id, str(forced_locations), current_loc
		])
		return {"eligible": false, "reason": "location_mismatch"}

	# 无地点约束的 forcedNext 事件插入时，包回合容量 +1（保留原有联动行为）。
	if forced_locations.is_empty():
		var pack_ctx: Dictionary = _dict_or_empty(world_state.get("packContext", {}))
		if not str(pack_ctx.get("locationId", "")).is_empty():
			pack_ctx["turnCapacity"] = int(pack_ctx.get("turnCapacity", 0)) + 1
			world_state["packContext"] = pack_ctx
			print("[叙事包] 无地点约束 forcedNext，包容量 +1")

	return {"eligible": true, "event_id": forced_id}


# 功能：创建事件待处理上下文。
# 说明：统一收束展示、选择、确认三个阶段的初始化逻辑，并提前计算选项可见性与可选性。
func _create_pending_turn_context(
	event_id: String,
	route: String,
	expected_forced: String,
	event_def: Dictionary
) -> Dictionary:
	var choice_result := {
		"choice_point_id": "",
		"selected_option_id": "",
		"resolved_by": "",
		"options": []
	}
	var resolution_mode := "event_effects"
	var has_choice := false
	var phase := "confirm"

	# 进入新一次事件前清除上次动态追加的虚拟 presentation 行（标记 _dynamic=true）：
	# - reflection 事件：confirm_reflection_location_select 追加的过渡叙事行
	# - 普通事件：选项结算后追加的 outcome 叙事屏（事件叙事反馈 MVP A）
	# 避免同一 event_id 跨次触发时虚拟行累积。该清理逻辑通用化于所有事件类型。
	var raw_pres: Array = event_def.get("presentation", [])
	var cleaned_pres: Array = []
	for raw_item_variant in raw_pres:
		var raw_item: Dictionary = raw_item_variant
		if not bool(raw_item.get("_dynamic", false)):
			cleaned_pres.append(raw_item)
	if cleaned_pres.size() != raw_pres.size():
		event_def["presentation"] = cleaned_pres
		_event_map[event_id] = event_def

	# 自省事件 resolution_mode 决策（Step 2 改造）：
	# - 老路径（reflection_state_machine）：presentation 含 adjust_relation / focus_* 时启用，
	#   或 presentation 为空（沿用旧 EMPTY_REFLECTION 逻辑）。
	# - 新路径（presentation 全程驱动）：presentation 仅含 text / location_select 时，与普通
	#   事件一致走 event_effects 路径；末屏 presents=location_select 由 main_game UI 层
	#   渲染同屏地点按钮，玩家选地点后引擎追加过渡叙事文本继续推进。设计基线见
	#   [[当前版本完整主路径_MVP设计]] §三·节点 2 "Step 2 实施落地细节"。
	var event_type := str(event_def.get("type", "")).strip_edges()
	if event_type == "reflection":
		var pres_items_for_check: Array = _get_event_presentation(event_def)
		var requires_state_machine: bool = pres_items_for_check.is_empty()
		for item_variant in pres_items_for_check:
			var item: Dictionary = item_variant
			var item_presents: String = str(item.get("presents", "text"))
			if item_presents == "adjust_relation" or item_presents == "focus_select" or item_presents == "focus_remove":
				requires_state_machine = true
				break
		if requires_state_machine:
			resolution_mode = "reflection"
			phase = "reflection"
		# else: demo 期典型路径——保持 resolution_mode = "event_effects"（默认），
		# presentation 走完直接结算，无需 reflection 状态机。

	var choice_point_id := str(event_def.get("choicePointId", "")).strip_edges()
	if not choice_point_id.is_empty():
		has_choice = true
		choice_result["choice_point_id"] = choice_point_id
		var choice_point_def: Dictionary = _choice_point_map.get(choice_point_id, {})
		if choice_point_def.is_empty():
			choice_result["resolved_by"] = "missing_choice_point_fallback_event_effects"
		else:
			var options_eval := _build_option_set(choice_point_def)
			choice_result["options"] = _option_public_states(options_eval)
			var first_selectable := _select_first_selectable(options_eval)
			if first_selectable.is_empty():
				choice_result["resolved_by"] = "no_selectable_option_fallback_event_effects"
			else:
				resolution_mode = "choice_resolution"
				choice_result["resolved_by"] = "pending_external_selection"
				phase = "choice"

	# 需求 2：使用过滤后的列表判断是否有 presentation 屏可展示。
	# 若 condition 全不满足（过滤后为空）则跳过 presentation 阶段（直接进 confirm/choice）。
	var presentation_items := _get_event_presentation_filtered(event_def)
	if not presentation_items.is_empty():
		phase = "presentation"

	# Phase A 诊断日志：事件初始化时打印 phase / resolution_mode / has_choice，
	# 定位"地点选择后首个填充事件 phase=confirm 而非 phase=choice"问题根因。
	print("[事件初始化] %s | phase=%s | resolution_mode=%s | has_choice=%s | resolved_by=%s" % [
		event_id, phase, resolution_mode, str(has_choice), str(choice_result.get("resolved_by", ""))
	])
	return {
		"event_id": event_id,
		"route": route,
		"expected_forced": expected_forced,
		"resolution_mode": resolution_mode,
		"has_choice": has_choice,
		"choice": choice_result,
		"policy": str(event_def.get("continuationPolicy", POLICY_RETURN)),
		"phase": phase,
		"presentation_index": 0
	}


# 功能：在展示阶段结束后切换到下一个可交互阶段。
# 说明：优先检测 reflection 模式；其次进入 choice；最后退回 confirm。
func _advance_pending_phase_after_presentation(event_def: Dictionary) -> void:
	var rm := str(_pending_turn_context.get("resolution_mode", "event_effects"))
	var next_phase := "confirm"
	# 事件叙事反馈 MVP A：outcome 屏翻完后 phase 必须切到 confirm（让 _outcome_pending 路由
	# 收口），即便 resolution_mode=choice_resolution（选项已结算）。无此守门会回到 phase=choice
	# 让 UI 重新显示选项。
	if bool(_pending_turn_context.get("_outcome_pending", false)):
		next_phase = "confirm"
	elif rm == "reflection":
		next_phase = "reflection"
	elif rm == "choice_resolution":
		next_phase = "choice"
		var choice_result: Dictionary = _dict_or_empty(_pending_turn_context.get("choice", {}))
		if choice_result.is_empty():
			next_phase = "confirm"
	# Phase A 诊断日志：phase 推进决策细节。
	print("[末屏推进] event=%s | resolution_mode=%s | next_phase=%s" % [
		str(event_def.get("id", "")), rm, next_phase
	])
	_pending_turn_context["phase"] = next_phase
	_pending_turn_context["presentation_index"] = 0


# 功能：读取事件展示配置（原始全量列表，含 _dynamic 虚拟行）。
# 说明：统一收束展示数据的空值处理，便于后续扩展更多展示类型。
# 注意：此函数返回未过滤的原始列表；渲染层应改用 _get_event_presentation_filtered，
#       后者会按 condition 字段过滤出满足 world_state 条件的行。
func _get_event_presentation(event_def: Dictionary) -> Array:
	var presentation: Variant = event_def.get("presentation", [])
	if typeof(presentation) == TYPE_ARRAY and presentation != null:
		return presentation
	return []


# 【CSV 契约边界】需求 2 — presentation condition 过滤入口。
# 来源：Design/配置翻译指南.md 锚点 presentation_condition。
# 过滤规则：
#   - 对同一 display_order 的多行（差分行组），先找满足 condition 的行，命中第一个即选用；
#   - 若同组内无行命中 condition，则选用 condition 为空的行（fallback 通用行）；
#   - 若同组内 condition 均为空（普通无差分行），直接保留该行不变（兼容旧数据）。
# condition 语法与 event_conditions.csv 的 weight_rule 表达式相同：
#   `<world_state_path> <op> "<value>"` 例：last_consumed_skeleton_event_id == "evt_s2_sk_he"
# 改动本函数时必须同步回看：配置翻译指南锚点 / csv_validator.py / 装配层 _apply_event_presentations。
func _get_event_presentation_filtered(event_def: Dictionary) -> Array:
	var raw: Array = _get_event_presentation(event_def)
	if raw.is_empty():
		return raw

	# 按 display_order 分组，确认各组是否存在 condition 字段（差分行组 vs 普通行）。
	# 使用 order → [items] 的字典进行分组。
	var groups: Dictionary = {}
	var order_seq: Array = []  # 保留 display_order 出现顺序
	for item_variant in raw:
		var item: Dictionary = item_variant
		var order: int = int(item.get("order", 0))
		if not groups.has(order):
			groups[order] = []
			order_seq.append(order)
		var arr: Array = groups[order]
		arr.append(item)

	var result: Array = []
	for order_variant in order_seq:
		var order: int = order_variant
		var group: Array = groups[order]

		# 判断该 order 组是否存在至少一个非空 condition（即为差分行组）。
		var has_any_condition := false
		for item_variant in group:
			var item: Dictionary = item_variant
			var cond := str(item.get("condition", "")).strip_edges()
			if not cond.is_empty():
				has_any_condition = true
				break

		if not has_any_condition:
			# 普通行：直接保留整组（通常只有 1 行，兼容旧数据）。
			for item_variant in group:
				result.append(item_variant)
			continue

		# 差分行组：先尝试找到第一个满足 condition 的行。
		var matched_item: Variant = null
		var fallback_item: Variant = null  # condition 为空的通用行
		for item_variant in group:
			var item: Dictionary = item_variant
			var cond := str(item.get("condition", "")).strip_edges()
			if cond.is_empty():
				# 记录 fallback 行（只保留最后一个，通常只有一个）。
				fallback_item = item
			elif matched_item == null and _evaluate_condition(cond):
				matched_item = item

		# 命中优先，无命中走 fallback，两者均无则跳过该 order（避免引入空行）。
		if matched_item != null:
			result.append(matched_item)
		elif fallback_item != null:
			result.append(fallback_item)
		# 若 condition 全不满足且无 fallback，该屏被静默跳过。
	return result


# 功能：构建返回给 Consumer 的展示阶段状态。
# 说明：Consumer 只消费当前展示项和索引信息，不直接解析事件定义原始结构。
func _build_presentation_state(event_def: Dictionary, phase: String) -> Dictionary:
	# 需求 2：渲染侧使用过滤后的列表，确保 total / index / current_item 均基于
	# 按 condition 过滤后实际展示给玩家的行集合。
	var presentation_items := _get_event_presentation_filtered(event_def)
	var state := {
		"active": false,
		"index": -1,
		"total": presentation_items.size(),
		"current_item": {}
	}
	if presentation_items.is_empty():
		return state
	# Phase A 调优 1：phase=choice / reflection / 等阶段也暴露末屏 presentation 作 current_item，
	# 让 UI 在选项 / 自省按钮组等同屏渲染时仍能显示末屏叙事文本。
	# active 字段仅在 phase=presentation 时为 true（保留原"是否需要继续翻页"语义）。
	var current_index: int
	if phase == "presentation":
		current_index = clampi(int(_pending_turn_context.get("presentation_index", 0)), 0, presentation_items.size() - 1)
		state["active"] = true
	else:
		current_index = presentation_items.size() - 1
		state["active"] = false
	state["index"] = current_index
	state["current_item"] = presentation_items[current_index]
	return state

# 功能：构建待处理事件的统一返回结构。
# 说明：预览态、展示态、待选择态都复用此函数，避免界面层依赖多套字段格式。
func _build_pending_turn_response(pending_context: Dictionary) -> Dictionary:
	var event_id := str(pending_context.get("event_id", ""))
	var route := str(pending_context.get("route", "scheduler"))
	var expected_forced := str(pending_context.get("expected_forced", ""))
	var has_choice := bool(pending_context.get("has_choice", false))
	var resolution_mode := str(pending_context.get("resolution_mode", "event_effects"))
	var phase := str(pending_context.get("phase", "confirm"))
	var event_def: Dictionary = _event_map.get(event_id, {})
	if event_def.is_empty():
		return {"ok": false, "error": "pending event not found: %s" % event_id}

	var choice_result: Dictionary = _dict_or_empty(pending_context.get("choice", {})).duplicate(true)
	# 说明：心性风险入口阶段和自省阶段也视为等待外部决策。
	var awaiting_choice := (phase == "choice" and resolution_mode == "choice_resolution") or phase == "preemptive_bet" or phase == "desperate_gamble" or phase == "reflection"
	if awaiting_choice and choice_result.is_empty():
		choice_result = {
			"choice_point_id": str(event_def.get("choicePointId", "")),
			"selected_option_id": "",
			"resolved_by": "pending_external_selection",
			"options": []
		}

	return _build_result_payload(
		route,
		event_id,
		event_def,
		expected_forced,
		awaiting_choice,
		has_choice,
		choice_result
	)

# 功能：构建统一的回合结果字典。
# 说明：集中维护界面依赖字段，并额外暴露 phase 与 presentation 状态，避免不同执行路径返回结构漂移。
func _build_result_payload(
	route: String,
	event_id: String,
	event_def: Dictionary,
	expected_forced: String,
	awaiting_choice: bool,
	has_choice: bool,
	choice_result: Dictionary
) -> Dictionary:
	_ensure_run_state()
	var run_state_payload := _build_run_state_payload()
	var phase := "resolved"
	if not _pending_turn_context.is_empty() and str(_pending_turn_context.get("event_id", "")) == event_id:
		phase = str(_pending_turn_context.get("phase", "confirm"))
	elif awaiting_choice:
		phase = "choice"
	var presentation_state := _build_presentation_state(event_def, phase)
	var result: Dictionary = {
		"ok": true,
		"phase": phase,
		"awaiting_choice": awaiting_choice,
		"route": route,
		"event_id": event_id,
		"title": str(event_def.get("title", "")),
		"event_background_art": str(event_def.get("backgroundArt", "")),
		"location_background_art": _resolve_location_background_art(),
		"resolved_background_art": _resolve_background_art(event_def),
		"policy": str(event_def.get("continuationPolicy", POLICY_RETURN)),
		"expected_forced": expected_forced,
		"chain_active": not (world_state.get("chainContext", null) == null),
		"has_choice": has_choice,
		"presentation": presentation_state,
		"choice": choice_result,
		"xinxing": _get_current_xinxing(),
		"xinxing_risk_profile": RuleEngine.get_xinxing_risk_profile(_get_current_xinxing()),
		"check_result": _last_check_result.duplicate(true),
		"affinity_changes": _last_affinity_changes.duplicate(true),
		"xinxing_transition": _last_xinxing_transition.duplicate(true),
		"world_ended": bool(run_state_payload.get("world_ended", false)),
		"run_status": str(run_state_payload.get("run_status", "running")),
		"ending_event_id": str(run_state_payload.get("ending_event_id", "")),
		"finished_turn": int(run_state_payload.get("finished_turn", 0))
	}
	# 功能：自省阶段附加状态机信息，供 UI 渲染自省交互界面。
	if phase == "reflection" and not _pending_turn_context.is_empty():
		var ref_result: Dictionary = _dict_or_empty(_pending_turn_context.get("reflection_result", {}))
		result["reflection_state"] = str(ref_result.get("state", ""))
		result["reflection_actions"] = ref_result.get("available_actions", [])
		result["reflection_ops_remaining"] = int(ref_result.get("ops_remaining", 0))
		# 透传状态机返回的附加数据（query_result、op_result 等）。
		var extra_keys: Array = ["query_result", "op_result", "added_focus", "removed_focus", "pending_add", "text", "skipped", "settled"]
		for key in extra_keys:
			if ref_result.has(key):
				if not result.has("reflection_extra"):
					result["reflection_extra"] = {}
				result["reflection_extra"][key] = ref_result[key]
	return result

# 功能：确保世界运行态结构完整。
# 说明：兼容旧存档、旧测试数据与未包含 runState 的输入，统一补齐 ended 所需字段。
func _ensure_run_state() -> void:
	var run_state := _dict_or_empty(world_state.get("runState", {}))
	var status := str(run_state.get("status", "running")).strip_edges()
	if status.is_empty():
		status = "running"
	run_state["status"] = status
	run_state["endingEventId"] = str(run_state.get("endingEventId", "")).strip_edges()
	run_state["finishedTurn"] = maxi(0, int(run_state.get("finishedTurn", 0)))
	world_state["runState"] = run_state


# 功能：将当前世界标记为结束态。
# 说明：ending event 完成最终结算后调用，负责写入 ended 状态并清理执行锁与待处理上下文。
func _finalize_world(ending_event_id: String) -> void:
	_ensure_run_state()
	var run_state := _dict_or_empty(world_state.get("runState", {}))
	run_state["status"] = "ended"
	run_state["endingEventId"] = ending_event_id.strip_edges()
	run_state["finishedTurn"] = int(world_state.get("turn", 0))
	world_state["runState"] = run_state
	world_state["forcedNextEventId"] = ""
	world_state["chainContext"] = null
	_pending_turn_context.clear()


# 功能：判断当前世界是否已进入结束态。
# 说明：所有对外入口统一通过这里读取 runState.status，避免重复拼接 ended 判定。
func _is_world_ended() -> bool:
	_ensure_run_state()
	var run_state := _dict_or_empty(world_state.get("runState", {}))
	return str(run_state.get("status", "running")).strip_edges() == "ended"


# 功能：构建对外暴露的最小结束态字段。
# 说明：统一 world ended 的公开字段名，避免 payload 与 ended 短路返回之间出现结构漂移。
func _build_run_state_payload() -> Dictionary:
	_ensure_run_state()
	var run_state := _dict_or_empty(world_state.get("runState", {}))
	var status := str(run_state.get("status", "running")).strip_edges()
	return {
		"world_ended": status == "ended",
		"run_status": status,
		"ending_event_id": str(run_state.get("endingEventId", "")).strip_edges(),
		"finished_turn": maxi(0, int(run_state.get("finishedTurn", 0)))
	}


# 功能：在世界已结束时返回稳定结果。
# 说明：结束不是异常；后续入口统一返回 ended 状态，方便外部流程直接消费而不是走报错分支。
func _build_world_ended_response() -> Dictionary:
	var run_state_payload := _build_run_state_payload()
	return {
		"ok": true,
		"phase": "ended",
		"awaiting_choice": false,
		"route": "ended",
		"event_id": "",
		"title": "",
		"event_background_art": "",
		"location_background_art": _resolve_location_background_art(),
		"resolved_background_art": "",
		"policy": "",
		"expected_forced": "",
		"chain_active": false,
		"has_choice": false,
		"presentation": {
			"active": false,
			"index": -1,
			"total": 0,
			"current_item": {}
		},
		"choice": {
			"choice_point_id": "",
			"selected_option_id": "",
			"resolved_by": "world_ended",
			"options": []
		},
		"xinxing": _get_current_xinxing(),
		"xinxing_risk_profile": RuleEngine.get_xinxing_risk_profile(_get_current_xinxing()),
		"world_ended": bool(run_state_payload.get("world_ended", true)),
		"run_status": str(run_state_payload.get("run_status", "ended")),
		"ending_event_id": str(run_state_payload.get("ending_event_id", "")),
		"finished_turn": int(run_state_payload.get("finished_turn", 0))
	}


# 功能：设置引擎当前使用的地点图。
# 说明：用于解析当前地点对应的默认背景路径，供事件背景缺失时兜底。
func _set_location_graph(location_graph: Variant) -> void:
	if location_graph is LocationGraph:
		_location_graph = location_graph
	else:
		_location_graph = null

# 功能：解析事件最终应展示的背景路径。
# 说明：规则为"事件背景优先，地点背景兜底"；引擎统一产出，Consumer 不再自行判断。
func _resolve_background_art(event_def: Dictionary) -> String:
	var event_background_art := str(event_def.get("backgroundArt", "")).strip_edges()
	if not event_background_art.is_empty():
		return event_background_art
	return _resolve_location_background_art()

# 功能：解析当前地点的背景路径。
# 说明：若地点图缺失或地点未配置背景，则返回空字符串。
func _resolve_location_background_art() -> String:
	if _location_graph == null:
		return ""
	var current_location_id := str(world_state.get("currentLocationId", "")).strip_edges()
	if current_location_id.is_empty():
		return ""
	return _location_graph.get_art_path(current_location_id)

# 功能：重建事件索引。
# 说明：将 events 数组映射为 {event_id: event_def}，供 O(1) 查询。
func _rebuild_event_map() -> void:
	_event_map.clear()
	for event_variant in events:
		var event_def: Dictionary = event_variant
		var event_id := str(event_def.get("id", ""))
		if event_id.is_empty():
			continue
		_event_map[event_id] = event_def

# 功能：重建选择点索引。
# 说明：将 choice_points 映射为 {choice_point_id: choice_point_def}。
func _rebuild_choice_point_map() -> void:
	_choice_point_map.clear()
	for choice_variant in choice_points:
		var choice_def: Dictionary = choice_variant
		var choice_id := str(choice_def.get("id", "")).strip_edges()
		if choice_id.is_empty():
			continue
		_choice_point_map[choice_id] = choice_def


# 功能：重建任务定义索引。
# 说明：将 task_defs 映射为 {task_id: task_def}，供任务动作 O(1) 查询。
func _rebuild_task_def_map() -> void:
	_task_def_map.clear()
	for task_variant in task_defs:
		var task_def: Dictionary = task_variant
		var task_id := str(task_def.get("id", "")).strip_edges()
		if task_id.is_empty():
			continue
		_task_def_map[task_id] = task_def


# 功能：按 task_id 构建任务评价配置索引。
# 说明：将 grades/indicators/overrides/effects 预分组，降低结算阶段的遍历开销。
func _rebuild_task_evaluation_index() -> void:
	_task_eval_index_by_task.clear()
	var grades: Array = _array_or_empty(task_evaluation.get("grades", []))
	var indicators: Array = _array_or_empty(task_evaluation.get("indicators", []))
	var grade_overrides: Array = _array_or_empty(task_evaluation.get("gradeOverrides", []))
	var effects: Array = _array_or_empty(task_evaluation.get("effects", []))

	for grade_variant in grades:
		var grade: Dictionary = _dict_or_empty(grade_variant)
		var task_id := str(grade.get("taskId", "")).strip_edges()
		if task_id.is_empty():
			continue
		var bucket := _ensure_task_eval_bucket(task_id)
		var grade_rows: Array = _array_or_empty(bucket.get("grades", []))
		grade_rows.append(grade)
		bucket["grades"] = grade_rows
		var mode := str(grade.get("gradeMode", "")).strip_edges().to_lower()
		if mode == "score_band":
			var score_bands: Array = _array_or_empty(bucket.get("scoreBands", []))
			score_bands.append(grade)
			_sort_grade_score_bands_by_min(score_bands)
			bucket["scoreBands"] = score_bands
		_task_eval_index_by_task[task_id] = bucket

	for indicator_variant in indicators:
		var indicator: Dictionary = _dict_or_empty(indicator_variant)
		var task_id := str(indicator.get("taskId", "")).strip_edges()
		if task_id.is_empty():
			continue
		var bucket := _ensure_task_eval_bucket(task_id)
		var indicator_rows: Array = _array_or_empty(bucket.get("indicators", []))
		indicator_rows.append(indicator)
		bucket["indicators"] = indicator_rows
		_task_eval_index_by_task[task_id] = bucket

	for override_variant in grade_overrides:
		var override_row: Dictionary = _dict_or_empty(override_variant)
		var task_id := str(override_row.get("taskId", "")).strip_edges()
		if task_id.is_empty():
			continue
		var bucket := _ensure_task_eval_bucket(task_id)
		var override_rows: Array = _array_or_empty(bucket.get("gradeOverrides", []))
		override_rows.append(override_row)
		_sort_grade_overrides_by_priority_desc(override_rows)
		bucket["gradeOverrides"] = override_rows
		_task_eval_index_by_task[task_id] = bucket

	for effect_variant in effects:
		var effect: Dictionary = _dict_or_empty(effect_variant)
		var task_id := str(effect.get("taskId", "")).strip_edges()
		if task_id.is_empty():
			continue
		var bucket := _ensure_task_eval_bucket(task_id)
		var effect_rows: Array = _array_or_empty(bucket.get("effects", []))
		effect_rows.append(effect)
		bucket["effects"] = effect_rows
		_task_eval_index_by_task[task_id] = bucket


# 功能：确保 task 评价索引桶存在并返回副本。
# 说明：桶结构固定，避免后续结算阶段频繁判空分支。
func _ensure_task_eval_bucket(task_id: String) -> Dictionary:
	var normalized_id := task_id.strip_edges()
	if normalized_id.is_empty():
		return {}
	if _task_eval_index_by_task.has(normalized_id):
		return _dict_or_empty(_task_eval_index_by_task.get(normalized_id, {}))
	return {
		"grades": [],
		"scoreBands": [],
		"indicators": [],
		"gradeOverrides": [],
		"effects": []
	}


# 功能：按 minScore 升序排序 score_band 档位。
# 说明：后续基础档位映射按区间顺序匹配，排序可减少比较歧义。
func _sort_grade_score_bands_by_min(score_bands: Array) -> void:
	for i in range(1, score_bands.size()):
		var current: Dictionary = _dict_or_empty(score_bands[i])
		var current_min := float(current.get("minScore", 0.0))
		var j := i - 1
		while j >= 0:
			var left: Dictionary = _dict_or_empty(score_bands[j])
			if float(left.get("minScore", 0.0)) <= current_min:
				break
			score_bands[j + 1] = score_bands[j]
			j -= 1
		score_bands[j + 1] = current


# 功能：按 priority 降序排序档位分流规则。
# 说明：运行时遇到首个命中规则即终止，需保证高优先级在前。
func _sort_grade_overrides_by_priority_desc(grade_overrides: Array) -> void:
	for i in range(1, grade_overrides.size()):
		var current: Dictionary = _dict_or_empty(grade_overrides[i])
		var current_priority := int(current.get("priority", 0))
		var j := i - 1
		while j >= 0:
			var left: Dictionary = _dict_or_empty(grade_overrides[j])
			if int(left.get("priority", 0)) >= current_priority:
				break
			grade_overrides[j + 1] = grade_overrides[j]
			j -= 1
		grade_overrides[j + 1] = current

# 功能：生成候选事件集合。
# 说明：这里只做可用性与权重计算，不做最终抽签。
#       Phase A 增加 3 项调度可见性守门（仅作用于普通调度路径，forced / final_pool 路径不受影响）：
#         1) reflection 事件仅 forced/包结束自动注入路径触发，普通调度排除
#         2) 末位池骨架（tag 含 final_event_pool_tag）仅末位池路径触发
#         3) ChainContinue 策略事件（chain 入口与 chain 内屏）仅 chainContext 已激活时可见；
#            chain 入口本就靠 final_event_pool_exhausted_forced_id 走 forced 路径，
#            chain 内屏由 chainContext.allowedTags 过滤继续工作。
#       设计基线见 [[当前版本完整主路径_MVP设计]] §三·节点 3 末尾位骨架抽取规则 + §四·改造清单。
func _build_candidates() -> Array:
	var out: Array = []
	var pool_tag: String = str(_pack_config.get("final_event_pool_tag", "")).strip_edges()
	var chain_active: bool = (world_state.get("chainContext", null) != null)
	for event_variant in events:
		var event_def: Dictionary = event_variant
		# 守门 1：reflection 类型事件普通调度排除。
		var event_type := str(event_def.get("type", "")).strip_edges()
		if event_type == "reflection":
			continue
		# 守门 2：末位池骨架普通调度排除（仅 final_pool 路径走）。
		if not pool_tag.is_empty():
			var event_tags_pool: Array = event_def.get("tags", [])
			if pool_tag in event_tags_pool:
				continue
		# 守门 3：ChainContinue 策略事件需 chainContext 激活才可见。
		var policy := str(event_def.get("continuationPolicy", "")).strip_edges()
		if (policy == "ChainContinue" or policy == "ChainContinueWithForcedNext") and not chain_active:
			continue
		# 守门 4：REQ-001 包内硬去重（2026-05-09）—— 当前包内已 played 的事件硬排除，
		#   避免同包内同一 event_id 重复触发。跨包仍可重复（体现叙事日常性）。
		#   仅作用普通调度路径；forced / final_pool 路径不受影响（不经过本函数）。
		var pack_ctx_dedup: Dictionary = _dict_or_empty(world_state.get("packContext", {}))
		var played_in_pack: Array = pack_ctx_dedup.get("played_events", [])
		if str(event_def.get("id", "")) in played_in_pack:
			continue
		if _is_event_eligible(event_def):
			var weight := _compute_weight(event_def)
			out.append({"id": str(event_def.get("id", "")), "weight": weight})
	return out


# 功能：判断当前是否处于包末位回合（即将处理的事件是包内最后一回合）。
# 说明：在 _select_next_event 中用于决定是否走末尾位池抽取分支。
#       条件：处于活动包（locationId 非空）+ turnsElapsed + 1 == turnCapacity。
#       _advance_pack_turn 在事件结算后才递增 turnsElapsed，因此调度阶段读到的值
#       表示"已处理回合数"，下一回合 = elapsed + 1。
func _is_at_pack_final_turn() -> bool:
	var pack_ctx: Dictionary = _dict_or_empty(world_state.get("packContext", {}))
	if str(pack_ctx.get("locationId", "")).is_empty():
		return false
	var elapsed := int(pack_ctx.get("turnsElapsed", 0))
	var capacity := int(pack_ctx.get("turnCapacity", 0))
	return capacity > 0 and elapsed + 1 == capacity


# 功能：读取指定末尾位池 tag 的已消耗事件列表。
# 说明：world_state.finalEventPoolConsumed 结构 { tag → [event_id, ...] }；不存在或非数组返回空列表。
func _get_final_pool_consumed_list(pool_tag: String) -> Array:
	if pool_tag.is_empty():
		return []
	var all_consumed: Dictionary = _dict_or_empty(world_state.get("finalEventPoolConsumed", {}))
	var raw: Variant = all_consumed.get(pool_tag, [])
	if typeof(raw) == TYPE_ARRAY and raw != null:
		return raw
	return []


# 功能：构建末尾位池候选事件列表。
# 说明：从 events 中筛选 tags 含 pool_tag 的事件，排除已消耗 + 不通过 eligibility 的。
#       权重在 _compute_weight 基础上叠加 location_boost（事件 requiredLocations 含当前地点时）。
#       注意 boost 的实际生效面：_is_event_eligible 已对配置了 requiredLocations 但不匹配当前地点
#       的事件做硬过滤，因此 boost 不会出现在"地点不匹配候选"上。boost 仅在以下情形真正起效：
#         1) 事件 requiredLocations 含多个地点且当前地点是其中之一 —— 优先于"全场可触发"事件；
#         2) 事件未配置 requiredLocations（全场可触发）—— 不获 boost，权重不变。
#       当前 4 地点-4 骨架 1:1 映射下，每个末位回合候选退化为唯一可触发的当地骨架，效果等价"必触当地"。
func _build_final_pool_candidates(pool_tag: String, location_boost: int) -> Array:
	var consumed: Array = _get_final_pool_consumed_list(pool_tag)
	var current_location := str(world_state.get("currentLocationId", ""))
	var out: Array = []
	for event_variant in events:
		var event_def: Dictionary = event_variant
		var event_id := str(event_def.get("id", ""))
		if event_id.is_empty():
			continue
		var event_tags: Array = event_def.get("tags", [])
		if not (pool_tag in event_tags):
			continue
		if event_id in consumed:
			continue
		if not _is_event_eligible(event_def):
			continue
		var weight := _compute_weight(event_def)
		var eligibility: Dictionary = event_def.get("eligibility", {})
		var required_locations: Array = eligibility.get("requiredLocations", [])
		if not required_locations.is_empty() and current_location in required_locations:
			weight += location_boost
		out.append({"id": event_id, "weight": weight})
	return out


# 功能：检查指定末尾位池 tag 是否已被全部消耗。
# 说明：用于"池空降级"判定。返回 true 表示该 tag 下所有事件均已记入消耗集合（无剩余可抽）。
#       仅按 tag 匹配判定，不考虑 eligibility（永远不满足条件的事件不应进池）。
func _is_final_pool_exhausted(pool_tag: String) -> bool:
	if pool_tag.is_empty():
		return false
	var consumed: Array = _get_final_pool_consumed_list(pool_tag)
	for event_variant in events:
		var event_def: Dictionary = event_variant
		var event_id := str(event_def.get("id", ""))
		if event_id.is_empty():
			continue
		var event_tags: Array = event_def.get("tags", [])
		if not (pool_tag in event_tags):
			continue
		if not (event_id in consumed):
			return false
	return true


# 功能：将事件 ID 标记到指定末尾位池 tag 的消耗集合中。
# 说明：写入 world_state.finalEventPoolConsumed[pool_tag]，去重；空参数直接返回。
func _mark_final_pool_consumed(pool_tag: String, event_id: String) -> void:
	if pool_tag.is_empty() or event_id.is_empty():
		return
	var all_consumed: Dictionary = _dict_or_empty(world_state.get("finalEventPoolConsumed", {}))
	var raw: Variant = all_consumed.get(pool_tag, [])
	var list: Array = []
	if typeof(raw) == TYPE_ARRAY and raw != null:
		list = raw
	if event_id in list:
		return
	list.append(event_id)
	all_consumed[pool_tag] = list
	world_state["finalEventPoolConsumed"] = all_consumed
	# Step 2 联动：同步写 last_consumed_skeleton_event_id 供中段自省 presentation 差分。
	# 字段名沿用 MVP 设计文档（"skeleton" 暗示骨架场景），实际任意末位池消耗都会写；
	# 未来若需要按 tag 区分差分键，可改为按 tag 分组（{ tag → last_id }）的字典结构。
	world_state["last_consumed_skeleton_event_id"] = event_id
	print("[叙事包] 末尾位池 %s 标记消耗: %s（累计 %d）" % [pool_tag, event_id, list.size()])


# 功能：导出当前候选事件权重快照。
# 说明：仅用于调试/测试，不改变世界状态。
func debug_get_candidate_weights() -> Dictionary:
	var candidates := _build_candidates()
	var weights: Dictionary = {}
	for candidate_variant in candidates:
		var candidate: Dictionary = candidate_variant
		var event_id := str(candidate.get("id", "")).strip_edges()
		if event_id.is_empty():
			continue
		weights[event_id] = int(candidate.get("weight", 1))
	return {
		"ok": true,
		"weights": weights,
		"candidates": candidates
	}

# 功能：执行事件硬约束过滤。
# 说明：地点、地点状态、世界级 flag、NPC 在场、链 allowedTags 任一不满足即排除。
func _is_event_eligible(event_def: Dictionary) -> bool:
	var eligibility: Dictionary = event_def.get("eligibility", {})
	var current_location := str(world_state.get("currentLocationId", ""))

	# 说明：地点硬过滤。
	var required_locations: Array = eligibility.get("requiredLocations", [])
	if not required_locations.is_empty() and not (current_location in required_locations):
		return false

	# 说明：地点状态硬过滤。
	var location_state_all: Dictionary = world_state.get("locationState", {})
	var current_location_state: Dictionary = location_state_all.get(current_location, {})
	var required_location_flags: Array = eligibility.get("requiredLocationFlags", [])
	for clause_variant in required_location_flags:
		var clause: Dictionary = clause_variant
		var key := str(clause.get("key", ""))
		var op := str(clause.get("op", "=="))
		var expected: Variant = clause.get("value", 0)
		var actual: Variant = current_location_state.get(key, null)
		if not _compare_values(actual, op, expected):
			return false

	# 说明：世界级硬过滤，通过点路径从 world_state 根开始解析（与 weight_rule 共用路径约定）。
	var required_flags: Array = eligibility.get("requiredFlags", [])
	for flag_clause_variant in required_flags:
		var flag_clause: Dictionary = flag_clause_variant
		var flag_key := str(flag_clause.get("key", ""))
		var flag_op := str(flag_clause.get("op", "=="))
		var flag_expected: Variant = flag_clause.get("value", 0)
		var flag_actual: Variant = _resolve_path_value(flag_key)
		if not _compare_values(flag_actual, flag_op, flag_expected):
			return false

	# 说明：NPC 在场硬过滤。
	var required_npcs: Array = eligibility.get("requiredNPCsPresent", [])
	if not required_npcs.is_empty():
		var npc_presence_all: Dictionary = world_state.get("npcPresence", {})
		var present_list: Array = npc_presence_all.get(current_location, [])
		for npc_id_variant in required_npcs:
			var npc_id := str(npc_id_variant)
			if not (npc_id in present_list):
				return false

	# 说明：链上下文额外过滤。
	var chain_context: Variant = world_state.get("chainContext", null)
	if typeof(chain_context) == TYPE_DICTIONARY and chain_context != null:
		var chain_dict: Dictionary = chain_context
		var allowed_tags: Array = chain_dict.get("allowedTags", [])
		if not allowed_tags.is_empty():
			var event_tags: Array = event_def.get("tags", [])
			if not _array_has_any(event_tags, allowed_tags):
				return false

	return true

# 功能：计算单个事件当前权重。
# 说明：综合 baseWeight、weightRules、历史惩罚、链式 tag 偏置与任务偏置。
func _compute_weight(event_def: Dictionary) -> int:
	var weight := int(event_def.get("baseWeight", 10))

	var rules: Array = event_def.get("weightRules", [])
	for rule_variant in rules:
		var rule: Dictionary = rule_variant
		var condition := str(rule.get("when", "")).strip_edges()
		if condition.is_empty():
			continue
		if _evaluate_condition(condition):
			weight += int(rule.get("delta", 0))

	# 说明：历史去重偏置，近期出现过的事件会轻微降权。
	var history: Array = world_state.get("history", [])
	if str(event_def.get("id", "")) in history:
		weight -= 3

	# 说明：链上下文偏置，通过 tag 映射提高链内事件权重。
	var chain_context: Variant = world_state.get("chainContext", null)
	if typeof(chain_context) == TYPE_DICTIONARY and chain_context != null:
		var chain_dict: Dictionary = chain_context
		var tag_bias: Dictionary = chain_dict.get("weightBias", {})
		var event_tags: Array = event_def.get("tags", [])
		for tag_variant in event_tags:
			var tag := str(tag_variant)
			if tag_bias.has(tag):
				weight += int(tag_bias[tag])

	# 说明：任务偏置由 event.taskLinks 与 active tasks 共同决定，只影响软权重。
	weight += _compute_task_bias(event_def)

	if weight < 1:
		return 1
	return weight


# 功能：计算任务偏置总和。
# 说明：同一事件可命中多个 taskLinks，并与并行 active 任务叠加。
func _compute_task_bias(event_def: Dictionary) -> int:
	var links := _array_or_empty(event_def.get("taskLinks", []))
	if links.is_empty():
		return 0

	var active_task_ids := _build_active_task_id_set()
	if active_task_ids.is_empty():
		return 0

	var bias := 0
	for link_variant in links:
		var parsed := _parse_task_link(str(link_variant))
		if parsed.is_empty():
			continue
		var task_id := str(parsed.get("taskId", ""))
		var link_type := str(parsed.get("type", ""))
		if task_id.is_empty() or link_type.is_empty():
			continue
		if not active_task_ids.has(task_id):
			continue
		bias += _get_task_bias_value(link_type)
	return bias


# 功能：构建 active 任务 ID 集合。
# 说明：用于在权重阶段快速判断某 task_id 是否处于 active 状态。
func _build_active_task_id_set() -> Dictionary:
	var out: Dictionary = {}
	var tasks_state := _dict_or_empty(world_state.get("tasks", {}))
	var active := _array_or_empty(tasks_state.get("active", []))
	for runtime_variant in active:
		var task_runtime := _dict_or_empty(runtime_variant)
		var task_id := str(task_runtime.get("taskId", "")).strip_edges()
		if task_id.is_empty():
			continue
		out[task_id] = true
	return out


# 功能：解析 taskLinks 单项语义。
# 说明：仅识别 advance:<task_id> 与 risk:<task_id>，其余值忽略。
func _parse_task_link(raw_link: String) -> Dictionary:
	var text := raw_link.strip_edges()
	if text.is_empty():
		return {}
	var pair := text.split(":", false, 1)
	if pair.size() != 2:
		return {}
	var link_type := str(pair[0]).strip_edges().to_lower()
	var task_id := str(pair[1]).strip_edges()
	if task_id.is_empty():
		return {}
	if link_type != "advance" and link_type != "risk":
		return {}
	return {
		"type": link_type,
		"taskId": task_id
	}


# 功能：返回单条任务链接的偏置值。
# 说明：当前 MVP 先使用固定默认值；后续可按 weightBiasProfile 继续扩展。
func _get_task_bias_value(link_type: String) -> int:
	var normalized_type := link_type.strip_edges().to_lower()
	if normalized_type == "advance":
		return TASK_BIAS_ADVANCE_DEFAULT
	if normalized_type == "risk":
		return TASK_BIAS_RISK_DEFAULT
	return 0

# 功能：解析并执行简单条件表达式。
# 说明：格式为 "<path> <op> <literal>"，支持 >= <= == != > <。
func _evaluate_condition(condition: String) -> bool:
	var operators := [">=", "<=", "==", "!=", ">", "<"]
	for op_variant in operators:
		var op := str(op_variant)
		var token := " %s " % op
		if condition.find(token) == -1:
			continue
		var parts := condition.split(token)
		if parts.size() != 2:
			return false
		var left_text := str(parts[0]).strip_edges()
		var right_text := str(parts[1]).strip_edges()
		var actual: Variant = _resolve_path_value(left_text)
		var expected: Variant = _parse_literal(right_text)
		return _compare_values(actual, op, expected)
	return false

# 功能：按点路径读取 world_state 值。
# 说明：例如 flags.isWanted；任意层不存在时返回 null。
func _resolve_path_value(path: String) -> Variant:
	var segments := path.split(".", false)
	if segments.is_empty():
		return null

	var cursor: Variant = world_state
	for segment_variant in segments:
		var segment := str(segment_variant)
		if typeof(cursor) != TYPE_DICTIONARY:
			return null
		var dict_cursor: Dictionary = cursor
		if not dict_cursor.has(segment):
			return null
		cursor = dict_cursor[segment]
	return cursor

# 功能：将表达式右值文本解析为 GDScript 值。
# 说明：支持 bool、int、双引号字符串，其他保持原文本。
func _parse_literal(raw: String) -> Variant:
	var text := raw.strip_edges()
	var lowered := text.to_lower()
	if lowered == "true":
		return true
	if lowered == "false":
		return false
	if text.is_valid_int():
		return int(text)
	if text.begins_with("\"") and text.ends_with("\"") and text.length() >= 2:
		return text.substr(1, text.length() - 2)
	return text

# 功能：统一比较函数。
# 说明：大小比较会先转为 float，再执行比较。
func _compare_values(actual: Variant, op: String, expected: Variant) -> bool:
	# 说明：null 处理——等值/不等值比较时将 null 视为 false（flag 不存在 ≡ false）；
	# 大小比较时 null 无法参与，直接判定不通过。
	if actual == null:
		if op == "==":
			return false == expected
		if op == "!=":
			return false != expected
		return false
	match op:
		"==":
			return actual == expected
		"!=":
			return actual != expected
		">":
			return float(actual) > float(expected)
		">=":
			return float(actual) >= float(expected)
		"<":
			return float(actual) < float(expected)
		"<=":
			return float(actual) <= float(expected)
		_:
			return false

# 功能：按权重随机抽取事件 id。
# 说明：当总权重异常（<=0）时回退第一个候选，保证不中断。
func _weighted_pick(candidates: Array) -> String:
	var total := 0
	for candidate_variant in candidates:
		var candidate: Dictionary = candidate_variant
		total += maxi(1, int(candidate.get("weight", 1)))

	if total <= 0:
		return str((candidates[0] as Dictionary).get("id", ""))

	var roll := _rng.randi_range(1, total)
	var cursor := 0
	for candidate_variant in candidates:
		var candidate: Dictionary = candidate_variant
		cursor += maxi(1, int(candidate.get("weight", 1)))
		if roll <= cursor:
			return str(candidate.get("id", ""))

	return str((candidates[0] as Dictionary).get("id", ""))

# 功能：检查指定 event_id 是否存在于事件池（Step 2 新增）。
# 说明：供调用方（如 main_game.gd 注入开场 forcedNextEventId 前）做存在性校验，
#       避免对缺失事件 ID 的 forcedNextEventId 写入触发 _select_next_event 的
#       missing_event_def fatal。
func has_event(event_id: String) -> bool:
	if event_id.strip_edges().is_empty():
		return false
	return _event_map.has(event_id.strip_edges())


# 功能：选择兜底事件。
# 说明：优先 evt_idle，其次取事件池中第一个可用 id。
func _fallback_event_id() -> String:
	if _event_map.has("evt_idle"):
		return "evt_idle"
	for event_variant in events:
		var event_def: Dictionary = event_variant
		var event_id := str(event_def.get("id", ""))
		if not event_id.is_empty():
			return event_id
	return ""

# 功能：将事件 effects 应用到 world_state。
# 说明：支持 setFlags、addParams、setLocation、forcedNext、clearForced、endChain。
func _apply_event_effects(event_def: Dictionary) -> void:
	var effects: Dictionary = event_def.get("effects", {})

	var set_flags: Dictionary = effects.get("setFlags", {})
	if not set_flags.is_empty():
		var flags: Dictionary = world_state.get("flags", {})
		for key in set_flags.keys():
			flags[str(key)] = set_flags[key]
		world_state["flags"] = flags

	var add_params: Dictionary = effects.get("addParams", {})
	if not add_params.is_empty():
		var params: Dictionary = world_state.get("params", {})
		for key in add_params.keys():
			var param_key := str(key)
			params[param_key] = int(params.get(param_key, 0)) + int(add_params[key])
		world_state["params"] = params

	var set_location := str(effects.get("setLocation", "")).strip_edges()
	if not set_location.is_empty():
		world_state["currentLocationId"] = set_location

	var forced_id := str(effects.get("forcedNextEventId", "")).strip_edges()
	if not forced_id.is_empty():
		world_state["forcedNextEventId"] = forced_id

	if bool(effects.get("clearForcedNext", false)):
		world_state["forcedNextEventId"] = ""

	if bool(effects.get("endChain", false)):
		world_state["chainContext"] = null

	var task_actions := _array_or_empty(effects.get("taskActions", []))
	_apply_task_actions(task_actions)

	# 末尾位池消耗记录：若事件 tags 含已配置的池 tag，自动写入消耗集合。
	# 设计基线见 [[当前版本完整主路径_MVP设计]] §三·节点 3 末尾位骨架抽取规则。
	# 任何路径触发的事件（forced / scheduler / final_pool）都覆盖，避免遗漏。
	# mark 后立即检查池是否变空：是则马上安排收口 forced，确保 MVP 设计要求的
	# "消耗完最后一个 → 立即触发收口事件"语义；同回合不覆盖外部已存在的 forced 安排。
	var final_pool_tag: String = str(_pack_config.get("final_event_pool_tag", "")).strip_edges()
	if not final_pool_tag.is_empty():
		var event_tags: Array = event_def.get("tags", [])
		if final_pool_tag in event_tags:
			_mark_final_pool_consumed(final_pool_tag, str(event_def.get("id", "")))
			if _is_final_pool_exhausted(final_pool_tag):
				var exhausted_id: String = str(_pack_config.get("final_event_pool_exhausted_forced_id", "")).strip_edges()
				if not exhausted_id.is_empty() and str(world_state.get("forcedNextEventId", "")).is_empty():
					world_state["forcedNextEventId"] = exhausted_id
					print("[叙事包] 末尾位池 %s 消费后耗尽，安排收口 forced=%s" % [final_pool_tag, exhausted_id])

# 功能：按 continuationPolicy 推进链上下文。
# 说明：forcedNextEventId 由 effects 或 resolution 驱动，不在这里判定。
func _apply_continuation_policy(event_def: Dictionary, chain_patch_override: Dictionary = {}) -> void:
	var policy := str(event_def.get("continuationPolicy", POLICY_RETURN))
	var base_chain_patch: Dictionary = event_def.get("chainPatch", {})
	var merged_chain_patch := _merge_dict(base_chain_patch, chain_patch_override)
	match policy:
		POLICY_CHAIN, POLICY_CHAIN_FORCED:
			_ensure_or_patch_chain_context(merged_chain_patch)
		POLICY_RETURN:
			# 说明：ReturnToScheduler 不主动建链；若显式给出 patch，则按 patch 执行。
			if not merged_chain_patch.is_empty():
				_ensure_or_patch_chain_context(merged_chain_patch)
		_:
			pass

# 功能：创建或更新 chainContext。
# 说明：首次按 patch 初始化，链内按 stageDelta 推进，并可按退出条件自动结束。
func _ensure_or_patch_chain_context(chain_patch: Dictionary) -> void:
	var raw_ctx: Variant = world_state.get("chainContext", null)
	var ctx: Dictionary = {}
	if typeof(raw_ctx) == TYPE_DICTIONARY and raw_ctx != null:
		ctx = (raw_ctx as Dictionary).duplicate(true)

	if ctx.is_empty():
		ctx = {
			"chainId": str(chain_patch.get("chainId", "chain_default")),
			"stage": int(chain_patch.get("stage", 1)),
			"allowedTags": chain_patch.get("allowedTags", []),
			"constraints": chain_patch.get("constraints", {}),
			"weightBias": chain_patch.get("weightBias", {}),
			"exitWhenStageGte": int(chain_patch.get("exitWhenStageGte", 0)),
			# 叙事包联动：链内回合结算模式（standard=每步消耗标准回合，deferred=冻结回合链末结算）。
			"turnMode": str(chain_patch.get("turnMode", "standard")),
			# 叙事包联动：deferred 模式下链结束时消耗的回合数（0=不消耗）。
			"deferredTurnCost": int(chain_patch.get("deferredTurnCost", 1)),
			# 叙事包联动：链结束后是否触发自省事件。
			"triggerReflectionOnExit": bool(chain_patch.get("triggerReflectionOnExit", false))
		}
	else:
		ctx["stage"] = int(ctx.get("stage", 0)) + int(chain_patch.get("stageDelta", 1))
		if chain_patch.has("allowedTags"):
			ctx["allowedTags"] = chain_patch.get("allowedTags", [])
		if chain_patch.has("constraints"):
			ctx["constraints"] = chain_patch.get("constraints", {})
		if chain_patch.has("weightBias"):
			ctx["weightBias"] = chain_patch.get("weightBias", {})
		if chain_patch.has("exitWhenStageGte"):
			ctx["exitWhenStageGte"] = int(chain_patch.get("exitWhenStageGte", 0))
		# 叙事包联动字段：仅在 patch 中明确提供时才覆盖，否则保留已有值。
		if chain_patch.has("turnMode"):
			ctx["turnMode"] = str(chain_patch.get("turnMode", "standard"))
		if chain_patch.has("deferredTurnCost"):
			ctx["deferredTurnCost"] = int(chain_patch.get("deferredTurnCost", 1))
		if chain_patch.has("triggerReflectionOnExit"):
			ctx["triggerReflectionOnExit"] = bool(chain_patch.get("triggerReflectionOnExit", false))

	var exit_stage := int(ctx.get("exitWhenStageGte", 0))
	if exit_stage > 0 and int(ctx.get("stage", 0)) >= exit_stage:
		# 叙事包联动：链退出时执行延迟结算（deferred 模式下按 deferredTurnCost 批量推进）。
		_finalize_chain_exit(ctx)
		world_state["chainContext"] = null
	else:
		world_state["chainContext"] = ctx

# 功能：记录最近事件历史。
# 说明：固定窗口 12 条，供权重去重使用。
func _record_history(event_id: String) -> void:
	var history: Array = world_state.get("history", [])
	history.append(event_id)
	while history.size() > 12:
		history.pop_front()
	world_state["history"] = history
	# REQ-001 包内硬去重（2026-05-09）：同步追加到 packContext.played_events，
	#   仅当包激活时（locationId 非空）。_build_candidates 守门 4 消费。
	#   forced / final_pool 路径也会经过本函数追加，但那些路径不走 _build_candidates，
	#   所以追加是无害的（仅占内存几 byte）。
	var pack_ctx: Dictionary = _dict_or_empty(world_state.get("packContext", {}))
	if not str(pack_ctx.get("locationId", "")).is_empty():
		var played: Array = pack_ctx.get("played_events", [])
		if not (event_id in played):
			played.append(event_id)
			pack_ctx["played_events"] = played
			world_state["packContext"] = pack_ctx

# 功能：判断两个数组是否存在任意交集。
# 说明：用于 tag 匹配。
func _array_has_any(left: Array, right: Array) -> bool:
	for left_item in left:
		if left_item in right:
			return true
	return false

# 功能：构建事件对应的选项集合。
# 说明：为每个选项标记三态：invisible、disabled、selectable。
func _build_option_set(choice_point_def: Dictionary) -> Array:
	# Line B S3: 选项层调度 (is_base 必出 + weight 加权 + trigger_condition 门控)。
	# 向后兼容: 旧数据无新字段时 is_base=false / weight=1 / trigger_condition=空 → 全产出。
	# 详见 [[前端骨架_LineB_实施]] §3.13。
	const MAX_OPTIONS := 3
	var all_options: Array = choice_point_def.get("options", [])

	# 第一步: trigger_condition 门控过滤 (空 = 放行)
	var filtered: Array = []
	for option_variant in all_options:
		var option_def: Dictionary = option_variant
		var tc: String = str(option_def.get("trigger_condition", "")).strip_edges()
		if tc.is_empty() or _evaluate_condition(tc):
			filtered.append(option_def)

	# 第二步: 分组 — 基础必出 vs 候选池
	var base_options: Array = []
	var pool_options: Array = []
	for option_variant in filtered:
		var option_def: Dictionary = option_variant
		if bool(option_def.get("is_base", false)):
			base_options.append(option_def)
		else:
			pool_options.append(option_def)

	# 第三步: 必出全部产出 + 剩余配额从候选池按 weight 抽取
	var selected: Array = base_options.duplicate()
	# 配额边界: 基础选项数已 >= MAX_OPTIONS 时不再补充 (设计如此则照搬, 即便超 3)
	var quota: int = MAX_OPTIONS - selected.size()
	if quota > 0 and not pool_options.is_empty():
		if pool_options.size() <= quota:
			# 候选不超配额: 全部产出 (向后兼容旧行为, 现有 mvp 数据走这里)
			selected.append_array(pool_options)
		else:
			# 候选超配额: 按 weight 加权抽 quota 个 (无重复)
			selected.append_array(_weighted_sample_options(pool_options, quota))

	# 第四步: 按 _display_order 排序 (保持原显示顺序稳定)
	selected.sort_custom(func(a, b):
		return int((a as Dictionary).get("_display_order", 0)) < int((b as Dictionary).get("_display_order", 0))
	)

	# 第五步: 为每个选项打 state 标识 (原 _build_option_set 行为)
	var out: Array = []
	for option_variant in selected:
		var option_def: Dictionary = option_variant
		var item := option_def.duplicate(true)
		# 说明：选项三态分别表示不显示、显示但不可选、可选。
		var state := "selectable"
		if not _option_visible(option_def):
			state = "invisible"
		elif not _option_selectable(option_def):
			state = "disabled"
		item["state"] = state
		out.append(item)
	return out


# 功能: 从候选池按 weight 加权无重复抽 n 个选项。
# 算法: 累积权重 + 单次随机 + 抽取后移除; 时间复杂度 O(n * pool.size)。
# 用于 Line B S3 选项产出 — 候选数 > 配额时收敛到 MAX_OPTIONS。
func _weighted_sample_options(pool: Array, n: int) -> Array:
	var working: Array = pool.duplicate()
	var picked: Array = []
	for i in n:
		if working.is_empty():
			break
		# 计算总权重
		var total: int = 0
		for opt_v in working:
			total += max(1, int((opt_v as Dictionary).get("weight", 1)))
		if total <= 0:
			break
		# 加权随机抽取
		var roll: int = randi() % total
		var acc: int = 0
		var pick_idx: int = -1
		for j in working.size():
			acc += max(1, int((working[j] as Dictionary).get("weight", 1)))
			if roll < acc:
				pick_idx = j
				break
		if pick_idx >= 0:
			picked.append(working[pick_idx])
			working.remove_at(pick_idx)
	return picked

# 功能：输出上层使用的选项简版结构。
# 说明：仅返回 id、text、state，避免暴露内部结算细节。
func _option_public_states(options_eval: Array) -> Array:
	var out: Array = []
	for option_variant in options_eval:
		var option_def: Dictionary = option_variant
		out.append(
			{
				"id": str(option_def.get("id", "")),
				"text": str(option_def.get("text", "")),
				"state": str(option_def.get("state", "disabled"))
			}
		)
	return out

# 功能：判定选项是否可见。
# 说明：visibilityWhen 条件需全部通过才可见。
func _option_visible(option_def: Dictionary) -> bool:
	var visibility_rules := _array_or_empty(option_def.get("visibilityWhen", []))
	for rule_variant in visibility_rules:
		var rule := str(rule_variant).strip_edges()
		if rule.is_empty():
			continue
		if not _evaluate_condition(rule):
			return false
	return true

# 功能：判定选项是否可选。
# 说明：需要同时通过 eligibility 与 cost 校验。
func _option_selectable(option_def: Dictionary) -> bool:
	if not _is_option_eligibility_pass(_dict_or_empty(option_def.get("eligibility", {}))):
		return false
	return _can_pay_cost(_dict_or_empty(option_def.get("cost", {})))

# 功能：逐条校验 eligibility 条件。
# 说明：支持字面量比较与内联规则字符串，例如 >=10。
func _is_option_eligibility_pass(eligibility: Dictionary) -> bool:
	for key_variant in eligibility.keys():
		var path := str(key_variant).strip_edges()
		var clause: Variant = eligibility[key_variant]
		var actual: Variant = _resolve_path_value(path)
		if typeof(clause) == TYPE_STRING:
			# 说明：规则示例：>=10、=true；左值来自 path 对应的 world_state 字段。
			var rule := str(clause).strip_edges()
			if rule.is_empty():
				continue
			if not _match_inline_rule(actual, rule):
				return false
		else:
			if actual != clause:
				return false
	return true

# 功能：解析并匹配内联规则。
# 说明：规则示例：>=10、=true，左值为 actual。
func _match_inline_rule(actual: Variant, rule: String) -> bool:
	var operators := [">=", "<=", "==", "!=", ">", "<"]
	for op_variant in operators:
		var op := str(op_variant)
		if not rule.begins_with(op):
			continue
		var right_text := rule.substr(op.length()).strip_edges()
		var expected: Variant = _parse_literal(right_text)
		return _compare_values(actual, op, expected)
	var expected_literal: Variant = _parse_literal(rule)
	return actual == expected_literal

# 功能：读取玩家指定字段的值。
# 说明：优先从 RoleState 读取（路径 A），若不存在则回退到 world_state.player（JSON 路径兼容）。
func _get_player_value(key: String, default_value: int = 0) -> int:
	if player_role_state != null:
		return int(player_role_state.get_value(key, default_value))
	var player: Dictionary = world_state.get("player", {})
	return int(player.get(key, default_value))

# 功能：写入玩家指定字段的值。
# 说明：优先写入 RoleState 并同步（路径 A），若不存在则直接写 world_state.player（JSON 路径兼容）。
# 已知限制（Gap 2）：JSON 回退路径直接写字典，不经过 RoleState.set_value()，
# xinxing 等有约束字段在此路径下不会触发 [-2,+2] 裁剪。
# 正常运行时 player_role_state 始终存在，此路径仅在测试或异常初始化时触发。
func _set_player_value(key: String, value: int) -> void:
	if player_role_state != null:
		player_role_state.set_value(key, value)
	else:
		var player: Dictionary = world_state.get("player", {})
		player[key] = value
		world_state["player"] = player

# 功能：检查玩家是否可支付选项代价。
# 说明：通过 _get_player_value 读取，兼容 RoleState 和 JSON 两种路径。
func _can_pay_cost(cost: Dictionary) -> bool:
	if cost.is_empty():
		return true
	for key_variant in cost.keys():
		var key := str(key_variant)
		var need := int(cost[key_variant])
		var have := _get_player_value(key, 0)
		if have < need:
			return false
	return true

# 功能：将选项代价扣减到玩家数据。
# 说明：通过 _set_player_value 写入，RoleState 路径会自动同步到 world_state。
func _apply_cost(cost: Dictionary) -> void:
	if cost.is_empty():
		return
	for key_variant in cost.keys():
		var key := str(key_variant)
		var current := _get_player_value(key, 0)
		_set_player_value(key, current - int(cost[key_variant]))
	if player_role_state != null:
		_sync_role_to_world_state()

# 功能：合并全局主动押注默认配置与选项级覆盖。
# 说明：选项级 biasModifiers 覆盖全局 bias，选项级 cost（worldStatePatch.player）覆盖全局 cost。
#       未配置覆盖的字段回退到 _preemptive_bet_defaults。
func _merge_preemptive_bet_config(option_bet_cfg: Dictionary) -> Dictionary:
	var defaults := _preemptive_bet_defaults
	# bias 合并：选项级 biasModifiers 存在时覆盖全局 bias。
	var option_bias := _dict_or_empty(option_bet_cfg.get("biasModifiers", {}))
	var effective_bias: Dictionary = defaults.get("bias", {}).duplicate(true)
	for key in option_bias.keys():
		effective_bias[str(key)] = option_bias[key]
	# cost 合并：选项级若通过 preemptive_bet rule 显式配置了 costOverride 则覆盖全局 cost。
	var option_cost_override := _dict_or_empty(option_bet_cfg.get("costOverride", {}))
	var effective_cost: Dictionary = defaults.get("cost", {}).duplicate(true)
	if not option_cost_override.is_empty():
		effective_cost = option_cost_override.duplicate(true)
	return {"cost": effective_cost, "bias": effective_bias}

# 功能：检查玩家是否能支付主动押注的额外代价。
func _can_pay_bet_cost(bet_cost: Dictionary) -> bool:
	if bet_cost.is_empty():
		return true
	for key_variant in bet_cost.keys():
		var key := str(key_variant)
		var need := int(bet_cost[key_variant])
		var have := _get_player_value(key, 0)
		if have < need:
			return false
	return true

# 功能：扣除主动押注的额外代价。
func _apply_bet_cost(bet_cost: Dictionary) -> void:
	if bet_cost.is_empty():
		return
	for key_variant in bet_cost.keys():
		var key := str(key_variant)
		var current := _get_player_value(key, 0)
		_set_player_value(key, current - int(bet_cost[key_variant]))
	if player_role_state != null:
		_sync_role_to_world_state()

# 功能：在可选项中按外部传入 ID 精确选择。
# 说明：仅当目标选项状态为 selectable 时返回，否则返回空字典。
func _select_option_by_id(options_eval: Array, option_id: String) -> Dictionary:
	var target := option_id.strip_edges()
	if target.is_empty():
		return {}
	for option_variant in options_eval:
		var option_def: Dictionary = option_variant
		if str(option_def.get("id", "")) == target and str(option_def.get("state", "")) == "selectable":
			return option_def
	return {}

# 功能：在可选项中查找第一个 selectable 选项。
# 说明：仅用于判断"是否存在可选项"，不用于自动结算。
func _select_first_selectable(options_eval: Array) -> Dictionary:
	for option_variant in options_eval:
		var option_def: Dictionary = option_variant
		if str(option_def.get("state", "")) == "selectable":
			return option_def
	return {}

# 功能：执行选项结算主流程（支持心性风险入口挂起）。
# 说明：流程为扣代价 → 读心性 → 主动押注检查 → 检定 → 孤注一掷检查 → 应用 resolution。
#       遇到风险入口时挂起到对应 phase，等待外部决策后继续推进。
func _apply_option_resolution(selected_option: Dictionary, event_def: Dictionary) -> void:
	var cost := _dict_or_empty(selected_option.get("cost", {}))
	if not _can_pay_cost(cost):
		_apply_event_effects(event_def)
		_apply_continuation_policy(event_def)
		return

	# 1. 支付 cost
	_apply_cost(cost)

	# Line B S8.2 桥接: 检测 forced_check_result (zhengdao-cards 标记投入鉴定算法注入)。
	# 有则跳过 vibe-test 骰池 + 心性风险入口 (preemptive_bet / desperate_gamble),
	# 直接用 forced 结果选 resolution 分支并应用。原 vibe-test 路径完全保留 (else 分支)。
	var forced_check := _dict_or_empty(_pending_turn_context.get("forced_check_result", {}))
	if not forced_check.is_empty():
		_apply_option_resolution_with_forced_check(selected_option, event_def, forced_check)
		return

	# 2. 读取心性 → 获取风险入口配置
	var xinxing := _get_current_xinxing()
	var risk_profile := RuleEngine.get_xinxing_risk_profile(xinxing)
	print("[心性] 当前心性: %d | 风险配置: %s" % [xinxing, str(risk_profile)])

	# 3. 主动押注检查：心性允许且选项含鉴定且未被 disabled。
	#    全局化后不再要求选项显式配置 preemptiveBet，含鉴定的选项默认走全局默认。
	# demo_mode: disable_preemptive_bet_path —— demo 期禁用押注前置 phase（避免心性接入泄露）。
	#   重构期审视入口：[[代码重构_预启动]] §4.3。
	var check_for_bet := _dict_or_empty(selected_option.get("check", {}))
	var option_bet_cfg: Variant = selected_option.get("preemptiveBet", null)
	var bet_disabled: bool = (typeof(option_bet_cfg) == TYPE_DICTIONARY and bool(option_bet_cfg.get("disabled", false)))
	var has_check := not check_for_bet.is_empty()
	var demo_disable_bet := is_demo_mode_enabled("disable_preemptive_bet_path")
	if bool(risk_profile.get("allow_preemptive_bet", false)) and has_check and not bet_disabled and not demo_disable_bet:
		# 挂起到 preemptive_bet phase，等待玩家决策
		_pending_turn_context["phase"] = "preemptive_bet"
		_pending_turn_context["selected_option"] = selected_option.duplicate(true)
		_pending_turn_context["risk_modifiers"] = {}
		print("[心性] 主动押注入口触发 → 挂起等待决策")
		return

	# 4. 清空上次缓存，准备本次结算数据透传
	_last_check_result = {}
	_last_affinity_changes = []
	_last_xinxing_transition = {}
	var xinxing_before := xinxing

	# 5. 执行检定
	var resolution := _dict_or_empty(selected_option.get("resolution", {}))
	var check := _dict_or_empty(selected_option.get("check", {}))
	var check_result := _is_check_pass(check)
	_last_check_result = check_result.duplicate(true)
	print("[鉴定结果] result_type: %s | pass: %s" % [str(check_result.get("result_type", "")), str(check_result.get("pass", true))])

	# 6. 孤注一掷检查：主结果 fail 且心性允许
	# demo_mode: disable_desperate_gamble_path —— demo 期禁用 fail 后的孤注一掷重掷路径
	#   （fail 直接走 fail，避免"为什么有时鉴定多了一次重试"的隐式机制泄露）。
	#   重构期审视入口：[[代码重构_预启动]] §4.3。
	var demo_disable_gamble := is_demo_mode_enabled("disable_desperate_gamble_path")
	if not check_result.get("pass", true) and bool(risk_profile.get("allow_desperate_gamble", false)) and not demo_disable_gamble:
		_pending_turn_context["phase"] = "desperate_gamble"
		_pending_turn_context["selected_option"] = selected_option.duplicate(true)
		_pending_turn_context["check_result"] = check_result.duplicate(true)
		_pending_turn_context["risk_modifiers"] = {}
		print("[心性] 孤注一掷入口触发 → 挂起等待决策")
		return

	# 7. 按 result_type 选择 resolution（支持 fail / critical_success / critical_fail 分支）
	resolution = _resolve_check_resolution(check, resolution, check_result)

	_apply_resolution(resolution, event_def)
	# -2 阶段关系回响：检定结束后检查是否触发自动关系反馈。
	_try_relationship_echo(check_result)
	# 回合结算末尾：稳健计数 +1（未使用孤注一掷的回合视为稳健）
	_ensure_xinxing_tracker()
	var tracker: Dictionary = world_state["xinxingTracker"]
	tracker["steady_count"] = int(tracker.get("steady_count", 0)) + 1
	world_state["xinxingTracker"] = tracker
	_check_xinxing_transition()
	# 记录心性转移
	var xinxing_after := _get_current_xinxing()
	if xinxing_after != xinxing_before:
		_last_xinxing_transition = {"old_value": xinxing_before, "new_value": xinxing_after}

# 功能：forced_check_result 在场时的选项结算（Line B S8.2 桥接路径）。
# 说明：cost 已在 _apply_option_resolution 主路径支付完，本函数从 result_type 选 resolution 直接应用。
#       跳过 _is_check_pass / preemptive_bet / desperate_gamble (zhengdao-cards MVP 1 期心性路径延后 S5)。
#       关系回响 + 稳健计数 + xinxing transition 与原路径保持一致，避免行为漂移。
func _apply_option_resolution_with_forced_check(
	selected_option: Dictionary, event_def: Dictionary, forced_check: Dictionary
) -> void:
	_last_check_result = forced_check.duplicate(true)
	_last_affinity_changes = []
	_last_xinxing_transition = {}
	var xinxing_before := _get_current_xinxing()

	var resolution := _dict_or_empty(selected_option.get("resolution", {}))
	var check := _dict_or_empty(selected_option.get("check", {}))
	resolution = _resolve_check_resolution(check, resolution, forced_check)
	print("[鉴定结果·forced] result_type: %s | pass: %s" % [
		str(forced_check.get("result_type", "")), str(forced_check.get("pass", true))
	])

	_apply_resolution(resolution, event_def)
	_try_relationship_echo(forced_check)

	_ensure_xinxing_tracker()
	var tracker: Dictionary = world_state["xinxingTracker"]
	tracker["steady_count"] = int(tracker.get("steady_count", 0)) + 1
	world_state["xinxingTracker"] = tracker
	_check_xinxing_transition()
	var xinxing_after := _get_current_xinxing()
	if xinxing_after != xinxing_before:
		_last_xinxing_transition = {"old_value": xinxing_before, "new_value": xinxing_after}

	# 清理 forced 标记，避免泄露到下一回合
	_pending_turn_context.erase("forced_check_result")

# 功能：执行选项检定。
# 说明：委托 RuleEngine.resolve_check 统一判定，传入引擎自身的 rng 和阈值。
#       risk_modifiers 可由风险入口（主动押注）额外构建后传入。
func _is_check_pass(check: Dictionary, risk_modifiers: Dictionary = {}) -> Dictionary:
	if check.is_empty():
		return {"pass": true, "result_type": "success"}
	# 功能：附加心性上下文到 risk_modifiers，供概率引擎约束 critical 结构。
	# 说明：调用方传入的 bias 与这里补充的心性字段做浅合并。
	var merged_risk_modifiers := risk_modifiers.duplicate(true)
	var current_xinxing := _get_current_xinxing()
	var risk_profile := RuleEngine.get_xinxing_risk_profile(current_xinxing)
	merged_risk_modifiers["xinxing"] = current_xinxing
	merged_risk_modifiers["risk_profile"] = risk_profile
	# demo_mode: disable_xinxing_stability_bias —— demo 期心性完全不暴露，强制 stability_bias=0
	#   防止 xinxing > 0 时给鉴定 dice 池加骰造成"鉴定突然变好"的隐式机制泄露。
	#   tracker 累积保留（数据完整供阶段 3 启用），仅在本鉴定计算位强制为 0。
	#   重构期审视入口：[[代码重构_预启动]] §4.3。
	var stability_bias_value: int = int(risk_profile.get("stability_bias", 0))
	if is_demo_mode_enabled("disable_xinxing_stability_bias"):
		stability_bias_value = 0
	merged_risk_modifiers["stability_bias"] = stability_bias_value

	# 关系修正判定：遍历 relationshipNpcs，汇总 relationship_bias 注入骰池。
	var relationship_npcs: Array = check.get("relationshipNpcs", [])
	var relationship_details: Array = []
	if not relationship_npcs.is_empty() and _affinity_map != null:
		var total_bias := 0
		for npc_entry_variant in relationship_npcs:
			var npc_entry: Dictionary = npc_entry_variant
			var npc_id := str(npc_entry.get("npc_id", ""))
			var rel_difficulty := int(npc_entry.get("difficulty", 0))
			if npc_id.is_empty():
				continue
			var npc_to_player := _affinity_map.get_score(npc_id, "player")
			var player_to_npc := _affinity_map.get_score("player", npc_id)
			var rel_result := RuleEngine.resolve_relationship_check(
				npc_to_player, player_to_npc, rel_difficulty, _affinity_thresholds, _rng
			)
			total_bias += int(rel_result.get("bias", 0))
			relationship_details.append({"npc_id": npc_id, "detail": rel_result})
		merged_risk_modifiers["relationship_bias"] = total_bias

	# 构造鉴定数据源：RoleState 优先，JSON 路径回退到 world_state.player。
	var role_or_player: Variant = player_role_state
	if role_or_player == null:
		role_or_player = world_state.get("player", {})
	var result := RuleEngine.resolve_check(check, role_or_player, _assessment_thresholds, _rng, merged_risk_modifiers)

	# 将关系判定详情附加到结果中，供调试和回响使用。
	if not relationship_details.is_empty():
		result["relationship_details"] = relationship_details

	# 调试输出
	var check_type := str(check.get("type", "")).strip_edges()
	if check_type == "assessment":
		_print_assessment_debug(check, result)
	return result

# 功能：根据检定 result_type 选择最终 resolution。
# 说明：优先级为 critical_success / critical_fail / fail / default；未配置时回退到基础 resolution。
func _resolve_check_resolution(check: Dictionary, base_resolution: Dictionary, check_result: Dictionary) -> Dictionary:
	var result_type := str(check_result.get("result_type", "success"))
	if result_type == "critical_success":
		var cs_resolution := _dict_or_empty(check.get("onCriticalSuccessResolution", {}))
		if not cs_resolution.is_empty():
			return cs_resolution
		return base_resolution
	if result_type == "critical_fail":
		var cf_resolution := _dict_or_empty(check.get("onCriticalFailResolution", {}))
		if not cf_resolution.is_empty():
			return cf_resolution
		var fail_resolution_fallback := _dict_or_empty(check.get("onFailResolution", {}))
		if not fail_resolution_fallback.is_empty():
			return fail_resolution_fallback
		return base_resolution
	if result_type == "fail":
		var fail_resolution := _dict_or_empty(check.get("onFailResolution", {}))
		if not fail_resolution.is_empty():
			return fail_resolution
	return base_resolution

func _resolve_preemptive_bet_phase(selected_option_id: String) -> Dictionary:
	var event_id := str(_pending_turn_context.get("event_id", ""))
	var event_def: Dictionary = _event_map.get(event_id, {})
	var selected_option: Dictionary = _dict_or_empty(_pending_turn_context.get("selected_option", {}))
	var decision := selected_option_id.strip_edges()
	# 清空缓存，准备本次结算数据透传
	_last_check_result = {}
	_last_affinity_changes = []
	_last_xinxing_transition = {}
	var xinxing_before := _get_current_xinxing()

	var risk_modifiers: Dictionary = {}
	if decision == "accept":
		# 合并全局默认与选项覆盖：选项级 biasModifiers / worldStatePatch 覆盖全局默认。
		var option_bet_cfg := _dict_or_empty(selected_option.get("preemptiveBet", {}))
		var effective_bet := _merge_preemptive_bet_config(option_bet_cfg)

		# 额外代价检查与扣除（叠加在选项 cost 之上，选项 cost 已在入口处扣过）。
		var bet_cost: Dictionary = effective_bet.get("cost", {})
		if not _can_pay_bet_cost(bet_cost):
			# 精力不足，视为放弃押注，直接走常规检定。
			print("[心性] 主动押注精力不足 → 自动跳过")
		else:
			_apply_bet_cost(bet_cost)
			# 提取 biasModifiers 写入 risk_modifiers，传入 resolve_check 供骰池引擎消费。
			# successBias 在骰池模式下语义为"加减骰子数"。
			var bias: Dictionary = effective_bet.get("bias", {})
			risk_modifiers["successBias"] = int(bias.get("successBias", 0))
			risk_modifiers["bet_active"] = true
			# 押注前立即应用额外资源/属性变化（如选项配置了 worldStatePatch）。
			var pre_bet_patch := _dict_or_empty(option_bet_cfg.get("worldStatePatch", {}))
			if not pre_bet_patch.is_empty():
				_apply_world_state_patch(pre_bet_patch)
			print("[心性] 主动押注已接受 → bonus_dice: %d | cost: %s" % [
				risk_modifiers["successBias"], str(bet_cost)
			])
	else:
		print("[心性] 主动押注已跳过")

	# 继续执行检定
	var resolution := _dict_or_empty(selected_option.get("resolution", {}))
	var check := _dict_or_empty(selected_option.get("check", {}))
	var check_result := _is_check_pass(check, risk_modifiers)
	_last_check_result = check_result.duplicate(true)
	print("[鉴定结果] result_type: %s | pass: %s" % [str(check_result.get("result_type", "")), str(check_result.get("pass", true))])

	resolution = _resolve_check_resolution(check, resolution, check_result)

	# 主动押注不提供孤注一掷（-2 心性不允许）
	_pending_turn_context.erase("selected_option")
	_pending_turn_context.erase("risk_modifiers")
	_pending_turn_context["phase"] = "confirm"
	_apply_resolution(resolution, event_def)
	# -2 阶段关系回响
	_try_relationship_echo(check_result)

	# 稳健计数 +1（主动押注不算孤注一掷）
	_ensure_xinxing_tracker()
	var tracker: Dictionary = world_state["xinxingTracker"]
	tracker["steady_count"] = int(tracker.get("steady_count", 0)) + 1
	world_state["xinxingTracker"] = tracker
	_check_xinxing_transition()
	# 记录心性转移
	var xinxing_after := _get_current_xinxing()
	if xinxing_after != xinxing_before:
		_last_xinxing_transition = {"old_value": xinxing_before, "new_value": xinxing_after}
	return _finalize_option_turn(event_def)

# 功能：处理孤注一掷阶段的玩家决策。
# 说明：selected_option_id 传入 "accept" 表示使用孤注一掷，其他值或空值表示放弃。
func _resolve_desperate_gamble_phase(selected_option_id: String) -> Dictionary:
	var event_id := str(_pending_turn_context.get("event_id", ""))
	var event_def: Dictionary = _event_map.get(event_id, {})
	var selected_option: Dictionary = _dict_or_empty(_pending_turn_context.get("selected_option", {}))
	var original_check_result: Dictionary = _dict_or_empty(_pending_turn_context.get("check_result", {}))
	var decision := selected_option_id.strip_edges()
	# 清空缓存，准备本次结算数据透传
	_last_check_result = {}
	_last_affinity_changes = []
	_last_xinxing_transition = {}
	var xinxing_before := _get_current_xinxing()

	var resolution := _dict_or_empty(selected_option.get("resolution", {}))
	var check := _dict_or_empty(selected_option.get("check", {}))

	if decision == "accept":
		# 玩家使用孤注一掷，重新执行检定
		print("[心性] 孤注一掷已使用 → 重新检定")
		var check_result := _is_check_pass(check)
		_last_check_result = check_result.duplicate(true)
		_last_check_result["is_desperate_gamble"] = true
		print("[鉴定结果] 重掷 result_type: %s | pass: %s" % [str(check_result.get("result_type", "")), str(check_result.get("pass", true))])
		resolution = _resolve_check_resolution(check, resolution, check_result)
		# 结构规则：-1 阶段孤注一掷重判为 critical_fail 时，立刻跌入 -2。
		if str(check_result.get("result_type", "")) == "critical_fail" and _get_current_xinxing() == -1:
			_set_player_value("xinxing", RuleEngine.apply_xinxing_delta(-1, -1))
			if player_role_state != null:
				_sync_role_to_world_state()
		# 孤注一掷计数 +1，重置稳健计数
		_ensure_xinxing_tracker()
		var tracker: Dictionary = world_state["xinxingTracker"]
		tracker["gamble_count"] = int(tracker.get("gamble_count", 0)) + 1
		tracker["steady_count"] = 0
		world_state["xinxingTracker"] = tracker
		# 孤注一掷使用后立即检查心性切换
		_check_xinxing_transition()
	else:
		# 玩家放弃孤注一掷，走 fail resolution
		print("[心性] 孤注一掷已放弃 → 使用失败结果")
		var fail_resolution := _dict_or_empty(check.get("onFailResolution", {}))
		if not fail_resolution.is_empty():
			resolution = fail_resolution
		# 稳健计数 +1
		_ensure_xinxing_tracker()
		var tracker: Dictionary = world_state["xinxingTracker"]
		tracker["steady_count"] = int(tracker.get("steady_count", 0)) + 1
		world_state["xinxingTracker"] = tracker
		_check_xinxing_transition()

	_pending_turn_context.erase("selected_option")
	_pending_turn_context.erase("check_result")
	_pending_turn_context.erase("risk_modifiers")
	_pending_turn_context["phase"] = "confirm"
	_apply_resolution(resolution, event_def)
	# -2 阶段关系回响：孤注一掷路径使用原始 check_result（回响仅关注关系判定详情）。
	_try_relationship_echo(original_check_result)
	# 记录心性转移
	var xinxing_after := _get_current_xinxing()
	if xinxing_after != xinxing_before:
		_last_xinxing_transition = {"old_value": xinxing_before, "new_value": xinxing_after}
	return _finalize_option_turn(event_def)

# 功能：处理自省事件阶段。
# 说明：解码 "action:target" 格式的操作编码，委托给自省状态机执行。
#       状态机返回 SETTLED 时消费 forcedNextEventId、推进回合；否则返回 pending 响应。
func _resolve_reflection_phase(
	selected_option_id: String,
	event_id: String,
	route: String,
	expected_forced: String,
	event_def: Dictionary
) -> Dictionary:
	# 首次进入自省 phase 时启动状态机。
	if not _reflection_sm.is_active():
		var start_result: Dictionary = _reflection_sm.start(self)
		print("[自省调度] 状态机已启动: %s" % str(start_result.get("state", "")))
		# 启动后如果已经直接 SETTLED（如空自省 confirm），走结算。
		if str(start_result.get("state", "")) == "SETTLED":
			return _finalize_reflection_turn(event_id, route, expected_forced, event_def)
		# 首次进入时如果没有传入操作，返回 pending 响应让 UI 获取初始状态。
		if selected_option_id.strip_edges().is_empty():
			_pending_turn_context["reflection_result"] = start_result
			return _build_pending_turn_response(_pending_turn_context)

	# 解码 "action:target" 格式。
	var parts: Array = selected_option_id.split(":", true, 1)
	var action := str(parts[0]).strip_edges() if parts.size() > 0 else ""
	var target := str(parts[1]).strip_edges() if parts.size() > 1 else ""

	if action.is_empty():
		return _build_pending_turn_response(_pending_turn_context)

	# 委托状态机执行操作。
	var act_result: Dictionary = _reflection_sm.act(action, target)
	print("[自省调度] act(%s, %s) → state=%s" % [action, target, str(act_result.get("state", ""))])
	_pending_turn_context["reflection_result"] = act_result

	# 状态机 SETTLED → 清除 pending_turn，推进回合。
	if str(act_result.get("state", "")) == "SETTLED":
		return _finalize_reflection_turn(event_id, route, expected_forced, event_def)

	# 未结算，返回 pending 响应继续等待下一步操作。
	return _build_pending_turn_response(_pending_turn_context)


# 功能：自省结算后完成回合推进。
# 说明：叙事包联动——自省作为包的终结环节，不消耗回合、不推进任务计时器。
#       仅执行历史记录和 continuation policy。自省完成后清空 packContext，进入地点选择。
func _finalize_reflection_turn(
	event_id: String,
	route: String,
	expected_forced: String,
	event_def: Dictionary
) -> Dictionary:
	# 消费 forcedNextEventId，与其他事件结算一致。
	world_state["forcedNextEventId"] = ""
	_apply_continuation_policy(event_def)
	_eval_complete_when_after_settlement()
	_record_history(event_id)
	# 叙事包联动：自省不消耗回合，不推进任务计时器。
	# _tick_tasks_after_turn() 和 turn += 1 被移除。
	_pending_turn_context.clear()
	# 叙事包联动：自省完成后清空包状态，下次进入地点选择。
	_clear_pack_context()
	print("[自省调度] 结算完成（不消耗回合），turn=%d" % int(world_state.get("turn", 0)))
	return _build_result_payload(
		route,
		event_id,
		event_def,
		expected_forced,
		false,
		false,
		{}
	)


# 功能：风险入口结算后完成回合推进。
# 说明：抽取自 _resolve_pending_turn 的回合末尾逻辑，避免风险入口与主流程重复编写。
func _finalize_option_turn(event_def: Dictionary) -> Dictionary:
	# 说明：统一执行事件级 effects（如 setFlags），确保一次性事件的 flag 在所有选项路径下都正确写入。
	_apply_event_effects(event_def)

	var event_id := str(_pending_turn_context.get("event_id", ""))
	var route := str(_pending_turn_context.get("route", "scheduler"))
	var expected_forced := str(_pending_turn_context.get("expected_forced", ""))

	# 事件叙事反馈 MVP A：风险路径（preemptive_bet / desperate_gamble）结算完毕后同样
	# 尝试追加 outcome 叙事屏；追加成功 → 切 phase=presentation + 标 _outcome_pending=true，
	# 玩家翻完 outcome 后下次 _resolve_pending_turn(confirm) 走 _finalize_post_outcome_settlement
	# 直接收口（避免 _apply_event_effects 重复跑两次）。
	var settled_option: Dictionary = _dict_or_empty(_pending_turn_context.get("_settled_option", {}))
	if not settled_option.is_empty():
		if _try_append_option_outcomes_and_redirect(settled_option, event_def):
			return _build_pending_turn_response(_pending_turn_context)

	return _finalize_post_outcome_settlement(event_id, route, expected_forced, event_def)


# 功能：选项结算尾段（含 history / 任务 tick / turn 推进 / pack 推进 / pending 清空）。
# 说明：事件叙事反馈 MVP A 抽出共享尾段，被两类入口复用：
#         1. _finalize_option_turn 风险路径无 outcome 时直接调用
#         2. _resolve_pending_turn confirm 分支下 _outcome_pending=true 时（玩家翻完
#            outcome 屏后回到 confirm）调用，跳过选项结算重跑。
# 注意：本函数假设 _apply_event_effects 已在调用方执行。
func _finalize_post_outcome_settlement(
	event_id: String,
	route: String,
	expected_forced: String,
	event_def: Dictionary
) -> Dictionary:
	var pending_has_choice: bool = bool(_pending_turn_context.get("has_choice", false))
	var pending_choice: Dictionary = _dict_or_empty(_pending_turn_context.get("choice", {}))
	var choice_result: Dictionary = pending_choice.duplicate(true)

	_eval_complete_when_after_settlement()
	_record_history(event_id)
	# 叙事包联动：使用缓存的 deferred 状态，避免链退出后 chainContext 被清空导致误判。
	var was_deferred: bool = bool(_pending_turn_context.get("_was_in_deferred_chain", false))
	if not was_deferred:
		_tick_tasks_after_turn()
	var ended_this_turn: bool = false
	if bool(event_def.get("isEndingEvent", false)):
		_finalize_world(event_id)
		ended_this_turn = true
	if not ended_this_turn:
		if not was_deferred:
			world_state["turn"] = int(world_state.get("turn", 0)) + 1
			# 叙事包联动：推进包内回合计数。
			_advance_pack_turn()
		_pending_turn_context.clear()

	return _build_result_payload(
		route,
		event_id,
		event_def,
		expected_forced,
		false,
		pending_has_choice,
		choice_result
	)


# 功能：尝试为已结算的 selected option 追加 outcome 叙事屏（事件叙事反馈 MVP A）。
# 说明：从 selected_option["outcomes"] 字典按 branch 抽取文本组（branch fallback 链：
#         critical_success → success → default
#         critical_fail    → fail    → default
#       success / fail 自身找不到时 fallback 到 default）。
#       命中即追加 _dynamic=true 虚拟 presentation 行，切 phase=presentation +
#       presentation_index 指向第一条 outcome 屏 + 标 _outcome_pending=true，返回 true。
#       未命中（无 outcomes 字段 / 对应分支无文本）返回 false，调用方走默认结算尾段。
# 设计基线见 [[事件叙事反馈_MVP设计]]。
func _try_append_option_outcomes_and_redirect(selected_option: Dictionary, event_def: Dictionary) -> bool:
	var outcomes_dict: Dictionary = _dict_or_empty(selected_option.get("outcomes", {}))
	if outcomes_dict.is_empty():
		return false

	# 决议 branch：有 check 走 _last_check_result.result_type；无 check 走 default。
	var branch: String = "default"
	if not _last_check_result.is_empty():
		var rt: String = str(_last_check_result.get("result_type", "")).strip_edges()
		if not rt.is_empty():
			branch = rt

	# branch 抽取 + fallback 链。
	var texts: Array = _resolve_outcome_branch_texts(outcomes_dict, branch)
	if texts.is_empty():
		return false

	var event_id: String = str(event_def.get("id", ""))
	var presentation_items: Array = _get_event_presentation(event_def)
	var max_seq: int = 0
	for it_var in presentation_items:
		var it: Dictionary = it_var
		max_seq = max(max_seq, int(it.get("order", 0)))
	var first_outcome_index: int = presentation_items.size()
	var option_id: String = str(selected_option.get("id", ""))
	for i in range(texts.size()):
		presentation_items.append({
			"id": "%s_outcome_%s_%d" % [option_id, branch, i + 1],
			"order": max_seq + i + 1,
			"type": "text",
			"speaker": "",
			"text": str(texts[i]),
			"presents": "text",
			"_dynamic": true
		})
	event_def["presentation"] = presentation_items
	_event_map[event_id] = event_def

	# 切 phase=presentation 让玩家翻 outcome 屏；同时记 _outcome_pending=true，
	# 翻完后回到 confirm 时直接走 _finalize_post_outcome_settlement。
	_pending_turn_context["phase"] = "presentation"
	_pending_turn_context["presentation_index"] = first_outcome_index
	_pending_turn_context["_outcome_pending"] = true
	print("[outcome] 选项 %s 追加 outcome 屏 %d 条 | branch=%s" % [option_id, texts.size(), branch])
	return true


# 功能：按 branch fallback 链解析 outcome 文本组。
# 说明：选项 outcomes 字典结构 { branch: [text1, text2, ...] }；本函数实现 branch 抽取链：
#         critical_success → success → default
#         critical_fail    → fail    → default
#         fail             → default
#         success          → default
#         其他自定义 branch → 直接查（无 fallback）
#       全部 fallback 失败返回 [] 空数组。
func _resolve_outcome_branch_texts(outcomes_dict: Dictionary, branch: String) -> Array:
	var fallback_chain: Array = []
	match branch:
		"critical_success":
			fallback_chain = ["critical_success", "success", "default"]
		"critical_fail":
			fallback_chain = ["critical_fail", "fail", "default"]
		"success":
			fallback_chain = ["success", "default"]
		"fail":
			fallback_chain = ["fail", "default"]
		_:
			fallback_chain = [branch]
	for b in fallback_chain:
		var key: String = str(b)
		if outcomes_dict.has(key):
			var texts: Array = outcomes_dict[key]
			if not texts.is_empty():
				return texts
	return []

# 功能：打印 assessment 骰池鉴定调试信息。
# 说明：在 _is_check_pass 委托 RuleEngine 计算后，输出骰面、命中数等骰池详情。
func _print_assessment_debug(check: Dictionary, result: Dictionary) -> void:
	var hit_threshold := int(check.get("hitThreshold", 6))
	var required_hits := int(check.get("requiredHits", 1))
	var items: Array = check.get("items", [])
	var use_role_state := player_role_state != null
	var role_or_player: Variant = player_role_state if use_role_state else world_state.get("player", {})
	var items_debug := ""
	for item_variant in items:
		var item: Dictionary = item_variant
		var key := str(item.get("key", ""))
		var direction := str(item.get("direction", "positive"))
		var stage: int
		if use_role_state:
			stage = RuleEngine.get_stage_from_role(player_role_state, key, _assessment_thresholds)
		else:
			stage = RuleEngine.get_ability_stage(int(role_or_player.get(key, 0)), _assessment_thresholds)
		var sign := "+" if direction != "negative" else "-"
		if not items_debug.is_empty():
			items_debug += " / "
		items_debug += "%s(stage=%d, %s)" % [key, stage, sign]
	var score := int(result.get("score", 0))
	var pool_size := int(result.get("pool_size", 0))
	var dice: Array = result.get("dice", [])
	var hits := int(result.get("hits", 0))
	var result_type := str(result.get("result_type", ""))
	print("[鉴定] items: %s | score: %d | pool: %dd10 | dice: %s | hits: %d/%d (≥%d) | result: %s" % [
		items_debug, score, pool_size, str(dice), hits, required_hits, hit_threshold, result_type
	])
	# 关系修正调试输出
	var rel_details: Array = result.get("relationship_details", [])
	for rel_entry_variant in rel_details:
		var rel_entry: Dictionary = rel_entry_variant
		var npc_id := str(rel_entry.get("npc_id", ""))
		var detail: Dictionary = rel_entry.get("detail", {})
		var npc_tier := str(detail.get("npc_tier", ""))
		var player_tier := str(detail.get("player_tier", ""))
		var direction := str(detail.get("direction", ""))
		var aligned := bool(detail.get("aligned", false))
		var bias := int(detail.get("bias", 0))
		var rolls: Array = detail.get("rolls", [])
		var rolls_str := ""
		for roll_variant in rolls:
			var roll: Dictionary = roll_variant
			if not rolls_str.is_empty():
				rolls_str += ", "
			rolls_str += "d10=%d vs≤%d→%s" % [
				int(roll.get("die", 0)),
				int(roll.get("hit_value", 0)),
				"hit" if bool(roll.get("success", false)) else "miss"
			]
		print("[关系修正] npc: %s | npc_tier: %s | player_tier: %s | dir: %s | aligned: %s | rolls: [%s] | bias: %+d" % [
			npc_id, npc_tier, player_tier, direction, str(aligned), rolls_str, bias
		])

# 功能：获取关系数据快照，供 UI 读取当前所有关系分值和档位。
# 说明：返回数组 [{from, to, score, tier}, ...]，无关系数据时返回空数组。
func get_affinity_snapshot() -> Array:
	if _affinity_map == null:
		return []
	var pairs := _affinity_map.get_all_pairs()
	var result: Array = []
	for pair_variant in pairs:
		var pair: Dictionary = pair_variant
		var score := int(pair.get("score", 0))
		var tier := RuleEngine.affinity_tier(score, _affinity_thresholds)
		result.append({
			"from": str(pair.get("from", "")),
			"to": str(pair.get("to", "")),
			"score": score,
			"tier": tier
		})
	return result

# 功能：获取鉴定阈值数组，供 UI 计算能力阶段。
func get_assessment_thresholds() -> Array:
	return _assessment_thresholds

# 功能：初始化关系系统，加载五档阈值和初始关系分值。
func _init_affinity_system() -> void:
	# 读取 affinityConfig（五档阈值 + 回响参数）
	_affinity_thresholds = _dict_or_empty(world_state.get("affinityConfig", {}))
	# 初始化 AffinityMap，从 affinityInit 加载初始关系分值
	_affinity_map = AffinityMapClass.new()
	var affinity_init: Dictionary = _dict_or_empty(world_state.get("affinityInit", {}))
	for pair_key in affinity_init.keys():
		var parts := str(pair_key).split("->", false, 1)
		if parts.size() == 2:
			var from_id := parts[0].strip_edges()
			var to_id := parts[1].strip_edges()
			_affinity_map.set_score(from_id, to_id, int(affinity_init[pair_key]))
	if not affinity_init.is_empty():
		print("[关系] AffinityMap 已初始化，共 %d 条关系" % affinity_init.size())

# 功能：执行 affinityDeltas 配置驱动的关系变更。
# 说明：NPC→玩家方向直接执行；玩家→NPC 方向受关注过滤。
func _apply_affinity_deltas(deltas: Array) -> void:
	for delta_variant in deltas:
		var delta_entry: Dictionary = delta_variant
		var from_id := str(delta_entry.get("from", ""))
		var to_id := str(delta_entry.get("to", ""))
		var delta_value := int(delta_entry.get("delta", 0))
		if from_id.is_empty() or to_id.is_empty() or delta_value == 0:
			continue
		# 玩家→NPC 方向受关注过滤
		if from_id == "player" and not _is_player_focusing(to_id):
			print("[关系] 玩家未关注 %s，跳过 affinity delta" % to_id)
			continue
		var current := _affinity_map.get_score(from_id, to_id)
		var result := RuleEngine.apply_affinity_delta(current, delta_value, _affinity_thresholds)
		var new_score := int(result.get("score", 0))
		var new_tier := str(result.get("tier", ""))
		_affinity_map.set_score(from_id, to_id, new_score)
		# 记录关系变化，供 payload 透传给 UI。
		_last_affinity_changes.append({
			"from": from_id, "to": to_id,
			"delta": delta_value, "old_score": current,
			"new_score": new_score, "new_tier": new_tier
		})
		# 同步追加到周期级累积记录，供自省系统汇总推荐。
		_cycle_affinity_changes.append({
			"from": from_id, "to": to_id,
			"delta": delta_value, "old_score": current,
			"new_score": new_score, "new_tier": new_tier
		})
		print("[关系] %s->%s: %d → %d (delta: %+d, tier: %s)" % [
			from_id, to_id, current, new_score, delta_value, new_tier
		])

# 功能：判断玩家是否关注指定 NPC。
# 说明：读取玩家关注列表；player_role_state 为 null 时兜底返回 true（全部关注）。
func _is_player_focusing(npc_id: String) -> bool:
	if player_role_state == null:
		return true
	return player_role_state.is_focusing(npc_id)

# 功能：检查并触发 -2 阶段关系回响。
# 说明：遍历 check_result 中的 relationship_details，对每个 NPC 调用 _apply_relationship_echo。
func _try_relationship_echo(check_result: Dictionary) -> void:
	if _affinity_map == null:
		return
	if _get_current_xinxing() != -2:
		return
	var rel_details: Array = check_result.get("relationship_details", [])
	if rel_details.is_empty():
		return
	for rel_entry_variant in rel_details:
		var rel_entry: Dictionary = rel_entry_variant
		var npc_id := str(rel_entry.get("npc_id", ""))
		var detail: Dictionary = rel_entry.get("detail", {})
		var rolls: Array = detail.get("rolls", [])
		var npc_tier := str(detail.get("npc_tier", ""))
		var player_tier := str(detail.get("player_tier", ""))
		var direction := str(detail.get("direction", ""))
		_apply_relationship_echo(npc_id, rolls, npc_tier, player_tier, direction)

# 功能：-2 阶段关系回响自动反馈。
# 说明：当心性 -2、态度对齐、且关系掷骰任意一次成功时，自动修改 NPC→玩家关系分值。
#       后续设计调整只改这一个方法。
func _apply_relationship_echo(
	npc_id: String,
	roll_results: Array,
	npc_to_player_tier: String,
	player_to_npc_tier: String,
	direction: String
) -> void:
	if npc_id.is_empty() or direction == "none":
		return
	# 检查是否对齐
	var is_aligned := false
	if direction == "add" and (player_to_npc_tier == "trust" or player_to_npc_tier == "devotion"):
		is_aligned = true
	elif direction == "remove" and (player_to_npc_tier == "distrust" or player_to_npc_tier == "hatred"):
		is_aligned = true
	if not is_aligned:
		return
	# 检查是否有任意一次成功
	var any_success := false
	for roll_variant in roll_results:
		var roll: Dictionary = roll_variant
		if bool(roll.get("success", false)):
			any_success = true
			break
	if not any_success:
		return
	# 根据对齐方向决定关系变化
	var echo_delta := 0
	if direction == "add":
		echo_delta = int(_affinity_thresholds.get("echo_trust_delta", 5))
	else:
		echo_delta = int(_affinity_thresholds.get("echo_distrust_delta", -5))
	# 执行 NPC→玩家关系变化
	var current := _affinity_map.get_score(npc_id, "player")
	var result := RuleEngine.apply_affinity_delta(current, echo_delta, _affinity_thresholds)
	var echo_new_score: int = int(result.get("score", 0))
	var echo_new_tier: String = str(result.get("tier", ""))
	_affinity_map.set_score(npc_id, "player", echo_new_score)
	# 追加到周期级累积记录，供自省系统汇总推荐。
	_cycle_affinity_changes.append({
		"from": npc_id, "to": "player",
		"delta": echo_delta, "old_score": current,
		"new_score": echo_new_score, "new_tier": echo_new_tier
	})
	print("[关系回响] -2阶段 %s->player: %d → %d (echo_delta: %+d, tier: %s)" % [
		npc_id, current, echo_new_score, echo_delta, echo_new_tier
	])

# 功能：应用 resolution，并衔接执行锁更新。
# 说明：统一处理 worldStatePatch、forcedNextEventId、chainContextPatch。
func _apply_resolution(resolution: Dictionary, event_def: Dictionary) -> void:
	# 说明：resolution 统一处理三类后果：worldStatePatch、forcedNextEventId、chainContextPatch。
	var world_patch := _dict_or_empty(resolution.get("worldStatePatch", {}))
	_apply_world_state_patch(world_patch)

	if resolution.has("forcedNextEventId"):
		var forced_id := str(resolution.get("forcedNextEventId", "")).strip_edges()
		world_state["forcedNextEventId"] = forced_id

	var chain_patch := _dict_or_empty(resolution.get("chainContextPatch", {}))
	_apply_continuation_policy(event_def, chain_patch)

	var task_actions := _array_or_empty(resolution.get("taskActions", []))
	_apply_task_actions(task_actions)

	# 关系变化：执行 affinityDeltas 配置驱动的关系变更。
	var affinity_deltas: Array = resolution.get("affinityDeltas", [])
	if not affinity_deltas.is_empty() and _affinity_map != null:
		_apply_affinity_deltas(affinity_deltas)

	# 关注列表修改：执行 focusPatch 配置驱动的关注列表变更。
	if resolution.has("focusPatch") and player_role_state != null:
		_apply_focus_patch(resolution.get("focusPatch", {}))


# 功能：应用关注列表修改补丁。
# 说明：支持 add（添加）、remove（移除）、set（替换）三种操作。
func _apply_focus_patch(patch: Dictionary) -> void:
	var op: String = str(patch.get("op", ""))
	var npcs: Array = patch.get("npcs", [])
	match op:
		"add":
			for npc_id_variant in npcs:
				var npc_id: String = str(npc_id_variant)
				player_role_state.add_focus(npc_id)
			print("[关注] add: %s → 当前关注列表: %s" % [str(npcs), str(player_role_state.focusing_npcs)])
		"remove":
			for npc_id_variant in npcs:
				var npc_id: String = str(npc_id_variant)
				player_role_state.remove_focus(npc_id)
			print("[关注] remove: %s → 当前关注列表: %s" % [str(npcs), str(player_role_state.focusing_npcs)])
		"set":
			player_role_state.init_focusing_npcs(npcs)
			print("[关注] set: %s" % str(player_role_state.focusing_npcs))
		_:
			print("[关注] 未知 focusPatch op: %s" % op)


# 功能：确保任务运行时结构完整。
# 说明：兼容旧存档或缺省配置，保证任务系统逻辑始终有稳定结构可写。
func _ensure_task_runtime_state() -> void:
	var task_config := _dict_or_empty(world_state.get("taskConfig", {}))
	task_config["maxActiveCount"] = maxi(1, int(task_config.get("maxActiveCount", 1)))
	world_state["taskConfig"] = task_config

	var tasks_state := _dict_or_empty(world_state.get("tasks", {}))
	var active := _array_or_empty(tasks_state.get("active", []))
	var completed := _array_or_empty(tasks_state.get("completed", []))
	var failed := _array_or_empty(tasks_state.get("failed", []))
	var abandoned := _array_or_empty(tasks_state.get("abandoned", []))
	var result_records := _array_or_empty(tasks_state.get("resultRecords", []))
	tasks_state["active"] = active
	tasks_state["completed"] = completed
	tasks_state["failed"] = failed
	tasks_state["abandoned"] = abandoned
	tasks_state["resultRecords"] = result_records
	world_state["tasks"] = tasks_state


# 功能：执行任务动作数组。
# 说明：任务动作属于软失败链路，单条动作异常不会中断主循环。
func _apply_task_actions(task_actions: Array) -> void:
	if task_actions.is_empty():
		return
	_ensure_task_runtime_state()
	for action_variant in task_actions:
		if typeof(action_variant) != TYPE_DICTIONARY:
			continue
		var action: Dictionary = action_variant
		_apply_task_action(action)


# 功能：执行单条任务动作。
# 说明：支持 accept_task、advance_task、abandon_task、complete_task 四类 MVP 动作。
func _apply_task_action(action: Dictionary) -> void:
	var op := str(action.get("op", "")).strip_edges()
	var task_id := str(action.get("taskId", "")).strip_edges()
	match op:
		"accept_task":
			_accept_task(task_id)
		"advance_task":
			var progress_key := str(action.get("progressKey", "progress")).strip_edges()
			var delta := int(action.get("delta", 1))
			_advance_task(task_id, progress_key, delta)
		"abandon_task":
			_abandon_task(task_id)
		"complete_task":
			_complete_task(task_id)
		_:
			pass


# 功能：判断任务是否已经进入任务系统已知集合。
# 说明：只要任务存在于 active、completed、failed、abandoned 任一列表，就视为已知任务，不再自动接取。
func _is_task_known(task_id: String) -> bool:
	var normalized_id := task_id.strip_edges()
	if normalized_id.is_empty():
		return false

	_ensure_task_runtime_state()
	if _find_active_task_index(normalized_id) >= 0:
		return true

	var tasks_state: Dictionary = _dict_or_empty(world_state.get("tasks", {}))
	var archive_keys: Array = ["completed", "failed", "abandoned"]
	for archive_key_variant in archive_keys:
		var archive_key: String = str(archive_key_variant)
		var archive_list: Array = _array_or_empty(tasks_state.get(archive_key, []))
		if archive_list.has(normalized_id):
			return true
	return false


# 功能：检查并自动接取满足 accept_when 的任务。
# 说明：该检查发生在选取回合事件之前，使新接取任务能立即参与本回合的事件权重计算。
func _check_auto_accept_tasks() -> void:
	_ensure_task_runtime_state()

	var tasks_state: Dictionary = _dict_or_empty(world_state.get("tasks", {}))
	var active: Array = _array_or_empty(tasks_state.get("active", []))
	var task_config: Dictionary = _dict_or_empty(world_state.get("taskConfig", {}))
	var max_active_count: int = maxi(1, int(task_config.get("maxActiveCount", 1)))
	if active.size() >= max_active_count:
		return

	for task_id_variant in _task_def_map.keys():
		var task_id: String = str(task_id_variant).strip_edges()
		if task_id.is_empty():
			continue
		var task_def: Dictionary = _dict_or_empty(_task_def_map.get(task_id, {}))
		if task_def.is_empty():
			continue

		var accept_when: String = str(task_def.get("acceptWhen", "")).strip_edges()
		if accept_when.is_empty():
			continue
		if _is_task_known(task_id):
			continue

		# 说明：每次接取后重新读取 active 数量，确保严格遵守并行任务上限。
		tasks_state = _dict_or_empty(world_state.get("tasks", {}))
		active = _array_or_empty(tasks_state.get("active", []))
		if active.size() >= max_active_count:
			break

		if _is_task_complete_when_satisfied({}, accept_when):
			_accept_task(task_id)


# 功能：接取任务并写入 active 列表。
# 说明：接取时会校验并行上限与任务定义存在性，重复接取同一 active 任务会被忽略。
func _accept_task(task_id: String) -> bool:
	var normalized_id := task_id.strip_edges()
	if normalized_id.is_empty():
		return false
	if _find_active_task_index(normalized_id) >= 0:
		return true

	var task_def := _dict_or_empty(_task_def_map.get(normalized_id, {}))
	if task_def.is_empty():
		return false

	var tasks_state := _dict_or_empty(world_state.get("tasks", {}))
	var active := _array_or_empty(tasks_state.get("active", []))
	var task_config := _dict_or_empty(world_state.get("taskConfig", {}))
	var max_active_count := maxi(1, int(task_config.get("maxActiveCount", 1)))
	if active.size() >= max_active_count:
		return false

	var current_turn := int(world_state.get("turn", 1))
	var duration_turns := maxi(1, int(task_def.get("durationTurns", 1)))
	active.append(
		{
			"taskId": normalized_id,
			"acceptedTurn": current_turn,
			# 说明：duration_turns 不包含接取任务的当回合，而是从下一回合开始计算。
			"deadlineTurn": current_turn + duration_turns,
			"status": "active",
			"progress": {}
		}
	)
	tasks_state["active"] = active
	_remove_task_id_from_archives(tasks_state, normalized_id)
	world_state["tasks"] = tasks_state
	return true


# 功能：推进任务进度。
# 说明：仅对 active 任务生效；progressKey 为空时回退到默认 progress。
func _advance_task(task_id: String, progress_key: String, delta: int) -> bool:
	var normalized_id := task_id.strip_edges()
	if normalized_id.is_empty():
		return false
	var index := _find_active_task_index(normalized_id)
	if index < 0:
		return false

	var tasks_state := _dict_or_empty(world_state.get("tasks", {}))
	var active := _array_or_empty(tasks_state.get("active", []))
	if index >= active.size():
		return false

	var task_runtime := _dict_or_empty(active[index])
	var key := progress_key.strip_edges()
	if key.is_empty():
		key = "progress"
	var progress := _dict_or_empty(task_runtime.get("progress", {}))
	progress[key] = int(progress.get(key, 0)) + delta
	task_runtime["progress"] = progress
	active[index] = task_runtime
	tasks_state["active"] = active
	world_state["tasks"] = tasks_state
	return true


# 功能：放弃任务。
# 说明：只对 active 任务生效，放弃后会归档到 abandoned 列表。
func _abandon_task(task_id: String) -> bool:
	return _finalize_task(task_id, "abandoned", "manual")


# 功能：完成任务。
# 说明：只对 active 任务生效，完成后会归档到 completed 列表。
func _complete_task(task_id: String) -> bool:
	return _finalize_task(task_id, "completed", "manual")


# 功能：结束 active 任务并归档。
# 说明：封装 completed/abandoned 两类共享迁移动作。
# 功能：统一处理任务终态结算。
# 说明：里程碑 3 在同一入口串联状态归档、完成档位计算、评价后果应用和结果记录。
func _finalize_task(task_id: String, status: String, reason: String = "") -> bool:
	var normalized_id := task_id.strip_edges()
	if normalized_id.is_empty():
		return false
	var normalized_status := status.strip_edges().to_lower()
	if normalized_status != "completed" and normalized_status != "failed" and normalized_status != "abandoned":
		return false

	var index := _find_active_task_index(normalized_id)
	if index < 0:
		return false

	var tasks_state := _dict_or_empty(world_state.get("tasks", {}))
	var active := _array_or_empty(tasks_state.get("active", []))
	if index >= active.size():
		return false
	var task_runtime := _dict_or_empty(active[index]).duplicate(true)
	active.remove_at(index)
	tasks_state["active"] = active

	var score: Variant = null
	var grade_id := ""
	if normalized_status == "completed":
		var task_def := _dict_or_empty(_task_def_map.get(normalized_id, {}))
		var grade_eval := _evaluate_task_grade(task_runtime, task_def)
		score = grade_eval.get("score", null)
		var base_grade_id := str(grade_eval.get("baseGradeId", "")).strip_edges()
		grade_id = _apply_grade_overrides(task_runtime, task_def, base_grade_id)

	_apply_task_evaluation_effects(normalized_id, normalized_status, grade_id)
	_archive_task_id(tasks_state, normalized_status, normalized_id)
	_append_task_result_record(tasks_state, task_runtime, normalized_status, grade_id, score, reason)
	world_state["tasks"] = tasks_state
	return true


# 功能：回合结束后推进任务并处理到期状态。
# 说明：任务到期后按 onExpire 归档，默认归档到 failed。
func _tick_tasks_after_turn() -> void:
	_ensure_task_runtime_state()
	var tasks_state := _dict_or_empty(world_state.get("tasks", {}))
	var active := _array_or_empty(tasks_state.get("active", []))
	if active.is_empty():
		return

	var current_turn := int(world_state.get("turn", 1))
	var expire_actions: Array = []
	for runtime_variant in active:
		var task_runtime := _dict_or_empty(runtime_variant)
		var task_id := str(task_runtime.get("taskId", "")).strip_edges()
		var deadline_turn := int(task_runtime.get("deadlineTurn", 0))
		if task_id.is_empty():
			continue
		if deadline_turn > 0 and current_turn >= deadline_turn:
			var task_def := _dict_or_empty(_task_def_map.get(task_id, {}))
			var on_expire := str(task_def.get("onExpire", "fail")).strip_edges().to_lower()
			var final_status := "failed"
			match on_expire:
				"abandon", "abandoned":
					final_status = "abandoned"
				"complete", "completed", "success":
					final_status = "completed"
			expire_actions.append({"taskId": task_id, "status": final_status, "reason": "expired"})

	for action_variant in expire_actions:
		var action := _dict_or_empty(action_variant)
		var task_id := str(action.get("taskId", "")).strip_edges()
		var status := str(action.get("status", "failed")).strip_edges()
		var reason := str(action.get("reason", "expired")).strip_edges()
		_finalize_task(task_id, status, reason)

# 功能：计算任务完成时的基础档位。
# 说明：按指标累计 score，再映射 score_band 得到 baseGradeId。
func _evaluate_task_grade(task_runtime: Dictionary, task_def: Dictionary) -> Dictionary:
	var task_id := str(task_runtime.get("taskId", task_def.get("id", ""))).strip_edges()
	if task_id.is_empty():
		return {"score": 0, "baseGradeId": ""}
	var eval_bucket := _dict_or_empty(_task_eval_index_by_task.get(task_id, {}))
	if eval_bucket.is_empty():
		return {"score": 0, "baseGradeId": ""}

	var indicators: Array = _array_or_empty(eval_bucket.get("indicators", []))
	var score := 0
	for indicator_variant in indicators:
		var indicator := _dict_or_empty(indicator_variant)
		var left := str(indicator.get("left", "")).strip_edges()
		var op := str(indicator.get("op", "")).strip_edges()
		var right := str(indicator.get("right", "")).strip_edges()
		if left.is_empty() or op.is_empty() or right.is_empty():
			score += int(indicator.get("failScore", 0))
			continue
		var actual: Variant = _resolve_task_condition_value(task_runtime, left)
		var expected: Variant = _parse_literal(right)
		if _compare_values(actual, op, expected):
			score += int(indicator.get("passScore", 0))
		else:
			score += int(indicator.get("failScore", 0))

	var base_grade_id := ""
	var score_bands: Array = _array_or_empty(eval_bucket.get("scoreBands", []))
	for grade_variant in score_bands:
		var grade := _dict_or_empty(grade_variant)
		var min_score := float(grade.get("minScore", 0.0))
		var max_score := float(grade.get("maxScore", 0.0))
		if float(score) >= min_score and float(score) <= max_score:
			base_grade_id = str(grade.get("gradeId", "")).strip_edges()
			break

	return {"score": score, "baseGradeId": base_grade_id}


# 功能：应用任务档位分流规则。
# 说明：按 priority 降序匹配，命中首条即返回最终档位。
func _apply_grade_overrides(task_runtime: Dictionary, task_def: Dictionary, base_grade: String) -> String:
	var task_id := str(task_runtime.get("taskId", task_def.get("id", ""))).strip_edges()
	if task_id.is_empty():
		return base_grade
	var eval_bucket := _dict_or_empty(_task_eval_index_by_task.get(task_id, {}))
	if eval_bucket.is_empty():
		return base_grade

	var final_grade := base_grade
	var grade_overrides: Array = _array_or_empty(eval_bucket.get("gradeOverrides", []))
	for override_variant in grade_overrides:
		var override_row := _dict_or_empty(override_variant)
		var from_grade_id := str(override_row.get("fromGradeId", "")).strip_edges()
		if not from_grade_id.is_empty() and from_grade_id != final_grade:
			continue
		var when_condition := str(override_row.get("when", "")).strip_edges()
		if not when_condition.is_empty() and not _is_task_complete_when_satisfied(task_runtime, when_condition):
			continue
		var to_grade_id := str(override_row.get("toGradeId", "")).strip_edges()
		if to_grade_id.is_empty():
			continue
		final_grade = to_grade_id
		break
	return final_grade


# 功能：按 task/status/grade 应用任务评价后果。
# 说明：优先精确命中 gradeId，若无精确项则回退到 gradeId 为空的通配项。
func _apply_task_evaluation_effects(task_id: String, status: String, grade_id: String) -> void:
	var normalized_task_id := task_id.strip_edges()
	var normalized_status := status.strip_edges().to_lower()
	if normalized_task_id.is_empty() or normalized_status.is_empty():
		return
	var eval_bucket := _dict_or_empty(_task_eval_index_by_task.get(normalized_task_id, {}))
	if eval_bucket.is_empty():
		return

	var effect_rows: Array = _array_or_empty(eval_bucket.get("effects", []))
	if effect_rows.is_empty():
		return

	var exact_effects: Array = []
	var fallback_effects: Array = []
	for effect_variant in effect_rows:
		var effect := _dict_or_empty(effect_variant)
		var row_status := str(effect.get("status", "")).strip_edges().to_lower()
		if row_status != normalized_status:
			continue
		var row_grade_id := str(effect.get("gradeId", "")).strip_edges()
		if not row_grade_id.is_empty() and row_grade_id == grade_id:
			exact_effects.append(effect)
		elif row_grade_id.is_empty():
			fallback_effects.append(effect)

	var matched_effects: Array = exact_effects if not exact_effects.is_empty() else fallback_effects
	for effect_variant in matched_effects:
		_apply_task_evaluation_effect_action(_dict_or_empty(effect_variant))


# 功能：执行单条任务评价效果动作。
# 说明：动作语义与配置侧 option_rules/event_outcomes 保持一致。
func _apply_task_evaluation_effect_action(effect: Dictionary) -> void:
	var target := str(effect.get("target", "")).strip_edges()
	var op := str(effect.get("op", "")).strip_edges()
	var key := str(effect.get("key", "")).strip_edges()
	var value_text := str(effect.get("value", "")).strip_edges()

	if target == "params" and op == "add":
		if key.is_empty():
			return
		_apply_world_state_patch({"params": {key: int(_parse_literal(value_text))}})
		return

	if target == "flags" and op == "set":
		if key.is_empty():
			return
		_apply_world_state_patch({"flags": {key: _parse_literal(value_text)}})
		return

	if target == "player" and op == "add":
		if key.is_empty():
			return
		_apply_world_state_patch({"player": {key: int(_parse_literal(value_text))}})
		return

	if target == "world" and op == "set_location":
		_apply_world_state_patch({"currentLocationId": value_text})
		return

	if target == "world" and op == "set_forced_next":
		world_state["forcedNextEventId"] = value_text
		return

	if target == "world" and op == "clear_forced_next":
		if _to_bool_text(value_text):
			world_state["forcedNextEventId"] = ""
		return

	if target == "world" and op == "end_chain":
		if _to_bool_text(value_text):
			world_state["chainContext"] = null
		return


# 功能：写入任务终态记录。
# 说明：用于验收和后续 UI 展示，保留任务完成时快照信息。
func _append_task_result_record(
	tasks_state: Dictionary,
	task_runtime: Dictionary,
	status: String,
	grade_id: String,
	score: Variant,
	reason: String
) -> void:
	var task_id := str(task_runtime.get("taskId", "")).strip_edges()
	if task_id.is_empty():
		return
	var result_records := _array_or_empty(tasks_state.get("resultRecords", []))
	result_records.append(
		{
			"taskId": task_id,
			"status": status,
			"gradeId": grade_id,
			"score": score,
			"acceptedTurn": int(task_runtime.get("acceptedTurn", 0)),
			"finishedTurn": int(world_state.get("turn", 0)),
			"reason": reason,
			"progress": _dict_or_empty(task_runtime.get("progress", {})).duplicate(true)
		}
	)
	tasks_state["resultRecords"] = result_records


# 功能：将文本转换为 bool。
# 说明：仅文本 true 视为 true，其余一律 false。
func _to_bool_text(raw: String) -> bool:
	return raw.strip_edges().to_lower() == "true"


# 功能：在结算后评估并自动完成任务。
# 说明：判定时机为"事件/选项动作全部落地后，任务回合推进前"，保证同回合达成不会被到期失败覆盖。
func _eval_complete_when_after_settlement() -> void:
	_ensure_task_runtime_state()
	var tasks_state := _dict_or_empty(world_state.get("tasks", {}))
	var active := _array_or_empty(tasks_state.get("active", []))
	if active.is_empty():
		return

	var complete_ids: Array = []
	for runtime_variant in active:
		var task_runtime := _dict_or_empty(runtime_variant)
		var task_id := str(task_runtime.get("taskId", "")).strip_edges()
		if task_id.is_empty():
			continue
		var task_def := _dict_or_empty(_task_def_map.get(task_id, {}))
		if task_def.is_empty():
			continue
		var complete_when := str(task_def.get("completeWhen", "")).strip_edges()
		if complete_when.is_empty():
			continue
		if _is_task_complete_when_satisfied(task_runtime, complete_when):
			complete_ids.append(task_id)

	for task_id_variant in complete_ids:
		_complete_task(str(task_id_variant))


# 功能：判断任务条件表达式是否命中（accept_when / complete_when 共用）。
# 说明：支持分号分隔的多条件 AND 语法，如 "flags.a == true;flags.b == true"。
#       单条件格式为 "<path> <op> <literal>"，支持路径来源 task/progress/world_state。
func _is_task_complete_when_satisfied(task_runtime: Dictionary, condition: String) -> bool:
	# 按分号拆分为多个子条件，全部满足才返回 true（AND 语义）。
	# 无有效子条件时返回 false，避免空字符串或纯分号输入被误判为满足。
	var sub_conditions: Array = condition.split(";", false)
	var evaluated_count: int = 0
	for sub_variant in sub_conditions:
		var sub_condition := str(sub_variant).strip_edges()
		if sub_condition.is_empty():
			continue
		evaluated_count += 1
		if not _eval_single_task_condition(task_runtime, sub_condition):
			return false
	return evaluated_count > 0


# 功能：求值单个条件子表达式。
# 说明：从 _is_task_complete_when_satisfied 拆出，保持单条件求值逻辑独立。
func _eval_single_task_condition(task_runtime: Dictionary, condition: String) -> bool:
	var operators := [">=", "<=", "==", "!=", ">", "<"]
	for op_variant in operators:
		var op := str(op_variant)
		var token := " %s " % op
		if condition.find(token) == -1:
			continue
		var parts := condition.split(token)
		if parts.size() != 2:
			return false
		var left_text := str(parts[0]).strip_edges()
		var right_text := str(parts[1]).strip_edges()
		var actual: Variant = _resolve_task_condition_value(task_runtime, left_text)
		var expected: Variant = _parse_literal(right_text)
		return _compare_values(actual, op, expected)
	return false


# 功能：解析任务条件表达式左值。
# 说明：支持 progress.*、task.*，其余按 world_state 路径读取。
func _resolve_task_condition_value(task_runtime: Dictionary, path: String) -> Variant:
	var normalized_path := path.strip_edges()
	if normalized_path.is_empty():
		return null

	if normalized_path.begins_with("progress."):
		var key_path := normalized_path.trim_prefix("progress.")
		return _resolve_dict_path(_dict_or_empty(task_runtime.get("progress", {})), key_path)

	if normalized_path == "progress":
		return _dict_or_empty(task_runtime.get("progress", {}))

	if normalized_path.begins_with("task."):
		var task_path := normalized_path.trim_prefix("task.")
		return _resolve_dict_path(task_runtime, task_path)

	return _resolve_path_value(normalized_path)


# 功能：按点路径读取字典值。
# 说明：任意层级缺失时返回 null。
func _resolve_dict_path(source: Dictionary, path: String) -> Variant:
	var normalized_path := path.strip_edges()
	if normalized_path.is_empty():
		return null
	var segments := normalized_path.split(".", false)
	if segments.is_empty():
		return null

	var cursor: Variant = source
	for segment_variant in segments:
		var segment := str(segment_variant).strip_edges()
		if segment.is_empty():
			return null
		if typeof(cursor) != TYPE_DICTIONARY:
			return null
		var dict_cursor: Dictionary = cursor
		if not dict_cursor.has(segment):
			return null
		cursor = dict_cursor[segment]
	return cursor


# 功能：查找 active 任务下标。
# 说明：未找到时返回 -1。
func _find_active_task_index(task_id: String) -> int:
	var normalized_id := task_id.strip_edges()
	if normalized_id.is_empty():
		return -1
	var tasks_state := _dict_or_empty(world_state.get("tasks", {}))
	var active := _array_or_empty(tasks_state.get("active", []))
	for idx in range(active.size()):
		var task_runtime := _dict_or_empty(active[idx])
		if str(task_runtime.get("taskId", "")).strip_edges() == normalized_id:
			return idx
	return -1


# 功能：归档任务 ID。
# 说明：同一归档列表内会做去重，避免重复写入。
func _archive_task_id(tasks_state: Dictionary, archive_key: String, task_id: String) -> void:
	var normalized_id := task_id.strip_edges()
	if normalized_id.is_empty():
		return
	var archive := _array_or_empty(tasks_state.get(archive_key, []))
	for item_variant in archive:
		if str(item_variant).strip_edges() == normalized_id:
			tasks_state[archive_key] = archive
			return
	archive.append(normalized_id)
	tasks_state[archive_key] = archive


# 功能：从所有归档列表移除任务 ID。
# 说明：接取任务时执行此操作，保证任务只存在于 active 或单一归档槽位。
func _remove_task_id_from_archives(tasks_state: Dictionary, task_id: String) -> void:
	var normalized_id := task_id.strip_edges()
	if normalized_id.is_empty():
		return
	var archive_keys := ["completed", "failed", "abandoned"]
	for key_variant in archive_keys:
		var key := str(key_variant)
		var source := _array_or_empty(tasks_state.get(key, []))
		var filtered: Array = []
		for item_variant in source:
			if str(item_variant).strip_edges() != normalized_id:
				filtered.append(item_variant)
		tasks_state[key] = filtered

# 功能：应用 worldStatePatch 到 world_state。
# 说明：params 与 player 为增量写入，flags 为覆盖写入。
func _apply_world_state_patch(patch: Dictionary) -> void:
	if patch.is_empty():
		return

	var flags_patch: Dictionary = patch.get("flags", {})
	if not flags_patch.is_empty():
		var flags: Dictionary = world_state.get("flags", {})
		for key in flags_patch.keys():
			flags[str(key)] = flags_patch[key]
		world_state["flags"] = flags

	var params_patch: Dictionary = patch.get("params", {})
	if not params_patch.is_empty():
		var params: Dictionary = world_state.get("params", {})
		for key in params_patch.keys():
			var param_key := str(key)
			params[param_key] = int(params.get(param_key, 0)) + int(params_patch[key])
		world_state["params"] = params

	var player_patch: Dictionary = patch.get("player", {})
	if not player_patch.is_empty():
		# Line B S2: 资源标记池路径 (key 是 *_token / xinxing_token / social_token / gold)
		# 走 ResourceMarkerPool, 由其处理 capacity 上限 (满容量丢弃多余, 与 §7.2 资源稀缺一致)。
		# 非 token key (如 *_exp 经验值、attribute 品质 physique/craft/insight、xinxing 心性值等)
		# 保持 vibe-test 单值累加路径。详见 [[前端骨架_LineB_实施]] §3.9。
		for key in player_patch.keys():
			var player_key := str(key)
			var delta := int(player_patch[key])
			if player_role_state != null and ResourceMarkerPool.ALL_TOKEN_KEYS.has(player_key):
				# 标记池路径: produce (delta > 0) / consume (delta < 0); 满容量丢弃多余
				if delta > 0:
					ResourceMarkerPool.produce(player_role_state, player_key, delta)
				elif delta < 0:
					# consume 不足时不变化 (原子性) — 与 vibe-test 单值会减成负数不同
					# 这里设计为强 clamp 到 0 (与 csv_validator cost 校验 + UI 投入校验保持一致)
					# 说明: player_role_state 静态类型为 Variant, 显式注解避免 `:=` 推断警告。
					var available: int = int(player_role_state.get_resource(player_key, 0))
					var to_consume: int = min(available, -delta)
					if to_consume > 0:
						ResourceMarkerPool.consume(player_role_state, player_key, to_consume)
				# delta == 0 不操作
			else:
				# 单值累加路径 (向后兼容; 非 token key + 无 RoleState 回退)
				var current := _get_player_value(player_key, 0)
				_set_player_value(player_key, current + delta)
		if player_role_state != null:
			_sync_role_to_world_state()

	var set_location := str(patch.get("currentLocationId", "")).strip_edges()
	if not set_location.is_empty():
		world_state["currentLocationId"] = set_location

# 功能：确保心性 tracker 结构完整。
# 说明：从 xinxingConfig 读取阈值配置，初始化 xinxingTracker 计数器。
func _ensure_xinxing_tracker() -> void:
	if not world_state.has("xinxingTracker"):
		world_state["xinxingTracker"] = {"gamble_count": 0, "steady_count": 0}
	var tracker: Dictionary = world_state["xinxingTracker"]
	if not tracker.has("gamble_count"):
		tracker["gamble_count"] = 0
	if not tracker.has("steady_count"):
		tracker["steady_count"] = 0
	world_state["xinxingTracker"] = tracker
	# 确保 xinxingConfig 存在（有默认值兜底）
	if not world_state.has("xinxingConfig"):
		world_state["xinxingConfig"] = {}
	var config: Dictionary = world_state["xinxingConfig"]
	if not config.has("gamble_to_neg1"):
		config["gamble_to_neg1"] = 3
	if not config.has("steady_to_pos1"):
		config["steady_to_pos1"] = 5
	if not config.has("steady_to_pos2"):
		config["steady_to_pos2"] = 5
	if not config.has("gamble_to_exit_positive"):
		config["gamble_to_exit_positive"] = 2
	world_state["xinxingConfig"] = config

# 功能：读取当前心性值。
# 说明：优先从 RoleState 读取，回退到 world_state.player。
func _get_current_xinxing() -> int:
	if player_role_state != null and player_role_state.has_method("get_xinxing"):
		return player_role_state.get_xinxing()
	var player: Dictionary = world_state.get("player", {})
	return int(player.get("xinxing", 0))

# 功能：心性阶段切换检查。
# 说明：在每次孤注一掷使用后和回合结算末尾调用，根据累积计数触发心性偏移。
func _check_xinxing_transition() -> void:
	_ensure_xinxing_tracker()
	var tracker: Dictionary = world_state["xinxingTracker"]
	var config: Dictionary = world_state["xinxingConfig"]
	var current_xinxing := _get_current_xinxing()
	var gamble_count := int(tracker.get("gamble_count", 0))
	var steady_count := int(tracker.get("steady_count", 0))
	var changed := false

	# 孤注一掷累计触发心性下降：当前心性 >= 0 时，连续使用孤注一掷达到阈值会下降到 -1
	if current_xinxing >= 0 and gamble_count >= int(config.get("gamble_to_neg1", 3)):
		current_xinxing = RuleEngine.apply_xinxing_delta(current_xinxing, -1)
		tracker["gamble_count"] = 0
		changed = true
		print("[心性] 孤注一掷累计触发 → 心性下降至 %d" % current_xinxing)

	# 稳健累计触发心性上升：心性 0 → +1
	if current_xinxing == 0 and steady_count >= int(config.get("steady_to_pos1", 5)):
		current_xinxing = RuleEngine.apply_xinxing_delta(current_xinxing, 1)
		tracker["steady_count"] = 0
		changed = true
		print("[心性] 稳健累计触发 → 心性上升至 %d" % current_xinxing)

	# 稳健累计触发心性上升：心性 +1 → +2
	if current_xinxing == 1 and steady_count >= int(config.get("steady_to_pos2", 5)):
		current_xinxing = RuleEngine.apply_xinxing_delta(current_xinxing, 1)
		tracker["steady_count"] = 0
		changed = true
		print("[心性] 稳健累计触发 → 心性上升至 %d" % current_xinxing)

	# 心性 > 0 时使用孤注一掷，累计达阈值直接退回 0（退出正面区间，不分步）
	if current_xinxing > 0 and gamble_count >= int(config.get("gamble_to_exit_positive", 2)):
		current_xinxing = 0
		tracker["gamble_count"] = 0
		changed = true
		print("[心性] 正面区间孤注一掷触发 → 退回中立 0")

	if changed:
		_set_player_value("xinxing", current_xinxing)
		if player_role_state != null:
			_sync_role_to_world_state()
	world_state["xinxingTracker"] = tracker

# 功能：将 RoleState 的能力与状态同步到 world_state.player。
# 说明：RoleState 为权威数据源，world_state.player 作为兼容层供 eligibility 表达式读取。
func _sync_role_to_world_state() -> void:
	if player_role_state == null:
		return
	var player: Dictionary = world_state.get("player", {})
	var flat: Dictionary = player_role_state.to_flat_dict()
	for key in flat.keys():
		player[str(key)] = flat[key]
	world_state["player"] = player

# 功能：合并两个字典。
# 说明：right 覆盖 left 的同名键，并返回新字典。
func _merge_dict(left: Dictionary, right: Dictionary) -> Dictionary:
	var merged := left.duplicate(true)
	for key in right.keys():
		merged[key] = right[key]
	return merged

# 功能：将任意值安全转换为 Dictionary。
# 说明：JSON 允许 null；这里统一收敛为 {}，避免 Nil 到 Dictionary 的赋值错误。
func _dict_or_empty(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_DICTIONARY and value != null:
		return value
	return {}

# 功能：将任意值安全转换为 Array。
# 说明：与 _dict_or_empty 同理，用于兼容 visibilityWhen 等可选数组字段。
func _array_or_empty(value: Variant) -> Array:
	if typeof(value) == TYPE_ARRAY and value != null:
		return value
	return []

# ── 叙事包系统 ──────────────────────────────────────────────────

# 功能：确保 world_state 中存在 packContext。
# 说明：首次加载时初始化为空包状态（locationId 为空表示尚未开始首个包）。
func _ensure_pack_context() -> void:
	if not world_state.has("packContext") or typeof(world_state.get("packContext", null)) != TYPE_DICTIONARY:
		world_state["packContext"] = {
			"locationId": "",
			"turnCapacity": 0,
			"turnsElapsed": 0,
			"interrupted": false
		}


# 功能：初始化叙事包系统配置，从 world_state.packConfig 加载。
# 说明：缺省时使用默认值，保证系统在无配置时也能正常运行。
#       末尾位池抽取相关字段（final_event_pool_tag / final_event_location_boost /
#       final_event_pool_exhausted_forced_id）支持包末位回合从 tag 池抽取骨架事件，
#       具体逻辑见 _select_next_event 中的"末尾位池分支"。
#       配置层留空即不启用末尾位池。设计基线见 [[当前版本完整主路径_MVP设计]] §三·节点 3。
func _init_pack_config() -> void:
	var raw: Dictionary = _dict_or_empty(world_state.get("packConfig", {}))
	_pack_config = {
		"defaultCapacity": int(raw.get("defaultCapacity", 3)),
		"final_event_pool_tag": str(raw.get("final_event_pool_tag", "")).strip_edges(),
		"final_event_location_boost": int(raw.get("final_event_location_boost", 0)),
		"final_event_pool_exhausted_forced_id": str(raw.get("final_event_pool_exhausted_forced_id", "")).strip_edges(),
	}
	# 末尾位池消耗记录（按 tag 分组持久化，支持多池共存与未来阶段切换）。
	# 结构：{ tag → [event_id, ...] }；首次加载时初始化空字典。
	if not world_state.has("finalEventPoolConsumed") or typeof(world_state.get("finalEventPoolConsumed", null)) != TYPE_DICTIONARY:
		world_state["finalEventPoolConsumed"] = {}

	# Step 2 自省事件结构改造相关字段（设计基线见 [[当前版本完整主路径_MVP设计]] §三·节点 2）。
	# visited_locations：跨自省持久；玩家在自省末屏选完地点后追加；导入阶段模式下用于地点选择 UI 过滤。
	# reflection_mode：驱动地点筛选模式（"intro"=导入阶段，逐次变短；"regular"=正式期，全量显示）。
	# last_consumed_skeleton_event_id：上一被消耗的末位池事件 event_id；
	#   由 _mark_final_pool_consumed 自动写入；中段自省 presentation 按 condition 选差分叙事。
	if not world_state.has("visited_locations") or typeof(world_state.get("visited_locations", null)) != TYPE_ARRAY:
		world_state["visited_locations"] = []
	if not world_state.has("reflection_mode") or str(world_state.get("reflection_mode", "")).is_empty():
		# 默认 intro（当前版本走导入阶段模式）；正式期切 regular 由 world_seed 配置或运行时切换。
		world_state["reflection_mode"] = "intro"
	if not world_state.has("last_consumed_skeleton_event_id"):
		world_state["last_consumed_skeleton_event_id"] = ""
	print("[叙事包] packConfig 已加载: %s" % str(_pack_config))


# 功能：初始化 demo 期临时收紧开关（demo_mode_config）。
# 说明：从 world_state.demoModeConfig 加载所有 bool 开关，缺省时默认 false（即不收紧）。
#       重构期审视清单见 [[代码重构_预启动]] §4.3 demo_mode_config 开关清单。
#       规约依赖见 [[鉴定 demo 期表现规约]]（鉴定降配 + 心性完全隐藏决议）。
#       命名规范："行为描述"风格：hide_X_panel_X / disable_X_path / simplify_X_ui。
func _init_demo_mode_config() -> void:
	var raw: Dictionary = _dict_or_empty(world_state.get("demoModeConfig", {}))
	_demo_mode_config = raw
	print("[demo_mode] demoModeConfig 已加载: %s" % str(_demo_mode_config))


# 功能：查询 demo_mode 开关是否启用。
# 说明：UI / 引擎消费位统一通过本 API 查询，便于重构期 grep `is_demo_mode_enabled` 一次性找全所有消费位。
#       缺省 false（未配置时默认不收紧），保证向后兼容。
func is_demo_mode_enabled(key: String) -> bool:
	return bool(_demo_mode_config.get(key, false))


# 功能：判断当前是否处于 deferred 模式的 chain 中。
# 说明：用于回合结算出口决定是否跳过 turn 推进和任务 tick。
func _is_in_deferred_chain() -> bool:
	var raw_ctx: Variant = world_state.get("chainContext", null)
	if typeof(raw_ctx) != TYPE_DICTIONARY or raw_ctx == null:
		return false
	var ctx: Dictionary = raw_ctx
	return str(ctx.get("turnMode", "standard")) == "deferred"


# 功能：链退出时执行延迟结算和叙事包状态更新。
# 说明：deferred 模式下按 deferredTurnCost 批量推进 turn 和任务 tick；
#       standard 模式下无额外操作（每步已正常结算）。
#       无论模式，都标记 packContext.interrupted 并记录是否需要触发自省。
func _finalize_chain_exit(chain_ctx: Dictionary) -> void:
	var turn_mode := str(chain_ctx.get("turnMode", "standard"))
	var trigger_reflection := bool(chain_ctx.get("triggerReflectionOnExit", false))

	# deferred 模式：批量结算冻结的回合。
	# 每次 tick 前先递增 turn，确保 _tick_tasks_after_turn 读取到正确的回合数判断任务到期。
	if turn_mode == "deferred":
		var cost := int(chain_ctx.get("deferredTurnCost", 1))
		if cost > 0:
			for i in range(cost):
				world_state["turn"] = int(world_state.get("turn", 0)) + 1
				_tick_tasks_after_turn()
			print("[叙事包] chain deferred 结算: turn += %d" % cost)

	# 标记当前包被 chain 打断。
	var pack_ctx: Dictionary = _dict_or_empty(world_state.get("packContext", {}))
	if not pack_ctx.is_empty():
		pack_ctx["interrupted"] = true
		world_state["packContext"] = pack_ctx

	# 记录是否需要在包结束后触发自省（由 preview_next_turn 消费）。
	if trigger_reflection:
		world_state["pendingReflectionAfterChain"] = true
	print("[叙事包] chain 退出: turnMode=%s, triggerReflection=%s" % [turn_mode, str(trigger_reflection)])


# 功能：推进叙事包回合计数并检查包是否结束。
# 说明：在标准回合结算后调用。返回 true 表示包已结束，主循环应在下次进入地点选择。
func _advance_pack_turn() -> bool:
	var pack_ctx: Dictionary = _dict_or_empty(world_state.get("packContext", {}))
	if pack_ctx.is_empty() or str(pack_ctx.get("locationId", "")).is_empty():
		return false
	pack_ctx["turnsElapsed"] = int(pack_ctx.get("turnsElapsed", 0)) + 1
	world_state["packContext"] = pack_ctx
	var elapsed := int(pack_ctx.get("turnsElapsed", 0))
	var capacity := int(pack_ctx.get("turnCapacity", 0))
	if capacity > 0 and elapsed >= capacity:
		print("[叙事包] 包已结束: elapsed=%d, capacity=%d" % [elapsed, capacity])
		return true
	return false


# 功能：清空叙事包状态，准备进入地点选择。
# 说明：清空 packContext 使 preview_next_turn 检测到空包并进入地点选择流程。
func _clear_pack_context() -> void:
	# played_events：包内硬去重（REQ-001，2026-05-09）—— 单包内同一 event_id 不重复触发，
	#   跨包仍可重复（叙事日常性）。普通调度路径在 _build_candidates 守门 4 消费，
	#   forced / final_pool 路径不受影响。详见 [[代码重构_预启动]] §五·REQ-001。
	world_state["packContext"] = {
		"locationId": "",
		"turnCapacity": 0,
		"turnsElapsed": 0,
		"interrupted": false,
		"played_events": []
	}


# 功能：初始化新的叙事包。
# 说明：玩家选定地点后调用，设置地点和回合容量。
func _start_new_pack(location_id: String) -> void:
	var capacity := int(_pack_config.get("defaultCapacity", 3))
	world_state["packContext"] = {
		"locationId": location_id,
		"turnCapacity": capacity,
		"turnsElapsed": 0,
		"interrupted": false,
		"played_events": []
	}
	world_state["currentLocationId"] = location_id
	print("[叙事包] 新包开始: location=%s, capacity=%d" % [location_id, capacity])


# 功能：检查叙事包是否处于需要进入地点选择的状态。
# 说明：packContext 为空（locationId 为空）表示尚未开始包或上一个包已结束。
func _is_pack_awaiting_location() -> bool:
	var pack_ctx: Dictionary = _dict_or_empty(world_state.get("packContext", {}))
	return str(pack_ctx.get("locationId", "")).is_empty()


# 功能：检查叙事包是否已结束（回合用完或被 chain 打断后）。
func _is_pack_finished() -> bool:
	var pack_ctx: Dictionary = _dict_or_empty(world_state.get("packContext", {}))
	if str(pack_ctx.get("locationId", "")).is_empty():
		return false
	if bool(pack_ctx.get("interrupted", false)):
		return true
	var elapsed := int(pack_ctx.get("turnsElapsed", 0))
	var capacity := int(pack_ctx.get("turnCapacity", 0))
	return capacity > 0 and elapsed >= capacity


# 功能：构建地点选择虚拟事件。
# 说明：根据 LocationGraph 生成可选地点列表，每个地点作为一个选项。
func _build_location_select_event() -> Dictionary:
	var current_location := str(world_state.get("currentLocationId", ""))
	var neighbor_ids: Array = []
	if _location_graph != null:
		neighbor_ids = _location_graph.get_neighbors(current_location)

	# 构建可选地点列表：邻居 + 当前地点（留在原地）。
	var location_ids: Array = []
	# 当前地点排在第一位（留在原地选项）。
	if not current_location.is_empty():
		location_ids.append(current_location)
	for neighbor_variant in neighbor_ids:
		var neighbor_id := str(neighbor_variant)
		if neighbor_id != current_location and not neighbor_id.is_empty():
			location_ids.append(neighbor_id)

	# 为每个地点生成选项。
	var options: Array = []
	var display_order := 1
	for loc_id_variant in location_ids:
		var loc_id := str(loc_id_variant)
		var display_name := loc_id
		if _location_graph != null:
			var graph_name := _location_graph.get_display_name(loc_id)
			if not graph_name.is_empty():
				display_name = graph_name

		# 附加地点信息：NPC 在场情况。
		var npc_presence: Dictionary = _dict_or_empty(world_state.get("npcPresence", {}))
		var npc_list: Array = _array_or_empty(npc_presence.get(loc_id, []))

		# 检查是否有待触发 forcedNext 事件指向该地点。
		var has_pending_forced := false
		var forced_id := str(world_state.get("forcedNextEventId", ""))
		if not forced_id.is_empty():
			var forced_def: Dictionary = _event_map.get(forced_id, {})
			var forced_eligibility: Dictionary = forced_def.get("eligibility", {})
			var forced_locations: Array = forced_eligibility.get("requiredLocations", [])
			if not forced_locations.is_empty() and loc_id in forced_locations:
				has_pending_forced = true

		var is_current := (loc_id == current_location)
		var option_text := display_name
		if is_current:
			option_text = "%s（留在原地）" % display_name

		options.append({
			"id": "loc_select_%s" % loc_id,
			"location_id": loc_id,
			"text": option_text,
			"display_order": display_order,
			"npc_present": npc_list,
			"has_pending_forced": has_pending_forced,
			"is_current": is_current,
			"visible": true,
			"selectable": true
		})
		display_order += 1

	return {
		"event_id": "_location_select",
		"title": "选择前往的地点",
		"type": "location_select",
		"options": options
	}


# 功能：构建自省末屏地点选择候选（Step 2 新增）。
# 说明：候选地点来源按 reflection_mode 分化：
#       - reflection_mode="intro"（导入阶段模式）：从 location_graph 全量地点构建候选
#         （MVP §二·原则 8 要求"首个自省 4 地点全可选"，玩家选过的地点逐次过滤），
#         不依赖当前地点的邻居关系；
#       - reflection_mode="regular"（正式期模式）：复用 _build_location_select_event 的
#         邻居图候选（与现有移动语义一致）。
#       两种模式均返回与 _build_location_select_event option 一致的字典结构（带 location_id /
#       text / npc_present / has_pending_forced 等字段）以便 UI 复用渲染。
func get_reflection_location_options() -> Array:
	var mode: String = str(world_state.get("reflection_mode", "intro"))
	if mode == "regular":
		var loc_event: Dictionary = _build_location_select_event()
		return loc_event.get("options", [])

	# intro 模式：全量地点构建 + 过滤 visited_locations。
	if _location_graph == null:
		return []
	var visited: Array = _array_or_empty(world_state.get("visited_locations", []))
	var current_location: String = str(world_state.get("currentLocationId", ""))
	var npc_presence: Dictionary = _dict_or_empty(world_state.get("npcPresence", {}))
	var forced_id: String = str(world_state.get("forcedNextEventId", ""))
	var forced_def: Dictionary = _event_map.get(forced_id, {})
	var forced_locations: Array = []
	if not forced_def.is_empty():
		forced_locations = forced_def.get("eligibility", {}).get("requiredLocations", [])

	var all_ids: Array = _location_graph.get_all_location_ids()
	var out: Array = []
	var display_order := 1
	for loc_id_variant in all_ids:
		var loc_id: String = str(loc_id_variant)
		if loc_id.is_empty():
			continue
		if loc_id in visited:
			continue
		var display_name: String = _location_graph.get_display_name(loc_id)
		if display_name.is_empty():
			display_name = loc_id
		var npc_list: Array = _array_or_empty(npc_presence.get(loc_id, []))
		var has_pending_forced: bool = (
			not forced_id.is_empty()
			and not forced_locations.is_empty()
			and (loc_id in forced_locations)
		)
		var is_current: bool = (loc_id == current_location)
		# 议题 E 子项 5（2026-05-10）：取消"（当前所在）"后缀标记——
		# 自省末屏候选展示纯地点名即可；is_current 字段保留供其他逻辑使用（如未来高亮 / 排序）。
		var option_text: String = display_name
		out.append({
			"id": "loc_select_%s" % loc_id,
			"location_id": loc_id,
			"text": option_text,
			"display_order": display_order,
			"npc_present": npc_list,
			"has_pending_forced": has_pending_forced,
			"is_current": is_current,
			"visible": true,
			"selectable": true
		})
		display_order += 1
	return out


# ── 自省与关系调整系统 ──────────────────────────────────────────

# 功能：初始化自省系统配置，从 world_state.reflectionConfig 加载。
# 说明：缺省时使用默认值，保证系统在无配置时也能正常运行。
func _init_reflection_config() -> void:
	var raw: Dictionary = _dict_or_empty(world_state.get("reflectionConfig", {}))
	_reflection_config = {
		"op_limit": int(raw.get("op_limit", 1)),
		"trust_delta_positive": int(raw.get("trust_delta_positive", 5)),
		"trust_delta_negative": int(raw.get("trust_delta_negative", -5)),
		"recommend_count": int(raw.get("recommend_count", 3)),
		"focus_limit": int(raw.get("focus_limit", -1)),
	}
	_reflection_ops_used = 0
	# 将关注上限写入 player_role_state。
	if player_role_state != null:
		player_role_state.focus_limit = int(_reflection_config.get("focus_limit", -1))
		# 从 world_seed 初始化关注列表（仅当当前关注列表为空时执行，避免覆盖存档数据）。
		var initial_npcs: Array = raw.get("initial_focus_npcs", [])
		if not initial_npcs.is_empty() and player_role_state.focusing_npcs.is_empty():
			player_role_state.init_focusing_npcs(initial_npcs)
			print("[自省] 初始关注列表已加载: %s" % str(player_role_state.focusing_npcs))
	print("[自省] reflectionConfig 已加载: %s" % str(_reflection_config))

# 功能：清空周期级关系变动记录。
# 说明：自省结算后调用。扩展预留：后续可支持部分保留、衰减等策略。
func clear_cycle_affinity_changes() -> void:
	_cycle_affinity_changes.clear()

# 功能：获取自省推荐 NPC 列表。
# 说明：从周期内累积变动中统计各 NPC 出现次数，按次数降序取前 recommend_count 个。
#       "player" 本身不计入推荐。
func get_reflection_recommended_npcs() -> Array:
	# 统计各 NPC 涉及变动的次数（双向均计入）
	var count_map: Dictionary = {}
	for change_variant in _cycle_affinity_changes:
		var change: Dictionary = change_variant
		var from_id: String = str(change.get("from", ""))
		var to_id: String = str(change.get("to", ""))
		if not from_id.is_empty() and from_id != "player":
			count_map[from_id] = int(count_map.get(from_id, 0)) + 1
		if not to_id.is_empty() and to_id != "player":
			count_map[to_id] = int(count_map.get(to_id, 0)) + 1
	# 排除已在关注列表中的 NPC，避免"刚移除又被推荐"。
	var focusing_list: Array = []
	if player_role_state != null:
		focusing_list = player_role_state.focusing_npcs
	# 转换为数组，按次数降序排序
	var npc_list: Array = []
	for npc_id in count_map.keys():
		if focusing_list.has(npc_id):
			continue
		npc_list.append({"npc_id": npc_id, "change_count": int(count_map[npc_id])})
	npc_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["change_count"]) > int(b["change_count"])
	)
	# 截断至推荐数量
	var recommend_count := int(_reflection_config.get("recommend_count", 3))
	if npc_list.size() > recommend_count:
		npc_list = npc_list.slice(0, recommend_count)
	return npc_list

# 功能：获取关注切换候选 NPC 列表。
# 说明：当前委托推荐方法，后续可独立筛选逻辑。
func get_focus_candidates() -> Array:
	return get_reflection_recommended_npcs()

# 功能：获取信任调整候选 NPC 列表。
# 说明：当前委托推荐方法，后续可独立筛选逻辑。
func get_trust_adjust_candidates() -> Array:
	return get_reflection_recommended_npcs()

# 功能：获取玩家当前关注的 NPC ID 列表。
# 说明：空列表表示关注所有 NPC。player_role_state 为 null 时返回空列表。
func get_player_focusing_npcs() -> Array:
	if player_role_state == null:
		return []
	return player_role_state.focusing_npcs.duplicate()

# 功能：查询自省剩余操作次数。
func get_reflection_ops_remaining() -> int:
	var op_limit := int(_reflection_config.get("op_limit", 1))
	return maxi(0, op_limit - _reflection_ops_used)

# 功能：执行关注切换操作。
# 说明：校验操作次数上限，切换玩家对指定 NPC 的关注状态，消耗 1 次操作次数。
func reflection_toggle_focus(npc_id: String) -> Dictionary:
	if get_reflection_ops_remaining() <= 0:
		return {"success": false, "reason": "ops_limit_reached", "ops_remaining": 0}
	if player_role_state == null:
		return {"success": false, "reason": "no_player_role_state", "ops_remaining": 0}
	var is_now_focusing: bool = player_role_state.toggle_focus(npc_id)
	_reflection_ops_used += 1
	print("[自省] 关注切换 %s → is_focusing=%s, ops_remaining=%d" % [
		npc_id, str(is_now_focusing), get_reflection_ops_remaining()
	])
	return {
		"success": true,
		"npc_id": npc_id,
		"is_focusing": is_now_focusing,
		"ops_remaining": get_reflection_ops_remaining()
	}

# 功能：执行信任/警戒调整操作（玩家→NPC 方向）。
# 说明：positive=true 正向信任，false 负向警戒。消耗 1 次操作次数。
func reflection_adjust_trust(npc_id: String, positive: bool) -> Dictionary:
	if get_reflection_ops_remaining() <= 0:
		return {"success": false, "reason": "ops_limit_reached", "ops_remaining": 0}
	if _affinity_map == null:
		return {"success": false, "reason": "no_affinity_map", "ops_remaining": get_reflection_ops_remaining()}
	# 根据方向选取刻度
	var delta: int
	if positive:
		delta = int(_reflection_config.get("trust_delta_positive", 5))
	else:
		delta = int(_reflection_config.get("trust_delta_negative", -5))
	var current := _affinity_map.get_score("player", npc_id)
	var result := RuleEngine.apply_affinity_delta(current, delta, _affinity_thresholds)
	var new_score: int = int(result.get("score", 0))
	var new_tier: String = str(result.get("tier", ""))
	_affinity_map.set_score("player", npc_id, new_score)
	_reflection_ops_used += 1
	print("[自省] 调整 player->%s: %d → %d (delta: %+d, tier: %s), ops_remaining=%d" % [
		npc_id, current, new_score, delta, new_tier, get_reflection_ops_remaining()
	])
	return {
		"success": true,
		"npc_id": npc_id,
		"delta": delta,
		"new_score": new_score,
		"new_tier": new_tier,
		"ops_remaining": get_reflection_ops_remaining()
	}

# 功能：自省结算，清空周期累积记录并重置操作次数。
func reflection_settle() -> void:
	clear_cycle_affinity_changes()
	_reflection_ops_used = 0
	# Line B S2: 自省阶段资源标记池基础回流。
	# 规则: 能力 token 全回流到 capacity / xinxing_token +1 / social_token 不全回 / gold 不重置。
	# 详见 [[前端骨架_LineB_实施]] §3.5 五类资源规则表 + ResourceMarkerPool.reset_all_for_reflection。
	if player_role_state != null:
		ResourceMarkerPool.reset_all_for_reflection(player_role_state)
		_sync_role_to_world_state()
	print("[自省] 结算完成：累积记录已清空，操作次数已重置，资源标记池已回流")

# ── 自省状态机代理接口 ─────────────────────────────────────────────

# 功能：启动自省状态机，返回初始状态和可用操作。
func start_reflection() -> Dictionary:
	return _reflection_sm.start(self)

# 功能：在自省状态机中执行操作，驱动状态转移。
func reflection_act(action: String, target: String = "") -> Dictionary:
	return _reflection_sm.act(action, target)

# 功能：确认空自省演出，触发结算。
func reflection_confirm() -> Dictionary:
	return _reflection_sm.confirm()

# 功能：查询自省状态机是否处于活跃状态。
func is_reflection_active() -> bool:
	return _reflection_sm.is_active()

# ── 开局选择状态机代理接口 ──────────────────────────────────────────

# 功能：启动开局选择状态机，返回初始状态和当前问题。
# 说明：传入非空 config 时使用传入配置；传入空数组时使用引擎预加载的 _creation_config。
#       若需要测试空配置场景，应直接调用 _creation_sm.start(self, [])。
func start_creation(config: Array = []) -> Dictionary:
	var use_config: Array = config if not config.is_empty() else _creation_config
	return _creation_sm.start(self, use_config)

# 功能：在开局选择状态机中执行选项操作，驱动流程推进。
func creation_act(option_id: String) -> Dictionary:
	return _creation_sm.act(option_id)

# 功能：推进开局选择的叙事段落，切换到下一段或进入选项阶段。
func creation_advance_narrative() -> Dictionary:
	return _creation_sm.advance_narrative()

# 功能：确认开局选择的叙事后果展示，推进到下一题或 SETTLED。
func creation_confirm_outcome() -> Dictionary:
	return _creation_sm.confirm_outcome()

# 功能：查询开局选择状态机是否处于活跃状态。
func is_creation_active() -> bool:
	return _creation_sm.is_active()

# 功能：查询是否有开局选择配置可用。
func has_creation_config() -> bool:
	return not _creation_config.is_empty()

# 功能：条件判定代理，供外部模块（如 CreationStateMachine）调用。
func evaluate_condition(expr: String) -> bool:
	return _evaluate_condition(expr)

# 功能：加载开局选择配置。
# 说明：优先从 csv_dir_path 下查找 creation_questions.csv；
#       若未找到则回退到默认路径 res://scripts/config/creation_questions.csv。
#       文件不存在时静默跳过，不影响引擎正常启动。
func _load_creation_config(csv_dir_path: String = "") -> void:
	var default_path := "res://scripts/config/creation_questions.csv"
	var config_path := default_path
	# 当指定了 csv_dir_path 且其中包含 creation_questions.csv 时，优先使用
	csv_dir_path = csv_dir_path.strip_edges()
	if not csv_dir_path.is_empty():
		var dir_candidate := csv_dir_path.path_join("creation_questions.csv")
		if FileAccess.file_exists(dir_candidate):
			config_path = dir_candidate
	if not FileAccess.file_exists(config_path):
		_creation_config = []
		return
	var result: Dictionary = ConfigLoader.load_creation_config(config_path)
	if result.get("ok", false):
		_creation_config = result.get("data", [])
		print("[开局选择] 配置已加载，共 %d 个问题" % _creation_config.size())
	else:
		_creation_config = []
		print("[开局选择] 配置加载失败: %s" % str(result.get("error", "")))
