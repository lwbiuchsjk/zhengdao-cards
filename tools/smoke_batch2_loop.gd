extends SceneTree

# 批次二循环冒烟: 验证「继续 = 重对账 pack_window_for_pile」的三分支信号(适配器层)。
# 用法: powershell.exe tools/run_godot.ps1 --headless --script tools/smoke_batch2_loop.gd
# 跑完自动 quit (退出码 0=全过, 1=有失败)。
#
# 覆盖(对应 [[事件包交互流程_持久盘面与流程驱动_MVP]] §七 3-6 的引擎侧信号; 视觉行为属 GUI 验收):
#   - 普通容量内: 每次结算后 pack_window → mode=blind, handQueue 递减(回盘面信号)
#   - 玩满 C: pack_window → mode=single(skeleton), pick 后 has_choice=true(骨架登场信号)
#   - 包结束: 骨架结算后 pack_window → mode=single(sys_reflection), pick 后 has_choice=false +
#             0 选项(自省终点信号; 骨架/自省走同一 single 通道, has_choice 自然分流)
# card_table 编排(摊牌/向前补齐/继续卡/余牌消散)属 GUI 验收, headless 不验。

const EngineDataSrc := preload("res://scripts/ui/engine_data_source.gd")

var _n: int = 0
var _ok: bool = true


func _check(cond: bool, label: String) -> void:
	_n += 1
	print(("  [PASS] " if cond else "  [FAIL] ") + label)
	if not cond:
		_ok = false


func _pack_ctx(ds: Object) -> Dictionary:
	var ws: Dictionary = ds._engine.world_state
	var ctx: Variant = ws.get("packContext", {})
	return ctx if ctx is Dictionary else {}


# 走完一个事件的全流程(pick → 选项 → 结算), 返回 pick 的事件信息(含 has_choice)。
func _play_event(ds: Object, pick_uid: String) -> Dictionary:
	var ev: Dictionary = ds.pick_hand(pick_uid)
	if not ev.get("ok", false):
		return ev
	var opts: Array = ds.options_for_event()
	ev["_opt_count"] = opts.size()
	if opts.is_empty():
		return ev  # 0 选项 = 自省终点, 不结算
	var o0: Dictionary = opts[0]
	var tier: String = str(ds.tier_from_invest(int(o0.get("opt_type", 0)), 0, int(o0.get("threshold", 0))))
	ds.outcome_for_option(str(o0.get("id", "")), tier)
	return ev


func _init() -> void:
	print("=== 批次二循环冒烟 开始 ===")
	var ds: Object = EngineDataSrc.new(0)

	# ── 步 1: 开包 → blind ──
	var w1: Dictionary = ds.pack_window_for_pile()
	_check(str(w1.get("mode", "")) == "blind", "步1 开包 mode=blind (实 %s)" % str(w1.get("mode", "")))
	var k1: int = (w1.get("cards", []) as Array).size()
	_check(k1 >= 2, "步1 窗口 K>=2 (实 %d)" % k1)
	var cap: int = int(_pack_ctx(ds).get("turnCapacity", 3))
	_check(cap >= 2, "包容量 capacity>=2 (实 %d, C=%d 普通)" % [cap, cap - 1])
	var ev1: Dictionary = _play_event(ds, str((w1.get("cards", [])[0] as Dictionary).get("uid", "")))
	_check(ev1.get("ok", false), "步1 普通事件全流程 ok")

	# ── 步 2: 继续 → 仍普通容量 → blind, handQueue 递减 ──
	var w2: Dictionary = ds.pack_window_for_pile()
	_check(str(w2.get("mode", "")) == "blind", "步2 继续 mode=blind (回盘面信号; 实 %s)" % str(w2.get("mode", "")))
	var k2: int = (w2.get("cards", []) as Array).size()
	_check(k2 == k1 - 1, "步2 handQueue 递减 (%d → %d)" % [k1, k2])
	# 玩满 C: 默认 cap=3 → C=2, 本步是第 2 个普通事件; 玩完即达末位。
	var ev2: Dictionary = _play_event(ds, str((w2.get("cards", [])[0] as Dictionary).get("uid", "")))
	_check(ev2.get("ok", false), "步2 普通事件全流程 ok (玩满 C=%d)" % (cap - 1))

	# ── 步 3: 继续 → 玩满 C → single(骨架登场) ──
	var w3: Dictionary = ds.pack_window_for_pile()
	_check(str(w3.get("mode", "")) == "single", "步3 玩满 C → mode=single (骨架登场信号; 实 %s)" % str(w3.get("mode", "")))
	_check((w3.get("cards", []) as Array).size() == 1, "步3 single 窗口 1 张")
	var sk_eid: String = str((w3.get("cards", [])[0] as Dictionary).get("event_id", ""))
	var ev3: Dictionary = _play_event(ds, "")  # single 传空串走 stash
	_check(ev3.get("ok", false) and str(ev3.get("event_id", "")) == sk_eid, "步3 pick 出骨架事件 (%s)" % sk_eid)
	_check(bool(ev3.get("has_choice", false)) and int(ev3.get("_opt_count", 0)) > 0, "步3 骨架 has_choice + 有选项 (走事件流程, 非终点)")

	# ── 步 4: 骨架继续 → 包结束 → single(自省终点) ──
	var w4: Dictionary = ds.pack_window_for_pile()
	_check(str(w4.get("mode", "")) == "single", "步4 包结束 → mode=single (自省同通道; 实 %s)" % str(w4.get("mode", "")))
	var ev4: Dictionary = _play_event(ds, "")
	_check(ev4.get("ok", false), "步4 pick 自省事件 ok (event_id=%s)" % str(ev4.get("event_id", "")))
	_check(not bool(ev4.get("has_choice", true)), "步4 自省 has_choice=false")
	_check(int(ev4.get("_opt_count", -1)) == 0, "步4 自省 0 选项 = 自然终点 (实 %d)" % int(ev4.get("_opt_count", -1)))

	print("=== 结束: %d 项, %s ===" % [_n, "全过" if _ok else "有失败"])
	quit(0 if _ok else 1)
