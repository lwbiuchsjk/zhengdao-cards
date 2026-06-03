extends SceneTree

# E0 冒烟脚本: 验证 CardZoneStore 卡实例 + Zone 权威态(原语①③ + 不变量 + 序列化)
# 用法: powershell.exe tools/run_godot.ps1 --headless --script tools/smoke_card_zone_store.gd
# 退出码 0=全过, 1=有失败。

const StoreScn := preload("res://scripts/systems/card_zone_store.gd")
const CardDataScn := preload("res://scripts/models/card_data.gd")


# 工具: 统计某 uid 当前出现在几个 Zone 的 members 里(验"恰一个"不变量)
func _zone_membership_count(store, uid: String, zones: Array) -> int:
	var n := 0
	for z in zones:
		if store.cards_in_zone(z).has(uid):
			n += 1
	return n


func _init() -> void:
	print("=== CardZoneStore E0 冒烟 开始 ===")
	var ok := true
	var n := 0
	var EK: int = CardDataScn.CardKind.EVENT
	var def := {"title": "练场训练", "tags": ["training"]}
	var all_zones := ["zone_hand", "zone_discard", "zone_void"]

	var store = StoreScn.new()
	store.register_zone("zone_hand", "hand")
	store.register_zone("zone_discard", "discard")
	store.register_zone("zone_void", "void")

	# 1. 建 3 张同 logical_id 卡入 hand → uid 各异、均在 hand
	n += 1
	var a: CardData = store.create_card("evt_drill", EK, def, "zone_hand")
	var b: CardData = store.create_card("evt_drill", EK, def, "zone_hand")
	var c: CardData = store.create_card("evt_drill", EK, def, "zone_hand")
	if a.card_uid != b.card_uid and b.card_uid != c.card_uid \
			and store.cards_in_zone("zone_hand").size() == 3 \
			and a.zone_id == "zone_hand":
		print("[smoke] 1 同名 3 实例入 hand、uid 各异 ✔")
	else:
		push_error("[smoke] 1 失败: hand=%s" % str(store.cards_in_zone("zone_hand")))
		ok = false

	# 2. 不变量: 每卡恰属一个 Zone
	n += 1
	if _zone_membership_count(store, a.card_uid, all_zones) == 1 \
			and _zone_membership_count(store, b.card_uid, all_zones) == 1:
		print("[smoke] 2 不变量「卡恒属恰一个 Zone」✔")
	else:
		push_error("[smoke] 2 不变量破")
		ok = false

	# 3. move A: hand→discard 原子转移
	n += 1
	var moved: bool = store.move_card(a.card_uid, "zone_discard")
	if moved and a.zone_id == "zone_discard" \
			and not store.cards_in_zone("zone_hand").has(a.card_uid) \
			and store.cards_in_zone("zone_discard").has(a.card_uid) \
			and store.cards_in_zone("zone_hand").size() == 2 \
			and _zone_membership_count(store, a.card_uid, all_zones) == 1:
		print("[smoke] 3 move A hand→discard 原子转移、B/C 不动 ✔")
	else:
		push_error("[smoke] 3 move 失败")
		ok = false

	# 4. 查询: logical / tag / kind
	n += 1
	if store.find_by_logical("evt_drill").size() == 3 \
			and store.find_by_tag("training").size() == 3 \
			and store.find_by_kind(EK).size() == 3:
		print("[smoke] 4 查询 logical/tag/kind ✔")
	else:
		push_error("[smoke] 4 查询失败")
		ok = false

	# 5. remove_card: 从 Zone + 在册表清除
	n += 1
	var removed: bool = store.remove_card(c.card_uid)
	if removed and not store.has_card(c.card_uid) \
			and not store.cards_in_zone("zone_hand").has(c.card_uid) \
			and store.count() == 2:
		print("[smoke] 5 remove_card 清除 ✔")
	else:
		push_error("[smoke] 5 remove 失败")
		ok = false

	# 6. 序列化往返 + uid 续号不冲突 + def 重挂
	n += 1
	var d: Dictionary = store.to_dict()
	var store2 = StoreScn.from_dict(d)
	# 续号: 重载后新建卡的 uid 不应撞已有
	var existing: Array = store2.all_uids()
	var e: CardData = store2.create_card("evt_new", EK, {}, "zone_hand")
	var dup_uid: bool = existing.has(e.card_uid)
	# Zone 成员 + 总数保持; def 经 relink 重挂
	store2.relink_defs(func(lid: String) -> Dictionary:
		return def if lid == "evt_drill" else {})
	var a2: CardData = store2.get_card(a.card_uid)
	if not dup_uid \
			and store2.has_card(a.card_uid) and a2.zone_id == "zone_discard" \
			and store2.cards_in_zone("zone_hand").has(b.card_uid) \
			and a2.get_def() == def:
		print("[smoke] 6 序列化往返 + uid 续号不冲突 + def 重挂 ✔")
	else:
		push_error("[smoke] 6 序列化失败: dup_uid=%s" % str(dup_uid))
		ok = false

	# 7. P1-1: 同 Zone move 幂等(返回 true、成员不重复/不乱序)
	n += 1
	var hand_before: Array = store.cards_in_zone("zone_hand")  # 此时 hand 含 b
	var same_move: bool = store.move_card(b.card_uid, "zone_hand")
	var hand_after: Array = store.cards_in_zone("zone_hand")
	if same_move and hand_after == hand_before and hand_after.count(b.card_uid) == 1:
		print("[smoke] 7 同 Zone move 幂等 ✔")
	else:
		push_error("[smoke] 7 同 Zone move 非幂等: %s→%s" % [str(hand_before), str(hand_after)])
		ok = false

	# 8. P1-2+P1-3+P2-2: 脏数据 from_dict — members 含 stale uid、cards 与 zone 不一致、含 null 值
	n += 1
	var dirty := {
		"uid_seq": 0,  # 故意过小, 应被 max(现有最大 uid+1) 纠正
		"zones": {
			"zone_hand": {"kind": "hand", "members": ["c0", "GHOST", "c0"]},  # stale/重复 GHOST + 重复 c0
			"zone_bad": null,  # 非 Dict 值
		},
		"cards": {
			"c0": {"card_uid": "c0", "logical_id": "evt_x", "card_kind": EK, "modifiers": [], "tags": [], "zone_id": "zone_discard"},  # 权威 zone=discard, 与 hand members 矛盾
			"c5": {"card_uid": "c5", "logical_id": "evt_y", "card_kind": EK, "modifiers": [], "tags": [], "zone_id": "zone_hand"},
			"junk": null,  # 非 Dict 卡, 应跳过
		},
	}
	var ds = StoreScn.from_dict(dirty)
	# 期望: c0 权威在 discard(不在 hand)、GHOST 被丢弃、hand 只含 c5、续号 = max(0, 5+1)=6
	var fresh: CardData = ds.create_card("evt_z", EK, {}, "zone_hand")
	if ds.cards_in_zone("zone_discard") == ["c0"] \
			and ds.cards_in_zone("zone_hand").has("c5") and not ds.cards_in_zone("zone_hand").has("c0") \
			and not ds.cards_in_zone("zone_hand").has("GHOST") \
			and not ds.has_card("junk") \
			and fresh.card_uid == "c6":
		print("[smoke] 8 脏数据 from_dict 重建一致 + 续号纠正(c6) ✔")
	else:
		push_error("[smoke] 8 脏数据重建失败: discard=%s hand=%s fresh=%s" % [
			str(ds.cards_in_zone("zone_discard")), str(ds.cards_in_zone("zone_hand")), fresh.card_uid])
		ok = false

	# 9. P1-4: add_existing 重复 uid — 不残留多 Zone
	n += 1
	var dup := CardDataScn.make("c5", "evt_y", EK, {}, "zone_discard")  # 与 ds 里 c5 同 uid, 但 zone 改 discard
	ds.add_existing(dup)
	if ds.cards_in_zone("zone_discard").count("c5") == 1 \
			and not ds.cards_in_zone("zone_hand").has("c5") \
			and _zone_membership_count(ds, "c5", ["zone_hand", "zone_discard", "zone_bad"]) == 1:
		print("[smoke] 9 add_existing 重复 uid 不残留多 Zone ✔")
	else:
		push_error("[smoke] 9 add_existing 残留: hand=%s discard=%s" % [
			str(ds.cards_in_zone("zone_hand")), str(ds.cards_in_zone("zone_discard"))])
		ok = false

	print("=== CardZoneStore E0 冒烟 %s (%d 项) ===" % ["全过 PASS" if ok else "有失败 FAIL", n])
	quit(0 if ok else 1)
