extends RefCounted
class_name WorldEventConfigAssembler

# 功能：将收束后的 6 张 CSV 配置组装为世界事件引擎可直接消费的数据结构。
const ConfigLoader = preload("res://scripts/systems/config_loader.gd")
# 功能：事件背景美术固定资源目录。
# 说明：配置表中只填写文件名，运行时统一在这里补全为资源路径。
const EVENT_BACKGROUND_BASE_DIR := "res://assets/art/environments/backgrounds"


# 功能：从 CSV 目录编译配置并输出运行时数据结构。
static func compile_from_csv_dir(csv_dir_path: String) -> Dictionary:
	var base = csv_dir_path.strip_edges()
	if base.is_empty():
		return {"ok": false, "error": "csv dir path is empty"}

	var tables_result = _load_tables(base)
	if not tables_result.get("ok", false):
		return tables_result

	var tables: Dictionary = tables_result["tables"]

	var world_result = _assemble_world_state(tables)
	if not world_result.get("ok", false):
		return world_result

	var task_defs_result = _assemble_task_defs(tables)
	if not task_defs_result.get("ok", false):
		return task_defs_result

	var task_eval_result = _assemble_task_evaluation_tables(tables)
	if not task_eval_result.get("ok", false):
		return task_eval_result
	var task_eval_validate_result = _validate_task_evaluation_tables(
		task_defs_result.get("task_defs", []),
		task_eval_result.get("task_evaluation", {})
	)
	if not task_eval_validate_result.get("ok", false):
		return task_eval_validate_result

	var choice_result = _assemble_choice_points(tables)
	if not choice_result.get("ok", false):
		return choice_result

	var events_result = _assemble_events(tables, choice_result.get("choice_point_ids", {}))
	if not events_result.get("ok", false):
		return events_result

	# Step 2：装配过渡叙事文本池并写入 world_state.transitionTextPool。
	# 结构：{ pool_id: { location_id: [text1, text2, ...] }（按 seq 升序） }；
	# 文件缺失时为空字典，引擎在自省末屏选完地点后查不到对应池则跳过过渡叙事段。
	var transition_pool: Dictionary = _assemble_transition_text_pool(tables)
	world_result["world_state"]["transitionTextPool"] = transition_pool

	return {
		"ok": true,
		"data": {
			"world_state": world_result["world_state"],
			"events": events_result["events"],
			"choice_points": choice_result["choice_points"],
			"task_defs": task_defs_result["task_defs"],
			"task_evaluation": task_eval_result["task_evaluation"]
		}
	}


# 功能：装配过渡叙事文本池（Step 2 新增）。
# 说明：从 transition_text_pool.csv 读取，按 pool_id / location_id 分组，按 seq 升序排序文本；
#       静默跳过格式异常行，避免单行错误阻断整体加载。
static func _assemble_transition_text_pool(tables: Dictionary) -> Dictionary:
	var rows: Array = tables.get("transition_text_pool.csv", [])
	# 中间结构：{ pool_id: { location_id: [{seq: int, text: String}, ...] } }
	var staging: Dictionary = {}
	for row_variant in rows:
		var row: Dictionary = row_variant
		var pool_id: String = str(row.get("pool_id", "")).strip_edges()
		var location_id: String = str(row.get("location_id", "")).strip_edges()
		var seq_text: String = str(row.get("seq", "")).strip_edges()
		# 叙事 text 统一经 _load_narrative_text 读取（装配层规约转义入口，含 \n unescape）。
		var text: String = _load_narrative_text(row)
		if pool_id.is_empty() or location_id.is_empty() or text.is_empty():
			continue
		if seq_text.is_empty() or not seq_text.is_valid_int():
			continue
		var seq: int = int(seq_text)
		if not staging.has(pool_id):
			staging[pool_id] = {}
		var by_location: Dictionary = staging[pool_id]
		if not by_location.has(location_id):
			by_location[location_id] = []
		var entries: Array = by_location[location_id]
		entries.append({"seq": seq, "text": text})
		by_location[location_id] = entries
		staging[pool_id] = by_location

	# 排序并扁平化为 { pool_id: { location_id: [text, ...] } }
	var out: Dictionary = {}
	for pool_id_variant in staging.keys():
		var pool_id_key: String = str(pool_id_variant)
		var by_location: Dictionary = staging[pool_id_key]
		var pool_out: Dictionary = {}
		for location_id_variant in by_location.keys():
			var location_id_key: String = str(location_id_variant)
			var entries: Array = by_location[location_id_key]
			entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return int(a.get("seq", 0)) < int(b.get("seq", 0))
			)
			var texts: Array = []
			for entry_variant in entries:
				var entry: Dictionary = entry_variant
				texts.append(str(entry.get("text", "")))
			pool_out[location_id_key] = texts
		out[pool_id_key] = pool_out
	return out


# 功能：从 CSV 行读取叙事 text 字段，统一做装配层转义处理。
# 说明：所有叙事文本字段（event_presentations.text / option_outcomes.text /
#       transition_text_pool.text 及未来新增叙事 CSV）必须经本函数读取，确保 unescape
#       行为一致。把"换行 unescape"从每个装配函数的可选步骤变成读取本身的不可分割部分,
#       避免新增叙事字段时漏处理（历史 BUG 复发的预防：曾在 option_outcomes / transition
#       两处遗漏 unescape，导致字面 \n 直接渲染到 UI 上）。
# 规约：见 CLAUDE.md §CSV 配置静态检查规范·叙事换行用字面 \n；
#       静态检查见 tools/csv_validator.py 检查 10（CSV 端不允许真换行）。
static func _load_narrative_text(row: Dictionary, field: String = "text") -> String:
	var text: String = str(row.get(field, ""))
	# 字面 \n 两字符 → 真换行（CSV 不识别转义,字面 "\n" 读出来是 \ + n 两字符）
	return text.replace("\\n", "\n")


# 功能：读取编译所需的 6 张核心 CSV 表。
static func _load_tables(base: String) -> Dictionary:
	var required_files: Array = [
		"world_seed.csv",
		"tasks.csv",
		"events.csv",
		"event_conditions.csv",
		"event_outcomes.csv",
		"event_presentations.csv",
		"options.csv",
		"option_rules.csv"
	]
	var optional_files: Array = [
		"task_eval_grades.csv",
		"task_eval_indicators.csv",
		"task_eval_grade_overrides.csv",
		"task_eval_effects.csv",
		# Step 2 自省过渡叙事文本池（设计基线见 [[当前版本完整主路径_MVP设计]] §三·节点 2）。
		# 字段：pool_id / location_id / seq / text；缺失时引擎跳过过渡叙事段。
		"transition_text_pool.csv",
		# 事件叙事反馈 MVP A：选项结算后追加叙事屏（设计基线见 [[事件叙事反馈_MVP设计]]）。
		# 字段：option_id / branch / seq / text；缺失时引擎跳过 outcome 屏追加（流程兼容旧配置）。
		"option_outcomes.csv"
	]

	var tables: Dictionary = {}
	for file_variant in required_files:
		var file_name = str(file_variant)
		var path = _join_path(base, file_name)
		var table_result = ConfigLoader.load_csv_table(path)
		if not table_result.get("ok", false):
			return {"ok": false, "error": str(table_result.get("error", "load csv failed"))}
		tables[file_name] = table_result.get("rows", [])

	# 说明：任务评价表在里程碑 1 作为可选配置接入，不影响旧配置目录继续编译。
	for file_variant in optional_files:
		var file_name = str(file_variant)
		var path = _join_path(base, file_name)
		if not FileAccess.file_exists(path):
			tables[file_name] = []
			continue
		var table_result = ConfigLoader.load_csv_table(path)
		if not table_result.get("ok", false):
			return {"ok": false, "error": str(table_result.get("error", "load csv failed"))}
		tables[file_name] = table_result.get("rows", [])

	return {"ok": true, "tables": tables}


# 功能：组装 world_state 初始状态。
# 说明：从 world_seed.csv 的 section/scope/key/value 通用结构解码。
static func _assemble_world_state(tables: Dictionary) -> Dictionary:
	var rows: Array = tables.get("world_seed.csv", [])

	var world_state = {
		"turn": 1,
		"currentLocationId": "",
		"flags": {},
		"params": {},
		"locationState": {},
		"npcPresence": {},
		"player": {},
		"taskConfig": {
			"maxActiveCount": 1
		},
		"tasks": {
			"active": [],
			"completed": [],
			"failed": [],
			"abandoned": [],
			"resultRecords": []
		},
		"history": [],
		"chainContext": null,
		"forcedNextEventId": "",
		"runState": {
			"status": "running",
			"endingEventId": "",
			"finishedTurn": 0
		}
	}

	var history_pairs: Array = []
	var chain_seed: Dictionary = {}

	for row_variant in rows:
		var row: Dictionary = row_variant
		var section := str(row.get("section", "")).strip_edges()
		var scope_a := str(row.get("scope_a", "")).strip_edges()
		var key := str(row.get("key", "")).strip_edges()
		var value_text := str(row.get("value", "")).strip_edges()

		if section.is_empty() or key.is_empty():
			continue

		match section:
			"core":
				if key == "turn":
					world_state["turn"] = _to_int(value_text, 1)
				elif key == "current_location_id":
					world_state["currentLocationId"] = value_text
				elif key == "forced_next_event_id":
					world_state["forcedNextEventId"] = value_text
			"flag":
				var flags: Dictionary = world_state.get("flags", {})
				flags[key] = _parse_literal(value_text)
				world_state["flags"] = flags
			"param":
				var params: Dictionary = world_state.get("params", {})
				params[key] = _to_int(value_text, 0)
				world_state["params"] = params
			"player":
				var player: Dictionary = world_state.get("player", {})
				player[key] = _parse_literal(value_text)
				world_state["player"] = player
			"task_config":
				# 说明：任务并行上限属于 world_state 初始化配置，默认至少为 1。
				var task_config: Dictionary = world_state.get("taskConfig", {})
				if key == "max_active_count":
					task_config["maxActiveCount"] = maxi(1, _to_int(value_text, 1))
				world_state["taskConfig"] = task_config
			"location_state":
				if scope_a.is_empty():
					continue
				var location_state: Dictionary = world_state.get("locationState", {})
				if not location_state.has(scope_a):
					location_state[scope_a] = {}
				var state_item: Dictionary = location_state[scope_a]
				state_item[key] = _parse_literal(value_text)
				location_state[scope_a] = state_item
				world_state["locationState"] = location_state
			"npc_presence":
				if scope_a.is_empty() or key != "npc_id" or value_text.is_empty():
					continue
				var npc_presence: Dictionary = world_state.get("npcPresence", {})
				if not npc_presence.has(scope_a):
					npc_presence[scope_a] = []
				var present_list: Array = npc_presence[scope_a]
				present_list.append(value_text)
				npc_presence[scope_a] = present_list
				world_state["npcPresence"] = npc_presence
			"history":
				if key != "event_id":
					continue
				var seq := _to_int(scope_a, 0)
				if seq <= 0 or value_text.is_empty():
					continue
				history_pairs.append({"seq": seq, "event_id": value_text})
			"xinxing_config":
				# 说明：心性阶段切换阈值配置，写入 xinxingConfig 字典。
				var xinxing_config: Dictionary = world_state.get("xinxingConfig", {})
				xinxing_config[key] = _to_int(value_text, 0)
				world_state["xinxingConfig"] = xinxing_config
			"affinity_config":
				# 说明：关系五档阈值与回响参数配置，写入 affinityConfig 字典。
				var affinity_config: Dictionary = world_state.get("affinityConfig", {})
				affinity_config[key] = _to_int(value_text, 0)
				world_state["affinityConfig"] = affinity_config
			"pack_config":
				# 说明：叙事包系统配置，写入 packConfig 字典。
				#       int 字段：defaultCapacity / final_event_location_boost。
				#       string 字段：final_event_pool_tag / final_event_pool_exhausted_forced_id（末尾位池抽取）。
				var pack_config: Dictionary = world_state.get("packConfig", {})
				match key:
					"final_event_pool_tag", "final_event_pool_exhausted_forced_id":
						pack_config[key] = value_text.strip_edges()
					_:
						pack_config[key] = _to_int(value_text, 0)
				world_state["packConfig"] = pack_config
			"demo_mode_config":
				# 说明：demo 期临时收紧的开关（心性 UI 隐藏、心性接入路径禁用等），写入 demoModeConfig 字典。
				#       值类型：bool（true/false 字符串）。重构期审视清单见 [[代码重构_预启动]] §4.3。
				#       命名规范："行为描述"风格：hide_X_panel_X / disable_X_path / simplify_X_ui，不用"模块归属"命名。
				var demo_mode_config: Dictionary = world_state.get("demoModeConfig", {})
				demo_mode_config[key] = _parse_literal(value_text)
				world_state["demoModeConfig"] = demo_mode_config
			"reflection_config":
				# 说明：自省系统配置（操作限额、调整刻度、推荐数量、关注上限、初始关注列表），写入 reflectionConfig 字典。
				var reflection_config: Dictionary = world_state.get("reflectionConfig", {})
				if key == "initial_focus_npcs":
					# initial_focus_npcs 为分号分隔的 NPC ID 字符串，转换为 Array。
					var npcs: Array = []
					if not value_text.is_empty():
						for npc_id in value_text.split(";"):
							var trimmed: String = npc_id.strip_edges()
							if not trimmed.is_empty():
								npcs.append(trimmed)
					reflection_config[key] = npcs
				else:
					reflection_config[key] = _to_int(value_text, 0)
				world_state["reflectionConfig"] = reflection_config
			"affinity":
				# 说明：初始关系分值配置。scope_a 为 "from->to" 格式，key 固定为 "score"。
				if scope_a.is_empty() or key != "score":
					continue
				var affinity_init: Dictionary = world_state.get("affinityInit", {})
				affinity_init[scope_a] = _to_int(value_text, 0)
				world_state["affinityInit"] = affinity_init
			"chain":
				chain_seed[key] = value_text
			_:
				continue

	_sort_history_pairs(history_pairs)
	var history: Array = []
	for pair_variant in history_pairs:
		var pair: Dictionary = pair_variant
		history.append(str(pair.get("event_id", "")))
	world_state["history"] = history

	world_state["chainContext"] = _build_chain_context_from_seed(chain_seed)
	return {"ok": true, "world_state": world_state}


# 功能：组装任务定义 task_defs。
# 说明：里程碑 A 仅完成配置编译与透传，不在此处处理任务运行时逻辑。
static func _assemble_task_defs(tables: Dictionary) -> Dictionary:
	var rows: Array = tables.get("tasks.csv", [])
	var out: Array = []
	var id_guard: Dictionary = {}

	for row_variant in rows:
		var row: Dictionary = row_variant
		var task_id := str(row.get("task_id", "")).strip_edges()
		if task_id.is_empty():
			continue
		if id_guard.has(task_id):
			return {"ok": false, "error": "duplicate task id: %s" % task_id}
		id_guard[task_id] = true

		out.append(
			{
				"id": task_id,
				"title": str(row.get("title", "")),
				"durationTurns": maxi(1, _to_int(row.get("duration_turns", "1"), 1)),
				"onExpire": str(row.get("on_expire", "fail")).strip_edges(),
				"weightBiasProfile": str(row.get("weight_bias_profile", "")).strip_edges(),
				# 说明：任务自动接取条件表达式，留空表示仅能通过显式 accept_task 接取。
				"acceptWhen": str(row.get("accept_when", "")).strip_edges(),
				# 说明：任务自动完成条件表达式，留空表示仅能通过显式 complete_task 完成。
				"completeWhen": str(row.get("complete_when", "")).strip_edges()
			}
		)

	return {"ok": true, "task_defs": out}


# 功能：编译任务评价相关配置表。
# 说明：里程碑 1 先完成 CSV 到运行时结构的透传，不在这里做完整业务校验。
static func _assemble_task_evaluation_tables(tables: Dictionary) -> Dictionary:
	var grades_rows: Array = tables.get("task_eval_grades.csv", [])
	var indicator_rows: Array = tables.get("task_eval_indicators.csv", [])
	var override_rows: Array = tables.get("task_eval_grade_overrides.csv", [])
	var effects_rows: Array = tables.get("task_eval_effects.csv", [])

	var grades: Array = []
	for row_variant in grades_rows:
		var row: Dictionary = row_variant
		var task_id := str(row.get("task_id", "")).strip_edges()
		var grade_id := str(row.get("grade_id", "")).strip_edges()
		if task_id.is_empty() or grade_id.is_empty():
			continue
		grades.append(
			{
				"taskId": task_id,
				"gradeId": grade_id,
				"gradeMode": str(row.get("grade_mode", "")).strip_edges(),
				"minScore": _parse_optional_number(row.get("min_score", "")),
				"maxScore": _parse_optional_number(row.get("max_score", "")),
				"displayOrder": _to_int(row.get("display_order", "0"), 0),
				"label": str(row.get("label", "")).strip_edges()
			}
		)

	var indicators: Array = []
	for row_variant in indicator_rows:
		var row: Dictionary = row_variant
		var task_id := str(row.get("task_id", "")).strip_edges()
		var indicator_id := str(row.get("indicator_id", "")).strip_edges()
		if task_id.is_empty() or indicator_id.is_empty():
			continue
		indicators.append(
			{
				"taskId": task_id,
				"indicatorId": indicator_id,
				"left": str(row.get("left", "")).strip_edges(),
				"op": str(row.get("op", "")).strip_edges(),
				"right": str(row.get("right", "")).strip_edges(),
				"passScore": _to_int(row.get("pass_score", "0"), 0),
				"failScore": _to_int(row.get("fail_score", "0"), 0)
			}
		)

	var grade_overrides: Array = []
	for row_variant in override_rows:
		var row: Dictionary = row_variant
		var task_id := str(row.get("task_id", "")).strip_edges()
		var rule_id := str(row.get("rule_id", "")).strip_edges()
		if task_id.is_empty() or rule_id.is_empty():
			continue
		grade_overrides.append(
			{
				"taskId": task_id,
				"ruleId": rule_id,
				"priority": _to_int(row.get("priority", "0"), 0),
				"fromGradeId": str(row.get("from_grade_id", "")).strip_edges(),
				"when": str(row.get("when", "")).strip_edges(),
				"toGradeId": str(row.get("to_grade_id", "")).strip_edges()
			}
		)

	var effects: Array = []
	for row_variant in effects_rows:
		var row: Dictionary = row_variant
		var task_id := str(row.get("task_id", "")).strip_edges()
		var status := str(row.get("status", "")).strip_edges()
		if task_id.is_empty() or status.is_empty():
			continue
		effects.append(
			{
				"taskId": task_id,
				"status": status,
				"gradeId": str(row.get("grade_id", "")).strip_edges(),
				"target": str(row.get("target", "")).strip_edges(),
				"op": str(row.get("op", "")).strip_edges(),
				"key": str(row.get("key", "")).strip_edges(),
				"value": str(row.get("value", "")).strip_edges()
			}
		)

	return {
		"ok": true,
		"task_evaluation": {
			"grades": grades,
			"indicators": indicators,
			"gradeOverrides": grade_overrides,
			"effects": effects
		}
	}


# 功能：校验任务评价配置的编译期约束。
# 说明：该校验属于里程碑 2，非法配置会在加载期阻断，避免进入运行时。
static func _validate_task_evaluation_tables(task_defs: Array, task_evaluation: Dictionary) -> Dictionary:
	var task_id_set: Dictionary = {}
	for task_variant in task_defs:
		var task_def: Dictionary = task_variant
		var task_id := str(task_def.get("id", "")).strip_edges()
		if task_id.is_empty():
			continue
		task_id_set[task_id] = true

	var grades: Array = task_evaluation.get("grades", [])
	var indicators: Array = task_evaluation.get("indicators", [])
	var grade_overrides: Array = task_evaluation.get("gradeOverrides", [])
	var effects: Array = task_evaluation.get("effects", [])

	var grade_key_guard: Dictionary = {}
	var grade_ids_by_task: Dictionary = {}
	var score_ranges_by_task: Dictionary = {}

	# 说明：先完成 grades 主校验，并构建后续引用校验所需的索引。
	for grade_variant in grades:
		var grade: Dictionary = grade_variant
		var task_id := str(grade.get("taskId", "")).strip_edges()
		var grade_id := str(grade.get("gradeId", "")).strip_edges()
		var grade_mode := str(grade.get("gradeMode", "")).strip_edges().to_lower()
		var min_score: Variant = grade.get("minScore", null)
		var max_score: Variant = grade.get("maxScore", null)

		if task_id.is_empty() or grade_id.is_empty():
			return {"ok": false, "error": "task_eval_grades has empty task_id or grade_id"}
		if not task_id_set.has(task_id):
			return {"ok": false, "error": "task_eval_grades references missing task_id: %s" % task_id}
		if grade_mode != "score_band" and grade_mode != "branch_only":
			return {"ok": false, "error": "task_eval_grades invalid grade_mode: %s/%s -> %s" % [task_id, grade_id, grade_mode]}

		var grade_key := "%s::%s" % [task_id, grade_id]
		if grade_key_guard.has(grade_key):
			return {"ok": false, "error": "task_eval_grades duplicate (task_id, grade_id): %s" % grade_key}
		grade_key_guard[grade_key] = true

		var grade_ids: Dictionary = grade_ids_by_task.get(task_id, {})
		grade_ids[grade_id] = true
		grade_ids_by_task[task_id] = grade_ids

		if grade_mode == "score_band":
			if min_score == null or max_score == null:
				return {"ok": false, "error": "task_eval_grades score_band requires min_score/max_score: %s/%s" % [task_id, grade_id]}
			if float(min_score) > float(max_score):
				return {"ok": false, "error": "task_eval_grades min_score > max_score: %s/%s" % [task_id, grade_id]}
			var ranges: Array = score_ranges_by_task.get(task_id, [])
			ranges.append({"gradeId": grade_id, "min": float(min_score), "max": float(max_score)})
			score_ranges_by_task[task_id] = ranges

	# 说明：按任务检查 score_band 区间是否重叠（闭区间）。
	for task_id_variant in score_ranges_by_task.keys():
		var task_id := str(task_id_variant)
		var ranges: Array = score_ranges_by_task.get(task_id, [])
		_sort_score_ranges_by_min(ranges)
		for idx in range(1, ranges.size()):
			var left: Dictionary = ranges[idx - 1]
			var right: Dictionary = ranges[idx]
			if float(right.get("min", 0.0)) <= float(left.get("max", 0.0)):
				return {
					"ok": false,
					"error": "task_eval_grades score_band overlap: %s/%s and %s" % [
						task_id,
						str(left.get("gradeId", "")),
						str(right.get("gradeId", ""))
					]
				}

	# 说明：校验指标表 task_id 存在性。
	for indicator_variant in indicators:
		var indicator: Dictionary = indicator_variant
		var task_id := str(indicator.get("taskId", "")).strip_edges()
		if task_id.is_empty():
			return {"ok": false, "error": "task_eval_indicators has empty task_id"}
		if not task_id_set.has(task_id):
			return {"ok": false, "error": "task_eval_indicators references missing task_id: %s" % task_id}

	# 说明：校验 override 的 task_id 和 grade 引用合法性。
	for override_variant in grade_overrides:
		var override_row: Dictionary = override_variant
		var task_id := str(override_row.get("taskId", "")).strip_edges()
		var rule_id := str(override_row.get("ruleId", "")).strip_edges()
		var from_grade_id := str(override_row.get("fromGradeId", "")).strip_edges()
		var to_grade_id := str(override_row.get("toGradeId", "")).strip_edges()
		if task_id.is_empty():
			return {"ok": false, "error": "task_eval_grade_overrides has empty task_id"}
		if not task_id_set.has(task_id):
			return {"ok": false, "error": "task_eval_grade_overrides references missing task_id: %s" % task_id}
		if to_grade_id.is_empty():
			return {"ok": false, "error": "task_eval_grade_overrides to_grade_id is empty: %s/%s" % [task_id, rule_id]}
		var task_grade_ids: Dictionary = grade_ids_by_task.get(task_id, {})
		if not task_grade_ids.has(to_grade_id):
			return {"ok": false, "error": "task_eval_grade_overrides to_grade_id not found: %s/%s -> %s" % [task_id, rule_id, to_grade_id]}
		if not from_grade_id.is_empty() and not task_grade_ids.has(from_grade_id):
			return {"ok": false, "error": "task_eval_grade_overrides from_grade_id not found: %s/%s -> %s" % [task_id, rule_id, from_grade_id]}

	# 说明：校验 effects 的 task_id、status 取值与 grade 引用。
	var allowed_status := {"completed": true, "failed": true, "abandoned": true}
	for effect_variant in effects:
		var effect: Dictionary = effect_variant
		var task_id := str(effect.get("taskId", "")).strip_edges()
		var status := str(effect.get("status", "")).strip_edges().to_lower()
		var grade_id := str(effect.get("gradeId", "")).strip_edges()
		if task_id.is_empty():
			return {"ok": false, "error": "task_eval_effects has empty task_id"}
		if not task_id_set.has(task_id):
			return {"ok": false, "error": "task_eval_effects references missing task_id: %s" % task_id}
		if not allowed_status.has(status):
			return {"ok": false, "error": "task_eval_effects invalid status: %s/%s" % [task_id, status]}
		if not grade_id.is_empty():
			var task_grade_ids: Dictionary = grade_ids_by_task.get(task_id, {})
			if not task_grade_ids.has(grade_id):
				return {"ok": false, "error": "task_eval_effects grade_id not found: %s -> %s" % [task_id, grade_id]}

	return {"ok": true}


# 功能：组装 choice_points 与 options 数据。
# 说明：新结构中不再单独维护 choice_points.csv，按 options.csv 自动归组。
# 【CSV 契约边界】本函数除处理 options / option_rules 外，还消费 option_outcomes.csv
# （事件叙事反馈 MVP A，设计基线见 [[事件叙事反馈_MVP设计]]）。option_outcomes 字段
# option_id / branch / seq / text，按 (option_id, branch) 分组、seq 升序，注入
# option["outcomes"][branch] = [text 数组] 供引擎在选项结算后追加为虚拟 presentation 屏。
static func _assemble_choice_points(tables: Dictionary) -> Dictionary:
	var option_rows: Array = tables.get("options.csv", [])
	var rule_rows: Array = tables.get("option_rules.csv", [])
	# 事件叙事反馈 MVP A：option_outcomes 为可选表（缺失时为空 [],兼容旧配置）。
	var outcome_rows: Array = tables.get("option_outcomes.csv", [])

	var cp_map: Dictionary = {}
	var cp_order: Array = []
	var option_ref: Dictionary = {}

	for row_variant in option_rows:
		var row: Dictionary = row_variant
		var option_id := str(row.get("option_id", "")).strip_edges()
		var cp_id := str(row.get("choice_point_id", "")).strip_edges()
		if option_id.is_empty() or cp_id.is_empty():
			continue
		if option_ref.has(option_id):
			return {"ok": false, "error": "duplicate option id: %s" % option_id}

		if not cp_map.has(cp_id):
			cp_map[cp_id] = {"id": cp_id, "options": []}
			cp_order.append(cp_id)

		# Line B S1 期新增 4 字段读取 (空值=default, 完全向后兼容):
		# - is_base: 是否基础选项必出 (空=false)
		# - weight: 候选池抽取权重 (空=1)
		# - trigger_condition: 触发门控表达式 (空=无门控)
		# - allow_desperate: 是否允许孤注一掷 (空=true, S5 期用)
		# 详见 [[前端骨架_LineB_实施]] §3.10。
		var is_base_str: String = str(row.get("is_base", "")).strip_edges().to_lower()
		var weight_str: String = str(row.get("weight", "")).strip_edges()
		var trigger_cond: String = str(row.get("trigger_condition", "")).strip_edges()
		var allow_desp_str: String = str(row.get("allow_desperate", "")).strip_edges().to_lower()

		var option = {
			"id": option_id,
			"text": str(row.get("text", "")),
			"eligibility": {},
			"cost": {},
			"check": null,
			"resolution": {
				"worldStatePatch": {},
				"forcedNextEventId": "",
				"chainContextPatch": {}
			},
			"_display_order": _to_int(row.get("display_order", "0"), 0),
			# Line B S3 字段 (向后兼容默认值):
			"is_base": is_base_str == "true",                # 空/false → false
			"weight": _to_int(weight_str, 1) if not weight_str.is_empty() else 1,
			"trigger_condition": trigger_cond,                # 空 → 无门控
			"allow_desperate": allow_desp_str != "false",    # 空/true → true; 仅 "false" → false
		}

		var cp_item: Dictionary = cp_map[cp_id]
		var options: Array = cp_item.get("options", [])
		options.append(option)
		cp_item["options"] = options
		cp_map[cp_id] = cp_item
		option_ref[option_id] = {"cp_id": cp_id, "index": options.size() - 1}

	for row_variant in rule_rows:
		var row: Dictionary = row_variant
		var option_id := str(row.get("option_id", "")).strip_edges()
		if option_id.is_empty() or not option_ref.has(option_id):
			continue
		_apply_option_rule_row(row, cp_map, option_ref)

	# 事件叙事反馈 MVP A：注入 option_outcomes 数据。
	# 中间结构：{ option_id: { branch: [{seq: int, text: String}, ...] } }
	var outcome_staging: Dictionary = {}
	for row_variant in outcome_rows:
		var row: Dictionary = row_variant
		var option_id: String = str(row.get("option_id", "")).strip_edges()
		var branch: String = str(row.get("branch", "")).strip_edges()
		var seq_text: String = str(row.get("seq", "")).strip_edges()
		# 叙事 text 统一经 _load_narrative_text 读取（装配层规约转义入口，含 \n unescape）。
		var text: String = _load_narrative_text(row)
		if option_id.is_empty() or branch.is_empty() or text.strip_edges().is_empty():
			continue
		if not option_ref.has(option_id):
			# 静默跳过未知 option_id 的 outcome 行，由 csv_validator 静态检查捕获 FK 错误。
			continue
		if seq_text.is_empty() or not seq_text.is_valid_int():
			continue
		var seq_value: int = int(seq_text)
		if not outcome_staging.has(option_id):
			outcome_staging[option_id] = {}
		var by_branch: Dictionary = outcome_staging[option_id]
		if not by_branch.has(branch):
			by_branch[branch] = []
		var entries: Array = by_branch[branch]
		entries.append({"seq": seq_value, "text": text})
		by_branch[branch] = entries
		outcome_staging[option_id] = by_branch

	# 排序并扁平化为 outcomes: { branch: [text, ...] }，写回对应 option dict。
	for option_id_variant in outcome_staging.keys():
		var option_id_key: String = str(option_id_variant)
		var by_branch: Dictionary = outcome_staging[option_id_key]
		var outcomes_out: Dictionary = {}
		for branch_variant in by_branch.keys():
			var branch_key: String = str(branch_variant)
			var entries: Array = by_branch[branch_key]
			entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return int(a.get("seq", 0)) < int(b.get("seq", 0))
			)
			var texts_out: Array = []
			for entry_variant in entries:
				var entry: Dictionary = entry_variant
				texts_out.append(str(entry.get("text", "")))
			outcomes_out[branch_key] = texts_out
		# 按 option_ref 索引找到 cp_map 中对应 option dict 写回 outcomes 字段。
		var ref: Dictionary = option_ref[option_id_key]
		var cp_id: String = str(ref.get("cp_id", ""))
		var idx: int = int(ref.get("index", -1))
		if cp_id.is_empty() or idx < 0:
			continue
		var cp_item: Dictionary = cp_map[cp_id]
		var options_arr: Array = cp_item.get("options", [])
		if idx >= options_arr.size():
			continue
		var option_dict: Dictionary = options_arr[idx]
		option_dict["outcomes"] = outcomes_out
		options_arr[idx] = option_dict
		cp_item["options"] = options_arr
		cp_map[cp_id] = cp_item

	var out_choice_points: Array = []
	for cp_id_variant in cp_order:
		var cp_id := str(cp_id_variant)
		var cp_item: Dictionary = cp_map[cp_id]
		var options: Array = cp_item.get("options", [])
		_sort_options_by_display_order(options)
		for idx in options.size():
			var option: Dictionary = options[idx]
			option.erase("_display_order")
			options[idx] = option
		cp_item["options"] = options
		out_choice_points.append(cp_item)

	var choice_point_ids: Dictionary = {}
	for cp_id_variant in cp_order:
		choice_point_ids[str(cp_id_variant)] = true

	return {
		"ok": true,
		"choice_points": out_choice_points,
		"choice_point_ids": choice_point_ids
	}


# 功能：组装 events 数据并做 choice point 外键校验。
# 说明：事件主表负责提供基础字段，条件表、后果表与展示表会在后续步骤增量回填。
static func _assemble_events(tables: Dictionary, choice_point_ids: Dictionary) -> Dictionary:
	var event_rows: Array = tables.get("events.csv", [])
	var condition_rows: Array = tables.get("event_conditions.csv", [])
	var outcome_rows: Array = tables.get("event_outcomes.csv", [])
	var presentation_rows: Array = tables.get("event_presentations.csv", [])

	var event_map: Dictionary = {}
	var event_order: Array = []

	for row_variant in event_rows:
		var row: Dictionary = row_variant
		var event_id := str(row.get("event_id", "")).strip_edges()
		if event_id.is_empty():
			continue
		if event_map.has(event_id):
			return {"ok": false, "error": "duplicate event id: %s" % event_id}

		# 功能：解析事件类型字段。
		# 说明：type 为空或缺省时视为普通事件；"reflection" 表示自省事件，结算时路由到状态机。
		var event_type := str(row.get("type", "")).strip_edges()
		var event_def = {
			"id": event_id,
			"title": str(row.get("title", "")),
			"backgroundArt": _build_background_art_path(str(row.get("background_art", ""))),
			"baseWeight": _to_int(row.get("base_weight", "10"), 10),
			"tags": _split_text_list(str(row.get("tags", "")), ";"),
			"taskLinks": _split_text_list(str(row.get("task_links", "")), ";"),
			# 功能：标记当前事件是否为世界结束事件。
			# 说明：MVP 阶段由事件主表直接声明，避免为 ending event 额外拆表。
			"isEndingEvent": _to_bool(row.get("is_ending_event", "")),
			"eligibility": {},
			"weightRules": [],
			"continuationPolicy": str(row.get("continuation_policy", "ReturnToScheduler")),
			"effects": {},
			"presentation": []
		}
		# 功能：仅在 type 非空时写入 event_def，避免普通事件携带多余字段。
		if not event_type.is_empty():
			event_def["type"] = event_type

		var cp_id := str(row.get("choice_point_id", "")).strip_edges()
		if not cp_id.is_empty():
			if not choice_point_ids.has(cp_id):
				return {"ok": false, "error": "event references missing choice point: %s -> %s" % [event_id, cp_id]}
			event_def["choicePointId"] = cp_id

		event_map[event_id] = event_def
		event_order.append(event_id)

	var ending_validate_result := _validate_ending_event_constraints(event_map)
	if not ending_validate_result.get("ok", false):
		return ending_validate_result

	for row_variant in condition_rows:
		var row: Dictionary = row_variant
		var event_id := str(row.get("event_id", "")).strip_edges()
		if event_id.is_empty() or not event_map.has(event_id):
			continue
		_apply_event_condition_row(event_map[event_id], row)

	for row_variant in outcome_rows:
		var row: Dictionary = row_variant
		var event_id := str(row.get("event_id", "")).strip_edges()
		if event_id.is_empty() or not event_map.has(event_id):
			continue
		_apply_event_outcome_row(event_map[event_id], row)

	var presentation_result := _apply_event_presentations(event_map, presentation_rows)
	if not presentation_result.get("ok", false):
		return presentation_result

	var events: Array = []
	for event_id_variant in event_order:
		var event_def: Dictionary = event_map[str(event_id_variant)]
		# 说明：空补丁和空展示数组都不写入最终产物，避免运行时额外做空值分支。
		if event_def.has("chainPatch"):
			var patch: Dictionary = event_def.get("chainPatch", {})
			if patch.is_empty():
				event_def.erase("chainPatch")
		if event_def.has("presentation"):
			var presentation: Array = event_def.get("presentation", [])
			if presentation.is_empty():
				event_def.erase("presentation")
		events.append(event_def)

	return {"ok": true, "events": events}


# 功能：校验 ending event 的编译期约束。
# 说明：当前 MVP 阶段结束事件禁止绑定 choice point，避免终局流程产生选项分叉。
static func _validate_ending_event_constraints(event_map: Dictionary) -> Dictionary:
	for event_id_variant in event_map.keys():
		var event_id := str(event_id_variant).strip_edges()
		var event_def: Dictionary = event_map[event_id]
		if not bool(event_def.get("isEndingEvent", false)):
			continue
		var choice_point_id := str(event_def.get("choicePointId", "")).strip_edges()
		if not choice_point_id.is_empty():
			return {
				"ok": false,
				"error": "ending event must not reference choice point: %s -> %s" % [event_id, choice_point_id]
			}
	return {"ok": true}


# 功能：将事件展示项编译到对应事件定义中。
# 说明：当前 MVP 只支持 text 类型展示项，并在编译期完成基础校验、去重与排序。
static func _apply_event_presentations(event_map: Dictionary, rows: Array) -> Dictionary:
	# 【CSV 契约边界】需求 2 — presentation condition 字段装配入口。
	# 来源: Design/配置翻译指南.md 锚点 presentation_condition（新增）。
	# 引擎消费侧：world_event_engine.gd::_get_event_presentation_filtered（按 world_state
	# 过滤 condition，只返回满足条件的行；空 condition = 通用 fallback 行）。
	# 改动本函数时必须同步回看：配置翻译指南锚点 / csv_validator.py / 引擎过滤函数。
	var used_presentation_ids: Dictionary = {}
	for row_variant in rows:
		var row: Dictionary = row_variant
		var event_id := str(row.get("event_id", "")).strip_edges()
		var presentation_id := str(row.get("presentation_id", "")).strip_edges()
		var display_order_text := str(row.get("display_order", "")).strip_edges()
		var item_type := str(row.get("item_type", "")).strip_edges()
		# 叙事 text 统一经 _load_narrative_text 读取（装配层规约转义入口，含 \n unescape）。
		var text := _load_narrative_text(row).strip_edges()
		if event_id.is_empty() and presentation_id.is_empty() and display_order_text.is_empty() and item_type.is_empty() and text.is_empty():
			continue
		if event_id.is_empty():
			return {"ok": false, "error": "event presentation row missing event_id"}
		if not event_map.has(event_id):
			return {"ok": false, "error": "event presentation references missing event: %s" % event_id}
		if presentation_id.is_empty():
			return {"ok": false, "error": "event presentation missing presentation_id: %s" % event_id}
		if used_presentation_ids.has(presentation_id):
			return {"ok": false, "error": "duplicate presentation id: %s" % presentation_id}
		if display_order_text.is_empty() or not display_order_text.is_valid_int() or int(display_order_text) <= 0:
			return {"ok": false, "error": "event presentation display_order must be positive int: %s" % presentation_id}
		if item_type != "text":
			return {"ok": false, "error": "unsupported presentation item_type: %s" % item_type}
		if text.is_empty():
			return {"ok": false, "error": "event presentation text is empty: %s" % presentation_id}

		# Step 2 新增：presents 字段表达 presentation 行承担的 UI 功能（设计基线见
		# [[当前版本完整主路径_MVP设计]] §三·节点 2 "Step 2 实施落地细节"）。
		# 合法值见 [[配置翻译指南]] 锚点 presents_values；空 / 缺省 → 默认 "text"。
		# 引擎仅识别白名单内的值；非白名单值降级为 "text" 并保留警告（不阻断加载）。
		var presents_raw := str(row.get("presents", "")).strip_edges()
		var presents := presents_raw if not presents_raw.is_empty() else "text"
		var allowed_presents: Array = ["text", "location_select", "adjust_relation", "focus_select", "focus_remove"]
		if not (presents in allowed_presents):
			push_warning("event_presentations: unknown presents '%s' on %s, fallback to 'text'" % [presents, presentation_id])
			presents = "text"

		# 需求 2 新增：condition 字段（空 = 通用 fallback 行；非空 = 按 world_state 过滤）。
		# 语法与 event_conditions.csv 的 weight_rule 表达式一致：
		#   `<world_state_path> <op> "<value>"` 例：last_consumed_skeleton_event_id == "evt_s2_sk_he"
		# 引擎过滤逻辑见 world_event_engine.gd::_get_event_presentation_filtered。
		var condition := str(row.get("condition", "")).strip_edges()

		used_presentation_ids[presentation_id] = true
		var event_def: Dictionary = event_map[event_id]
		var presentation: Array = event_def.get("presentation", [])
		presentation.append(
			{
				"id": presentation_id,
				"order": int(display_order_text),
				"type": item_type,
				"speaker": str(row.get("speaker", "")).strip_edges(),
				"text": text,
				"presents": presents,
				"condition": condition
			}
		)
		_sort_presentation_items(presentation)
		event_def["presentation"] = presentation
		event_map[event_id] = event_def
	return {"ok": true}


# 功能：应用单行事件条件。
# 说明：同一事件允许出现多行同类型条件，编译时会按类型聚合为 eligibility 或 weightRules。
static func _apply_event_condition_row(event_def: Dictionary, row: Dictionary) -> void:
	var condition_type := str(row.get("condition_type", "")).strip_edges()
	var left := str(row.get("left", "")).strip_edges()
	var op := str(row.get("op", "")).strip_edges()
	var right := str(row.get("right", "")).strip_edges()
	var delta_text := str(row.get("delta", "")).strip_edges()

	if condition_type.is_empty():
		return

	if condition_type == "required_location":
		if right.is_empty():
			return
		var eligibility_a: Dictionary = event_def.get("eligibility", {})
		var locations: Array = eligibility_a.get("requiredLocations", [])
		locations.append(right)
		eligibility_a["requiredLocations"] = locations
		event_def["eligibility"] = eligibility_a
		return

	if condition_type == "required_npc":
		if right.is_empty():
			return
		var eligibility_b: Dictionary = event_def.get("eligibility", {})
		var npcs: Array = eligibility_b.get("requiredNPCsPresent", [])
		npcs.append(right)
		eligibility_b["requiredNPCsPresent"] = npcs
		event_def["eligibility"] = eligibility_b
		return

	if condition_type == "required_location_flag":
		if left.is_empty():
			return
		var eligibility_c: Dictionary = event_def.get("eligibility", {})
		var clauses: Array = eligibility_c.get("requiredLocationFlags", [])
		clauses.append({"key": left, "op": op if not op.is_empty() else "==", "value": _parse_literal(right)})
		eligibility_c["requiredLocationFlags"] = clauses
		event_def["eligibility"] = eligibility_c
		return

	# 说明：世界级 flag 硬过滤，用于实现一次性事件等需要全局状态判断的场景。
	if condition_type == "required_flag":
		if left.is_empty():
			return
		var eligibility_d: Dictionary = event_def.get("eligibility", {})
		var flag_clauses: Array = eligibility_d.get("requiredFlags", [])
		flag_clauses.append({"key": left, "op": op if not op.is_empty() else "==", "value": _parse_literal(right)})
		eligibility_d["requiredFlags"] = flag_clauses
		event_def["eligibility"] = eligibility_d
		return

	if condition_type == "weight_rule":
		if left.is_empty() or op.is_empty() or right.is_empty():
			return
		var rules: Array = event_def.get("weightRules", [])
		rules.append({"when": "%s %s %s" % [left, op, right], "delta": _to_int(delta_text, 0)})
		event_def["weightRules"] = rules


# 功能：应用单行事件后果。
# 说明：branch 当前仅处理 default，其他分支预留给未来扩展。
static func _apply_event_outcome_row(event_def: Dictionary, row: Dictionary) -> void:
	var branch := str(row.get("branch", "default")).strip_edges()
	if not branch.is_empty() and branch != "default":
		return

	var target := str(row.get("target", "")).strip_edges()
	var op := str(row.get("op", "")).strip_edges()
	var key := str(row.get("key", "")).strip_edges()
	var value_text := str(row.get("value", "")).strip_edges()

	if target == "chain_context" and op == "patch":
		var patch: Dictionary = event_def.get("chainPatch", {})
		_apply_chain_patch_item(patch, key, value_text)
		event_def["chainPatch"] = patch
		return

	var effects: Dictionary = event_def.get("effects", {})
	_apply_effect_or_resolution_action(effects, target, op, key, value_text)
	event_def["effects"] = effects


# 功能：应用单行选项规则。
# 说明：branch 当前仅在 resolution 下识别 fail；空值与其他值都按默认结算处理。
static func _apply_option_rule_row(row: Dictionary, cp_map: Dictionary, option_ref: Dictionary) -> void:
	var option_id := str(row.get("option_id", "")).strip_edges()
	var ref: Dictionary = option_ref[option_id]
	var cp_id := str(ref.get("cp_id", ""))
	var index := int(ref.get("index", -1))
	if index < 0 or not cp_map.has(cp_id):
		return

	var cp_item: Dictionary = cp_map[cp_id]
	var options: Array = cp_item.get("options", [])
	if index >= options.size():
		return

	var option: Dictionary = options[index]
	var rule_type := str(row.get("rule_type", "")).strip_edges()
	var branch := str(row.get("branch", "")).strip_edges()
	var left := str(row.get("left", "")).strip_edges()
	var op := str(row.get("op", "")).strip_edges()
	var right := str(row.get("right", "")).strip_edges()
	var target := str(row.get("target", "")).strip_edges()
	var key := str(row.get("key", "")).strip_edges()
	var value_text := str(row.get("value", "")).strip_edges()

	if rule_type == "visibility":
		if not left.is_empty() and not op.is_empty() and not right.is_empty():
			var visibility_when: Array = option.get("visibilityWhen", [])
			visibility_when.append("%s %s %s" % [left, op, right])
			option["visibilityWhen"] = visibility_when
	elif rule_type == "eligibility":
		if not left.is_empty():
			var eligibility: Dictionary = option.get("eligibility", {})
			if op.is_empty():
				eligibility[left] = right
			else:
				eligibility[left] = op + right
			option["eligibility"] = eligibility
	elif rule_type == "cost":
		if not key.is_empty():
			var cost: Dictionary = option.get("cost", {})
			cost[key] = _to_int(value_text, 0)
			option["cost"] = cost
	elif rule_type == "check":
		var check_variant: Variant = option.get("check", {})
		var check: Dictionary = {}
		if typeof(check_variant) == TYPE_DICTIONARY and check_variant != null:
			check = check_variant
		if key == "type":
			check["type"] = value_text
		elif key == "successRate":
			check["successRate"] = _to_float(value_text, 1.0)
		elif key == "hitThreshold":
			# 骰池命中阈值：单颗 d10 ≥ 该值算命中
			check["hitThreshold"] = _to_int(value_text, 6)
		elif key == "requiredHits":
			# 骰池需要命中数：凑够该数量算通过
			check["requiredHits"] = _to_int(value_text, 1)
		elif key == "items":
			# 鉴定参与项，格式：key:direction;key:direction
			check["items"] = _parse_assessment_items(value_text)
		elif key == "relationshipNpcs":
			# 关系修正 NPC 列表，格式：npc_id:difficulty;npc_id:difficulty
			check["relationshipNpcs"] = _parse_relationship_npcs(value_text)
		option["check"] = check
	elif rule_type == "preemptive_bet":
		# 说明：主动押注配置，写入 option.preemptiveBet。
		# target == "disabled" 时，标记该选项关闭主动押注（不走全局默认）。
		# target == "bet_modifier" 时，key 为 bias 字段名（successBias 等），写入 biasModifiers 子字典，覆盖全局默认。
		# target == "cost_override" 时，key 为资源名（如 energy），写入 costOverride 子字典，覆盖全局默认代价。
		# 其他 target（如 player）走 _apply_effect_or_resolution_action，写入 worldStatePatch，押注前由引擎预应用。
		var preemptive_bet: Dictionary = option.get("preemptiveBet", {})
		if target == "disabled":
			preemptive_bet["disabled"] = true
		elif target == "bet_modifier":
			if not key.is_empty():
				var bias_modifiers: Dictionary = preemptive_bet.get("biasModifiers", {})
				bias_modifiers[key] = _to_int(value_text, 0)
				preemptive_bet["biasModifiers"] = bias_modifiers
		elif target == "cost_override":
			if not key.is_empty():
				var cost_override: Dictionary = preemptive_bet.get("costOverride", {})
				cost_override[key] = _to_int(value_text, 0)
				preemptive_bet["costOverride"] = cost_override
		else:
			_apply_effect_or_resolution_action(preemptive_bet, target, op, key, value_text)
		option["preemptiveBet"] = preemptive_bet
	elif rule_type == "resolution":
		if branch == "fail":
			var fail_check_variant: Variant = option.get("check", {})
			var fail_check: Dictionary = {}
			if typeof(fail_check_variant) == TYPE_DICTIONARY and fail_check_variant != null:
				fail_check = fail_check_variant
			var fail_resolution: Dictionary = fail_check.get(
				"onFailResolution",
				{
					"worldStatePatch": {},
					"forcedNextEventId": "",
					"chainContextPatch": {}
				}
			)
			_apply_effect_or_resolution_action(fail_resolution, target, op, key, value_text)
			fail_check["onFailResolution"] = fail_resolution
			option["check"] = fail_check
		elif branch == "critical_success":
			# 说明：大成功分支，解析并写入 check.onCriticalSuccessResolution。
			var cs_check_variant: Variant = option.get("check", {})
			var cs_check: Dictionary = {}
			if typeof(cs_check_variant) == TYPE_DICTIONARY and cs_check_variant != null:
				cs_check = cs_check_variant
			var cs_resolution: Dictionary = cs_check.get(
				"onCriticalSuccessResolution",
				{
					"worldStatePatch": {},
					"forcedNextEventId": "",
					"chainContextPatch": {}
				}
			)
			_apply_effect_or_resolution_action(cs_resolution, target, op, key, value_text)
			cs_check["onCriticalSuccessResolution"] = cs_resolution
			option["check"] = cs_check
		elif branch == "critical_fail":
			# 说明：大失败分支，解析并写入 check.onCriticalFailResolution。
			var cf_check_variant: Variant = option.get("check", {})
			var cf_check: Dictionary = {}
			if typeof(cf_check_variant) == TYPE_DICTIONARY and cf_check_variant != null:
				cf_check = cf_check_variant
			var cf_resolution: Dictionary = cf_check.get(
				"onCriticalFailResolution",
				{
					"worldStatePatch": {},
					"forcedNextEventId": "",
					"chainContextPatch": {}
				}
			)
			_apply_effect_or_resolution_action(cf_resolution, target, op, key, value_text)
			cf_check["onCriticalFailResolution"] = cf_resolution
			option["check"] = cf_check
		else:
			var resolution: Dictionary = option.get("resolution", {})
			_apply_effect_or_resolution_action(resolution, target, op, key, value_text)
			option["resolution"] = resolution

	options[index] = option
	cp_item["options"] = options
	cp_map[cp_id] = cp_item


# 【CSV 契约边界】本函数是 CSV 配置契约三件套的"引擎消费"端。
# target 路由分支是 CSV 翻译的契约真源参考之一。修改、新增、删除本函数的 target 分支时，
# 必须同步回看：
#   1. Design/配置翻译指南.md（锚点 resolution_target_routing 的 target 路由总表）
#   2. tools/csv_translator.py::parse_effect_expression（自动翻译产出）
#   3. tools/csv_validator.py（target/key 校验规则，特别是规则 7 与 KNOWN_RULE_TYPES）
# 详见项目 CLAUDE.md 的 "CSV 契约三件套" 规则段。
#
# 功能：统一应用 effects 与 resolution 行为动作。
# 说明：事件 effects 与选项 resolution 共享 target/op/key/value 语义，复用该函数。
static func _apply_effect_or_resolution_action(container: Dictionary, target: String, op: String, key: String, value_text: String) -> void:
	if target == "params" and op == "add":
		var params_patch: Dictionary = container.get("addParams", container.get("worldStatePatch", {}).get("params", {}))
		params_patch[key] = int(params_patch.get(key, 0)) + _to_int(value_text, 0)
		if container.has("worldStatePatch"):
			var world_patch_a: Dictionary = container.get("worldStatePatch", {})
			world_patch_a["params"] = params_patch
			container["worldStatePatch"] = world_patch_a
		else:
			container["addParams"] = params_patch
		return

	if target == "flags" and op == "set":
		var flags_patch: Dictionary = container.get("setFlags", container.get("worldStatePatch", {}).get("flags", {}))
		flags_patch[key] = _parse_literal(value_text)
		if container.has("worldStatePatch"):
			var world_patch_b: Dictionary = container.get("worldStatePatch", {})
			world_patch_b["flags"] = flags_patch
			container["worldStatePatch"] = world_patch_b
		else:
			container["setFlags"] = flags_patch
		return

	if target == "world" and op == "set_location":
		if container.has("worldStatePatch"):
			var world_patch_c: Dictionary = container.get("worldStatePatch", {})
			world_patch_c["currentLocationId"] = value_text
			container["worldStatePatch"] = world_patch_c
		else:
			container["setLocation"] = value_text
		return

	if target == "world" and op == "set_forced_next":
		container["forcedNextEventId"] = value_text
		return

	if target == "world" and op == "end_chain":
		container["endChain"] = _to_bool(value_text)
		return

	if target == "world" and op == "clear_forced_next":
		container["clearForcedNext"] = _to_bool(value_text)
		return

	if target == "player" and op == "add":
		# 说明：玩家属性/资源增量，写入 worldStatePatch.player，供引擎通过 _apply_world_state_patch 消费。
		var world_patch_p: Dictionary = container.get("worldStatePatch", {})
		var player_patch: Dictionary = world_patch_p.get("player", {})
		player_patch[key] = int(player_patch.get(key, 0)) + _to_int(value_text, 0)
		world_patch_p["player"] = player_patch
		container["worldStatePatch"] = world_patch_p
		return

	if target == "affinity" and key == "affinityDeltas":
		# 说明：关系变化配置，格式为 "from->to:delta;from->to:delta"。
		container["affinityDeltas"] = _parse_affinity_deltas(value_text)
		return

	if target == "chain_context" and op == "patch":
		var chain_patch: Dictionary = container.get("chainContextPatch", {})
		_apply_chain_patch_item(chain_patch, key, value_text)
		container["chainContextPatch"] = chain_patch
		return

	if target == "focus":
		# 说明：关注列表修改动作。op 为 add/remove/set，value_text 为分号分隔的 NPC ID。
		var focus_patch: Dictionary = {"op": op}
		var npcs: Array = []
		if not value_text.is_empty():
			for npc_id in value_text.split(";"):
				var trimmed: String = npc_id.strip_edges()
				if not trimmed.is_empty():
					npcs.append(trimmed)
		focus_patch["npcs"] = npcs
		container["focusPatch"] = focus_patch
		return

	if target == "task":
		var task_action := _build_task_action(op, key, value_text)
		if task_action.is_empty():
			return
		var task_actions: Array = container.get("taskActions", [])
		task_actions.append(task_action)
		container["taskActions"] = task_actions


# 功能：构建任务动作编译结果。
# 说明：统一将 CSV target=task 的一行映射为运行时可执行的动作对象。
static func _build_task_action(op: String, key: String, value_text: String) -> Dictionary:
	var normalized_op := op.strip_edges()
	if normalized_op.is_empty():
		return {}

	var task_id := key.strip_edges()
	if task_id.is_empty():
		task_id = value_text.strip_edges()

	match normalized_op:
		"accept_task", "abandon_task", "complete_task":
			if task_id.is_empty():
				return {}
			return {
				"op": normalized_op,
				"taskId": task_id
			}
		"advance_task":
			if task_id.is_empty():
				return {}
			var payload := _parse_advance_task_payload(value_text)
			return {
				"op": normalized_op,
				"taskId": task_id,
				"progressKey": payload.get("progressKey", "progress"),
				"delta": int(payload.get("delta", 1))
			}
		_:
			return {}


# 功能：解析 advance_task 的 value 文本。
# 说明：支持 "key:delta"、"key,delta"、"delta" 三种写法。
static func _parse_advance_task_payload(value_text: String) -> Dictionary:
	var text := value_text.strip_edges()
	if text.is_empty():
		return {"progressKey": "progress", "delta": 1}

	if text.is_valid_int():
		return {"progressKey": "progress", "delta": _to_int(text, 1)}

	var split_token := ":"
	if text.find(":") == -1 and text.find(",") != -1:
		split_token = ","
	if text.find(split_token) != -1:
		var parts := text.split(split_token, false, 1)
		var progress_key := str(parts[0]).strip_edges()
		var delta_text := ""
		if parts.size() > 1:
			delta_text = str(parts[1]).strip_edges()
		if progress_key.is_empty():
			progress_key = "progress"
		return {"progressKey": progress_key, "delta": _to_int(delta_text, 1)}

	return {"progressKey": text, "delta": 1}


# 功能：应用 chain patch 单项。
# 说明：兼容 allowedTags/weightBias 的 JSON 文本与拆分字段写法。
static func _apply_chain_patch_item(patch: Dictionary, key: String, value_text: String) -> void:
	if key.is_empty():
		return

	if key == "chainId":
		patch[key] = value_text
		return
	if key == "stage" or key == "stageDelta" or key == "exitWhenStageGte":
		patch[key] = _to_int(value_text, 0)
		return

	if key == "allowedTags":
		# 仅当 value_text 形似 JSON 数组（以 [ 起始）才走 JSON.parse_string；否则直接 fallback。
		# 直接调用 JSON.parse_string 解析非 JSON 字符串会触发 Godot 引擎层 stderr ERROR 副作用，
		# 污染调试日志。CSV 中实际通用写法是 "chain;shi" 这种 ; 分隔字符串。
		var stripped_tags := value_text.strip_edges()
		if stripped_tags.begins_with("["):
			var parsed_tags: Variant = JSON.parse_string(stripped_tags)
			if typeof(parsed_tags) == TYPE_ARRAY:
				patch[key] = parsed_tags
				return
		patch[key] = _split_text_list(value_text, ";")
		return

	if key == "weightBias":
		# 同 allowedTags：仅当形似 JSON 字典（以 { 起始）才走 JSON.parse_string；否则跳过赋值。
		var stripped_bias := value_text.strip_edges()
		if stripped_bias.begins_with("{"):
			var parsed_bias: Variant = JSON.parse_string(stripped_bias)
			if typeof(parsed_bias) == TYPE_DICTIONARY:
				patch[key] = parsed_bias
		return

	if key.begins_with("weightBias."):
		var tag := key.trim_prefix("weightBias.")
		if tag.is_empty():
			return
		var bias: Dictionary = patch.get("weightBias", {})
		bias[tag] = _to_int(value_text, 0)
		patch["weightBias"] = bias
		return

	patch[key] = _parse_literal(value_text)


# 功能：从 world_seed 的 chain section 提取 chainContext。
# 说明：当 chain_id 为空时返回 null，表示初始世界不进入链式上下文。
static func _build_chain_context_from_seed(chain_seed: Dictionary) -> Variant:
	var chain_id := str(chain_seed.get("chain_id", "")).strip_edges()
	if chain_id.is_empty():
		return null

	var ctx = {
		"chainId": chain_id,
		"stage": _to_int(chain_seed.get("stage", "1"), 1),
		"allowedTags": [],
		"weightBias": {},
		"exitWhenStageGte": _to_int(chain_seed.get("exit_when_stage_gte", "0"), 0)
	}

	var tags_text := str(chain_seed.get("allowed_tags_json", "")).strip_edges()
	if not tags_text.is_empty():
		var parsed_tags: Variant = JSON.parse_string(tags_text)
		if typeof(parsed_tags) == TYPE_ARRAY:
			ctx["allowedTags"] = parsed_tags

	var bias_text := str(chain_seed.get("weight_bias_json", "")).strip_edges()
	if not bias_text.is_empty():
		var parsed_bias: Variant = JSON.parse_string(bias_text)
		if typeof(parsed_bias) == TYPE_DICTIONARY:
			ctx["weightBias"] = parsed_bias

	return ctx


# 功能：按 display_order 升序排序选项。
static func _sort_options_by_display_order(options: Array) -> void:
	for i in range(1, options.size()):
		var current: Dictionary = options[i]
		var current_order := int(current.get("_display_order", 0))
		var j := i - 1
		while j >= 0:
			var left: Dictionary = options[j]
			if int(left.get("_display_order", 0)) <= current_order:
				break
			options[j + 1] = options[j]
			j -= 1
		options[j + 1] = current


# 功能：按展示顺序升序排序事件展示项。
# 说明：这里复用插入排序，保持与选项、历史记录相同的稳定排序行为。
static func _sort_presentation_items(items: Array) -> void:
	for i in range(1, items.size()):
		var current: Dictionary = items[i]
		var current_order := int(current.get("order", 0))
		var j := i - 1
		while j >= 0:
			var left: Dictionary = items[j]
			if int(left.get("order", 0)) <= current_order:
				break
			items[j + 1] = items[j]
			j -= 1
		items[j + 1] = current


static func _sort_history_pairs(history_pairs: Array) -> void:
	for i in range(1, history_pairs.size()):
		var current: Dictionary = history_pairs[i]
		var current_seq = int(current.get("seq", 0))
		var j = i - 1
		while j >= 0:
			var left: Dictionary = history_pairs[j]
			if int(left.get("seq", 0)) <= current_seq:
				break
			history_pairs[j + 1] = history_pairs[j]
			j -= 1
		history_pairs[j + 1] = current


# 功能：按 score range 的 min 字段升序排序。
# 说明：用于区间重叠校验，保证相邻比较即可覆盖全部冲突。
static func _sort_score_ranges_by_min(ranges: Array) -> void:
	for i in range(1, ranges.size()):
		var current: Dictionary = ranges[i]
		var current_min := float(current.get("min", 0.0))
		var j := i - 1
		while j >= 0:
			var left: Dictionary = ranges[j]
			if float(left.get("min", 0.0)) <= current_min:
				break
			ranges[j + 1] = ranges[j]
			j -= 1
		ranges[j + 1] = current


# 功能：按分隔符拆分文本数组，并去除空项。
static func _split_text_list(text: String, sep: String) -> Array:
	var out: Array = []
	for item in text.split(sep, false):
		var normalized := str(item).strip_edges()
		if not normalized.is_empty():
			out.append(normalized)
	return out


# 功能：将背景文件名转换为完整资源路径。
# 说明：保持配置层只感知文件名，避免业务表硬编码完整路径。
static func _build_background_art_path(file_name: String) -> String:
	var normalized := file_name.strip_edges()
	if normalized.is_empty():
		return ""
	return "%s/%s" % [EVENT_BACKGROUND_BASE_DIR, normalized]


# 功能：拼接配置目录与文件名。
# 说明：兼容传入目录结尾已带 / 或 \ 的情况。
static func _join_path(base: String, file_name: String) -> String:
	if base.ends_with("/") or base.ends_with("\\"):
		return base + file_name
	return base + "/" + file_name


# 功能：将输入安全转换为 int。
# 说明：空字符串或非法数字时回退到默认值。
static func _to_int(value: Variant, default_value: int) -> int:
	var text = str(value).strip_edges()
	if text.is_empty():
		return default_value
	if text.is_valid_int():
		return int(text)
	return default_value


# 功能：将输入安全转换为 float。
# 说明：空字符串或非法数字时回退到默认值。
static func _to_float(value: Variant, default_value: float) -> float:
	var text = str(value).strip_edges()
	if text.is_empty():
		return default_value
	if text.is_valid_float():
		return float(text)
	return default_value


# 功能：将输入安全转换为可选数值。
# 说明：空字符串返回 null，用于支持 branch_only 档位空区间语义。
static func _parse_optional_number(value: Variant) -> Variant:
	var text := str(value).strip_edges()
	if text.is_empty():
		return null
	if text.is_valid_int():
		return int(text)
	if text.is_valid_float():
		return float(text)
	return null


# 功能：将输入转换为 bool。
# 说明：当前仅将文本 true 识别为 true，其余值统一视为 false。
static func _to_bool(value: Variant) -> bool:
	return str(value).strip_edges().to_lower() == "true"


# 功能：将 CSV 字面量文本解析为运行时值。
# 说明：支持 bool、int、float，其他内容保留为原始字符串。
static func _parse_literal(value: String) -> Variant:
	var text = value.strip_edges()
	if text.is_empty():
		return ""
	var lowered = text.to_lower()
	if lowered == "true":
		return true
	if lowered == "false":
		return false
	if text.is_valid_int():
		return int(text)
	if text.is_valid_float():
		return float(text)
	return text


# 功能：解析鉴定参与项文本为结构化数组。
# 说明：输入格式为 "key:direction;key:direction"，例如 "physique:positive;energy:negative"。
static func _parse_assessment_items(text: String) -> Array:
	var items: Array = []
	for segment in text.split(";", false):
		var trimmed := segment.strip_edges()
		if trimmed.is_empty():
			continue
		var parts := trimmed.split(":", false, 1)
		var item_key := str(parts[0]).strip_edges()
		var item_direction := "positive"
		if parts.size() > 1:
			item_direction = str(parts[1]).strip_edges()
		if not item_key.is_empty():
			items.append({"key": item_key, "direction": item_direction})
	return items


# 功能：解析关系修正 NPC 配置文本为结构化数组。
# 说明：输入格式为 "npc_id:difficulty;npc_id:difficulty"。
static func _parse_relationship_npcs(text: String) -> Array:
	var npcs: Array = []
	for segment in text.split(";", false):
		var trimmed := segment.strip_edges()
		if trimmed.is_empty():
			continue
		var parts := trimmed.split(":", false, 1)
		var npc_id := str(parts[0]).strip_edges()
		var difficulty := 0
		if parts.size() > 1:
			difficulty = _to_int(str(parts[1]).strip_edges(), 0)
		if not npc_id.is_empty():
			npcs.append({"npc_id": npc_id, "difficulty": difficulty})
	return npcs


# 功能：解析关系变化配置文本为结构化数组。
# 说明：输入格式为 "from->to:delta;from->to:delta"，例如 "player->npc_mentor:+10;npc_mentor->player:+5"。
static func _parse_affinity_deltas(text: String) -> Array:
	var deltas: Array = []
	for segment in text.split(";", false):
		var trimmed := segment.strip_edges()
		if trimmed.is_empty():
			continue
		# 分离 "from->to" 和 ":delta"
		var colon_parts := trimmed.split(":", false, 1)
		if colon_parts.size() < 2:
			continue
		var pair_text := str(colon_parts[0]).strip_edges()
		var delta := _to_int(str(colon_parts[1]).strip_edges(), 0)
		# 分离 "from" 和 "to"
		var arrow_parts := pair_text.split("->", false, 1)
		if arrow_parts.size() < 2:
			continue
		var from_id := str(arrow_parts[0]).strip_edges()
		var to_id := str(arrow_parts[1]).strip_edges()
		if not from_id.is_empty() and not to_id.is_empty():
			deltas.append({"from": from_id, "to": to_id, "delta": delta})
	return deltas
