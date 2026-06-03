extends SceneTree

# E0 冒烟脚本: 验证 CardData 数据模型(三原语①② + 序列化)
# 用法: powershell.exe tools/run_godot.ps1 --headless --script tools/smoke_card_data.gd
# 退出码 0=全过, 1=有失败。

const CardDataScn := preload("res://scripts/models/card_data.gd")


func _init() -> void:
	print("=== CardData E0 冒烟 开始 ===")
	var ok := true
	var n := 0

	# 共享静态 def(模拟引擎事件定义);多实例共享同一引用
	var def := {"title": "练场训练", "tags": ["training", "common"], "effect": "+1 craft"}

	# 1. make + 字段 + tags 从 def 派生
	n += 1
	var a := CardDataScn.make("uid-A", "evt_drill", CardDataScn.CardKind.EVENT, def, "zone_hand")
	if a.card_uid == "uid-A" and a.logical_id == "evt_drill" and a.card_kind == CardDataScn.CardKind.EVENT \
			and a.zone_id == "zone_hand" and a.has_tag("training") and a.has_tag("common"):
		print("[smoke] 1 make + tags 派生 ✔")
	else:
		push_error("[smoke] 1 make/tags 失败: %s" % str(a))
		ok = false

	# 2. 原语①: 同 logical_id 多实例各持不同 uid、可区分
	n += 1
	var b := CardDataScn.make("uid-B", "evt_drill", CardDataScn.CardKind.EVENT, def, "zone_hand")
	var c := CardDataScn.make("uid-C", "evt_drill", CardDataScn.CardKind.EVENT, def, "zone_hand")
	if a.card_uid != b.card_uid and b.card_uid != c.card_uid and a.logical_id == c.logical_id:
		print("[smoke] 2 同名多实例 uid 各异(A≠B≠C, 同 logical_id) ✔")
	else:
		push_error("[smoke] 2 多实例区分失败")
		ok = false

	# 3. 原语②: def 共享引用 + 空 modifiers → effective_def 零拷贝返回同一引用
	n += 1
	if a.get_def() == def and a.effective_def() == def and not a.has_modifiers():
		print("[smoke] 3 def 共享 + 空 modifiers effective 返回 def ✔")
	else:
		push_error("[smoke] 3 def 引用/effective 失败")
		ok = false

	# 4. 只对 A 挂修饰,不影响 B(实例隔离)
	n += 1
	a.add_modifier({"type": "boost", "value": 2})
	if a.has_modifiers() and not b.has_modifiers() and a.get_modifiers().size() == 1:
		print("[smoke] 4 只强化 A、B 不受影响(实例隔离) ✔")
	else:
		push_error("[smoke] 4 修饰隔离失败")
		ok = false
	a.clear_modifiers()

	# 5. tag 追加去重
	n += 1
	a.add_tag("training")  # 已有,不重复
	a.add_tag("rare")
	if a.tags.count("training") == 1 and a.has_tag("rare"):
		print("[smoke] 5 tag 追加去重 ✔")
	else:
		push_error("[smoke] 5 tag 去重失败: %s" % str(a.tags))
		ok = false

	# 6. 原语③: zone setter
	n += 1
	a.set_zone("zone_discard")
	if a.zone_id == "zone_discard":
		print("[smoke] 6 zone 转移字段写入 ✔")
	else:
		push_error("[smoke] 6 zone 写入失败")
		ok = false

	# 7. to_dict/from_dict 往返(def_ref 不入序列化,需 link 重挂)
	n += 1
	b.add_modifier({"type": "mark", "value": 1})
	var d: Dictionary = b.to_dict()
	if d.has("_def_ref") or d.has("def_ref"):
		push_error("[smoke] 7 序列化不应含 def_ref")
		ok = false
	var b2 := CardDataScn.from_dict(d)
	if b2.card_uid == b.card_uid and b2.logical_id == b.logical_id and b2.card_kind == b.card_kind \
			and b2.zone_id == b.zone_id and b2.get_modifiers().size() == 1 and b2.get_def().is_empty():
		# 重挂 def 后 effective 可用
		b2.link_def(def)
		if b2.get_def() == def:
			print("[smoke] 7 to_dict/from_dict 往返 + link_def 重挂 ✔")
		else:
			push_error("[smoke] 7 link_def 失败")
			ok = false
	else:
		push_error("[smoke] 7 往返字段不一致: %s" % str(b2))
		ok = false

	print("=== CardData E0 冒烟 %s (%d 项) ===" % ["全过 PASS" if ok else "有失败 FAIL", n])
	quit(0 if ok else 1)
