extends SceneTree

# F1 盲选窗口 — 逻辑单元冒烟 (uid 采用 + 数据源同形)。
# 用法: powershell.exe tools/run_godot.ps1 --headless --script tools/smoke_f1_uid_window.gd
# 跑完自动 quit (退出码 0=全过, 1=有失败)。
#
# 覆盖 F1 新增的纯逻辑层 (视觉行为—摊牌/翻牌/消散/镜头—属 GUI 手动验收, headless 不验):
#   A. CardZoneStore.create_card uid_override — 采用引擎下发 uid + 续号防撞 (A 决策落地)
#   B. MockDataSource pack_window_for_pile / pick_hand 同形 — USE_ENGINE=false fallback 单路径一致
# EngineDataSource 的窗口接口已由 smoke_a1_pack_window 覆盖, 本脚本不重复。

const CardZoneStoreScn := preload("res://scripts/systems/card_zone_store.gd")
const MockDataSourceScn := preload("res://scripts/ui/mock_data_source.gd")
const CardScn := preload("res://scripts/ui/card.gd")

var _n: int = 0
var _ok: bool = true


func _check(cond: bool, label: String) -> void:
	_n += 1
	if cond:
		print("  [PASS] ", label)
	else:
		_ok = false
		print("  [FAIL] ", label)


func _init() -> void:
	print("=== F1 盲选窗口逻辑冒烟 开始 ===")

	# ───── A. CardZoneStore.create_card uid_override + 检重防御 (codex P1) ─────
	# 注: F1 已撤掉前端对 uid_override 的使用(双 store 撞号), 但 create_card 保留参数 + 检重防御
	#     供持久盘面阶段正确实现使用。本段验检重逻辑本身。
	print("--- A. uid_override 检重防御 ---")
	var store: Object = CardZoneStoreScn.new()
	store.register_zone("hand_window")

	# 采用一个 store 内不存在的 uid "c50" → 成功
	var c1: Object = store.create_card("evt_x", CardScn.CardType.EVENT, {}, "hand_window", [], "c50")
	_check(c1 != null and c1.card_uid == "c50", "采用不撞的 uid_override='c50' (实 %s)" % (c1.card_uid if c1 != null else "null"))

	# 再采用已存在的 "c50" → 检重防御拒绝, 返回 null (不静默覆盖)
	var dup: Object = store.create_card("evt_dup", CardScn.CardType.EVENT, {}, "hand_window", [], "c50")
	_check(dup == null, "撞号 uid_override='c50' 被检重拒绝 (返回 null)")
	# 撞号拒绝后 zone 不应混入坏条目 (仍只有 c1 那张)
	_check(store.cards_in_zone("hand_window").size() == 1, "撞号拒绝后 zone 成员未污染 (实 %d)" % store.cards_in_zone("hand_window").size())

	# 续号防撞: 采用 c50 后自动分配应 > c50
	var c2: Object = store.create_card("evt_y", CardScn.CardType.EVENT, {}, "hand_window")
	_check(c2 != null and c2.card_uid != "c50", "采用后自动分配不撞 c50 (实 %s)" % (c2.card_uid if c2 != null else "null"))
	var c2_num := int(str(c2.card_uid).substr(1)) if c2 != null else -1
	_check(c2_num > 50, "续号已推高 > 50 (实 %d)" % c2_num)

	# 空 override → 正常自动分配
	var c3: Object = store.create_card("evt_z", CardScn.CardType.EVENT, {}, "hand_window", [], "")
	_check(c3 != null and not str(c3.card_uid).is_empty(), "空 override 正常自动分配 (实 %s)" % (c3.card_uid if c3 != null else "null"))

	# 三张有效卡 uid 互异 + 均在 zone (dup 被拒不计)
	var uids: Dictionary = {}
	for c in [c1, c2, c3]:
		uids[str(c.card_uid)] = true
	_check(uids.size() == 3, "三张有效卡 uid 互异 (实 %d)" % uids.size())
	var zone_members: Array = store.cards_in_zone("hand_window")
	_check(zone_members.size() == 3, "三张有效卡均在 hand_window zone (实 %d)" % zone_members.size())

	# ───── B. MockDataSource 同形 (USE_ENGINE=false fallback) ─────
	print("--- B. MockDataSource 承诺窗口同形 ---")
	var mock: Object = MockDataSourceScn.new()
	var win: Dictionary = mock.pack_window_for_pile()
	_check(win.get("ok", false), "mock pack_window_for_pile ok")
	_check(str(win.get("mode", "")) == "single", "mock mode=single (实 %s)" % str(win.get("mode", "")))
	var cards: Array = win.get("cards", [])
	_check(cards.size() == 1, "mock 窗口 1 张 (实 %d)" % cards.size())
	var card0: Dictionary = cards[0] if not cards.is_empty() else {}
	_check(str(card0.get("uid", "x")) == "", "mock 卡 uid 空")
	_check(not str(card0.get("event_id", "")).is_empty(), "mock 卡 event_id 非空")

	var ev: Dictionary = mock.pick_hand("")
	_check(ev.get("ok", false), "mock pick_hand ok")
	_check(str(ev.get("event_id", "")) == str(card0.get("event_id", "")), "mock pick 事件 = 窗口卡 event_id")
	for key in ["ok", "event_id", "title", "body", "has_choice", "choice_point_id"]:
		_check(ev.has(key), "mock pick_hand 返回含字段 %s" % key)

	print("=== 结束: %d 项, %s ===" % [_n, "全过" if _ok else "有失败"])
	quit(0 if _ok else 1)
