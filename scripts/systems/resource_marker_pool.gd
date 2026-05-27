extends RefCounted
class_name ResourceMarkerPool

# ResourceMarkerPool — 资源标记池管理器
#
# Line B S2 落地（2026-05-27, 详见 [[前端骨架_LineB_实施]] §3.5-§3.9）
#
# 职责:
# - 管理「卡(种类) + 标记数(数量)」双值模型的标记产出/消费/查询。
# - 标记 count 存于 RoleState.resources[*_token / xinxing_token / social_token / gold]。
# - 标记 capacity 来源:
#     能力 (physique/craft/insight) → RoleState.attributes 对应 key 的品质阶段
#     心性 (xinxing_token)           → 固定 3 (MVP 1 期)
#     人际 (social_token)            → RoleState.attributes["social"] 品质阶段
#     金钱 (gold)                    → 无上限 (capacity = -1)
# - 满容量行为: 丢弃多余 (Line B S1 期主对话决议, 与 §7.2 资源稀缺哲学一致)
#
# 与 RoleState 解耦: 本类不持有 RoleState 引用, 调用方传入。S2 期主要被
# world_event_config_assembler 的 outcome 应用路径调用; 前端 mock_data 也可
# 直接借此模块产出 §3.2 stub 形状账单 (S8 期接通真数据)。
#
# 不做 (留增强切片):
# - 经验值升阶触发 (S4 期 ability_progression.csv 接 callback)
# - 心性档位 switch / 孤注一掷 (S5 期)
# - NPC 卡分配 / social_token 方向状态 (S6 期)

# ============================================================
# 资源类型规则常量
# ============================================================

# 能力线 → 标记 key 映射 (capacity 来自 attribute 同名 key 的品质阶段)
const ABILITY_TOKEN_KEYS := {
	"physique": "physique_token",
	"craft": "craft_token",
	"insight": "insight_token",
}

# 心性标记池: MVP 1 期容量写死 3
const XINXING_TOKEN_KEY := "xinxing_token"
const XINXING_CAPACITY := 3

# 人际标记池: capacity 由 social 品质阶段决定
const SOCIAL_TOKEN_KEY := "social_token"
const SOCIAL_ATTRIBUTE_KEY := "social"

# 金钱: 数字型, 无上限
const GOLD_KEY := "gold"
const GOLD_NO_CAP := -1  # 哨兵值: capacity=-1 视为无上限

# 五类资源可接收的所有 token key (用于校验 / iteration)
const ALL_TOKEN_KEYS := [
	"physique_token", "craft_token", "insight_token",
	"xinxing_token", "social_token", "gold",
]

# ============================================================
# 查询接口
# ============================================================

# 功能: 查询某资源标记池的当前 count 与 capacity。
# 参数:
#   role_state — 玩家 RoleState (resources / attributes 读取源)
#   token_key  — 标记 key (见 ALL_TOKEN_KEYS)
# 返回: { count: int, capacity: int }
#   capacity = GOLD_NO_CAP (-1) 表示无上限。
#   未知 token_key 返回 { count: 0, capacity: 0 } (相当于满容量, produce 丢弃)。
static func query(role_state: RoleState, token_key: String) -> Dictionary:
	if role_state == null:
		return {"count": 0, "capacity": 0}
	var count := role_state.get_resource(token_key, 0)
	var capacity := get_capacity(role_state, token_key)
	return {"count": count, "capacity": capacity}


# 功能: 获取某资源标记池的容量上限。
# 规则: 能力 token → attribute 同名品质阶段; xinxing_token → 固定 3;
#       social_token → attribute "social" 品质阶段; gold → -1 (无上限)。
static func get_capacity(role_state: RoleState, token_key: String) -> int:
	if role_state == null:
		return 0
	# 能力线: capacity = attribute 同名 key (如 physique_token → attributes["physique"])
	for ability_key in ABILITY_TOKEN_KEYS.keys():
		if ABILITY_TOKEN_KEYS[ability_key] == token_key:
			return role_state.get_attribute(ability_key, 1)  # 默认初始品质阶段 1
	# 心性
	if token_key == XINXING_TOKEN_KEY:
		return XINXING_CAPACITY
	# 人际
	if token_key == SOCIAL_TOKEN_KEY:
		return role_state.get_attribute(SOCIAL_ATTRIBUTE_KEY, 1)  # social 阶段决定
	# 金钱
	if token_key == GOLD_KEY:
		return GOLD_NO_CAP
	# 未知 key → 视为 0 (满容量, produce 丢弃)
	return 0


# ============================================================
# 产出 / 消费接口
# ============================================================

# 功能: 给某资源标记池产出 N 个标记 (gain)。
# 规则: 满容量丢弃多余 (Line B S1 期决议); 返回实际产出量。
# 参数:
#   role_state — 玩家 RoleState (写入 resources)
#   token_key  — 标记 key
#   amount     — 产出数量 (正整数, 调用方保证)
# 返回: 实际产出量 (0 ~ amount, 受 capacity 约束)
static func produce(role_state: RoleState, token_key: String, amount: int) -> int:
	if role_state == null or amount <= 0:
		return 0
	if not ALL_TOKEN_KEYS.has(token_key):
		# 未知 key: 不产出, 不报错 (上层 csv_validator 已挡; 这里 silent)
		return 0
	var current := role_state.get_resource(token_key, 0)
	var capacity := get_capacity(role_state, token_key)
	# 金钱无上限: 直接累加
	if capacity == GOLD_NO_CAP:
		role_state.set_resource(token_key, current + amount)
		return amount
	# 满容量丢弃多余
	# 说明：min/max 返回 Variant，按项目规范用显式类型声明。
	var space: int = max(0, capacity - current)
	var actual: int = min(amount, space)
	if actual > 0:
		role_state.set_resource(token_key, current + actual)
	return actual


# 功能: 从某资源标记池消费 N 个标记 (loss/投入)。
# 返回: 是否消费成功 (count >= amount); 不足时不消费 (原子性) 并返回 false。
# 注意: 金钱可以消费到 0 (gold 不允许负数, 同 vibe-test 规范); 不足返回 false。
static func consume(role_state: RoleState, token_key: String, amount: int) -> bool:
	if role_state == null or amount <= 0:
		return false
	if not ALL_TOKEN_KEYS.has(token_key):
		return false
	var current := role_state.get_resource(token_key, 0)
	if current < amount:
		return false
	role_state.set_resource(token_key, current - amount)
	return true


# 功能: 强制设置某资源标记池的 count (用于自省回流 / 调试 / 存档还原)。
# 规则: 自动 clamp 到 [0, capacity] (gold 无上限时只 clamp 下界)。
# 返回: 实际写入值。
static func set_count(role_state: RoleState, token_key: String, value: int) -> int:
	if role_state == null:
		return 0
	var capacity := get_capacity(role_state, token_key)
	# 说明：max/min 返回 Variant，按项目规范用显式类型声明。
	var clamped: int = max(0, value)
	if capacity != GOLD_NO_CAP:
		clamped = min(clamped, capacity)
	role_state.set_resource(token_key, clamped)
	return clamped


# ============================================================
# 自省回流接口
# ============================================================

# 功能: 自省阶段重置某资源标记池 (基础版, S2 期 / 详细规则随 §7.3 调)。
# 规则:
#   能力 token (physique_token/craft_token/insight_token) → 全回流到 capacity
#   xinxing_token → +1 (不超 capacity)
#   social_token  → 不全回 (规则细化留 S6 期; S2 期暂不变动)
#   gold          → 不重置
#   未知 key      → 不操作
# 返回: 重置后的 count (未操作时返回当前 count, 含 social_token / gold 等)
static func reset(role_state: RoleState, token_key: String) -> int:
	if role_state == null:
		return 0
	# 能力线: 全回流到 capacity
	for ability_key in ABILITY_TOKEN_KEYS.keys():
		if ABILITY_TOKEN_KEYS[ability_key] == token_key:
			var cap := get_capacity(role_state, token_key)
			role_state.set_resource(token_key, cap)
			return cap
	# 心性: +1 不超 capacity
	if token_key == XINXING_TOKEN_KEY:
		var current := role_state.get_resource(token_key, 0)
		var cap2 := get_capacity(role_state, token_key)
		var new_count: int = min(current + 1, cap2)
		role_state.set_resource(token_key, new_count)
		return new_count
	# social_token / gold / 未知: 不动 (规则后置)
	return role_state.get_resource(token_key, 0)


# 功能: 自省全量重置 (扫所有 ABILITY_TOKEN_KEYS + xinxing_token)。
# S2 期被引擎自省流程调用 (具体 hook 点在 S2.5 任务接入)。
static func reset_all_for_reflection(role_state: RoleState) -> void:
	if role_state == null:
		return
	for ability_key in ABILITY_TOKEN_KEYS.keys():
		var tk: String = ABILITY_TOKEN_KEYS[ability_key]
		reset(role_state, tk)
	reset(role_state, XINXING_TOKEN_KEY)
	# social_token / gold 不在自省重置范围 (S2 期; S6 期接 social 自省半回规则)


# ============================================================
# §3.2 stub 账单工具 (S2.4 任务: 给定 outcome delta 列表, 输出账单形状)
# ============================================================

# 功能: 按 outcome 应用结果生成 §3.2 stub 形状账单。
# 输入: deltas = [{token_key, amount}] (amount 正=gain 负=loss);
#       tier   = "great_success" | "success" | "fail" | "great_fail"
#       flags  = [String]
# 输出: { markers: [...], tier, exp_deltas: [], flags } 形状对齐
#       [[卡牌前端交互设计]] §3.2 stub。S2 期 markers.kind 一律 "entity"。
#       未来 S4 期 exp_deltas 由经验升阶模块填充, growth marker 由对应 outcome 元数据决定。
static func build_outcome_bill(deltas: Array, tier: String, flags: Array) -> Dictionary:
	var markers: Array = []
	for delta in deltas:
		if not (delta is Dictionary):
			continue
		var token_key := str(delta.get("token_key", ""))
		var amount := int(delta.get("amount", 0))
		if amount == 0 or token_key.is_empty():
			continue
		# 派生 §3.2 stub 中的 type 字段 (去 _token 后缀, 给前端展示用)
		var marker_type := token_key.replace("_token", "")
		markers.append({
			"type": marker_type,
			"count": abs(amount),
			"dir": "gain" if amount > 0 else "loss",
			"kind": "entity",  # S2 期硬编码; S4 期出现 growth 时再扩
		})
	return {
		"markers": markers,
		"tier": tier,
		"exp_deltas": [],   # S4 期填
		"flags": flags.duplicate(),
	}
