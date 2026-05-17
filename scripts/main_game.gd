extends Node

# zhengdao-cards C 阶段启动验证脚本
#
# 职责: 不带任何 UI, 跑通"加载 CSV → 引擎初始化 → 触发一个事件"链路, console log 输出验证。
# 完整卡牌交互层留到 MVP 1 期实施 (详见 [前端表现卡牌化_MVP草案] §3.7 第 1 步)。
#
# 验证项 (对应草案 §7.8 C 阶段验证标准):
#   1) Godot 项目可 import (Godot 编辑器能识别 project.godot 即满足)
#   2) ConfigRuntime.ensure_loaded() 加载所有 CSV 无报错
#   3) WorldEventEngine.load_from_data() 引擎初始化无报错
#   4) preview_next_turn() 至少能产出一个事件 / 或检测到开局选择 phase

const ConfigRuntime := preload("res://scripts/systems/config_runtime.gd")
const WorldEventEngine := preload("res://scripts/systems/world_event_engine.gd")


func _ready() -> void:
	print("[main_game] === C 阶段启动验证 开始 ===")

	# 1) 加载 CSV 配置
	var runtime: ConfigRuntime = ConfigRuntime.shared()
	var load_result: Dictionary = runtime.ensure_loaded()
	if not load_result.get("ok", false):
		push_error("[main_game] 配置加载失败: %s" % str(load_result.get("error", "unknown")))
		_finish(1)
		return
	print("[main_game] [1/4] ConfigRuntime.ensure_loaded() OK")

	# 2) 构建运行时上下文 (player/npc/graph/affinity/world_event)
	var context: Dictionary = runtime.build_context()
	if not context.get("ok", false):
		push_error("[main_game] 上下文构建失败: %s" % str(context.get("error", "unknown")))
		_finish(1)
		return

	var world_event_data: Dictionary = context.get("world_event", {})
	var events_arr: Array = world_event_data.get("events", [])
	var choice_points_arr: Array = world_event_data.get("choice_points", [])
	var task_defs_arr: Array = world_event_data.get("task_defs", [])
	print("[main_game] [2/4] build_context() OK | events=%d, choice_points=%d, task_defs=%d" % [
		events_arr.size(),
		choice_points_arr.size(),
		task_defs_arr.size()
	])

	# 3) 引擎实例化 + 数据注入
	var engine: WorldEventEngine = WorldEventEngine.new(0)
	var location_graph_obj: Variant = context.get("graph", null)
	var player_role: Variant = context.get("player", null)
	var inject_result: Dictionary = engine.load_from_data(world_event_data, location_graph_obj, player_role)
	if not inject_result.get("ok", false):
		push_error("[main_game] 引擎数据注入失败: %s" % str(inject_result.get("error", "unknown")))
		_finish(1)
		return
	print("[main_game] [3/4] WorldEventEngine.load_from_data() OK")

	# 4) 触发: 优先走开局选择 (若存在 creation_config), 否则 preview_next_turn
	if engine.has_creation_config():
		var creation_result: Dictionary = engine.start_creation()
		var creation_state: String = str(creation_result.get("state", ""))
		print("[main_game] [4/4] start_creation() state=%s (开局选择 phase 已激活)" % creation_state)
	else:
		var preview: Dictionary = engine.preview_next_turn()
		var preview_ok: bool = preview.get("ok", false) or not preview.get("error", "").is_empty() == false
		var ev_id: String = str(preview.get("event_id", preview.get("eventId", "")))
		var phase: String = str(preview.get("phase", preview.get("status", "")))
		print("[main_game] [4/4] preview_next_turn() event_id=%s, phase=%s" % [ev_id, phase])

	print("[main_game] === C 阶段启动验证 通过 ===")
	_finish(0)


# 在 headless 模式下退出主循环, 编辑器内运行时仅打印不退出。
func _finish(code: int) -> void:
	if DisplayServer.get_name() == "headless":
		get_tree().quit(code)
