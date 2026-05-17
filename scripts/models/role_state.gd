extends RefCounted
class_name RoleState

# 角色形象资源固定目录：配置中只填写文件名（如 icon.svg）。
const PORTRAIT_BASE_DIR := "res://assets/art/characters/portraits"

# 属性名称映射表（从 attribute_names.csv 加载）。
# 格式：{internal_key: {display_name, category, value_range, description}}
# 由 init_attribute_names() 初始化；未初始化时 get_display_name() 返回原始 key。
static var _attribute_names: Dictionary = {}
# 设计文档名称 → 内部功能名称的反向映射表。由 init_attribute_names() 构建。
static var _reverse_display_names: Dictionary = {}

# 玩家与 NPC 共用的角色状态模型。
var role_id: String
var role_type: String
var display_name: String
var location_id: String
var portrait_file: String
var attributes: Dictionary
var resources: Dictionary
# 玩家关注的 NPC ID 列表。空列表视为关注所有 NPC。仅玩家角色使用。
var focusing_npcs: Array = []
# 玩家关注 NPC 数量上限。-1 表示无限制。由 world_seed 的 reflection_config.focus_limit 初始化。
var focus_limit: int = -1

# 初始化角色数据。字典会深拷贝，避免外部引用污染内部状态。
func _init(
	p_role_id: String = "",
	p_role_type: String = "npc",
	p_display_name: String = "",
	p_location_id: String = "",
	p_portrait_file: String = "",
	p_attributes: Dictionary = {},
	p_resources: Dictionary = {}
) -> void:
	role_id = p_role_id
	role_type = p_role_type
	display_name = p_display_name
	location_id = p_location_id
	portrait_file = p_portrait_file.strip_edges()
	attributes = p_attributes.duplicate(true)
	resources = p_resources.duplicate(true)
	focusing_npcs = []

func has_portrait() -> bool:
	return not portrait_file.is_empty()

func get_portrait_path() -> String:
	if not has_portrait():
		return ""
	return "%s/%s" % [PORTRAIT_BASE_DIR, portrait_file]

# 从外部加载的映射数据初始化属性名称表。由 ConfigRuntime 启动时调用。
# names 格式：{internal_key: {display_name, category, value_range, description}}
static func init_attribute_names(names: Dictionary) -> void:
	_attribute_names = names.duplicate(true)
	_reverse_display_names = {}
	for key in _attribute_names.keys():
		var entry: Dictionary = _attribute_names[key]
		var dn: String = str(entry.get("display_name", key))
		_reverse_display_names[dn] = key

# 获取属性的设计文档显示名称；未初始化或无映射时返回原始 key。
static func get_display_name(key: String) -> String:
	if _attribute_names.has(key):
		return str((_attribute_names[key] as Dictionary).get("display_name", key))
	return key

# 将设计文档名称转换为内部功能名称；无映射时返回原始名称。
static func get_internal_key(design_name: String) -> String:
	return str(_reverse_display_names.get(design_name, design_name))

# 获取属性的完整元信息字典；无映射时返回空字典。
static func get_attribute_meta(key: String) -> Dictionary:
	if _attribute_names.has(key):
		return (_attribute_names[key] as Dictionary).duplicate(true)
	return {}

func load_portrait_texture() -> Texture2D:
	if not has_portrait():
		return null

	var portrait_path := get_portrait_path()
	var resource := ResourceLoader.load(portrait_path)
	if resource is Texture2D:
		return resource

	# 兜底：若资源未被导入，尝试按文件直接加载。
	return _load_texture_from_file(portrait_path)

# 便捷读取心性值，等同于 get_attribute("xinxing", 0)。
func get_xinxing() -> int:
	return get_attribute("xinxing", 0)

# 设置心性值，裁剪至 [-2, +2]。与 get_xinxing() 形成对称的读写边界。
# xinxing 的值域约束属于数据不变量，由数据模型自身负责维护。
func set_xinxing(value: int) -> void:
	attributes["xinxing"] = clampi(value, -2, 2)

# 功能：初始化关注列表。
# 说明：抽象为独立方法，便于后续扩展初始化策略。当前默认传入空列表。
func init_focusing_npcs(npc_list: Array = []) -> void:
	focusing_npcs = npc_list.duplicate()

# 功能：判断玩家是否关注指定 NPC。
# 说明：空列表视为关注所有 NPC，保持向后兼容。
func is_focusing(npc_id: String) -> bool:
	if focusing_npcs.is_empty():
		return true
	return focusing_npcs.has(npc_id)

# 功能：判断关注列表是否已满。
# 说明：focus_limit <= 0 时视为无限制，永远返回 false。
func is_focus_full() -> bool:
	if focus_limit <= 0:
		return false
	return focusing_npcs.size() >= focus_limit

# 功能：从关注列表移除指定 NPC。
# 说明：返回是否移除成功（NPC 不在列表中时返回 false）。
func remove_focus(npc_id: String) -> bool:
	var idx := focusing_npcs.find(npc_id)
	if idx >= 0:
		focusing_npcs.remove_at(idx)
		return true
	return false

# 功能：向关注列表添加指定 NPC。
# 说明：已存在时不重复添加，返回 false。
func add_focus(npc_id: String) -> bool:
	if focusing_npcs.has(npc_id):
		return false
	focusing_npcs.append(npc_id)
	return true

# 功能：切换指定 NPC 的关注状态。
# 说明：已关注则取消，未关注则添加。返回切换后的关注状态。
func toggle_focus(npc_id: String) -> bool:
	var idx := focusing_npcs.find(npc_id)
	if idx >= 0:
		focusing_npcs.remove_at(idx)
		return false
	else:
		focusing_npcs.append(npc_id)
		return true

# 获取属性值；当键不存在时返回默认值（默认1）。
func get_attribute(key: String, default_value: int = 1) -> int:
	return int(attributes.get(key, default_value))

# 设置属性值。有约束的字段（xinxing）路由至具名访问器以保证不变量。
func set_attribute(key: String, value: int) -> void:
	if key == "xinxing":
		set_xinxing(value)
		return
	attributes[key] = value

# 获取资源值；当键不存在时返回默认值（默认0）。
func get_resource(key: String, default_value: int = 0) -> int:
	return int(resources.get(key, default_value))

# 设置资源值。按设计允许负数。
func set_resource(key: String, value: int) -> void:
	resources[key] = value

# 统一取值入口：优先查 attributes，再查 resources，均无则返回默认值。
func get_value(key: String, default_value: int = 0) -> int:
	if attributes.has(key):
		return int(attributes[key])
	if resources.has(key):
		return int(resources[key])
	return default_value

# 统一写值入口：优先写已存在的字典，均无则写入 resources。
# 有约束的字段（xinxing）路由至具名访问器以保证不变量。
func set_value(key: String, value: int) -> void:
	if key == "xinxing":
		set_xinxing(value)
		return
	if attributes.has(key):
		attributes[key] = value
	elif resources.has(key):
		resources[key] = value
	else:
		resources[key] = value

# 将所有 attributes 和 resources 合并为一个扁平字典，用于同步到 world_state.player。
func to_flat_dict() -> Dictionary:
	var flat := {}
	for key in attributes.keys():
		flat[str(key)] = int(attributes[key])
	for key in resources.keys():
		flat[str(key)] = int(resources[key])
	return flat

# 序列化为 Dictionary，便于存档、传输与调试输出。
func to_dict() -> Dictionary:
	return {
		"role_id": role_id,
		"role_type": role_type,
		"display_name": display_name,
		"location_id": location_id,
		"portrait_file": portrait_file,
		"attributes": attributes.duplicate(true),
		"resources": resources.duplicate(true),
		"focusing_npcs": focusing_npcs.duplicate(),
		"focus_limit": focus_limit
	}

# 从 Dictionary 快照反序列化为 RoleState。
static func from_dict(data: Dictionary) -> RoleState:
	var state := RoleState.new(
		str(data.get("role_id", "")),
		str(data.get("role_type", "npc")),
		str(data.get("display_name", "")),
		str(data.get("location_id", "")),
		str(data.get("portrait_file", "")),
		data.get("attributes", {}),
		data.get("resources", {})
	)
	# 还原关注列表；缺省时保持空列表（视为关注所有 NPC）
	var focusing: Array = data.get("focusing_npcs", [])
	state.init_focusing_npcs(focusing)
	# 还原关注上限；缺省为 -1（无限制）
	state.focus_limit = int(data.get("focus_limit", -1))
	return state

static func _load_texture_from_file(path: String) -> Texture2D:
	if not FileAccess.file_exists(path):
		return null

	var image := Image.new()
	var err := image.load(path)
	if err == OK:
		return ImageTexture.create_from_image(image)

	# SVG 文件在未导入时走字符串解析兜底。
	if path.get_extension().to_lower() == "svg":
		var svg_text := FileAccess.get_file_as_string(path)
		if svg_text.is_empty():
			return null
		var svg_image := Image.new()
		var svg_err := svg_image.load_svg_from_string(svg_text)
		if svg_err == OK:
			return ImageTexture.create_from_image(svg_image)

	return null
