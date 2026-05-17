extends RefCounted

# 自省状态机：管理自省事件的完整交互流程。
# 作为独立类由 WorldEventEngine 持有和驱动，与 UI 层无关。
# 对外暴露状态、可用操作列表、操作结果，供 UI 层将来消费。

# ── 状态枚举 ──────────────────────────────────────────────────────
enum State {
	IDLE,              # 未激活
	ENTRY_CHECK,       # 入口前置检查
	EMPTY_REFLECTION,  # 空自省：无可操作项，等待确认后自动结算
	MAIN_MENU,         # 主菜单：调整关系 / 关注 / 跳过
	ADJUST_RELATION,   # 调整关系扁平列表
	FOCUS_SELECT,      # 关注：选择推荐NPC
	FOCUS_REMOVE,      # 关注：关注已满，选择移除已关注NPC
	SETTLED,           # 已结算，自省结束
}

# ── 内部状态 ──────────────────────────────────────────────────────
var _state: int = State.IDLE
# 对 WorldEventEngine 的引用，用于调用自省操作接口。
var _engine: RefCounted = null
# FOCUS_REMOVE 状态下暂存的待添加 NPC ID。
var _pending_focus_npc: String = ""
# 空自省默认演出文本。后续可替换为 CSV 配置驱动。
const EMPTY_REFLECTION_TEXT := "一切如常，没有特别值得回顾的事。"

# ── 对外接口 ──────────────────────────────────────────────────────

# 功能：启动自省状态机。
# 说明：执行入口前置检查，根据推荐列表和关注列表是否都为空决定进入主菜单或空自省。
func start(engine: RefCounted) -> Dictionary:
	_engine = engine
	_state = State.ENTRY_CHECK
	_pending_focus_npc = ""
	# 重置操作次数（确保每次自省从满额开始）。
	_engine._reflection_ops_used = 0
	# 前置检查：推荐列表和关注列表是否都为空。
	var recommended: Array = _engine.get_reflection_recommended_npcs()
	var focusing: Array = _get_focusing_npcs()
	if recommended.is_empty() and focusing.is_empty():
		_state = State.EMPTY_REFLECTION
		print("[自省状态机] 空自省：推荐列表和关注列表都为空")
		return _build_response({"text": EMPTY_REFLECTION_TEXT})
	_state = State.MAIN_MENU
	print("[自省状态机] 进入主菜单")
	return _build_response()

# 功能：查询当前状态。
func get_state() -> String:
	return State.keys()[_state]

# 功能：查询状态机是否处于活跃状态（非 IDLE / SETTLED）。
func is_active() -> bool:
	return _state != State.IDLE and _state != State.SETTLED

# 功能：获取当前状态下的可用操作列表。
# 说明：每个操作项包含 action（操作ID）、label（显示文本）、enabled（是否可选）、target（NPC ID，可选）。
func get_available_actions() -> Array:
	match _state:
		State.MAIN_MENU:
			return _build_main_menu_actions()
		State.ADJUST_RELATION:
			return _build_adjust_relation_actions()
		State.FOCUS_SELECT:
			return _build_focus_select_actions()
		State.FOCUS_REMOVE:
			return _build_focus_remove_actions()
		State.EMPTY_REFLECTION:
			return [{"action": "confirm", "label": "确认", "enabled": true}]
		_:
			return []

# 功能：执行操作，驱动状态转移。
# 参数：action 为操作ID，target 为操作目标（NPC ID 等，部分操作不需要）。
func act(action: String, target: String = "") -> Dictionary:
	match _state:
		State.MAIN_MENU:
			return _handle_main_menu(action)
		State.ADJUST_RELATION:
			return _handle_adjust_relation(action, target)
		State.FOCUS_SELECT:
			return _handle_focus_select(action, target)
		State.FOCUS_REMOVE:
			return _handle_focus_remove(action, target)
		State.EMPTY_REFLECTION:
			if action == "confirm":
				return _do_settle()
		_:
			return {"ok": false, "error": "invalid_state", "state": get_state()}
	return {"ok": false, "error": "invalid_action", "state": get_state(), "action": action}

# 功能：确认空自省演出，触发结算。
func confirm() -> Dictionary:
	if _state != State.EMPTY_REFLECTION:
		return {"ok": false, "error": "not_in_empty_reflection", "state": get_state()}
	return _do_settle()

# ── 主菜单 ────────────────────────────────────────────────────────

# 功能：构建主菜单可用操作列表。
func _build_main_menu_actions() -> Array:
	var actions: Array = []
	# 调整关系：关注列表非空时列出已关注NPC，为空时列出推荐NPC。无NPC时置灰。
	var adjust_npcs: Array = _get_adjust_relation_npcs()
	actions.append({
		"action": "adjust_relation",
		"label": "调整关系",
		"enabled": not adjust_npcs.is_empty(),
	})
	# 关注：推荐列表（已排除已关注NPC）。为空时置灰。
	var recommended: Array = _engine.get_reflection_recommended_npcs()
	actions.append({
		"action": "focus",
		"label": "关注",
		"enabled": not recommended.is_empty(),
	})
	# 跳过：始终可选。
	actions.append({
		"action": "skip",
		"label": "跳过",
		"enabled": true,
	})
	return actions

# 功能：处理主菜单操作。
func _handle_main_menu(action: String) -> Dictionary:
	match action:
		"adjust_relation":
			var npcs: Array = _get_adjust_relation_npcs()
			if npcs.is_empty():
				return {"ok": false, "error": "no_adjustable_npcs", "state": get_state()}
			_state = State.ADJUST_RELATION
			print("[自省状态机] 进入调整关系列表")
			return _build_response()
		"focus":
			var recommended: Array = _engine.get_reflection_recommended_npcs()
			if recommended.is_empty():
				return {"ok": false, "error": "no_recommended_npcs", "state": get_state()}
			_state = State.FOCUS_SELECT
			print("[自省状态机] 进入关注选择")
			return _build_response()
		"skip":
			return _do_skip()
		_:
			return {"ok": false, "error": "invalid_action", "state": get_state(), "action": action}

# ── 调整关系 ──────────────────────────────────────────────────────

# 功能：获取调整关系可操作的NPC列表。
# 说明：关注列表非空时返回已关注NPC ID列表，为空时返回推荐NPC ID列表。
func _get_adjust_relation_npcs() -> Array:
	var focusing: Array = _get_focusing_npcs()
	if not focusing.is_empty():
		return focusing.duplicate()
	# 关注列表为空时，使用推荐列表中的NPC。
	var recommended: Array = _engine.get_reflection_recommended_npcs()
	var npc_ids: Array = []
	for item_variant in recommended:
		var item: Dictionary = item_variant
		npc_ids.append(str(item.get("npc_id", "")))
	return npc_ids

# 功能：构建调整关系扁平操作列表。
# 说明：每个NPC生成三个操作：查看信息（base）、+信任（overlay）、+警惕（overlay）。
#       group 字段标识同一NPC的操作组，role 字段区分按钮用途，供 UI 做分组布局。
func _build_adjust_relation_actions() -> Array:
	var actions: Array = []
	var npcs: Array = _get_adjust_relation_npcs()
	for npc_id_variant in npcs:
		var npc_id: String = str(npc_id_variant)
		actions.append({
			"action": "query",
			"target": npc_id,
			"label": "%s 查看信息" % npc_id,
			"enabled": true,
			"group": npc_id,
			"role": "base",
		})
		actions.append({
			"action": "trust",
			"target": npc_id,
			"label": "+信任",
			"enabled": true,
			"group": npc_id,
			"role": "overlay",
		})
		actions.append({
			"action": "distrust",
			"target": npc_id,
			"label": "+警惕",
			"enabled": true,
			"group": npc_id,
			"role": "overlay",
		})
	return actions

# 功能：处理调整关系操作。
func _handle_adjust_relation(action: String, target: String) -> Dictionary:
	match action:
		"trust":
			var result: Dictionary = _engine.reflection_adjust_trust(target, true)
			if not result.get("success", false):
				return {"ok": false, "error": str(result.get("reason", "unknown")), "state": get_state()}
			print("[自省状态机] +信任 %s: %s" % [target, str(result)])
			return _after_op_consume({"op_result": result})
		"distrust":
			var result: Dictionary = _engine.reflection_adjust_trust(target, false)
			if not result.get("success", false):
				return {"ok": false, "error": str(result.get("reason", "unknown")), "state": get_state()}
			print("[自省状态机] +警惕 %s: %s" % [target, str(result)])
			return _after_op_consume({"op_result": result})
		"query":
			var query_result: Dictionary = _query_npc_trust(target)
			print("[自省状态机] 查询 %s: %s" % [target, str(query_result)])
			# 查询不消耗额度，停留在调整关系列表。
			return _build_response({"query_result": query_result})
		_:
			return {"ok": false, "error": "invalid_action", "state": get_state(), "action": action}

# 功能：查询指定NPC的当前信任信息。
func _query_npc_trust(npc_id: String) -> Dictionary:
	var score: int = _engine._affinity_map.get_score("player", npc_id)
	var tier: String = RuleEngine.affinity_tier(score, _engine._affinity_thresholds)
	return {
		"action": "query",
		"npc_id": npc_id,
		"current_score": score,
		"current_tier": tier,
		"direction": "player_to_npc",
	}

# ── 关注选择 ──────────────────────────────────────────────────────

# 功能：构建关注选择操作列表。
func _build_focus_select_actions() -> Array:
	var actions: Array = []
	var recommended: Array = _engine.get_reflection_recommended_npcs()
	for item_variant in recommended:
		var item: Dictionary = item_variant
		var npc_id: String = str(item.get("npc_id", ""))
		actions.append({
			"action": "add_focus",
			"target": npc_id,
			"label": "关注 %s" % npc_id,
			"enabled": true,
			"change_count": int(item.get("change_count", 0)),
		})
	return actions

# 功能：处理关注选择操作。
func _handle_focus_select(action: String, target: String) -> Dictionary:
	if action != "add_focus":
		return {"ok": false, "error": "invalid_action", "state": get_state(), "action": action}
	# 检查关注上限。
	if _engine.player_role_state == null:
		return {"ok": false, "error": "no_player_role_state", "state": get_state()}
	if _engine.player_role_state.is_focus_full():
		# 关注已满，进入移除选择状态。
		_pending_focus_npc = target
		_state = State.FOCUS_REMOVE
		print("[自省状态机] 关注已满，需先移除一个已关注NPC，待添加: %s" % target)
		return _build_response({"pending_add": target})
	# 关注未满，直接添加。
	_engine.player_role_state.add_focus(target)
	_engine._reflection_ops_used += 1
	print("[自省状态机] 添加关注 %s，当前关注列表: %s" % [target, str(_engine.player_role_state.focusing_npcs)])
	return _after_op_consume({"added_focus": target})

# ── 关注移除 ──────────────────────────────────────────────────────

# 功能：构建关注移除操作列表（当前已关注NPC列表）。
func _build_focus_remove_actions() -> Array:
	var actions: Array = []
	var focusing: Array = _get_focusing_npcs()
	for npc_id_variant in focusing:
		var npc_id: String = str(npc_id_variant)
		actions.append({
			"action": "remove_focus",
			"target": npc_id,
			"label": "移除 %s" % npc_id,
			"enabled": true,
		})
	return actions

# 功能：处理关注移除操作。
# 说明：移除选中的已关注NPC，然后添加之前暂存的待添加NPC，消耗1次额度。
func _handle_focus_remove(action: String, target: String) -> Dictionary:
	if action != "remove_focus":
		return {"ok": false, "error": "invalid_action", "state": get_state(), "action": action}
	if _engine.player_role_state == null:
		return {"ok": false, "error": "no_player_role_state", "state": get_state()}
	# 移除旧NPC。
	var removed: bool = _engine.player_role_state.remove_focus(target)
	if not removed:
		return {"ok": false, "error": "npc_not_in_focus_list", "state": get_state(), "target": target}
	# 添加暂存的待添加NPC。
	_engine.player_role_state.add_focus(_pending_focus_npc)
	_engine._reflection_ops_used += 1
	print("[自省状态机] 移除 %s，添加 %s，当前关注列表: %s" % [
		target, _pending_focus_npc, str(_engine.player_role_state.focusing_npcs)
	])
	var result_data: Dictionary = {"removed_focus": target, "added_focus": _pending_focus_npc}
	_pending_focus_npc = ""
	return _after_op_consume(result_data)

# ── 通用逻辑 ─────────────────────────────────────────────────────

# 功能：获取玩家当前关注NPC列表。
func _get_focusing_npcs() -> Array:
	if _engine.player_role_state == null:
		return []
	return _engine.player_role_state.focusing_npcs

# 功能：消耗额度后的统一处理。判断额度是否归零，决定回主菜单或结算。
func _after_op_consume(extra_data: Dictionary = {}) -> Dictionary:
	var remaining: int = _engine.get_reflection_ops_remaining()
	if remaining <= 0:
		print("[自省状态机] 额度耗尽，自动结算")
		_engine.reflection_settle()
		_state = State.SETTLED
		extra_data["settled"] = true
		return _build_response(extra_data)
	_state = State.MAIN_MENU
	print("[自省状态机] 回到主菜单，剩余额度: %d" % remaining)
	return _build_response(extra_data)

# 功能：跳过自省。消耗全部剩余额度，触发结算。
func _do_skip() -> Dictionary:
	var op_limit: int = int(_engine._reflection_config.get("op_limit", 1))
	_engine._reflection_ops_used = op_limit
	_engine.reflection_settle()
	_state = State.SETTLED
	print("[自省状态机] 玩家跳过，全部额度已消耗，结算完成")
	return _build_response({"skipped": true})

# 功能：执行结算（空自省 confirm 时调用）。
func _do_settle() -> Dictionary:
	_engine.reflection_settle()
	_state = State.SETTLED
	print("[自省状态机] 结算完成")
	return _build_response({"settled": true})

# 功能：构建统一返回结构。
func _build_response(extra: Dictionary = {}) -> Dictionary:
	var response: Dictionary = {
		"ok": true,
		"state": get_state(),
		"ops_remaining": _engine.get_reflection_ops_remaining() if _engine != null else 0,
		"available_actions": get_available_actions(),
	}
	for key in extra.keys():
		response[key] = extra[key]
	return response
