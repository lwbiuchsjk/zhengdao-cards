extends SceneTree

# E1 引擎包模型冒烟脚本: 盲选窗口(handQueue 预抽 + uid 贯穿 + 盲选注入 + skeleton 让位 + 余牌清理)。
# 覆盖 [[完整事件流程_实施]] §四 E1 / §五 的引擎侧可自动化部分(前端 F1 才接,故引擎独立验)。
# 用法: powershell.exe tools/run_godot.ps1 --headless --script tools/smoke_pack_hand_window.gd
# 退出码 0=全过, 1=有失败。

const EngineScn := preload("res://scripts/systems/world_event_engine.gd")
const CONFIG_DIR := "res://scripts/config/world_event_mvp"

var _n: int = 0
var _ok: bool = true


func _check(cond: bool, label: String) -> void:
	_n += 1
	if cond:
		print("  [PASS] ", label)
	else:
		_ok = false
		print("  [FAIL] ", label)


# 新建并加载一个引擎实例(固定 seed 便于复现)。
func _fresh_engine() -> Object:
	var engine: Object = EngineScn.new(12345)
	var res: Dictionary = engine.load_from_csv_dir(CONFIG_DIR)
	if not res.get("ok", false):
		print("  [FATAL] 配置加载失败: ", res.get("error", ""))
		_ok = false
	return engine


func _pack_ctx(engine: Object) -> Dictionary:
	var ws: Dictionary = engine.world_state
	var ctx: Variant = ws.get("packContext", {})
	return ctx if ctx is Dictionary else {}


func _init() -> void:
	print("=== E1 盲选窗口冒烟 开始 ===")

	# ───── A. 核心盲选: 预抽 → 摊窗 → uid 各异 → 盲选注入 → 移除/转区 ─────
	print("--- A. 核心盲选 ---")
	var e: Object = _fresh_engine()
	var open: Dictionary = e.confirm_location_select("loc_pharmacy")
	_check(open.get("ok", false), "开包 loc_pharmacy")

	# 预抽 K=5 张(handSpread 默认 5)
	var hq: Array = _pack_ctx(e).get("handQueue", [])
	_check(hq.size() == 5, "预抽 K=5 张 (实抽 %d)" % hq.size())

	# 实例进 _card_store 的 hand_window zone
	var zone_cards: Array = e._card_store.cards_in_zone("hand_window")
	_check(zone_cards.size() == 5, "hand_window zone 持 5 张实例 (实 %d)" % zone_cards.size())

	# preview 出 hand_window phase
	var pv: Dictionary = e.preview_next_turn()
	_check(str(pv.get("phase", "")) == "hand_window", "preview phase=hand_window")
	var window: Array = pv.get("hand_window", [])
	_check(window.size() == 5, "窗口返回 5 张 (实 %d)" % window.size())

	# uid 各异(line 109: 同名多实例可分辨)+ 每张带 event_id/title
	var uid_set: Dictionary = {}
	var all_have_eid: bool = true
	for c_variant in window:
		var c: Dictionary = c_variant
		uid_set[str(c.get("uid", ""))] = true
		if str(c.get("event_id", "")).is_empty():
			all_have_eid = false
	_check(uid_set.size() == 5, "5 个 uid 互异 (实 %d)" % uid_set.size())
	_check(all_have_eid, "每张窗口卡带非空 event_id")

	# 盲选第一张
	var pick: Dictionary = window[0]
	var pick_uid: String = str(pick.get("uid", ""))
	var pick_eid: String = str(pick.get("event_id", ""))
	var after: Dictionary = e.confirm_hand_pick(pick_uid)
	_check(after.get("ok", false), "confirm_hand_pick ok")
	_check(str(after.get("phase", "")) != "hand_window", "选后出真事件(脱离窗口 phase)")
	_check(str(e.world_state.get("forcedNextEventId", "")) == pick_eid, "forcedNextEventId 注入=所选 event")

	# handQueue 移除该 uid、窗口剩 4
	var hq2: Array = _pack_ctx(e).get("handQueue", [])
	_check(not (pick_uid in hq2), "选中 uid 已移出 handQueue")
	_check(hq2.size() == 4, "窗口剩 4 (实 %d)" % hq2.size())

	# 选中卡转区 causal_chain、离开 hand_window
	var chain_cards: Array = e._card_store.cards_in_zone("causal_chain")
	var hw_after: Array = e._card_store.cards_in_zone("hand_window")
	_check(pick_uid in chain_cards, "选中卡转入 causal_chain")
	_check(not (pick_uid in hw_after), "选中卡离开 hand_window zone")

	# ───── B. skeleton 让位: 末位回合不开盲选窗口, 走末位池 ─────
	print("--- B. skeleton 让位 ---")
	var e2: Object = _fresh_engine()
	e2.confirm_location_select("loc_pharmacy")
	var cap: int = int(_pack_ctx(e2).get("turnCapacity", 3))
	# 直接置 turnsElapsed = capacity-1(下一回合即末位), 验证调度让位(不走完整事件结算)
	var ctx2: Dictionary = _pack_ctx(e2)
	ctx2["turnsElapsed"] = cap - 1
	e2.world_state["packContext"] = ctx2
	var pv2: Dictionary = e2.preview_next_turn()
	_check(str(pv2.get("phase", "")) != "hand_window", "末位回合不再开盲选窗口")
	_check(str(pv2.get("event_id", "")) == "evt_s2_sk_he", "末位池出 skeleton evt_s2_sk_he (实 %s)" % str(pv2.get("event_id", "")))

	# ───── C. 余牌清理: 清包回收未玩 uid, 不泄漏 ─────
	print("--- C. 余牌清理 ---")
	var e3: Object = _fresh_engine()
	e3.confirm_location_select("loc_pharmacy")
	var hq3_before: Array = _pack_ctx(e3).get("handQueue", [])
	var hw_before: Array = e3._card_store.cards_in_zone("hand_window")
	_check(hq3_before.size() == 5 and hw_before.size() == 5, "清理前 handQueue=5 + zone=5")
	e3._clear_pack_context()
	var hq3_after: Array = _pack_ctx(e3).get("handQueue", [])
	var hw_after3: Array = e3._card_store.cards_in_zone("hand_window")
	_check(hq3_after.is_empty(), "清包后 handQueue 空")
	_check(hw_after3.is_empty(), "清包后 hand_window zone 空(余牌已 remove)")

	# ───── D. 适配器兜底: events_for_pile 遇 hand_window 自动单抽出真事件(A1 前兼容) ─────
	print("--- D. 适配器兜底 ---")
	var EngineDataSrc := preload("res://scripts/ui/engine_data_source.gd")
	var ds: Object = EngineDataSrc.new(0)
	var ev: Dictionary = ds.events_for_pile()
	_check(ev.get("ok", false), "适配器 events_for_pile ok (err=%s)" % str(ev.get("error", "")))
	_check(not str(ev.get("event_id", "")).is_empty(), "兜底单抽出非空 event_id (实 %s)" % str(ev.get("event_id", "")))

	# ───── E. P2 修复: 包结束清 causal_chain, 选中卡不泄漏 ─────
	print("--- E. causal_chain 清理 (P2 修复) ---")
	var e5: Object = _fresh_engine()
	e5.confirm_location_select("loc_pharmacy")
	var pv5: Dictionary = e5.preview_next_turn()
	var window5: Array = pv5.get("hand_window", [])
	var pick5: Dictionary = window5[0]
	e5.confirm_hand_pick(str(pick5.get("uid", "")))
	var chain_before: Array = e5._card_store.cards_in_zone("causal_chain")
	_check(chain_before.size() == 1, "选牌后 causal_chain 有 1 张 (实 %d)" % chain_before.size())
	e5._clear_pack_context()
	var chain_after: Array = e5._card_store.cards_in_zone("causal_chain")
	_check(chain_after.is_empty(), "清包后 causal_chain 空 (选中卡已回收, 无泄漏)")
	_check(e5._card_store.count() == 0, "清包后 _card_store 无残留实例 (实 %d)" % e5._card_store.count())

	print("=== 结束: %d 项, %s ===" % [_n, "全过" if _ok else "有失败"])
	quit(0 if _ok else 1)
