extends RefCounted

# 开局选择状态机：管理角色创建的逐题交互流程。
# 作为独立类由 WorldEventEngine 持有和驱动，与 UI 层无关。
# 对外暴露状态、当前问题、可用操作列表，供 UI 层消费。

# ── 状态枚举 ──────────────────────────────────────────────────────
enum State {
	IDLE,          # 未激活
	PRESENTING,    # 正在展示一个问题，等待玩家选择
	SETTLED,       # 全部问题完成
}

# ── 内部状态 ──────────────────────────────────────────────────────
var _state: int = State.IDLE
# 对 WorldEventEngine 的引用，用于访问游戏状态和 apply effect。
var _engine: RefCounted = null
# 全部问题配置（从 ConfigLoader 解析后传入）。
var _questions: Array = []
# 当前展示的问题在 _questions 中的索引。
var _current_index: int = 0
# 满足条件的有效问题索引列表（用于进度计算，每次 act 后重新扫描）。
var _valid_indices: Array = []
# 已回答的问题数量（用于进度计算）。
var _answered_count: int = 0
# 当前问题的叙事段落列表（按 | 拆分）。
var _narrative_lines: Array = []
# 当前展示到的叙事段索引。
var _narrative_index: int = 0
# outcome phase 标记：选择选项后是否正在展示叙事后果。
var _in_outcome: bool = false
# outcome phase 暂存的叙事后果文本。
var _outcome_text: String = ""
# outcome phase 暂存的 act() 额外返回信息（选项 ID、检定结果等）。
var _outcome_extra: Dictionary = {}


# ── 对外接口 ──────────────────────────────────────────────────────

# 功能：启动开局选择状态机。
# 说明：加载配置，定位第一个满足条件的问题。无有效问题时直接进入 SETTLED。
func start(engine: RefCounted, config: Array) -> Dictionary:
	_engine = engine
	_questions = config
	_current_index = 0
	_answered_count = 0
	_valid_indices = []
	# 清除可能残留的 outcome 状态，防止上一次未完成流程的泄漏。
	_in_outcome = false
	_outcome_text = ""
	_outcome_extra = {}

	if _questions.is_empty():
		_state = State.SETTLED
		print("[开局选择] 无配置，直接 SETTLED")
		return _build_response()

	# 预扫描所有满足条件的问题索引，用于进度显示。
	_valid_indices = _scan_valid_indices()
	if _valid_indices.is_empty():
		_state = State.SETTLED
		print("[开局选择] 无满足条件的问题，直接 SETTLED")
		return _build_response()

	_current_index = int(_valid_indices[0])
	_state = State.PRESENTING
	_init_narrative()
	print("[开局选择] 开始，第一题: %s" % _get_current_question_id())
	return _build_response()


# 功能：查询当前状态。
func get_state() -> String:
	return State.keys()[_state]


# 功能：查询状态机是否处于活跃状态（非 IDLE / SETTLED）。
func is_active() -> bool:
	return _state != State.IDLE and _state != State.SETTLED


# 功能：获取当前问题的可用选项列表。
# 说明：格式与 ReflectionStateMachine 对齐：{action, label, enabled}。
func get_available_actions() -> Array:
	if _state != State.PRESENTING:
		return []
	# narrating / outcome 阶段选项不可见，返回空。
	if _is_narrating() or _in_outcome:
		return []
	var question: Dictionary = _questions[_current_index]
	var options: Array = question.get("options", [])
	var actions: Array = []
	for opt_variant in options:
		var opt: Dictionary = opt_variant
		actions.append({
			"action": str(opt.get("option_id", "")),
			"label": str(opt.get("option_text", "")),
			"enabled": true,
		})
	return actions


# 功能：玩家选择一个选项，执行检定（如有），按分支 apply effect，推进到下一题或 SETTLED。
func act(option_id: String) -> Dictionary:
	if _state != State.PRESENTING:
		return {"ok": false, "error": "not_presenting", "state": get_state()}
	# narrating / outcome 阶段不允许选择选项。
	if _is_narrating():
		return {"ok": false, "error": "still_narrating", "state": get_state()}
	if _in_outcome:
		return {"ok": false, "error": "in_outcome", "state": get_state()}

	var question: Dictionary = _questions[_current_index]
	var selected_option: Dictionary = _find_option(question, option_id)
	if selected_option.is_empty():
		return {"ok": false, "error": "invalid_option", "state": get_state(), "option_id": option_id}

	# 执行检定（如有），决定 apply 哪组分支 effects。
	# 安全规则：配置了 check 但引擎无法执行时，视为无检定，只 apply default。
	var check: Dictionary = selected_option.get("check", {})
	var check_result: Dictionary = {}
	var check_executed := false
	var check_passed := false
	if not check.is_empty() and _engine != null and _engine.has_method("_is_check_pass"):
		check_result = _engine._is_check_pass(check)
		check_executed = true
		check_passed = check_result.get("pass", false)
		print("[开局选择] 检定 %s → %s (result_type=%s)" % [
			option_id,
			"通过" if check_passed else "失败",
			str(check_result.get("result_type", ""))
		])
	elif not check.is_empty():
		print("[开局选择] 选项 %s 配置了检定但引擎不支持，跳过检定仅 apply default" % option_id)

	# 始终 apply default 分支的 effects。
	# 向后兼容：若无 effects_default 字段，回退到 effects 字段。
	var effects_default: Array = selected_option.get("effects_default", selected_option.get("effects", []))
	var effects_branch: Array = []
	if not check_executed:
		# 未执行检定（无配置 / 引擎不支持），只 apply default。
		effects_branch = []
	elif check_passed:
		effects_branch = selected_option.get("effects_success", [])
	else:
		effects_branch = selected_option.get("effects_fail", [])

	var total_applied := 0
	for effect_variant in effects_default:
		var effect: Dictionary = effect_variant
		_apply_effect(effect)
		total_applied += 1
	for effect_variant in effects_branch:
		var effect: Dictionary = effect_variant
		_apply_effect(effect)
		total_applied += 1

	# apply 完成后同步 world_state.player。
	if _engine != null and _engine.player_role_state != null:
		_engine._sync_role_to_world_state()

	var extra: Dictionary = {"selected_option": option_id}
	if not check_result.is_empty():
		extra["check_result"] = check_result

	print("[开局选择] 选择 %s (问题 %s)，已 apply %d 条 effect" % [
		option_id, str(question.get("question_id", "")), total_applied
	])

	# 确定叙事后果文本：优先取对应检定分支，为空则回退 outcome_default。
	var outcome := _resolve_outcome_text(selected_option, check_executed, check_passed)
	if not outcome.is_empty():
		# 有叙事后果，进入 outcome phase，暂存状态等待 confirm_outcome()。
		_in_outcome = true
		_outcome_text = outcome
		_outcome_extra = extra
		extra["phase"] = "outcome"
		extra["outcome_text"] = outcome
		print("[开局选择] 进入 outcome phase")
		return _build_response(extra)

	# 无叙事后果，直接推进到下一题或 SETTLED。
	return _advance_to_next_question(extra)


# ── 叙事分段 ─────────────────────────────────────────────────────

# 功能：推进叙事段落，返回下一段文字或切换到 choosing 阶段。
# 说明：仅在 narrating 阶段有效；最后一段展示完毕后自动切换到 choosing。
func advance_narrative() -> Dictionary:
	if _state != State.PRESENTING:
		return {"ok": false, "error": "not_presenting", "state": get_state()}
	if not _is_narrating():
		return {"ok": false, "error": "not_narrating", "state": get_state()}

	_narrative_index += 1
	if _is_narrating():
		print("[开局选择] 叙事推进 %d/%d" % [_narrative_index + 1, _narrative_lines.size()])
	else:
		print("[开局选择] 叙事完毕，进入 choosing")
	return _build_response()


# 功能：初始化当前问题的叙事段落状态。
func _init_narrative() -> void:
	if _current_index < _questions.size():
		var question: Dictionary = _questions[_current_index]
		_narrative_lines = question.get("narrative_lines", [str(question.get("question_text", ""))])
	else:
		_narrative_lines = []
	_narrative_index = 0


# 功能：判断当前是否处于 narrating 阶段（多段且尚未展示到最后一段）。
func _is_narrating() -> bool:
	return _narrative_lines.size() > 1 and _narrative_index < _narrative_lines.size() - 1


# 功能：获取当前阶段名称（outcome > narrating > choosing）。
func _get_current_phase() -> String:
	if _in_outcome:
		return "outcome"
	if _is_narrating():
		return "narrating"
	return "choosing"


# ── 叙事后果 ─────────────────────────────────────────────────────

# 功能：确认叙事后果展示完毕，推进到下一题或 SETTLED。
# 说明：仅在 outcome phase 有效，否则返回错误。
func confirm_outcome() -> Dictionary:
	if _state != State.PRESENTING:
		return {"ok": false, "error": "not_presenting", "state": get_state()}
	if not _in_outcome:
		return {"ok": false, "error": "not_in_outcome", "state": get_state()}

	_in_outcome = false
	var extra: Dictionary = _outcome_extra.duplicate()
	_outcome_text = ""
	_outcome_extra = {}
	# 清除 act() 暂存的 outcome 阶段专属字段，避免覆盖下一题的 phase。
	extra.erase("phase")
	extra.erase("outcome_text")
	print("[开局选择] outcome 确认，推进")
	return _advance_to_next_question(extra)


# 功能：根据检定结果选择对应的叙事后果文本。
# 说明：优先取对应分支，为空则回退 outcome_default。
func _resolve_outcome_text(option: Dictionary, check_executed: bool, check_passed: bool) -> String:
	if not check_executed:
		return str(option.get("outcome_default", ""))
	var branch_key := "outcome_success" if check_passed else "outcome_fail"
	var text := str(option.get(branch_key, ""))
	if text.is_empty():
		text = str(option.get("outcome_default", ""))
	return text


# 功能：推进到下一个满足条件的问题，或进入 SETTLED。
# 说明：从 act() 和 confirm_outcome() 共同调用的推进逻辑。
func _advance_to_next_question(extra: Dictionary) -> Dictionary:
	# effect 可能改变后续问题的条件判定结果，重新扫描有效问题列表。
	_valid_indices = _scan_valid_indices_from(_current_index + 1)
	var next_valid := _find_next_valid_index(_current_index + 1)
	if next_valid < 0:
		_state = State.SETTLED
		extra["settled"] = true
		print("[开局选择] 全部问题完成，SETTLED")
		return _build_response(extra)

	_current_index = next_valid
	_answered_count += 1
	_init_narrative()
	print("[开局选择] 下一题: %s" % _get_current_question_id())
	return _build_response(extra)


# ── Effect Apply ─────────────────────────────────────────────────

# 功能：根据 effect_target 分发并执行单条 effect。
# 说明：MVP 阶段实现 attribute/resource/affinity/affinity_all/focus，
#       其余类型预留分支但仅打印警告。
func _apply_effect(effect: Dictionary) -> void:
	var target := str(effect.get("target", ""))
	var key := str(effect.get("key", ""))
	var raw_value := str(effect.get("value", ""))

	match target:
		"attribute":
			_apply_attribute_delta(key, raw_value)
		"resource":
			_apply_resource_delta(key, raw_value)
		"affinity":
			_apply_affinity_delta(key, raw_value)
		"affinity_all":
			_apply_affinity_all_delta(raw_value)
		"focus":
			_apply_focus(key)
		"flag":
			_apply_flag(key, raw_value)
		"param":
			_apply_param_delta(key, raw_value)
		"location":
			_apply_location(raw_value)
		"npc_presence":
			_apply_npc_presence(key, raw_value)
		_:
			print("[开局选择] 未知 effect_target: %s" % target)


# 功能：属性 delta 累加。
func _apply_attribute_delta(key: String, raw_value: String) -> void:
	if _engine == null or _engine.player_role_state == null:
		return
	var delta := _parse_delta(raw_value)
	var old_val: int = _engine.player_role_state.get_attribute(key, 1)
	_engine.player_role_state.set_attribute(key, old_val + delta)
	print("[开局选择] attribute %s: %d → %d" % [key, old_val, old_val + delta])


# 功能：资源 delta 累加。
func _apply_resource_delta(key: String, raw_value: String) -> void:
	if _engine == null or _engine.player_role_state == null:
		return
	var delta := _parse_delta(raw_value)
	var old_val: int = _engine.player_role_state.get_resource(key)
	_engine.player_role_state.set_resource(key, old_val + delta)
	print("[开局选择] resource %s: %d → %d" % [key, old_val, old_val + delta])


# 功能：单条亲和关系 delta 累加。
# 说明：key 格式为 "from->to"。
func _apply_affinity_delta(key: String, raw_value: String) -> void:
	if _engine == null or _engine._affinity_map == null:
		return
	var parts := key.split("->")
	if parts.size() != 2:
		print("[开局选择] affinity key 格式错误: %s" % key)
		return
	var from_id := str(parts[0]).strip_edges()
	var to_id := str(parts[1]).strip_edges()
	var delta := _parse_delta(raw_value)
	var old_val: int = _engine._affinity_map.get_score(from_id, to_id)
	_engine._affinity_map.set_score(from_id, to_id, old_val + delta)
	print("[开局选择] affinity %s->%s: %d → %d" % [from_id, to_id, old_val, old_val + delta])


# 功能：对所有 NPC 批量设置亲和关系 delta。
# 说明：遍历引擎中 ConfigRuntime 的 roles，对 role_type=="npc" 的条目批量操作。
func _apply_affinity_all_delta(raw_value: String) -> void:
	if _engine == null or _engine._affinity_map == null or _engine.player_role_state == null:
		return
	var delta := _parse_delta(raw_value)
	var player_id: String = _engine.player_role_state.role_id
	# 从 ConfigRuntime 获取所有角色，筛选 NPC。
	var runtime: RefCounted = _engine.ConfigRuntime.shared()
	var roles: Array = runtime.get_roles()
	for role_variant in roles:
		if role_variant == null:
			continue
		if str(role_variant.role_type) != "npc":
			continue
		var npc_id: String = str(role_variant.role_id)
		var old_val: int = _engine._affinity_map.get_score(player_id, npc_id)
		_engine._affinity_map.set_score(player_id, npc_id, old_val + delta)
		print("[开局选择] affinity_all %s->%s: %d → %d" % [player_id, npc_id, old_val, old_val + delta])


# 功能：添加 NPC 到关注列表。
func _apply_focus(key: String) -> void:
	if _engine == null or _engine.player_role_state == null:
		return
	_engine.player_role_state.add_focus(key)
	print("[开局选择] focus add: %s" % key)


# 功能：设置 world_state flag（预留，MVP 阶段可用但暂无配置使用）。
func _apply_flag(key: String, raw_value: String) -> void:
	if _engine == null:
		return
	var flags: Dictionary = _engine.world_state.get("flags", {})
	var parsed: Variant = _parse_flag_value(raw_value)
	flags[key] = parsed
	_engine.world_state["flags"] = flags
	print("[开局选择] flag %s = %s" % [key, str(parsed)])


# 功能：world_state param delta 累加（预留）。
func _apply_param_delta(key: String, raw_value: String) -> void:
	if _engine == null:
		return
	var params: Dictionary = _engine.world_state.get("params", {})
	var delta := _parse_delta(raw_value)
	var old_val: int = int(params.get(key, 0))
	params[key] = old_val + delta
	_engine.world_state["params"] = params
	print("[开局选择] param %s: %d → %d" % [key, old_val, old_val + delta])


# 功能：设置玩家当前位置（预留）。
func _apply_location(raw_value: String) -> void:
	if _engine == null:
		return
	_engine.world_state["currentLocationId"] = raw_value
	print("[开局选择] location → %s" % raw_value)


# 功能：追加 NPC 到指定地点的 npcPresence（预留）。
func _apply_npc_presence(location_key: String, npc_id: String) -> void:
	if _engine == null:
		return
	var presence: Dictionary = _engine.world_state.get("npcPresence", {})
	var list: Array = presence.get(location_key, [])
	if not list.has(npc_id):
		list.append(npc_id)
	presence[location_key] = list
	_engine.world_state["npcPresence"] = presence
	print("[开局选择] npc_presence %s += %s" % [location_key, npc_id])


# ── 内部工具 ─────────────────────────────────────────────────────

# 功能：解析 delta 值（支持 +/- 前缀）。
func _parse_delta(raw: String) -> int:
	var text := raw.strip_edges()
	if text.is_empty():
		return 0
	if text.is_valid_int():
		return int(text)
	# 带 + 前缀的情况。
	if text.begins_with("+") and text.substr(1).is_valid_int():
		return int(text.substr(1))
	return 0


# 功能：解析 flag 值（支持 bool、int、字符串）。
func _parse_flag_value(raw: String) -> Variant:
	var text := raw.strip_edges().to_lower()
	if text == "true":
		return true
	if text == "false":
		return false
	if raw.strip_edges().is_valid_int():
		return int(raw.strip_edges())
	return raw.strip_edges()


# 功能：在指定问题中查找选项。
func _find_option(question: Dictionary, option_id: String) -> Dictionary:
	var options: Array = question.get("options", [])
	for opt_variant in options:
		var opt: Dictionary = opt_variant
		if str(opt.get("option_id", "")) == option_id:
			return opt
	return {}


# 功能：从指定索引开始，查找下一个满足条件的问题索引。
# 返回：找到的索引；未找到时返回 -1。
func _find_next_valid_index(from_index: int) -> int:
	var i := from_index
	while i < _questions.size():
		if _is_question_valid(i):
			return i
		i += 1
	return -1


# 功能：预扫描所有满足条件的问题索引。
func _scan_valid_indices() -> Array:
	return _scan_valid_indices_from(0)


# 功能：从指定索引开始，扫描所有满足条件的问题索引。
# 说明：用于 effect apply 后重新计算剩余有效问题，确保 question_total 准确。
func _scan_valid_indices_from(from_index: int) -> Array:
	var indices: Array = []
	for i in range(from_index, _questions.size()):
		if _is_question_valid(i):
			indices.append(i)
	return indices


# 功能：判断指定索引的问题是否满足条件。
func _is_question_valid(index: int) -> bool:
	var question: Dictionary = _questions[index]
	var condition := str(question.get("condition", ""))
	if condition.is_empty():
		return true
	# 通过引擎代理调用条件判定。
	if _engine != null and _engine.has_method("evaluate_condition"):
		return _engine.evaluate_condition(condition)
	return false


# 功能：获取当前问题 ID（用于日志）。
func _get_current_question_id() -> String:
	if _current_index < _questions.size():
		return str(_questions[_current_index].get("question_id", ""))
	return ""


# 功能：构建统一返回结构。
func _build_response(extra: Dictionary = {}) -> Dictionary:
	var response: Dictionary = {
		"ok": true,
		"state": get_state(),
		"available_actions": get_available_actions(),
	}
	# PRESENTING 状态下附加问题信息和叙事分段状态。
	if _state == State.PRESENTING and _current_index < _questions.size():
		var question: Dictionary = _questions[_current_index]
		response["question_id"] = str(question.get("question_id", ""))
		response["question_text"] = str(question.get("question_text", ""))
		response["background_art"] = str(question.get("background_art", ""))
		response["question_index"] = _answered_count
		response["question_total"] = _answered_count + _valid_indices.size()
		# phase 字段：outcome > narrating > choosing，按优先级判定。
		response["phase"] = _get_current_phase()
		var line_idx := mini(_narrative_index, _narrative_lines.size() - 1)
		response["narrative_line"] = str(_narrative_lines[line_idx]) if not _narrative_lines.is_empty() else ""
		response["narrative_index"] = _narrative_index
		response["narrative_total"] = _narrative_lines.size()
	for key in extra.keys():
		response[key] = extra[key]
	return response
