extends RefCounted
class_name MockDataSource

# MockDataSource — Line A mock fallback (与 EngineDataSource 同形接口)
#
# Line B S8.3 落地 (2026-05-27, 详见 [[前端骨架_LineB_实施]] §S8)
#
# 职责: 当 card_table.USE_ENGINE=false 时承接前端调用, 走 Line A 原始 mock 路径,
# 不接 engine、不接 ConfigRuntime。供调试 / 回归测试 / 引擎链路异常时 fallback。
#
# 接口契约与 EngineDataSource 严格同形, 切换 _data_source 实例时 card_table 零修改。
# 内部:
# - events_for_pile / options_for_event 硬编码 Line A 原始数据（"山道遇雨" + 3 选项）
# - tier_from_invest 沿用 Line A 原 mock 公式 (_tier_from_invest)
# - outcome_for_option / tier_label 转调 MockData static (§3.2 stub 形状由 MockData 维护)

const MockDataScn := preload("res://scripts/ui/mock_data.gd")

# 选项类型枚举 — 与 EngineDataSource.OptType / MockData.OptType 严格一致。
enum OptType { CHECK, DIRECT }

# Mock 事件单例 — 仅一组数据循环抽。Line A 原始数据, 与本文件落地前 card_table 硬编码一致。
const MOCK_EVENT := {
	"event_id": "mock_evt_mountain_rain",
	"title": "山道遇雨",
	"body": "雨势渐大，前方有破庙可避。你会如何应对？",
}

const MOCK_OPTIONS := [
	{
		"id": "mock_opt_1",
		"text": "冒雨赶路",
		"opt_type_name": "DIRECT",
		"whitelist": [],
		"threshold": 0,
	},
	{
		"id": "mock_opt_2",
		"text": "破庙暂避",
		"opt_type_name": "CHECK",
		"whitelist": ["physique", "xinxing"],
		"threshold": 3,
	},
	{
		"id": "mock_opt_3",
		"text": "寻人引路",
		"opt_type_name": "CHECK",
		"whitelist": ["insight", "social"],
		"threshold": 2,
	},
]

# ============================================================
# 对外接口 (与 EngineDataSource 同形)
# ============================================================

# 功能: 抽下一个事件 (mock 路径恒返回同一事件)。
func events_for_pile() -> Dictionary:
	return {
		"ok": true,
		"event_id": MOCK_EVENT["event_id"],
		"title": MOCK_EVENT["title"],
		"body": MOCK_EVENT["body"],
		"has_choice": true,
		"choice_point_id": "mock_cp",
	}


# 功能: 取当前事件的选项 (mock 路径恒返回 3 个固定选项)。
func options_for_event() -> Array:
	var out: Array = []
	for opt_v in MOCK_OPTIONS:
		var opt: Dictionary = opt_v
		out.append({
			"id": str(opt["id"]),
			"text": str(opt["text"]),
			"opt_type": _name_to_opt_type(str(opt["opt_type_name"])),
			"whitelist": (opt["whitelist"] as Array).duplicate(),
			"threshold": int(opt["threshold"]),
		})
	return out


# 功能: 标记投入 → tier 决策 (Line A 原 mock 公式, 不接 MarkerCheckResolver)。
# 与 EngineDataSource 不同, mock 路径 tier 由"投入数 vs 阈值"分段映射,
# 保留 Line A 原始行为作回归基线。
func tier_from_invest(opt_type: int, invested: int, threshold: int) -> String:
	if opt_type != OptType.CHECK:
		return "success"
	if threshold <= 0:
		return "success"
	if invested >= int(ceil(threshold * 1.5)):
		return "great_success"
	if invested >= threshold:
		return "success"
	if invested * 2 >= threshold:
		return "fail"
	return "great_fail"


# 功能: 按 tier 产 mock 账单 (option_id 参数被 mock 忽略, 只用 tier; 接口契约统一保留)。
func outcome_for_option(_option_id: String, tier: String) -> Dictionary:
	return MockDataScn.outcome_for(tier)


# 功能: 档位中文名 (转调 MockData.tier_label)
func tier_label(tier: String) -> String:
	return MockDataScn.tier_label(tier)


# ============================================================
# 内部工具
# ============================================================

func _name_to_opt_type(name: String) -> int:
	if name == "CHECK":
		return OptType.CHECK
	return OptType.DIRECT
