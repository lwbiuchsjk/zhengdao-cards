extends RefCounted
class_name ConfigLoader

# ConfigLoader
# 职责：
# - 从磁盘读取配置文件，并解析为类型化模型对象。
# - 不负责缓存、不提供单例、不承担业务流程编排。
# - 作为底层数据源，供 ConfigRuntime 统一调度调用。
const RoleState := preload("res://scripts/models/role_state.gd")
const AffinityMap := preload("res://scripts/models/affinity_map.gd")
const LocationGraph := preload("res://scripts/models/location_graph.gd")

# 通用 CSV 解析函数，供下方所有 load_* 接口复用。
# 返回：
# - {"ok": true, "headers": Array[String], "rows": Array[Dictionary]}
# - {"ok": false, "error": String}
static func load_csv_table(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "csv not found: %s" % path}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "cannot open csv: %s" % path}
	if file.eof_reached():
		return {"ok": false, "error": "csv is empty: %s" % path}

	var header_row := file.get_csv_line()
	var headers: Array[String] = []
	for header in header_row:
		headers.append(str(header).strip_edges())
	if headers.is_empty():
		return {"ok": false, "error": "csv header is empty: %s" % path}

	var rows: Array = []
	while not file.eof_reached():
		var values := file.get_csv_line()
		if values.is_empty():
			continue
		if values.size() == 1 and str(values[0]).strip_edges().is_empty():
			continue

		var row: Dictionary = {}
		for i in headers.size():
			var key := headers[i]
			var value := ""
			if i < values.size():
				value = str(values[i]).strip_edges()
			row[key] = value
		rows.append(row)

	return {"ok": true, "headers": headers, "rows": rows}

# 从 roles.csv 加载角色定义，并转换为 RoleState 对象列表。
# 返回：
# - {"ok": true, "roles": Array[RoleState]}
# - {"ok": false, "error": String}
static func load_roles(path: String) -> Dictionary:
	var table_result := load_csv_table(path)
	if not table_result.get("ok", false):
		return table_result

	var roles: Array = []
	var rows: Array = table_result["rows"]
	for row_variant in rows:
		var row: Dictionary = row_variant
		var role := RoleState.new(
			str(row.get("role_id", "")),
			str(row.get("role_type", "")),
			str(row.get("display_name", "")),
			str(row.get("location_id", "")),
			str(row.get("portrait_file", "")),
			{
				"aptitude": _to_int(row.get("aptitude", "1"), 1),
				"physique": _to_int(row.get("physique", "1"), 1),
				"craft": _to_int(row.get("craft", "1"), 1),
				"insight": _to_int(row.get("insight", "1"), 1),
				"xinxing": clampi(_to_int(row.get("xinxing", "0"), 0), -2, 2)
			},
			{
				"hp": _to_int(row.get("hp", "0"), 0),
				"energy": _to_int(row.get("energy", "0"), 0),
				"spirit": _to_int(row.get("spirit", "2"), 2),
				"gold": _to_int(row.get("gold", "0"), 0)
			}
		)
		roles.append(role)

	return {"ok": true, "roles": roles}

# 从地点邻接配置加载 LocationGraph。
# 返回：
# - {"ok": true, "graph": LocationGraph}
# - {"ok": false, "error": String}
static func load_location_graph(path: String) -> Dictionary:
	var table_result := load_csv_table(path)
	if not table_result.get("ok", false):
		return table_result

	var graph := LocationGraph.new()
	var rows: Array = table_result["rows"]
	for row_variant in rows:
		var row: Dictionary = row_variant
		var location_id := str(row.get("location_id", ""))
		if location_id.is_empty():
			continue

		var neighbors_text := str(row.get("neighbors", ""))
		var neighbors: Array[String] = []
		for neighbor in neighbors_text.split(";", false):
			var normalized := str(neighbor).strip_edges()
			if not normalized.is_empty():
				neighbors.append(normalized)
		graph.set_neighbors(location_id, neighbors)
		graph.set_art_file(location_id, str(row.get("art_file", "")))
		graph.set_display_name(location_id, str(row.get("display_name", "")))

	return {"ok": true, "graph": graph}

# 从好感度配置加载 AffinityMap。
# 返回：
# - {"ok": true, "affinity": AffinityMap}
# - {"ok": false, "error": String}
static func load_affinity_map(path: String) -> Dictionary:
	var table_result := load_csv_table(path)
	if not table_result.get("ok", false):
		return table_result

	var affinity := AffinityMap.new()
	var rows: Array = table_result["rows"]
	for row_variant in rows:
		var row: Dictionary = row_variant
		var from_role_id := str(row.get("from_role_id", ""))
		var to_role_id := str(row.get("to_role_id", ""))
		if from_role_id.is_empty() or to_role_id.is_empty():
			continue

		var score := _to_int(row.get("score", "0"), 0)
		affinity.set_score(from_role_id, to_role_id, score)

	return {"ok": true, "affinity": affinity}

# 从 creation_questions.csv 加载开局选择配置，解析为结构化问题-选项树。
# 返回：
# - {"ok": true, "data": Array} — data 为按行序排列的问题数组
# - {"ok": false, "error": String}
static func load_creation_config(path: String) -> Dictionary:
	var table_result := load_csv_table(path)
	if not table_result.get("ok", false):
		return table_result

	var rows: Array = table_result["rows"]
	# 按行序收集问题和选项，同 question_id 的行合并为一个问题。
	var questions: Array = []
	# 当前正在构建的问题 ID → questions 数组中的索引。
	var question_index_map: Dictionary = {}
	# 当前问题内的选项 ID → options 数组中的索引。
	var option_index_maps: Dictionary = {}

	for row_variant in rows:
		var row: Dictionary = row_variant
		var qid := str(row.get("question_id", "")).strip_edges()
		if qid.is_empty():
			continue

		# 若该问题尚未出现，创建新问题条目。
		if not question_index_map.has(qid):
			var raw_text := str(row.get("question_text", ""))
			# 按 | 分段符拆分叙事段落；无 | 时为单元素数组，行为向后兼容。
			var narrative_lines: Array = []
			for seg in raw_text.split("|"):
				var trimmed := seg.strip_edges()
				if not trimmed.is_empty():
					narrative_lines.append(trimmed)
			if narrative_lines.is_empty():
				narrative_lines.append(raw_text)
			var question: Dictionary = {
				"question_id": qid,
				"question_text": raw_text,
				"narrative_lines": narrative_lines,
				"condition": str(row.get("condition", "")),
				"background_art": str(row.get("background_art", "")).strip_edges(),
				"options": []
			}
			question_index_map[qid] = questions.size()
			option_index_maps[qid] = {}
			questions.append(question)

		var q_idx: int = int(question_index_map[qid])
		var question: Dictionary = questions[q_idx]
		var options: Array = question["options"]
		var oid := str(row.get("option_id", "")).strip_edges()
		if oid.is_empty():
			continue

		# 构建 effect 条目，附带分支标记。
		var effect: Dictionary = {
			"target": str(row.get("effect_target", "")),
			"key": str(row.get("effect_key", "")),
			"value": str(row.get("effect_value", ""))
		}
		var branch := str(row.get("effect_branch", "default")).strip_edges()
		if branch.is_empty():
			branch = "default"

		# 若该选项已存在，追加 effect 到对应分支；否则创建新选项。
		var opt_map: Dictionary = option_index_maps[qid]
		if opt_map.has(oid):
			var o_idx: int = int(opt_map[oid])
			var existing_option: Dictionary = options[o_idx]
			_append_creation_effect(existing_option, effect, branch)
			# 检定配置只在首次出现时写入，后续同选项行不覆盖。
			_try_parse_creation_check(existing_option, row)
			# 叙事后果按分支写入，已有内容不覆盖。
			_try_parse_creation_outcome(existing_option, row)
		else:
			var new_option: Dictionary = {
				"option_id": oid,
				"option_text": str(row.get("option_text", "")),
				"effects_default": [],
				"effects_success": [],
				"effects_fail": [],
				# 向后兼容：保留 effects 字段，指向 effects_default。
				"effects": [],
				"check": {},
				# 叙事后果文本，按检定分支区分。
				"outcome_default": "",
				"outcome_success": "",
				"outcome_fail": "",
			}
			_append_creation_effect(new_option, effect, branch)
			_try_parse_creation_check(new_option, row)
			_try_parse_creation_outcome(new_option, row)
			opt_map[oid] = options.size()
			options.append(new_option)

	# 向后兼容：将 effects_default 复制到 effects，供旧逻辑使用。
	for q_variant in questions:
		var q: Dictionary = q_variant
		for opt_variant in q.get("options", []):
			var opt: Dictionary = opt_variant
			opt["effects"] = opt.get("effects_default", [])

	return {"ok": true, "data": questions}


# 功能：将 effect 追加到选项的对应分支数组中。
static func _append_creation_effect(option: Dictionary, effect: Dictionary, branch: String) -> void:
	var key := "effects_" + branch
	if not option.has(key):
		key = "effects_default"
	var arr: Array = option[key]
	arr.append(effect)


# 功能：从 CSV 行中解析检定配置，写入选项的 check 字段。
# 说明：只在选项尚无 check 配置时解析，避免同选项多行重复覆盖。
static func _try_parse_creation_check(option: Dictionary, row: Dictionary) -> void:
	var existing_check: Dictionary = option.get("check", {})
	if not existing_check.is_empty():
		return
	var check_type := str(row.get("check_type", "")).strip_edges()
	if check_type.is_empty():
		return
	var check: Dictionary = {"type": check_type}
	var items_str := str(row.get("check_items", "")).strip_edges()
	if not items_str.is_empty():
		check["items"] = _parse_creation_check_items(items_str)
	var hit_threshold := str(row.get("check_hit_threshold", "")).strip_edges()
	if not hit_threshold.is_empty():
		check["hitThreshold"] = int(hit_threshold)
	var required_hits := str(row.get("check_required_hits", "")).strip_edges()
	if not required_hits.is_empty():
		check["requiredHits"] = int(required_hits)
	option["check"] = check


# 功能：解析检定 items 字符串为数组。
# 格式：与 option_rules 一致，如 "craft:positive;insight:negative"。
static func _parse_creation_check_items(text: String) -> Array:
	var items: Array = []
	var parts := text.split(";")
	for part in parts:
		var seg := part.strip_edges()
		if seg.is_empty():
			continue
		var kv := seg.split(":")
		if kv.size() < 2:
			continue
		items.append({
			"key": str(kv[0]).strip_edges(),
			"direction": str(kv[1]).strip_edges()
		})
	return items


# 功能：从 CSV 行中解析叙事后果文本，按分支写入选项。
# 说明：outcome_branch 为 default/success/fail，对应写入 outcome_default/outcome_success/outcome_fail。
#       已有非空内容的分支不覆盖。
static func _try_parse_creation_outcome(option: Dictionary, row: Dictionary) -> void:
	var outcome_text := str(row.get("outcome_text", "")).strip_edges()
	if outcome_text.is_empty():
		return
	var outcome_branch := str(row.get("outcome_branch", "default")).strip_edges()
	if outcome_branch.is_empty():
		outcome_branch = "default"
	var key := "outcome_" + outcome_branch
	if not option.has(key):
		key = "outcome_default"
	# 已有非空内容时不覆盖（同选项多行场景）。
	var existing := str(option.get(key, ""))
	if existing.is_empty():
		option[key] = outcome_text


# 从 attribute_names.csv 加载属性名称映射表。
# 返回：
# - {"ok": true, "names": Dictionary}  — names 格式为 {internal_key: {display_name, category, value_range, description}}
# - {"ok": false, "error": String}
static func load_attribute_names(path: String) -> Dictionary:
	var table_result := load_csv_table(path)
	if not table_result.get("ok", false):
		return table_result

	var names: Dictionary = {}
	var rows: Array = table_result["rows"]
	for row_variant in rows:
		var row: Dictionary = row_variant
		var internal_key := str(row.get("internal_key", "")).strip_edges()
		if internal_key.is_empty():
			continue
		names[internal_key] = {
			"display_name": str(row.get("display_name", internal_key)),
			"category": str(row.get("category", "")),
			"value_range": str(row.get("value_range", "")),
			"description": str(row.get("description", ""))
		}

	return {"ok": true, "names": names}


static func _to_int(value: Variant, default_value: int) -> int:
	var text := str(value).strip_edges()
	if text.is_empty():
		return default_value
	if text.is_valid_int():
		return int(text)
	return default_value
