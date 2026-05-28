extends SceneTree

# Line B S8.2 冒烟脚本: 验证 EngineDataSource 启动 + 基本接口形状
# 用法: powershell.exe tools/run_godot.ps1 --headless --script tools/smoke_engine_data_source.gd
# 跑完: 自动 quit (退出码 0=ok, 1=fail)。本文件可保留作 S8.2 单元测试入口。

const EngineDataSourceScn := preload("res://scripts/ui/engine_data_source.gd")


func _init() -> void:
	print("=== EngineDataSource S8.2 冒烟 开始 ===")
	var ok := true

	# 1. 启动
	var ds := EngineDataSourceScn.new(42)
	if ds._engine == null:
		push_error("[smoke] _engine is null")
		ok = false

	# 2. 抽事件 (preview_next_turn)
	var event_info: Dictionary = ds.events_for_pile()
	print("[smoke] events_for_pile → ok=%s, event_id=%s, title=%s, has_choice=%s, error=%s" % [
		str(event_info.get("ok", false)),
		str(event_info.get("event_id", "")),
		str(event_info.get("title", "")),
		str(event_info.get("has_choice", false)),
		str(event_info.get("error", ""))
	])
	if not event_info.get("ok", false):
		push_error("[smoke] events_for_pile failed: %s" % str(event_info.get("error", "")))
		ok = false

	# 3. 取选项 (仅在 has_choice=true 时有效, location_select 阶段无选项点)
	if event_info.get("has_choice", false):
		var options: Array = ds.options_for_event()
		print("[smoke] options_for_event → count=%d" % options.size())
		for opt in options:
			var opt_d: Dictionary = opt
			var ot_int: int = int(opt_d.get("opt_type", 0))
			var ot_label := "CHECK" if ot_int == EngineDataSourceScn.OptType.CHECK else "DIRECT"
			print("  - %s | opt_type=%s | whitelist=%s | threshold=%d | text=%s" % [
				str(opt_d.get("id", "")),
				ot_label,
				str(opt_d.get("whitelist", [])),
				int(opt_d.get("threshold", 0)),
				str(opt_d.get("text", ""))
			])

	# 4. MarkerCheckResolver 调用形状 (无投入 / 标称难度 / 超额各一)
	var tier_zero := ds.tier_from_invest(EngineDataSourceScn.OptType.CHECK, 0, 3)
	var tier_at_d := ds.tier_from_invest(EngineDataSourceScn.OptType.CHECK, 2, 3)
	var tier_excess := ds.tier_from_invest(EngineDataSourceScn.OptType.CHECK, 5, 3)
	var tier_direct := ds.tier_from_invest(EngineDataSourceScn.OptType.DIRECT, 0, 3)
	print("[smoke] tier_from_invest: zero=%s, at_d-1=%s, excess=%s, direct=%s" % [
		tier_zero, tier_at_d, tier_excess, tier_direct
	])
	if tier_at_d != "success":
		push_error("[smoke] tier @ D-1 应必然成功 (S8.0 决议)")
		ok = false
	if tier_direct != "success":
		push_error("[smoke] DIRECT 选项 tier 应恒为 success")
		ok = false

	# 5. tier_label
	var label := ds.tier_label("great_success")
	print("[smoke] tier_label(great_success) = %s" % label)
	if label != "大成功":
		push_error("[smoke] tier_label 映射错")
		ok = false

	# 6. outcome_for_option — 端到端结算: 取第一个选项调结算, 验证账单形状 + forced_tier 桥接路径 +
	#    outcome drain 路径 + token diff 路径 (P3 修复, codex 审查建议)
	if event_info.get("has_choice", false):
		var options_for_settle: Array = ds.options_for_event()
		if not options_for_settle.is_empty():
			var first: Dictionary = options_for_settle[0]
			var first_id := str(first.get("id", ""))
			var bill: Dictionary = ds.outcome_for_option(first_id, "success")
			print("[smoke] outcome_for_option(%s, success) → tier=%s, markers=%d, exp_deltas=%d, flags=%d" % [
				first_id, str(bill.get("tier", "")),
				(bill.get("markers", []) as Array).size(),
				(bill.get("exp_deltas", []) as Array).size(),
				(bill.get("flags", []) as Array).size(),
			])
			# 账单形状校验 (与 [[卡牌前端交互设计]] §3.2 stub 对齐)
			for key in ["tier", "markers", "exp_deltas", "flags"]:
				if not bill.has(key):
					push_error("[smoke] outcome bill 缺字段: %s" % key)
					ok = false
			if str(bill.get("tier", "")) != "success":
				push_error("[smoke] outcome bill tier 不匹配预期 success")
				ok = false

	print("=== EngineDataSource S8.2 冒烟 %s ===" % ("通过" if ok else "失败"))
	quit(0 if ok else 1)
