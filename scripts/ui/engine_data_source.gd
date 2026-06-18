extends RefCounted
class_name EngineDataSource

# EngineDataSource — Line A 卡牌前端 / Line B 引擎 的桥接适配器
#
# Line B S8.2 落地（2026-05-27, 详见 [[前端骨架_LineB_实施]] §S8）
#
# 职责:
# - 在前端表现层 (card_table.gd) 与引擎 (WorldEventEngine) 之间做形状适配。
# - 不持有任何业务逻辑; 算式调 MarkerCheckResolver, 标记账单调 ResourceMarkerPool。
# - 与 mock_data.gd 同形 API (events_for_pile / options_for_event /
#   tier_from_invest / outcome_for_option) — card_table 通过 USE_ENGINE 开关二选一。
#
# 与 mock_data.gd 的关系:
# - mock_data.gd 保留作 USE_ENGINE=false fallback (调试 / 回归测试用)。
# - 两者实现的接口签名一致, 由 card_table.gd 顶部 _data_source 字段统一调用。
#
# 待完善 (推进 S8.3-S8.7 时一并处理):
# - difficulty (D) 字段当前 CSV 无承载, 暂硬编码默认值 3 (FALLBACK_DIFFICULTY)。
#   S8.5 与用户讨论是否在 options.csv 加 invest_difficulty 字段, 或派生自
#   check_whitelist 长度。
# - exp_deltas 当前留空 (S4 期经验升阶模块接通后填充)。

const WorldEventEngineScn := preload("res://scripts/systems/world_event_engine.gd")
const ConfigRuntimeScn := preload("res://scripts/systems/config_runtime.gd")
const MarkerCheckResolverScn := preload("res://scripts/systems/marker_check_resolver.gd")
const ResourceMarkerPoolScn := preload("res://scripts/systems/resource_marker_pool.gd")
const MockDataScn := preload("res://scripts/ui/mock_data.gd")

# 占位: 当 option 的 check 字段未提供"投入鉴定难度 D"时的兜底值。
# S8.5 期决议 CSV 字段落地后改为读取真实字段。
const FALLBACK_DIFFICULTY := 3

# 选项类型枚举 — 与 MockData.OptType 完全一致 (前端读法一致, 互换不影响 card_table)
enum OptType { CHECK, DIRECT }

# ============================================================
# 状态
# ============================================================

var _engine: WorldEventEngine = null
var _runtime: ConfigRuntime = null
var _player: RoleState = null
# choice_points 副本: 适配器从此查 option_def 取 check / whitelist / difficulty 等字段。
# 不直接访问 engine private _choice_point_map, 保持 engine 接口边界。
var _choice_points_by_id: Dictionary = {}
# 当前 pending 的 choice_point_id (由 events_for_pile 触发 preview 时记下, options_for_event 与 outcome_for_option 用)。
var _pending_choice_point_id: String = ""
# 当前 pending 事件 engine 实际筛选后的可见选项 id 集合 (S3 _build_option_set 调度结果)。
# options_for_event 以此过滤 cp_def.options, 避免暴露 trigger_condition / weight 被收敛掉的选项。
var _pending_visible_option_ids: Dictionary = {}
# 当前事件是否已结算 (events_for_pile 抽出 → false; outcome_for_option 结算 → true)。
# events_for_pile 据此区分"重抽未结算事件" (cancel) vs "结算后抽下一事件" (不 cancel, 保留 turn 推进)。
var _pending_resolved: bool = true
# A1: pack_window_for_pile 走 single 路 (skeleton 末位回合) 时, preview 已 set 引擎 pending,
# 暂存该 preview 供 pick_hand 直接 finalize (免二次 preview)。blind 路与 pick 后清空。
var _pending_hand_preview: Dictionary = {}

# ============================================================
# 生命周期
# ============================================================

func _init(random_seed: int = 0) -> void:
	_runtime = ConfigRuntimeScn.shared()
	var load_result: Dictionary = _runtime.ensure_loaded()
	if not load_result.get("ok", false):
		push_error("[EngineDataSource] 配置加载失败: %s" % str(load_result.get("error", "unknown")))
		return
	var context: Dictionary = _runtime.build_context()
	if not context.get("ok", false):
		push_error("[EngineDataSource] 上下文构建失败: %s" % str(context.get("error", "unknown")))
		return
	_player = context.get("player", null)
	var world_event_data: Dictionary = context.get("world_event", {})
	_index_choice_points(world_event_data)

	_engine = WorldEventEngineScn.new(random_seed)
	var inject_result: Dictionary = _engine.load_from_data(
		world_event_data, context.get("graph", null), _player
	)
	if not inject_result.get("ok", false):
		push_error("[EngineDataSource] 引擎数据注入失败: %s" % str(inject_result.get("error", "unknown")))
		return
	print("[EngineDataSource] init OK | events=%d, choice_points=%d" % [
		(world_event_data.get("events", []) as Array).size(),
		_choice_points_by_id.size()
	])


# ============================================================
# 对外接口 (与 MockData 同形)
# ============================================================

# 功能: 抽下一个事件 — 调 engine.preview_next_turn() + 转换为前端事件卡数据。
# 返回: { event_id, title, body, has_choice, choice_point_id }
#       body 取自 presentation.current_item.text; 无展示行时回退空字符串。
# 透明消化: 开局 / 包结束的 location_select 阶段对 card_table 不可见,
#           本函数自动选第一个可达地点并再次 preview 直到拿到真事件 (最多 MAX_AUTO_HOPS 次,
#           防止配置异常死循环)。MVP 1 期 card_table 不接地点选择 UI (设计范围外)。
const MAX_AUTO_HOPS := 8

func events_for_pile() -> Dictionary:
	if _engine == null:
		return {"ok": false, "error": "engine not initialized"}
	# 卡牌前端"重抽"语义: 玩家在结果前点新事件牌库, 前一次 pending 未结算 → 清掉重新选事件。
	# engine.cancel_pending_turn 不推 turn 不记历史, 世界状态零副作用。
	# 已结算分支不 cancel: turn 已在 confirm 中推进, preview 会顺序选下一事件
	# (包内回合推进, 末位回合才命中 skeleton 系列)。
	if not _pending_resolved:
		_engine.cancel_pending_turn()
	var preview: Dictionary = _engine.preview_next_turn()
	for hop in MAX_AUTO_HOPS:
		if not preview.get("ok", false):
			return {"ok": false, "error": str(preview.get("error", "preview failed"))}
		var phase := str(preview.get("phase", ""))
		if phase != "location_select":
			break
		# 自动选第一个可达地点 + 再 preview。
		# 注: 选项 id 是复合的 (loc_select_<loc_id>), 真实地点 id 在 location_id 字段;
		#     confirm_location_select 接受 location_id, 不接受复合 id。
		var options: Array = preview.get("options", [])
		if options.is_empty():
			return {"ok": false, "error": "location_select with no options"}
		var first_option: Dictionary = options[0]
		var loc_id := str(first_option.get("location_id", ""))
		if loc_id.is_empty():
			return {"ok": false, "error": "location_select option has empty location_id"}
		var sel := _engine.confirm_location_select(loc_id)
		if not sel.get("ok", false):
			return {"ok": false, "error": "confirm_location_select failed: %s" % str(sel.get("error", ""))}
		preview = _engine.preview_next_turn()
	# 防御: location_select drain 耗尽 MAX_AUTO_HOPS 后仍在 location_select 阶段 → 拒绝伪装成事件抽出
	if str(preview.get("phase", "")) == "location_select":
		return {"ok": false, "error": "location_select drain exceeded MAX_AUTO_HOPS"}
	# E1 临时兼容 (A1 前兜底): preview 遇盲选窗口 phase, 现有前端尚未接盲选 UI (F1 才做),
	# 此处自动选第一张承诺牌 (confirm_hand_pick) 退化为"单抽", 保持核心循环跑通。
	# F1 盲选窗口 UI 接通后, 改由 pack_window_for_pile / pick_hand 处理, 移除本兜底。
	if str(preview.get("phase", "")) == "hand_window":
		var hw: Array = preview.get("hand_window", [])
		if hw.is_empty():
			return {"ok": false, "error": "hand_window with no cards"}
		var first_uid := str((hw[0] as Dictionary).get("uid", ""))
		if first_uid.is_empty():
			return {"ok": false, "error": "hand_window card has empty uid"}
		preview = _engine.confirm_hand_pick(first_uid)
		if not preview.get("ok", false):
			return {"ok": false, "error": "confirm_hand_pick failed: %s" % str(preview.get("error", ""))}
		# 防御: confirm_hand_pick 注入 forced 后, preview 应走 forced 路径出真事件, 不应再返回 hand_window。
		# 若仍是 hand_window (forced 优先性被破坏 / handQueue 未正确移除), 显式报错, 避免被当
		# presentation 误解析成 title/body 全空的空白事件卡。
		if str(preview.get("phase", "")) == "hand_window":
			return {"ok": false, "error": "confirm_hand_pick did not advance past hand_window (forced 注入异常?)"}
	# A1: presentation 消化 + choice 提取 + _pending_* 收尾抽到公共尾函数, 与 pick_hand 共用。
	return _finalize_event_from_preview(preview)


# 功能: 摊出盲选窗口 — 调 preview + location 透明消化, 返回 K 张卡背数据 (F1 消费, 只 preview 不 commit)。
# 返回: { ok, mode, cards:[{uid, event_id, title}] } 或 { ok:false, error }
#   mode="blind":  盲选窗口路径, cards 为 K 张承诺手牌 (uid 非空, title 备而不显)。
#   mode="single": skeleton 末位回合无窗口, 引擎直接吐真事件 → window-of-1 (uid 空)。
#                  该 preview 已 set 引擎 pending, stash 供 pick_hand 直接 finalize ("预览即锁定",
#                  见实施 §六; 安全性挂 F2 事件锁定, 入口防御 cancel + preview 幂等双保险自愈)。
func pack_window_for_pile() -> Dictionary:
	if _engine == null:
		return {"ok": false, "error": "engine not initialized"}
	_pending_hand_preview = {}
	# 防御: 残留未结算的真事件 pending (F2 应已挡住玩家路径; 此处兜异常重入) → cancel 复位。
	# skeleton 的"预览即锁定"pending 不在此清 (其 _pending_resolved 仍 true), 由 preview 幂等自愈。
	if not _pending_resolved:
		_engine.cancel_pending_turn()
		_pending_resolved = true
	var preview: Dictionary = _engine.preview_next_turn()
	# location_select 透明消化 (与 events_for_pile 同循环; 开包/包结束阶段对前端不可见)。
	for hop in MAX_AUTO_HOPS:
		if not preview.get("ok", false):
			return {"ok": false, "error": str(preview.get("error", "preview failed"))}
		if str(preview.get("phase", "")) != "location_select":
			break
		var options: Array = preview.get("options", [])
		if options.is_empty():
			return {"ok": false, "error": "location_select with no options"}
		var loc_id := str((options[0] as Dictionary).get("location_id", ""))
		if loc_id.is_empty():
			return {"ok": false, "error": "location_select option has empty location_id"}
		var sel := _engine.confirm_location_select(loc_id)
		if not sel.get("ok", false):
			return {"ok": false, "error": "confirm_location_select failed: %s" % str(sel.get("error", ""))}
		preview = _engine.preview_next_turn()
	if str(preview.get("phase", "")) == "location_select":
		return {"ok": false, "error": "location_select drain exceeded MAX_AUTO_HOPS"}
	# blind 路: 盲选窗口 → 透传 K 张卡背 (uid + event_id + title)。
	if str(preview.get("phase", "")) == "hand_window":
		var hw: Array = preview.get("hand_window", [])
		if hw.is_empty():
			return {"ok": false, "error": "hand_window with no cards"}
		var cards: Array = []
		for c_v in hw:
			var c: Dictionary = c_v
			var uid := str(c.get("uid", ""))
			if uid.is_empty():
				return {"ok": false, "error": "hand_window card has empty uid"}
			cards.append({
				"uid": uid,
				"event_id": str(c.get("event_id", "")),
				"title": str(c.get("title", "")),
			})
		print("[适配器] pack_window_for_pile → mode=blind | K=%d" % cards.size())
		return {"ok": true, "mode": "blind", "cards": cards}
	# single 路: skeleton 直接吐真事件 (preview 已 set pending) → window-of-1。stash 供 pick_hand finalize。
	# P2 防御: 仅真实 pending 事件 (event_id 非空且 phase != ended) 走 single; 否则 (世界结束 / 未知 phase)
	#   显式报错, 避免把 ended/空白响应包成卡背交给前端、再被 pick_hand("") 消化出错误状态。
	var sk_event_id := str(preview.get("event_id", ""))
	var sk_phase := str(preview.get("phase", ""))
	if sk_event_id.is_empty() or sk_phase == "ended":
		return {"ok": false, "error": "pack_window_for_pile 非预期 phase=%s, event_id=%s (世界结束/未知态)" % [sk_phase, sk_event_id]}
	_pending_hand_preview = preview
	print("[适配器] pack_window_for_pile → mode=single (skeleton) | event_id=%s" % sk_event_id)
	return {
		"ok": true,
		"mode": "single",
		"cards": [{
			"uid": "",
			"event_id": sk_event_id,
			"title": str(preview.get("title", "")),
		}],
	}


# 功能: 按 uid 取引擎 store 持有的 CardData (持久盘面 · DD1 镜像派)。
# 说明: blind 路的盲选卡背是引擎预抽的 handQueue 实例, 前端只镜像、不在前端 store 自建 ——
#       前端卡 model 直接持引擎这份 CardData → 前端卡 uid == 引擎 uid, registry 可按引擎 uid
#       寻址该持久手牌卡节点 (杜绝 F1 双 store 同 cN 空间撞号)。引擎是 uid 真源, 调用方只读。
func engine_card_data(uid: String) -> CardData:
	if _engine == null:
		return null
	var store: CardZoneStore = _engine.get_card_store()
	if store == null:
		return null
	return store.get_card(uid)


# 功能: 盲选一张手牌 → 出真实承诺事件 (F1 点牌回调)。
# 参数: card_uid — blind 路传引擎 handQueue 的 uid; single 路 (skeleton) 传空串。
# 返回: 同 events_for_pile 形 { ok, event_id, title, body, has_choice, choice_point_id } 或 { ok:false, error }
func pick_hand(card_uid: String) -> Dictionary:
	if _engine == null:
		return {"ok": false, "error": "engine not initialized"}
	var preview: Dictionary
	if card_uid.is_empty():
		# single 路 (skeleton): 用 pack_window_for_pile stash 的 preview (已 pending)。
		if _pending_hand_preview.is_empty():
			return {"ok": false, "error": "pick_hand(single) without staged preview (先调 pack_window_for_pile?)"}
		preview = _pending_hand_preview
		_pending_hand_preview = {}
	else:
		# blind 路: confirm_hand_pick 注入 forced → 引擎走 forced 路径出真事件。
		_pending_hand_preview = {}
		preview = _engine.confirm_hand_pick(card_uid)
		if not preview.get("ok", false):
			return {"ok": false, "error": "confirm_hand_pick failed: %s" % str(preview.get("error", ""))}
		# 防御: forced 注入后应脱离 hand_window phase; 仍是则 forced 优先性被破坏, 显式报错。
		if str(preview.get("phase", "")) == "hand_window":
			return {"ok": false, "error": "confirm_hand_pick did not advance past hand_window (forced 注入异常?)"}
	return _finalize_event_from_preview(preview)


# 功能: 取当前 pending 事件的选项列表 (供前端展开选项卡)。
# 返回: [{id, text, opt_type, whitelist, threshold}]
#       opt_type:    OptType.CHECK / OptType.DIRECT (check 字段非空 ⇒ CHECK)
#       whitelist:   鉴定可投入的资源类型列表 (从 check.items 派生)
#       threshold:   MarkerCheckResolver 的投入鉴定难度 D (S8 期占位 FALLBACK_DIFFICULTY)
func options_for_event() -> Array:
	if _engine == null or _pending_choice_point_id.is_empty():
		print("[适配器] options_for_event → 选项数=0 (无 choice_point: '%s')" % _pending_choice_point_id)
		return []
	var cp_def: Dictionary = _choice_points_by_id.get(_pending_choice_point_id, {})
	if cp_def.is_empty():
		push_warning("[EngineDataSource] choice_point not found: %s" % _pending_choice_point_id)
		return []
	# engine S3 _build_option_set 已筛选可见选项 (trigger_condition 门控 + weight 抽取后),
	# events_for_pile 时已把 preview.choice.options 的 id 集合记入 _pending_visible_option_ids;
	# 此处取 cp_def.options ∩ visible_ids 拿到完整 option_def (含 check/whitelist 等 preview 不返回的字段)。
	# 兜底: 若 visible_ids 为空 (异常或非 choice 事件), 返回空列表而非全集, 避免暴露 engine 已排除的选项。
	var out: Array = []
	if _pending_visible_option_ids.is_empty():
		print("[适配器] options_for_event → 选项数=0 (engine 可见选项集为空, cp=%s)" % _pending_choice_point_id)
		return out
	for option_variant in cp_def.get("options", []):
		var option_def: Dictionary = option_variant
		var option_id := str(option_def.get("id", ""))
		if not _pending_visible_option_ids.has(option_id):
			continue
		out.append({
			"id": option_id,
			"text": str(option_def.get("text", "")),
			"opt_type": _derive_opt_type(option_def),
			"whitelist": _derive_whitelist(option_def),
			"threshold": _derive_difficulty(option_def),
		})
	print("[适配器] options_for_event → cp=%s | 选项数=%d" % [_pending_choice_point_id, out.size()])
	return out


# 功能: 标记投入数 → tier 决策 (调 MarkerCheckResolver)。
# 参数: opt_type / invested / difficulty — 来自 card_table 投入循环结束时
# 返回: "great_success" | "success" | "fail" | "great_fail"
func tier_from_invest(opt_type: int, invested: int, difficulty: int) -> String:
	if opt_type != OptType.CHECK:
		return "success"
	return MarkerCheckResolverScn.resolve(invested, difficulty)


# 功能: 玩家选择选项 + tier 已定 → 引擎结算 + 生成 §3.2 stub 账单。
# 参数:
#   option_id — 玩家选的选项 id
#   tier      — tier_from_invest 返回的档位 (DIRECT 选项传 "success")
# 返回: §3.2 stub 形状 { markers, tier, exp_deltas, flags }
#       与 MockData.outcome_for 完全同形, 由 card_table._reveal_result 直接读。
func outcome_for_option(option_id: String, tier: String) -> Dictionary:
	if _engine == null:
		return _empty_outcome(tier)
	# 应用前 snapshot 标记池, 应用后 diff → deltas 列表。
	# 这是最干净的取 deltas 方式 (engine 不返回 deltas, 也不暴露 resolution apply hook)。
	var before := _snapshot_token_counts()
	var result: Dictionary
	# DIRECT 选项无 check 字段, vibe-test 路径会直接走 base resolution, 不需要 forced。
	# CHECK 选项 (含 check 字段) 走 forced_tier 路径, 让引擎按我们算的 tier 选 resolution 分支。
	if tier == "success" and _is_direct_option(option_id):
		result = _engine.confirm_pending_turn(option_id)
	else:
		result = _engine.confirm_pending_turn_with_forced_tier(option_id, tier)
	if not result.get("ok", false):
		push_warning("[EngineDataSource] confirm failed: %s" % str(result.get("error", "unknown")))
		return _empty_outcome(tier)
	# 透明消化 outcome 屏: 选项结算后引擎可能追加 outcome 叙事屏 (phase=presentation),
	# 需继续 confirm("") 推到末屏才真正 advance turn。卡牌前端结果卡已展示 tier+marker,
	# outcome 叙事屏对 card_table 无意义。
	# B 升格: 收集结算后的 outcome 叙事屏(原全部 drain 丢弃) → 供升格舞台在结果揭示时切换展示。
	var outcome_screens: Array[String] = []
	var first_outcome := _extract_presentation_body(result)
	if not first_outcome.is_empty():
		outcome_screens.append(first_outcome)
	var hops: int = 0
	while bool(result.get("ok", false)) and str(result.get("phase", "")) == "presentation":
		result = _drain_one_presentation_step(result)
		hops += 1
		if hops > MAX_AUTO_HOPS:
			push_warning("[EngineDataSource] outcome drain exceeded MAX_AUTO_HOPS")
			break
		if bool(result.get("ok", false)):
			var t := _extract_presentation_body(result)
			if not t.is_empty():
				outcome_screens.append(t)
	# P2-2: drain 失败不应假装结算完成 — 保 _pending_resolved=false 让下次 events_for_pile 触发 cancel,
	#       avoid 把未完成结算的世界状态延续到下一回合。
	if not bool(result.get("ok", false)):
		push_warning("[EngineDataSource] outcome drain failed: %s" % str(result.get("error", "unknown")))
		return _empty_outcome(tier)
	# 结算完成: 标记 turn 已推进, 下次 events_for_pile 不 cancel (顺序选下一事件, 末位才命中 skeleton)
	_pending_resolved = true
	var after := _snapshot_token_counts()
	var deltas := _diff_token_counts(before, after)
	var bill: Dictionary = ResourceMarkerPoolScn.build_outcome_bill(deltas, tier, [])
	bill["narrative"] = "\n\n".join(outcome_screens)   # B 升格: 结果反馈文字, 供升格舞台
	return bill


# 功能: 档位中文名 (与 MockData.tier_label 同形)
func tier_label(tier: String) -> String:
	return MockDataScn.tier_label(tier)


# ============================================================
# 内部工具
# ============================================================

# 索引 choice_points 到 _choice_points_by_id, 供 options_for_event / outcome_for_option 查 option_def。
func _index_choice_points(world_event_data: Dictionary) -> void:
	_choice_points_by_id.clear()
	for cp_variant in world_event_data.get("choice_points", []):
		var cp: Dictionary = cp_variant
		var cp_id := str(cp.get("id", ""))
		if not cp_id.is_empty():
			_choice_points_by_id[cp_id] = cp


# 功能: 把一份已脱离 location_select / hand_window 的 preview 收尾为前端事件卡数据。
# 说明: A1 抽出的公共尾 — events_for_pile (skeleton/forced 路径) 与 pick_hand 共用, 杜绝两份漂移。
#   流程: 取首屏 title/body → 透明消化 presentation 屏 → 提取 choice_point + 可见 option 集
#         → 标 _pending_resolved=false (新事件待结算)。
#   透明消化: 卡牌前端事件卡只显示一屏正文, 引擎多屏叙事推进对 card_table 无意义, 自动 confirm("")
#             推到 choice / confirm 阶段 (与 location_select 同性质, 抹平 vibe-test/zhengdao 语义差)。
#             自省末屏 presents=location_select 走 _drain_one_presentation_step 内的专用分支。
# 返回: { ok, event_id, title, body, has_choice, choice_point_id } 或 { ok:false, error }
func _finalize_event_from_preview(preview: Dictionary) -> Dictionary:
	if not preview.get("ok", false):
		return {"ok": false, "error": str(preview.get("error", "preview not ok"))}
	# P1 修复: 到此引擎必有活跃 pending (confirm_hand_pick / forced / skeleton 已 set)。立即标"未结算",
	#   使后续任何 early-return (presentation drain 溢出 / drain 失败) 仍让下次 pack_window_for_pile 的
	#   入口防御 cancel 生效, 避免引擎卡在同一 pending、适配器却以为已结算的失配。
	_pending_resolved = false
	# title/body 取消化前第一屏 (作为事件卡正文); event_id 同样取首屏 (消化不改事件身份)。
	var title := str(preview.get("title", ""))
	var body := _extract_presentation_body(preview)
	var event_id := str(preview.get("event_id", ""))
	# B 升格: 收集全部 presentation 屏文本(原仅取 p1 当 body, p2~p4 被 drain 丢弃) → 供升格舞台展示完整叙事。
	# 背景美术取首屏 resolved_background_art(事件级, 仅留文件名, 前端自拼 res 路径)。
	var background_art := str(preview.get("resolved_background_art", "")).get_file()
	var narrative_screens: Array[String] = []
	if not body.is_empty():
		narrative_screens.append(body)
	var hops: int = 0
	while bool(preview.get("ok", false)) and str(preview.get("phase", "")) == "presentation":
		preview = _drain_one_presentation_step(preview)
		hops += 1
		if hops > MAX_AUTO_HOPS:
			return {"ok": false, "error": "presentation drain exceeded MAX_AUTO_HOPS"}
		if bool(preview.get("ok", false)):
			var screen_text := _extract_presentation_body(preview)
			if not screen_text.is_empty():
				narrative_screens.append(screen_text)
	if not preview.get("ok", false):
		return {"ok": false, "error": str(preview.get("error", "drain failed"))}
	_pending_choice_point_id = ""
	_pending_visible_option_ids.clear()
	var has_choice := bool(preview.get("has_choice", false))
	if has_choice:
		var choice: Dictionary = preview.get("choice", {})
		_pending_choice_point_id = str(choice.get("choice_point_id", ""))
		# 记下 engine S3 _build_option_set 筛选后的可见 option id 集合, 供 options_for_event 过滤 (P2-1 修复)。
		for opt_v in choice.get("options", []):
			var opt: Dictionary = opt_v
			var oid := str(opt.get("id", ""))
			if not oid.is_empty():
				_pending_visible_option_ids[oid] = true
	# _pending_resolved 已在函数顶部置 false (P1 修复), 此处不再重复。
	print("[适配器] finalize → event_id=%s | title=%s | has_choice=%s | cp=%s" % [
		event_id, title, str(has_choice), _pending_choice_point_id
	])
	return {
		"ok": true,
		"event_id": event_id,
		"title": title,
		"body": body,
		"narrative": "\n\n".join(narrative_screens),   # B 升格: 完整叙事(p1~pN), 供升格舞台
		"background_art": background_art,               # B 升格: 16:9 场景图文件名(缺则空)
		"has_choice": has_choice,
		"choice_point_id": _pending_choice_point_id,
	}


# 从 preview 返回结构中抽取 presentation body 文本 (用于事件卡正文)。
func _extract_presentation_body(preview: Dictionary) -> String:
	var pres: Dictionary = preview.get("presentation", {})
	var current_item: Dictionary = pres.get("current_item", {})
	return str(current_item.get("text", ""))


# 推进一屏 presentation: 普通屏走 confirm_pending_turn("");
# 自省末屏 presents=location_select 走 confirm_reflection_location_select (选第一个候选地点)。
# zhengdao-cards MVP 1 期不接自省 UI, 自省事件全程透明消化 (LineB §一·不做)。
func _drain_one_presentation_step(preview: Dictionary) -> Dictionary:
	var pres: Dictionary = preview.get("presentation", {})
	var current_item: Dictionary = pres.get("current_item", {})
	var presents := str(current_item.get("presents", "text"))
	if presents == "location_select":
		var ref_options: Array = _engine.get_reflection_location_options()
		if ref_options.is_empty():
			return {"ok": false, "error": "reflection location_select: no options"}
		var first: Dictionary = ref_options[0]
		var loc_id := str(first.get("location_id", ""))
		if loc_id.is_empty():
			return {"ok": false, "error": "reflection location_select: empty location_id"}
		return _engine.confirm_reflection_location_select(loc_id)
	return _engine.confirm_pending_turn("")


# 派生选项类型: option_def.check 非空 ⇒ CHECK; 否则 DIRECT。
# 注: assembler 默认 check=null (不是 {}), .get(_, {}) 默认值在 key 存在但值 null 时不生效;
#     需显式 null check (本模块多处复用此模式 → _option_check_dict 统一封装)。
func _derive_opt_type(option_def: Dictionary) -> int:
	var check := _option_check_dict(option_def)
	if check.is_empty():
		return OptType.DIRECT
	return OptType.CHECK


# 派生白名单: 从 check.items 提取 key 列表 (鉴定可投入资源类型)。
# 例: items=[{key:"craft", direction:"positive"}] → whitelist=["craft"]
func _derive_whitelist(option_def: Dictionary) -> Array:
	var check := _option_check_dict(option_def)
	var items: Array = check.get("items", [])
	var out: Array = []
	for item_variant in items:
		var item: Dictionary = item_variant
		var key := str(item.get("key", ""))
		if not key.is_empty():
			out.append(key)
	return out


# 安全取 option.check 字典: 字段不存在 / null 都统一返回空 Dict。
func _option_check_dict(option_def: Dictionary) -> Dictionary:
	var check_v: Variant = option_def.get("check", null)
	if check_v == null or typeof(check_v) != TYPE_DICTIONARY:
		return {}
	return check_v


# 派生鉴定难度 D: S8 期 CSV 无承载, 全部回退 FALLBACK_DIFFICULTY。
# TODO S8.5: 与用户决议 CSV 字段后改读真实字段 (候选: options.csv 加 invest_difficulty,
#            或从 check.hitThreshold / check.requiredHits 推, 或派生自 whitelist 长度)。
func _derive_difficulty(option_def: Dictionary) -> int:
	var _unused := option_def  # 占位避免 lint 警告 (S8.5 后会用上)
	return FALLBACK_DIFFICULTY


# 判定 option_id 是否为 DIRECT (无 check 字段) — outcome_for_option 路径选择用。
func _is_direct_option(option_id: String) -> bool:
	if _pending_choice_point_id.is_empty():
		return true
	var cp_def: Dictionary = _choice_points_by_id.get(_pending_choice_point_id, {})
	for option_variant in cp_def.get("options", []):
		var option: Dictionary = option_variant
		if str(option.get("id", "")) == option_id:
			return _option_check_dict(option).is_empty()
	return true


# 标记池快照: 对所有 token key 取 (count, capacity), 供 diff 计算 deltas。
func _snapshot_token_counts() -> Dictionary:
	var snap: Dictionary = {}
	if _player == null:
		return snap
	for token_key in ResourceMarkerPoolScn.ALL_TOKEN_KEYS:
		snap[token_key] = _player.get_resource(token_key, 0)
	return snap


# 计算两份 snapshot 的差异, 返回 [{token_key, amount}] (amount 正=gain 负=loss)。
# 0 差异不入列, 避免账单冗余。
func _diff_token_counts(before: Dictionary, after: Dictionary) -> Array:
	var deltas: Array = []
	for token_key in ResourceMarkerPoolScn.ALL_TOKEN_KEYS:
		var delta := int(after.get(token_key, 0)) - int(before.get(token_key, 0))
		if delta != 0:
			deltas.append({"token_key": token_key, "amount": delta})
	return deltas


# 空账单兜底 (engine 调用失败时返回, 保证 card_table 不崩)
func _empty_outcome(tier: String) -> Dictionary:
	return {"tier": tier, "markers": [], "exp_deltas": [], "flags": [], "narrative": ""}
