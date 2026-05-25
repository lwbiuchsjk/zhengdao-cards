class_name MockData
extends RefCounted
## Line A mock 数据(对 [[卡牌前端交互设计]] §3.2 stub) —— Line B 引擎扩展完成后, 由真实
## marker 账单替代; 本模块只负责让前端循环跑通, 不含任何引擎逻辑。
##
## §3.2 stub 形状:
##   { markers:[{type,count,dir,kind}], tier, exp_deltas:[{line,amount}], flags:[...] }

# 选项二分(§7.1-A.4 / §2.5): 鉴定型(走聚焦+投入) / 直接型(无押注, 直接揭示)
enum OptType { CHECK, DIRECT }

## 单条 marker(§3.2): 资源类型 / 数量 / 方向 / 类别(实体 entity·成长 growth)
static func _m(type: String, count: int, dir: String, kind: String) -> Dictionary:
	return {"type": type, "count": count, "dir": dir, "kind": kind}

## 按档位产出 mock 结果账单(§3.2 stub 形状)。
## 保底: 每档恒有产出(§7.3 失败保底), 故无空结果态。
static func outcome_for(tier: String) -> Dictionary:
	var out: Dictionary = {"tier": tier, "markers": [], "exp_deltas": [], "flags": []}
	match tier:
		"great_success":
			out["markers"] = [_m("physique", 2, "gain", "entity"), _m("insight", 1, "gain", "entity")]
			out["exp_deltas"] = [{"line": "physique", "amount": 2}]
		"success":
			out["markers"] = [_m("craft", 1, "gain", "entity")]
			out["exp_deltas"] = [{"line": "craft", "amount": 1}]
		"fail":
			out["markers"] = [_m("insight", 1, "gain", "growth")]  # 失败也给成长(保底)
			out["exp_deltas"] = [{"line": "insight", "amount": 1}]
		"great_fail":
			out["markers"] = [_m("xinxing", 1, "loss", "entity")]  # 溢出净负
			out["exp_deltas"] = [{"line": "physique", "amount": 1}]  # 仍给基础经验
	return out

## 档位中文显式名(§3: 必须显式告知 tier)
static func tier_label(tier: String) -> String:
	match tier:
		"great_success": return "大成功"
		"success": return "小成功"
		"fail": return "失败"
		"great_fail": return "大失败"
	return tier
