extends RefCounted
class_name CardData

## 卡牌实例数据模型(E0 卡牌实体地基 · 三原语之一、二)
##
## 详见 [[完整事件流程_实施]] §四 E0。本类是"卡牌即数据实体"的基石:
## 一张卡牌(视觉 Card 节点)恒绑定一个 CardData 实例,持有其**稳定身份**与**实例状态**。
##
## 三原语在本类的落点:
## - 原语①「稳定实例身份」: `card_uid` —— 全局唯一、跨流程稳定。同一 `logical_id`
##   的多张卡(如 3 张【练场训练】)各持不同 `card_uid`,故可逐张区分与寻址。
## - 原语②「实例状态 = def_ref + modifiers」: `_def_ref` 是对**静态定义(共享)** 的引用
##   (不拷贝整 def);`_modifiers` 是叠加层。"只强化某张卡" = 给该 uid 挂修饰,
##   不动 def、不影响同名其他实例。**MVP 阶段 modifiers 恒为空**(只建形状,
##   结算集成延后,见 §六边界)。
## - 原语③「Zone」: `zone_id` 记录该卡当前所属区域。区域**转移**由注册表 / world_state
##   的 move 流程驱动(本类只持有字段 + setter,不自行决定转移规则)。
##
## 真源约定: 卡实例的权威态在 `world_state`(引擎权威),前端 CardRegistry 做镜像。
## 本模型可序列化(to_dict/from_dict)以入 world_state;`_def_ref` 不入序列化
## (静态 def 属共享数据,按 `logical_id` 在加载后由注册表重新挂接,避免每实例冗余拷贝)。

# 卡牌逻辑类别(规范枚举)。与视图层 Card.CardType 取值对齐,视图由本枚举派生。
enum CardKind { EVENT, OPTION, RESULT, RESOURCE, LOCATION, DECK, LEAVE, CONTINUE }

# ---- 原语①: 稳定实例身份 ----
var card_uid: String = ""          # 全局唯一实例 id(由注册表 / world_state 工厂分配,本类不自生成)
var logical_id: String = ""        # 逻辑定义 id(映射引擎 event_id / option_id / 资源 key 等)
var card_kind: int = CardKind.EVENT

# ---- 原语②: 实例状态 = def_ref + modifiers ----
# 静态定义引用(共享,不拷贝)。GDScript Dictionary 为引用类型,多实例共享同一 def 字典。
var _def_ref: Dictionary = {}
# 修饰叠加层。每项为 { type, ... } 的 Dictionary。MVP 恒空(结算集成延后)。
var _modifiers: Array = []

# ---- 检索 / 分类辅助 ----
var tags: Array = []               # 标签(为将来检索 / 教育类玩法预留)

# ---- 原语③: Zone 所属 ----
var zone_id: String = ""           # 当前所属区域 id(转移由 move 流程驱动)


# ============================================================
# 构造 / 序列化
# ============================================================

## 工厂: 构造一个卡实例。`def_ref` 传入静态 def 的**共享引用**(勿在外部 duplicate)。
## tags 缺省时尝试从 def_ref.tags 取(若有)。
static func make(uid: String, p_logical_id: String, kind: int, def_ref: Dictionary = {}, p_zone_id: String = "", p_tags: Array = []) -> CardData:
	var inst := CardData.new()
	inst.card_uid = uid
	inst.logical_id = p_logical_id
	inst.card_kind = kind
	inst._def_ref = def_ref
	inst.zone_id = p_zone_id
	if not p_tags.is_empty():
		inst.tags = p_tags.duplicate()
	else:
		var def_tags: Variant = def_ref.get("tags", null)
		if def_tags is Array:
			inst.tags = (def_tags as Array).duplicate()
	return inst


## 导出为可序列化 Dictionary(入 world_state 用)。
## 注意: **不含 `_def_ref` 内容** —— 静态 def 共享,按 logical_id 加载后重挂(见 from_dict / link_def)。
func to_dict() -> Dictionary:
	return {
		"card_uid": card_uid,
		"logical_id": logical_id,
		"card_kind": card_kind,
		"modifiers": _modifiers.duplicate(true),
		"tags": tags.duplicate(),
		"zone_id": zone_id,
	}


## 从 Dictionary 恢复实例。`_def_ref` 留空,由调用方(注册表)随后 link_def() 按 logical_id 重挂。
static func from_dict(data: Dictionary) -> CardData:
	var inst := CardData.new()
	inst.card_uid = str(data.get("card_uid", ""))
	inst.logical_id = str(data.get("logical_id", ""))
	inst.card_kind = int(data.get("card_kind", CardKind.EVENT))
	var mods: Variant = data.get("modifiers", [])
	inst._modifiers = (mods as Array).duplicate(true) if mods is Array else []
	var t: Variant = data.get("tags", [])
	inst.tags = (t as Array).duplicate() if t is Array else []
	inst.zone_id = str(data.get("zone_id", ""))
	return inst


# ============================================================
# 原语②: def 引用 + 修饰叠加
# ============================================================

## 重新挂接静态 def 共享引用(加载 / 反序列化后由注册表调用)。
func link_def(def_ref: Dictionary) -> void:
	_def_ref = def_ref


## 取静态 def(共享引用,只读勿改)。
func get_def() -> Dictionary:
	return _def_ref


## 取**生效定义** = 静态 def 叠加 modifiers 后的结果。
## MVP: modifiers 恒空 → 直接返回 def 共享引用(零拷贝)。
## 延后(后续切片): modifiers 非空时在此叠加(+/替换/条件),并返回叠加后的新字典,
##   不污染共享 _def_ref。结算集成见 [[完整事件流程_实施]] §六边界。
func effective_def() -> Dictionary:
	if _modifiers.is_empty():
		return _def_ref
	# —— 修饰叠加占位: 后续切片实现具体叠加规则,此处暂返回 def 副本以示"应在此叠加" ——
	push_warning("[CardData] modifiers 叠加结算尚未实现(E0 仅建形状),uid=%s" % card_uid)
	return _def_ref.duplicate(true)


## 追加一个修饰(后续切片用;MVP 不调用)。
func add_modifier(modifier: Dictionary) -> void:
	_modifiers.append(modifier)


## 当前修饰列表(只读副本)。
func get_modifiers() -> Array:
	return _modifiers.duplicate(true)


## 是否挂有修饰。
func has_modifiers() -> bool:
	return not _modifiers.is_empty()


## 清空全部修饰。
func clear_modifiers() -> void:
	_modifiers.clear()


# ============================================================
# 检索 / Zone 辅助
# ============================================================

## 是否含指定标签。
func has_tag(tag: String) -> bool:
	return tags.has(tag)


## 追加标签(去重)。
func add_tag(tag: String) -> void:
	if not tags.has(tag):
		tags.append(tag)


## 设置所属区域(仅写字段;转移规则 / 双向同步由 move 流程负责,勿绕过)。
func set_zone(p_zone_id: String) -> void:
	zone_id = p_zone_id


## 调试字符串。
func _to_string() -> String:
	return "[CardData uid=%s logical=%s kind=%d zone=%s mods=%d]" % [
		card_uid, logical_id, card_kind, zone_id, _modifiers.size()
	]
