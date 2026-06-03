extends RefCounted
class_name CardZoneStore

## 卡牌实例 + Zone 权威态(E0 卡牌实体地基 · 原语①③ 的真源)
##
## 详见 [[完整事件流程_实施]] §四 E0。本 store 是**卡实例与区域归属的唯一权威**:
## - 持有所有在册卡实例(uid → CardData);
## - 持有 Zone 模型(zone_id → {kind, members});
## - 保证不变量「**每张在册卡恒属恰一个 Zone**」,区域转移经 move_card 原子完成。
##
## 真源约定(§四 E0): 本 store 是真源,前端 CardRegistry 镜像之。E1 接入引擎时,
## 由引擎持有本 store、其 to_dict 入 world_state 持久化(uid 单调计数器一并序列化,
## 避免重载后 uid 冲突)。
##
## 最小实现纪律(§六边界): 只做"实例 + 区域 + 转移 + 查询"骨架;Zone 的**增益/转化/
## 入出堆触发**与 modifier 结算**延后**,本 store 不含。

const CardDataScn := preload("res://scripts/models/card_data.gd")

var _cards: Dictionary = {}     # uid(String) -> CardData
var _zones: Dictionary = {}     # zone_id(String) -> { "kind": String, "members": Array[String uid] }
var _uid_seq: int = 0           # 单调 uid 计数器(确定性、可序列化,不依赖 RNG)


# ============================================================
# Zone 管理
# ============================================================

## 登记一个 Zone(幂等)。kind 用于将来按区域类别赋予语义(增益/转化等,延后)。
func register_zone(zone_id: String, kind: String = "generic") -> void:
	if zone_id.is_empty():
		push_error("[CardZoneStore] register_zone: zone_id 不可空")
		return
	if not _zones.has(zone_id):
		_zones[zone_id] = {"kind": kind, "members": []}


## 是否已登记该 Zone。
func has_zone(zone_id: String) -> bool:
	return _zones.has(zone_id)


## 取 Zone 类别(未登记返回空串)。
func zone_kind(zone_id: String) -> String:
	var z: Dictionary = _zones.get(zone_id, {})
	return str(z.get("kind", ""))


## 取某 Zone 内全部卡 uid(副本)。
func cards_in_zone(zone_id: String) -> Array:
	var z: Dictionary = _zones.get(zone_id, {})
	var members: Array = z.get("members", [])
	return members.duplicate()


# ============================================================
# 卡实例生命周期(原语①: uid 分配)
# ============================================================

## 分配一个稳定唯一 uid(单调,确定性)。
func _alloc_uid() -> String:
	var uid := "c%d" % _uid_seq
	_uid_seq += 1
	return uid


## 新建一张卡实例并放入指定 Zone。
## def_ref 传静态 def 共享引用(勿 duplicate);zone_id 必填(维持"恒属一个 Zone"不变量,
## 未登记则自动登记为 generic)。返回新建的 CardData。
func create_card(logical_id: String, kind: int, def_ref: Dictionary = {}, zone_id: String = "", tags: Array = []) -> CardData:
	if zone_id.is_empty():
		push_error("[CardZoneStore] create_card: zone_id 必填(每卡恒属一个 Zone)")
		return null
	if not _zones.has(zone_id):
		register_zone(zone_id)
	var uid := _alloc_uid()
	var card: CardData = CardDataScn.make(uid, logical_id, kind, def_ref, zone_id, tags)
	_cards[uid] = card
	(_zones[zone_id]["members"] as Array).append(uid)
	return card


## 纳入一个已有 CardData(如反序列化后回填)。按其 zone_id 入对应 Zone 成员。
func add_existing(card: CardData) -> void:
	if card == null or card.card_uid.is_empty():
		push_error("[CardZoneStore] add_existing: 无效卡")
		return
	# P1-4: uid 已存在则先清其所有 Zone membership 再替换, 避免同 uid 残留多 Zone
	if _cards.has(card.card_uid):
		_erase_from_all_zones(card.card_uid)
	_cards[card.card_uid] = card
	# 防御: 外部 uid 可能撞未来 create_card 续号, 据此推高计数器
	var num := _uid_num_of(card.card_uid)
	if num >= _uid_seq:
		_uid_seq = num + 1
	var zid := card.zone_id
	if not zid.is_empty():
		if not _zones.has(zid):
			register_zone(zid)
		var members: Array = _zones[zid]["members"]
		if not members.has(card.card_uid):
			members.append(card.card_uid)


## 取卡实例(不存在返回 null)。
func get_card(uid: String) -> CardData:
	return _cards.get(uid, null)


## 是否在册。
func has_card(uid: String) -> bool:
	return _cards.has(uid)


## 区域转移(原子): 从原 Zone 成员移除 + 加入目标 Zone + 更新 card.zone_id。
## 维持不变量「卡恒属恰一个 Zone」。目标 Zone 未登记则自动登记。返回是否成功。
func move_card(uid: String, to_zone: String) -> bool:
	var card: CardData = _cards.get(uid, null)
	if card == null:
		push_warning("[CardZoneStore] move_card: 卡不存在 uid=%s" % uid)
		return false
	if to_zone.is_empty():
		push_warning("[CardZoneStore] move_card: to_zone 不可空")
		return false
	# P1-1: 同 Zone 移动幂等 — 直接返回, 不动成员顺序
	if card.zone_id == to_zone:
		return true
	if not _zones.has(to_zone):
		register_zone(to_zone)
	# 清除该 uid 在所有 Zone 的残留 membership(防御), 再加入目标 Zone
	_erase_from_all_zones(uid)
	(_zones[to_zone]["members"] as Array).append(uid)
	card.set_zone(to_zone)
	return true


## 彻底移除一张卡(从其 Zone + 在册表)。注: 弃/放逐应用 move_card 转移到对应 Zone,
## 仅在真正销毁实例时用本函数。
func remove_card(uid: String) -> bool:
	if not _cards.has(uid):
		return false
	# P2-1: 从所有 Zone 清扫该 uid(防御 stale/重复 membership), 再除在册表
	_erase_from_all_zones(uid)
	_cards.erase(uid)
	return true


# ============================================================
# 查询(检索类玩法地基)
# ============================================================

## 按 logical_id 查在册 uid 列表。
func find_by_logical(logical_id: String) -> Array:
	var out: Array = []
	for uid in _cards:
		var card: CardData = _cards[uid]
		if card.logical_id == logical_id:
			out.append(uid)
	return out


## 按标签查在册 uid 列表。
func find_by_tag(tag: String) -> Array:
	var out: Array = []
	for uid in _cards:
		var card: CardData = _cards[uid]
		if card.has_tag(tag):
			out.append(uid)
	return out


## 按类别查在册 uid 列表。
func find_by_kind(kind: int) -> Array:
	var out: Array = []
	for uid in _cards:
		var card: CardData = _cards[uid]
		if card.card_kind == kind:
			out.append(uid)
	return out


## 全部在册 uid。
func all_uids() -> Array:
	return _cards.keys()


## 在册卡总数。
func count() -> int:
	return _cards.size()


# ============================================================
# 内部工具
# ============================================================

## 从所有 Zone 的 members 清除该 uid(统一 membership 维护, 防御 stale/重复)。
func _erase_from_all_zones(uid: String) -> void:
	for zid in _zones:
		(_zones[zid]["members"] as Array).erase(uid)


## 解析 "cN" 形式 uid 的数值部分; 非该形式返回 -1(不参与续号下界计算)。
static func _uid_num_of(uid: String) -> int:
	if uid.begins_with("c") and uid.substr(1).is_valid_int():
		return uid.substr(1).to_int()
	return -1


# ============================================================
# 序列化(入 world_state 用)
# ============================================================

## 导出(含 uid 计数器,保证重载后续号不冲突)。卡的 def_ref 不入序列化(静态 def 共享,
## 重载后由调用方按 logical_id 重挂,见 relink_defs)。
func to_dict() -> Dictionary:
	var cards_out: Dictionary = {}
	for uid in _cards:
		var card: CardData = _cards[uid]
		cards_out[uid] = card.to_dict()
	return {
		"cards": cards_out,
		"zones": _zones.duplicate(true),
		"uid_seq": _uid_seq,
	}


## 从 Dictionary 恢复。卡的 _def_ref 留空,需随后 relink_defs 按 logical_id 重挂。
static func from_dict(data: Dictionary) -> CardZoneStore:
	var store := CardZoneStore.new()
	# P2-2: 类型安全 — 接 Variant 后判类型, 避免 null/非 Dict 运行时报错
	var zones_v: Variant = data.get("zones", {})
	var zones_in: Dictionary = zones_v if zones_v is Dictionary else {}
	var cards_v: Variant = data.get("cards", {})
	var cards_in: Dictionary = cards_v if cards_v is Dictionary else {}
	# 先恢复各 Zone 的 kind(members 留空, 稍后以 card.zone_id 权威重建 — P1-3)
	for zid in zones_in:
		var z_v: Variant = zones_in[zid]
		var z: Dictionary = z_v if z_v is Dictionary else {}
		store._zones[zid] = {"kind": str(z.get("kind", "generic")), "members": []}
	# 恢复 cards, 并以 card.zone_id 权威重建 members(保证"恰一个 Zone"不变量, 丢弃脏 members)
	var max_uid_num := -1
	for uid in cards_in:
		var cd_v: Variant = cards_in[uid]
		if not (cd_v is Dictionary):
			continue
		var card: CardData = CardDataScn.from_dict(cd_v)
		store._cards[card.card_uid] = card
		var zid := card.zone_id
		if not zid.is_empty():
			if not store._zones.has(zid):
				store.register_zone(zid)
			(store._zones[zid]["members"] as Array).append(card.card_uid)
		var num := _uid_num_of(card.card_uid)
		if num > max_uid_num:
			max_uid_num = num
	# P1-2: uid_seq 取 max(序列化值, 现有最大 uid + 1), 防重载后续号撞已存在 uid
	store._uid_seq = maxi(int(data.get("uid_seq", 0)), max_uid_num + 1)
	return store


## 反序列化后重挂静态 def: resolver 接收 logical_id 返回 def 共享引用。
func relink_defs(resolver: Callable) -> void:
	for uid in _cards:
		var card: CardData = _cards[uid]
		var def_ref: Dictionary = resolver.call(card.logical_id)
		card.link_def(def_ref)
