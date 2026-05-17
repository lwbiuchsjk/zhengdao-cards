extends RefCounted
class_name LocationGraph

# 地点美术资源固定目录：配置中只填写文件名（如 town.svg）。
const LOCATION_ART_BASE_DIR := "res://assets/art/environments/backgrounds"

# 地点邻接图：location_id -> neighbor_ids[]
var adjacency: Dictionary = {}
# 地点美术配置：location_id -> art_file
var art_files: Dictionary = {}
# 地点名称配置：location_id -> display_name
var display_names: Dictionary = {}

# 设置某地点的邻接列表，并统一转换为 String。
func set_neighbors(location_id: String, neighbors: Array) -> void:
	var normalized: Array[String] = []
	for n in neighbors:
		normalized.append(str(n))
	adjacency[location_id] = normalized

# 获取某地点邻接列表；不存在时返回空数组。
func get_neighbors(location_id: String) -> Array[String]:
	var raw: Array = adjacency.get(location_id, [])
	var out: Array[String] = []
	for n in raw:
		out.append(str(n))
	return out


# 功能：返回图中全部已知 location_id 列表（Step 2 新增）。
# 说明：供"导入阶段模式"自省事件构建全量地点候选（不限于当前地点的邻居）使用。
func get_all_location_ids() -> Array[String]:
	var out: Array[String] = []
	for key_variant in adjacency.keys():
		out.append(str(key_variant))
	return out

# 移动判定：同地点可达，否则必须在邻接列表中。
func is_neighbor(from_location_id: String, to_location_id: String) -> bool:
	if from_location_id == to_location_id:
		return true
	return to_location_id in get_neighbors(from_location_id)

func set_art_file(location_id: String, art_file: String) -> void:
	art_files[location_id] = art_file.strip_edges()

func get_art_file(location_id: String) -> String:
	return str(art_files.get(location_id, ""))

func get_art_path(location_id: String) -> String:
	var art_file := get_art_file(location_id)
	if art_file.is_empty():
		return ""
	return "%s/%s" % [LOCATION_ART_BASE_DIR, art_file]

func load_art_texture(location_id: String) -> Texture2D:
	var art_path := get_art_path(location_id)
	if art_path.is_empty():
		return null

	var resource := ResourceLoader.load(art_path)
	if resource is Texture2D:
		return resource

	return _load_texture_from_file(art_path)

func set_display_name(location_id: String, display_name: String) -> void:
	display_names[location_id] = display_name.strip_edges()

func get_display_name(location_id: String) -> String:
	var configured := str(display_names.get(location_id, "")).strip_edges()
	if not configured.is_empty():
		return configured
	# 若未配置名称，回退为 location_id。
	return location_id

# 导出地点图数据。
func to_dict() -> Dictionary:
	return {
		"adjacency": adjacency.duplicate(true),
		"art_files": art_files.duplicate(true),
		"display_names": display_names.duplicate(true)
	}

# 从 Dictionary 恢复地点图数据。
static func from_dict(data: Dictionary) -> LocationGraph:
	var graph := LocationGraph.new()

	# 兼容旧结构：直接是 adjacency 映射。
	var adjacency_data: Dictionary = data
	var art_files_data: Dictionary = {}
	var display_names_data: Dictionary = {}
	if data.has("adjacency"):
		adjacency_data = data.get("adjacency", {})
		art_files_data = data.get("art_files", {})
		display_names_data = data.get("display_names", {})

	for key in adjacency_data.keys():
		var location_id := str(key)
		var neighbors: Array = adjacency_data[key]
		graph.set_neighbors(location_id, neighbors)

	for key in art_files_data.keys():
		graph.set_art_file(str(key), str(art_files_data[key]))

	for key in display_names_data.keys():
		graph.set_display_name(str(key), str(display_names_data[key]))

	return graph

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
