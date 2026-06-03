extends SceneTree

# E0 第三块冒烟脚本: 验证 CardRegistry 前端镜像 + 与 CardZoneStore 共享 CardData 引用联动。
# 覆盖 [[完整事件流程_实施]] §五 场景 0 的可自动化部分(实例身份 / 视图绑定 / Zone 转移同步);
# "Line A 回修"(地点/牌库/资源卡 app 显示与交互)属 GUI 路径, 由真实 app 验证。
# 用法: powershell.exe tools/run_godot.ps1 --headless --script tools/smoke_card_registry.gd
# 退出码 0=全过, 1=有失败。

const StoreScn := preload("res://scripts/systems/card_zone_store.gd")
const RegistryScn := preload("res://scripts/ui/card_registry.gd")
const CardScn := preload("res://scripts/ui/card.gd")

var _n: int = 0
var _ok: bool = true


# 断言工具: 计数 + 打印
func _check(cond: bool, label: String) -> void:
	_n += 1
	if cond:
		print("  [PASS] ", label)
	else:
		_ok = false
		print("  [FAIL] ", label)


# spawn 模拟(同 card_table._spawn_card 的数据路径, 去掉视觉/入树): store 分配 → Card 持 model → 注册
func _spawn(store, registry, logical_id: String, kind: int, zone: String) -> Object:
	var data: Object = store.create_card(logical_id, kind, {}, zone)
	var c: Object = CardScn.new()
	c.model = data
	registry.register(c)
	return c


func _init() -> void:
	print("=== CardRegistry E0 冒烟 开始 ===")
	var EK: int = CardScn.CardType.EVENT
	var store: Object = StoreScn.new()
	var registry: Object = RegistryScn.new()
	store.register_zone("chain")
	store.register_zone("discard")

	# 1) 实例身份: 同一 logical_id 两张卡各持不同 uid, registry 按 uid 唯一定位
	var a: Object = _spawn(store, registry, "evt_train", EK, "chain")
	var b: Object = _spawn(store, registry, "evt_train", EK, "chain")
	var uid_a: String = a.model.card_uid
	var uid_b: String = b.model.card_uid
	_check(uid_a != uid_b, "同名多实例 uid 互异 (%s vs %s)" % [uid_a, uid_b])
	_check(registry.get_node_by_uid(uid_a) == a, "registry 按 uid_a 定位到 A")
	_check(registry.get_node_by_uid(uid_b) == b, "registry 按 uid_b 定位到 B")
	_check(registry.count() == 2, "在册节点数 = 2")

	# 2) 视图绑定: Card 节点可反查 model(身份不靠闭包)
	_check(a.model != null and a.model.logical_id == "evt_train", "A 反查 model.logical_id")
	_check(registry.nodes_by_logical("evt_train").size() == 2, "按 logical_id 查得 2 张在场节点")

	# 3) Zone 转移同步: move_card 后 store 成员表 + registry(经共享 model 引用)一致
	store.move_card(uid_a, "discard")
	_check(store.cards_in_zone("discard").has(uid_a), "store: A 已入 discard")
	_check(not store.cards_in_zone("chain").has(uid_a), "store: A 已离 chain")
	_check(a.model.zone_id == "discard", "共享引用: A.model.zone_id 同步为 discard")
	var in_discard: Array = registry.nodes_by_zone("discard")
	var in_chain: Array = registry.nodes_by_zone("chain")
	_check(in_discard.size() == 1 and in_discard[0] == a, "registry: discard 仅含 A")
	_check(in_chain.size() == 1 and in_chain[0] == b, "registry: chain 仅含 B")

	# 4) despawn 注销: unregister 后镜像移除(store 数据仍可留档, 此处不验)
	registry.unregister(a)
	_check(not registry.has_uid(uid_a), "unregister 后 uid_a 不在册")
	_check(registry.count() == 1, "注销后在册节点数 = 1")
	_check(registry.get_node_by_uid(uid_a) == null, "已注销 uid 查询返回 null")

	# 清理(未入树的 Card 节点手动释放)
	a.free()
	b.free()

	print("=== 结束: %d 项, %s ===" % [_n, "全过" if _ok else "有失败"])
	quit(0 if _ok else 1)
