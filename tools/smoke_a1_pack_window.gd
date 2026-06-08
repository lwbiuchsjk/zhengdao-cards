extends SceneTree

# A1 适配器冒烟脚本: EngineDataSource 承诺窗口接口 (pack_window_for_pile / pick_hand)。
# 用法: powershell.exe tools/run_godot.ps1 --headless --script tools/smoke_a1_pack_window.gd
# 跑完自动 quit (退出码 0=全过, 1=有失败)。
#
# 覆盖 (对应实施 §四 A1 + §六边界):
#   A. blind 路   — 摊窗 K 张卡背 (uid 非空 + event_id) → pick_hand(uid) 出真实承诺事件 (forced=所选)
#   B. single 路  — 末位回合 skeleton, 引擎直接吐真事件 → mode=single (uid 空) → pick_hand("") 走 stash
#   C. 自愈       — skeleton 回合连调两次 pack_window_for_pile, 幂等 (同 event_id) + 后续 pick 仍正常 (§六保险)
#   D. 公共尾一致 — pick_hand 返回形与 events_for_pile 同 (event_id/title/body/has_choice/choice_point_id)
# dedup 开关属引擎 packConfig 层 (A1 零代码), 由 E1 引擎 smoke / I1 集成验证, 本脚本不覆盖。

const EngineDataSrc := preload("res://scripts/ui/engine_data_source.gd")

var _n: int = 0
var _ok: bool = true


func _check(cond: bool, label: String) -> void:
	_n += 1
	if cond:
		print("  [PASS] ", label)
	else:
		_ok = false
		print("  [FAIL] ", label)


# 取适配器内引擎的 packContext (用于 B 段直接置 turnsElapsed 逼末位回合, 同 E1 smoke 手法)。
func _pack_ctx(ds: Object) -> Dictionary:
	var ws: Dictionary = ds._engine.world_state
	var ctx: Variant = ws.get("packContext", {})
	return ctx if ctx is Dictionary else {}


func _init() -> void:
	print("=== A1 承诺窗口适配器冒烟 开始 ===")

	# ───── A. blind 路: 摊窗 → 盲选 → 出真实承诺事件 ─────
	print("--- A. blind 路 (盲选窗口) ---")
	var ds: Object = EngineDataSrc.new(0)
	_check(ds._engine != null, "适配器引擎初始化")

	var win: Dictionary = ds.pack_window_for_pile()
	_check(win.get("ok", false), "pack_window_for_pile ok (err=%s)" % str(win.get("error", "")))
	_check(str(win.get("mode", "")) == "blind", "首包 mode=blind (实 %s)" % str(win.get("mode", "")))
	var cards: Array = win.get("cards", [])
	_check(not cards.is_empty(), "窗口非空 (K=%d)" % cards.size())

	# 每张卡背带非空 uid + event_id
	var all_uid: bool = true
	var all_eid: bool = true
	for c_v in cards:
		var c: Dictionary = c_v
		if str(c.get("uid", "")).is_empty():
			all_uid = false
		if str(c.get("event_id", "")).is_empty():
			all_eid = false
	_check(all_uid, "每张卡背带非空 uid")
	_check(all_eid, "每张卡背带非空 event_id")

	# 盲选第一张 → pick_hand(uid)
	var pick: Dictionary = cards[0]
	var pick_uid: String = str(pick.get("uid", ""))
	var pick_eid: String = str(pick.get("event_id", ""))
	var ev: Dictionary = ds.pick_hand(pick_uid)
	_check(ev.get("ok", false), "pick_hand(uid) ok (err=%s)" % str(ev.get("error", "")))
	_check(str(ev.get("event_id", "")) == pick_eid, "出真实承诺事件 = 所选 (forced 注入; 实 %s 期 %s)" % [
		str(ev.get("event_id", "")), pick_eid
	])
	# D. 返回形与 events_for_pile 同 (字段齐备)
	for key in ["ok", "event_id", "title", "body", "has_choice", "choice_point_id"]:
		_check(ev.has(key), "pick_hand 返回含字段 %s" % key)

	# ───── B+C. single 路 (skeleton) + 自愈 ─────
	print("--- B+C. single 路 (skeleton) + 自愈 ---")
	var ds2: Object = EngineDataSrc.new(0)
	# 先摊首包窗 (建包 + 抽 turn-1 窗口); blind 路不占引擎 pending。
	var w0: Dictionary = ds2.pack_window_for_pile()
	_check(str(w0.get("mode", "")) == "blind", "ds2 首包 mode=blind")
	# 直接置 turnsElapsed = capacity-1, 下一次 preview 即末位回合 (同 E1 smoke §B 手法)。
	var ctx: Dictionary = _pack_ctx(ds2)
	var cap: int = int(ctx.get("turnCapacity", 3))
	ctx["turnsElapsed"] = cap - 1
	ds2._engine.world_state["packContext"] = ctx

	# 第一次摊窗 → 末位回合, 引擎跳过盲选窗口直接吐 skeleton → mode=single。
	var s1: Dictionary = ds2.pack_window_for_pile()
	_check(s1.get("ok", false), "skeleton pack_window ok (err=%s)" % str(s1.get("error", "")))
	_check(str(s1.get("mode", "")) == "single", "末位回合 mode=single (实 %s)" % str(s1.get("mode", "")))
	var s1_cards: Array = s1.get("cards", [])
	_check(s1_cards.size() == 1, "single 窗口 1 张 (实 %d)" % s1_cards.size())
	var sk_eid: String = str((s1_cards[0] as Dictionary).get("event_id", ""))
	_check(not sk_eid.is_empty(), "skeleton event_id 非空 (实 %s)" % sk_eid)
	_check(str((s1_cards[0] as Dictionary).get("uid", "")) == "", "single 卡 uid 空 (非 handQueue 实例)")

	# C. 自愈: 同一末位回合再调一次, 应幂等返回同 skeleton (preview 幂等 + 入口防御双保险)。
	var s2: Dictionary = ds2.pack_window_for_pile()
	_check(str(s2.get("mode", "")) == "single", "重入仍 mode=single (自愈)")
	var sk_eid2: String = str((s2.get("cards", [])[0] as Dictionary).get("event_id", ""))
	_check(sk_eid2 == sk_eid, "重入幂等: 同 skeleton event_id (%s == %s)" % [sk_eid2, sk_eid])

	# pick_hand("") 走 stash 的 preview finalize → 出 skeleton 真事件。
	var sk_ev: Dictionary = ds2.pick_hand("")
	_check(sk_ev.get("ok", false), "pick_hand(single) ok (err=%s)" % str(sk_ev.get("error", "")))
	_check(str(sk_ev.get("event_id", "")) == sk_eid, "single pick 出 skeleton 事件 (实 %s 期 %s)" % [
		str(sk_ev.get("event_id", "")), sk_eid
	])

	# 边界: 无 stash 时 pick_hand("") 应报错 (不静默)。
	var bad: Dictionary = ds2.pick_hand("")
	_check(not bad.get("ok", true), "无 stash 的 pick_hand(single) 显式报错")

	print("=== 结束: %d 项, %s ===" % [_n, "全过" if _ok else "有失败"])
	quit(0 if _ok else 1)
