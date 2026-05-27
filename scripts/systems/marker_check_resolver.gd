extends RefCounted
class_name MarkerCheckResolver

# MarkerCheckResolver — 标记投入鉴定算法（独立支柱模块）
#
# Line B S8 期落地（2026-05-27, 详见 [[前端骨架_LineB_实施]] §3.6 标记投入鉴定算法）
#
# 设计内核（来自 [[前端表现卡牌化_MVP草案]] §3.4 鉴定形态 + §7.7 孤注一掷）:
# - 投入 < D-1: 始终有失败可能（基础送骰 1/D 保底）
# - 投入 = D-1: 必然成功（基础送骰填齐第 D 等效投入）
# - 投入 > D-1: 进入大成功提升区，线性加码
# - 投入达上限: 大成功封顶（再投入无收益，UI 应阻止）
# - great_fail 恒为 0: 由 §7.7 孤注一掷链路产出，常规鉴定不产
#
# 算式封装为独立模块的关键架构意义:
# 后续 playtest 调参 / 算法替换只改本文件，外部调用方（前端 mock_data /
# 引擎 outcome 应用）只调对外接口 distribution / resolve / get_invest_cap，
# 不接触算式内部细节。

# ============================================================
# 模块内部常量（封闭，调参改源码）
# ============================================================

# 每个超额标记带来的大成功率增量。
# 与 p_gs_max 共同决定 inv_max：inv_max = (D-1) + ceil(p_gs_max / STEP_PER_INV)。
# 0.10 = 5 步达到默认 0.50 封顶，进阶感清晰。
const STEP_PER_INV := 0.10

# 默认大成功封顶率（外部未传时使用）
const DEFAULT_P_GS_MAX := 0.50

# 四档 tier 常量（与 [[卡牌前端交互设计]] §3.2 stub 对齐）
const TIER_GREAT_SUCCESS := "great_success"
const TIER_SUCCESS := "success"
const TIER_FAIL := "fail"
const TIER_GREAT_FAIL := "great_fail"

# ============================================================
# 对外接口
# ============================================================

# 功能: 计算给定投入数和鉴定难度下的概率分布（纯函数，不掷骰）。
# 参数:
#   inv        — 投入标记数（≥0）
#   difficulty — 鉴定难度 D（≥1；≤0 视为 0 难度兜底）
#   p_gs_max   — 大成功封顶率（默认 0.5；外部可传入覆盖）
# 返回: { great_success: f, success: f, fail: f, great_fail: f }
#       概率和恒等于 1.0；great_fail 在常规鉴定路径恒为 0
static func distribution(inv: int, difficulty: int,
		p_gs_max: float = DEFAULT_P_GS_MAX) -> Dictionary:
	# D ≤ 0 兜底: 恒返回 success
	if difficulty <= 0:
		return {
			TIER_GREAT_SUCCESS: 0.0,
			TIER_SUCCESS: 1.0,
			TIER_FAIL: 0.0,
			TIER_GREAT_FAIL: 0.0,
		}

	# 超额标记数（基础送骰填齐第 D 等效投入后才有超额）
	var excess: int = max(0, inv - (difficulty - 1))

	if excess == 0:
		# inv ≤ D-1: 不足段（线性成功率）
		var r: float = float(inv + 1) / float(difficulty)
		# r 上限 = 1.0（excess == 0 → inv ≤ D-1 → r ≤ 1）
		return {
			TIER_GREAT_SUCCESS: 0.0,
			TIER_SUCCESS: r,
			TIER_FAIL: 1.0 - r,
			TIER_GREAT_FAIL: 0.0,
		}

	# excess > 0: 超额段（大成功率随超额线性提升至封顶）
	var p_gs: float = min(p_gs_max, STEP_PER_INV * float(excess))
	return {
		TIER_GREAT_SUCCESS: p_gs,
		TIER_SUCCESS: 1.0 - p_gs,
		TIER_FAIL: 0.0,
		TIER_GREAT_FAIL: 0.0,
	}


# 功能: 按分布掷骰得 tier。
# 参数:
#   inv / difficulty / p_gs_max — 同 distribution
#   rng — 可选；为 null 时使用全局 randf。传入便于测试复现。
# 返回: "great_success" | "success" | "fail" | "great_fail"
static func resolve(inv: int, difficulty: int,
		p_gs_max: float = DEFAULT_P_GS_MAX,
		rng: RandomNumberGenerator = null) -> String:
	var dist: Dictionary = distribution(inv, difficulty, p_gs_max)
	var roll: float
	if rng != null:
		roll = rng.randf()
	else:
		roll = randf()

	# 按固定顺序累积（避免遍历 Dictionary 顺序不稳）
	var acc: float = 0.0
	for tier in [TIER_GREAT_SUCCESS, TIER_SUCCESS, TIER_FAIL, TIER_GREAT_FAIL]:
		acc += float(dist.get(tier, 0.0))
		if roll < acc:
			return str(tier)
	# 数值兜底（浮点累积误差）
	return TIER_SUCCESS


# 功能: UI 投入上限建议（再多投入无收益）。
# 派生公式: inv_max = (D - 1) + ceil(p_gs_max / STEP_PER_INV)
# 配置 p_gs_max 改变 → inv_max 自动变化（用户决议 2026-05-27）。
static func get_invest_cap(difficulty: int,
		p_gs_max: float = DEFAULT_P_GS_MAX) -> int:
	if difficulty <= 0:
		return 0
	# ceil(p_gs_max / STEP_PER_INV) 用整数运算: 上取整
	var step_count: int = int(ceil(p_gs_max / STEP_PER_INV))
	return (difficulty - 1) + step_count
