extends RefCounted
class_name ConfigRuntime

# ConfigRuntime
# 职责：
# - 管理固定配置流程：加载 -> 校验 -> 缓存 -> 分发快照。
# - 对业务/测试脚本屏蔽 ConfigLoader 与文件 IO 细节。
# - 提供全局共享单例，贯穿应用生命周期。
const ConfigLoader := preload("res://scripts/systems/config_loader.gd")
const WorldEventConfigAssembler := preload("res://scripts/systems/world_event_config_assembler.gd")
const RoleState := preload("res://scripts/models/role_state.gd")
const LocationGraph := preload("res://scripts/models/location_graph.gd")
const AffinityMap := preload("res://scripts/models/affinity_map.gd")

# 默认配置路径；未传入覆盖参数时使用这些路径。
const DEFAULT_PATHS := {
	"roles": "res://scripts/config/roles.csv",
	"location_graph": "res://scripts/config/location_graph.csv",
	"affinity": "res://scripts/config/affinity.csv",
	"attribute_names": "res://scripts/config/attribute_names.csv",
	# S1 期占位：表结构 + .import 已建；S4 期接 loader 实现升阶机制（详见 [[前端骨架_LineB_实施]] §3.1）
	"ability_progression": "res://scripts/config/ability_progression.csv",
	"world_event_csv_dir": "res://scripts/config/world_event_mvp"
}

static var _shared_instance: ConfigRuntime

var _loaded := false
var _source_paths: Dictionary = {}
var _roles: Array = []
var _location_graph: LocationGraph
var _affinity_map: AffinityMap
var _world_event_data: Dictionary = {}

# 全局单例入口。业务代码应通过此方法获取实例，而不是直接 new()。
static func shared() -> ConfigRuntime:
	if _shared_instance == null:
		_shared_instance = ConfigRuntime.new()
	return _shared_instance

func is_loaded() -> bool:
	return _loaded

# 确保配置已完成加载并进入缓存。
# 可选参数 `paths` 可覆盖 DEFAULT_PATHS 中的路径键。
# `force_reload=true` 时会忽略已缓存内容，重新加载磁盘配置。
# 当解析后的路径与当前缓存一致且未强制重载时，直接复用缓存。
# 返回：
# - {"ok": true}
# - {"ok": false, "error": String}
func ensure_loaded(paths: Dictionary = {}, force_reload: bool = false) -> Dictionary:
	var resolved_paths := DEFAULT_PATHS.duplicate(true)
	for key in paths.keys():
		resolved_paths[str(key)] = str(paths[key])

	if (not force_reload) and _loaded and resolved_paths == _source_paths:
		return {"ok": true}

	var roles_result := ConfigLoader.load_roles(str(resolved_paths.get("roles", "")))
	if not roles_result.get("ok", false):
		return roles_result
	var roles: Array = roles_result.get("roles", [])

	var pick_result := _pick_first_player_and_npc(roles, str(resolved_paths.get("roles", "")))
	if not pick_result.get("ok", false):
		return pick_result

	var graph_result := ConfigLoader.load_location_graph(str(resolved_paths.get("location_graph", "")))
	if not graph_result.get("ok", false):
		return graph_result

	var affinity_result := ConfigLoader.load_affinity_map(str(resolved_paths.get("affinity", "")))
	if not affinity_result.get("ok", false):
		return affinity_result

	var world_event_dir := str(resolved_paths.get("world_event_csv_dir", "")).strip_edges()
	if world_event_dir.is_empty():
		return {"ok": false, "error": "world event csv dir is empty"}
	var world_event_result := WorldEventConfigAssembler.compile_from_csv_dir(world_event_dir)
	if not world_event_result.get("ok", false):
		return {
			"ok": false,
			"error": "world event config compile failed: %s" % str(world_event_result.get("error", "unknown"))
		}

	_roles = roles
	_location_graph = graph_result["graph"]
	_affinity_map = affinity_result["affinity"]
	_world_event_data = (world_event_result.get("data", {}) as Dictionary).duplicate(true)
	_source_paths = resolved_paths
	_loaded = true

	# 所有核心配置加载成功后，再初始化属性名称翻译表（纯展示用途，失败不阻断）。
	# 放在写入缓存之后，确保重载时不会出现翻译表与配置数据不一致的状态。
	var attr_names_path := str(resolved_paths.get("attribute_names", ""))
	if attr_names_path.is_empty():
		RoleState.init_attribute_names({})
	else:
		var attr_names_result := ConfigLoader.load_attribute_names(attr_names_path)
		if attr_names_result.get("ok", false):
			RoleState.init_attribute_names(attr_names_result["names"])
		else:
			RoleState.init_attribute_names({})

	return {"ok": true}

# 返回角色数据副本，避免调用方直接修改运行时缓存。
func get_roles() -> Array:
	var out: Array = []
	for role_variant in _roles:
		var role: RoleState = role_variant
		out.append(RoleState.from_dict(role.to_dict()))
	return out

# 基于缓存构建完整的业务/测试上下文快照。
# 返回对象均为副本，保证运行时缓存不被外部修改。
# 返回：
# - {"ok": true, "roles": Array, "player": RoleState, "npc": RoleState, "graph": LocationGraph, "affinity": AffinityMap}
# - {"ok": false, "error": String}
func build_context() -> Dictionary:
	if not _loaded:
		return {"ok": false, "error": "config runtime is not loaded"}

	var roles := get_roles()
	var pick_result := _pick_first_player_and_npc(roles)
	if not pick_result.get("ok", false):
		return pick_result

	return {
		"ok": true,
		"roles": roles,
		"player": pick_result["player"],
		"npc": pick_result["npc"],
		"graph": LocationGraph.from_dict(_location_graph.to_dict()),
		"affinity": AffinityMap.from_dict(_affinity_map.to_dict()),
		"world_event": get_world_event_data()
	}

# 返回世界事件编译结果副本，避免外部直接修改运行时缓存。
# 返回：
# - {"world_state": Dictionary, "events": Array, "choice_points": Array}
func get_world_event_data() -> Dictionary:
	if not _loaded:
		return {}
	return _world_event_data.duplicate(true)

# 运行时层的业务规则：
# roles 配置中至少要包含一个 player 和一个 npc。
static func _pick_first_player_and_npc(roles: Array, source_path: String = "") -> Dictionary:
	var player: RoleState = null
	var npc: RoleState = null

	for role_variant in roles:
		var role: RoleState = role_variant
		var role_type := role.role_type.to_lower()
		if role_type == "player" and player == null:
			player = role
		elif role_type == "npc" and npc == null:
			npc = role

	if player == null or npc == null:
		var suffix := ""
		if not source_path.is_empty():
			suffix = ": %s" % source_path
		return {"ok": false, "error": "roles csv must contain at least one player and one npc%s" % suffix}

	return {"ok": true, "player": player, "npc": npc}
