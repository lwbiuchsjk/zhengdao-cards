extends RefCounted
class_name CardRegistry

## 前端镜像注册表(E0 卡牌实体地基 · 第三块)
##
## 详见 [[完整事件流程_实施]] §四 E0。职责: 把**在场的视觉 Card 节点**按其数据身份
## (`model: CardData`)索引,作为 `CardZoneStore` 权威态的前端镜像 —— 给定 uid / logical_id /
## kind / zone / tag,反查对应的**在场节点**(而 store 反查的是数据 CardData)。
##
## 真源 / 镜像分工:
## - `CardZoneStore` 持数据真源(uid→CardData、Zone 成员、转移规则);
## - `CardRegistry` 持"哪个 uid 对应哪个**在场 Card 节点**"。
## - 二者通过**共享同一 CardData 引用**联动: spawn 时 `store.create_card` 产出的 CardData
##   被同时塞进 `Card.model` 与 `store._cards`,故 `move_card` 改写 `zone_id` 后,registry
##   经 `card.model.zone_id` 立即可见 —— **E0 阶段无需显式订阅 store 变更**。
## - (E1 引擎接入后 world_state 转为序列化态、不再共享引用,届时本注册表改为订阅
##   world_state 变更同步;接口形状不变,见 §四 E0 对 E1 的影响。)
##
## 最小实现: 主索引 `_by_uid`;logical_id / kind / zone / tag 查询遍历主表
## (在场卡数量少,无需维护反向表)。

# 弱类型 preload(不依赖 Card 全局 class_name 缓存,与 card_table 同风格): 仅用于 is 判定。
const CardScn := preload("res://scripts/ui/card.gd")

var _by_uid: Dictionary = {}   # uid(String) -> Card 节点


# ============================================================
# 登记 / 注销(spawn / despawn 钩子)
# ============================================================

## 登记一张在场卡(须已持有效 model + uid;否则拒绝并告警)。
func register(card: Node) -> void:
	if card == null:
		push_error("[CardRegistry] register: card 为 null")
		return
	var model: CardData = card.get("model")
	if model == null or model.card_uid.is_empty():
		push_error("[CardRegistry] register: card 无有效 model / uid")
		return
	_by_uid[model.card_uid] = card


## 注销一张卡(despawn 时调用;未登记 / 无 model 静默)。
func unregister(card: Node) -> void:
	if card == null:
		return
	var model: CardData = card.get("model")
	if model == null:
		return
	_by_uid.erase(model.card_uid)


# ============================================================
# 查询(返回在场 Card 节点)
# ============================================================

## 按 uid 取在场节点(不存在 / 已失效返回 null)。
func get_node_by_uid(uid: String) -> Node:
	var card: Node = _by_uid.get(uid, null)
	return card if is_instance_valid(card) else null


## uid 是否在册。
func has_uid(uid: String) -> bool:
	return _by_uid.has(uid)


## 按 logical_id 取在场节点列表(如多张同名卡)。
func nodes_by_logical(logical_id: String) -> Array:
	return _filter(func(m: CardData) -> bool: return m.logical_id == logical_id)


## 按 kind(CardData.CardKind / Card.CardType 同序)取在场节点列表。
func nodes_by_kind(kind: int) -> Array:
	return _filter(func(m: CardData) -> bool: return m.card_kind == kind)


## 按所属 Zone 取在场节点列表(zone_id 经共享 CardData 引用与 store 同步)。
func nodes_by_zone(zone_id: String) -> Array:
	return _filter(func(m: CardData) -> bool: return m.zone_id == zone_id)


## 按标签取在场节点列表。
func nodes_by_tag(tag: String) -> Array:
	return _filter(func(m: CardData) -> bool: return m.has_tag(tag))


## 全部在场节点(副本)。
func all_nodes() -> Array:
	var out: Array = []
	for uid in _by_uid:
		var card: Node = _by_uid[uid]
		if is_instance_valid(card):
			out.append(card)
	return out


## 在册节点数。
func count() -> int:
	return _by_uid.size()


## 清空注册表(不回收节点,仅解除镜像;节点回收由调用方负责)。
func clear() -> void:
	_by_uid.clear()


# ============================================================
# 内部工具
# ============================================================

## 按 model 谓词过滤在场节点(失效节点跳过)。
func _filter(pred: Callable) -> Array:
	var out: Array = []
	for uid in _by_uid:
		var card: Node = _by_uid[uid]
		if not is_instance_valid(card):
			continue
		var model: CardData = card.get("model")
		if model != null and pred.call(model):
			out.append(card)
	return out
