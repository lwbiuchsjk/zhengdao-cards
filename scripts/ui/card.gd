class_name Card
extends Node2D
## 统一卡牌基底(§1.1) —— 所有卡(事件/选项/结果/资源/地点/牌库/我要走)共享尺寸 + 卡框。
##
## 关键设计:
## - 卡为 Node2D, 上区世界(受镜头) + 下区 CanvasLayer(不受镜头) 通用; 标记拖放用 global_position 数学。
## - 视觉用纯色块占位(MVP 无美术), 文字用 Label 子节点; 翻牌 = scale.x Tween(伪 3D)。
## - 卡牌以原点为中心绘制(-SIZE/2 ~ +SIZE/2), 故 hover 放大 / 翻牌缩放均绕中心。
## - hover/click 经 Area2D 拾取(需 viewport.physics_object_picking = true, 由牌桌根开启)。

# 卡牌类型(决定卡框色 + 类型标识占位)
enum CardType { EVENT, OPTION, RESULT, RESOURCE, LOCATION, DECK, LEAVE }
# 卡牌状态机(§1.1): 牌背/牌面/默认/hover/选中/禁用/聚焦/已投
enum State { FACE_DOWN, FACE_UP, HOVER, SELECTED, DISABLED, FOCUSED, SPENT }

const SIZE := Vector2(200, 280)       # 统一基础尺寸
const HOVER_SCALE := 1.12             # hover 原地放大倍率
const FLIP_TIME := 0.30               # 整段翻牌时长(秒)

# 各类型卡框占位色
const TYPE_COLORS: Dictionary = {
	CardType.EVENT: Color("4a5a7a"),
	CardType.OPTION: Color("4f7a52"),
	CardType.RESULT: Color("7a4f7a"),
	CardType.RESOURCE: Color("7a684a"),
	CardType.LOCATION: Color("4a7070"),
	CardType.DECK: Color("383848"),
	CardType.LEAVE: Color("6a4a4a"),
}
const TYPE_LABELS: Dictionary = {
	CardType.EVENT: "事件", CardType.OPTION: "选项", CardType.RESULT: "结果",
	CardType.RESOURCE: "资源", CardType.LOCATION: "地点", CardType.DECK: "牌库", CardType.LEAVE: "离去",
}

signal clicked(card: Card)

@export var card_type: CardType = CardType.EVENT
@export var title_text: String = ""
@export var body_text: String = ""
@export var start_face_up: bool = true
@export var back_label: String = ""  # 牌背中心标注(空则用类型名); 区分多种卡背(事件牌库/事件/结果)

# E0 卡牌实体地基: 持有的数据身份(CardData 实例)。每张视觉卡 spawn 时由 card_table 注入,
# 承载稳定 card_uid / logical_id / Zone 归属 / modifiers。MVP 阶段为引用持有 ——
# 表现逻辑(翻牌 / hover / click)不读它; 身份与检索查询统一走 CardRegistry + CardZoneStore。
var model: CardData = null

var _state: State = State.FACE_UP
var _face_up: bool = true
var _hovered: bool = false
var _selected: bool = false  # 聚焦选中态(卡面高亮边框)
var _base_scale: Vector2 = Vector2.ONE
var _flip_tween: Tween
var _scale_tween: Tween
var _title_label: Label
var _body_label: Label
var _type_label: Label
var _back_label: Label  # 牌背中心标注(仅牌背时显示)

# 跨卡共享的 CJK 字体(默认字体不含中文字形, 用系统字体兜底; Windows 上命中雅黑)
static var _cjk_font: SystemFont

## 返回共享 CJK 字体(供卡牌 + 牌桌按钮统一调用)
static func get_cjk_font() -> SystemFont:
	if _cjk_font == null:
		_cjk_font = SystemFont.new()
		_cjk_font.font_names = PackedStringArray([
			"Microsoft YaHei", "Microsoft YaHei UI", "SimHei", "Noto Sans CJK SC", "sans-serif",
		])
	return _cjk_font

func _ready() -> void:
	_base_scale = scale  # 捕获初始缩放(允许外部预设非 1 缩放), hover/翻牌均以此为基准
	_face_up = start_face_up
	_state = State.FACE_UP if _face_up else State.FACE_DOWN
	_build_visual()
	_refresh_face()

## 构建卡面视觉: 类型标识 + 标题 + 正文 + 拾取区(纯色块占位)
func _build_visual() -> void:
	var top_left: Vector2 = -SIZE * 0.5
	# 类型标识(顶部)
	_type_label = _make_label(TYPE_LABELS[card_type], 14, top_left + Vector2(10, 8), SIZE.x - 20)
	add_child(_type_label)
	# 标题
	_title_label = _make_label(title_text, 22, top_left + Vector2(10, 34), SIZE.x - 20)
	add_child(_title_label)
	# 正文(自动换行)
	_body_label = _make_label(body_text, 15, top_left + Vector2(10, 78), SIZE.x - 20)
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.size = Vector2(SIZE.x - 20, SIZE.y - 90)
	add_child(_body_label)
	# 牌背中心标注: 居中, 仅牌背时显示; 空则回退到类型名
	var back_text: String = back_label if not back_label.is_empty() else String(TYPE_LABELS[card_type])
	_back_label = Label.new()
	_back_label.text = back_text
	_back_label.position = top_left
	_back_label.size = SIZE
	_back_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_back_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_back_label.add_theme_font_override("font", get_cjk_font())
	_back_label.add_theme_font_size_override("font_size", 22)
	_back_label.add_theme_color_override("font_color", Color("9a9ab0"))
	add_child(_back_label)
	# 拾取区(Area2D, 居中覆盖整卡)
	var area := Area2D.new()
	area.input_pickable = true
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = SIZE
	shape.shape = rect
	area.add_child(shape)
	add_child(area)
	area.mouse_entered.connect(_on_mouse_entered)
	area.mouse_exited.connect(_on_mouse_exited)
	area.input_event.connect(_on_area_input)
	queue_redraw()

## 创建一个套用 CJK 字体的 Label(卡面文字工具)
func _make_label(text: String, font_size: int, pos: Vector2, width: float) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.position = pos
	lbl.size = Vector2(width, 0)
	lbl.add_theme_font_override("font", get_cjk_font())
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", Color("ece7da"))
	return lbl

## 绘制卡框(纯色块占位): 牌面 = 类型色; 牌背 = 暗色 + 对角斜纹
func _draw() -> void:
	var rect := Rect2(-SIZE * 0.5, SIZE)
	if _face_up:
		draw_rect(rect, TYPE_COLORS[card_type], true)
		draw_rect(rect, Color("ece7da"), false, 2.0)  # 描边
		if _selected:
			draw_rect(rect.grow(5.0), Color("ffd86a"), false, 5.0)  # 聚焦选中高亮
	else:
		draw_rect(rect, Color("2b2b3a"), true)
		draw_rect(rect, Color("6a6a80"), false, 2.0)
		# 内框装饰(留出中心给背面标注, 避免遮挡)
		var inset := Rect2(rect.position + Vector2(12, 12), rect.size - Vector2(24, 24))
		draw_rect(inset, Color("44445a"), false, 1.5)

# ---------- 翻牌(§3 揭示用, S1 先实现基础翻转) ----------

## 翻到指定面(face_up=true 牌面 / false 牌背), scale.x 收拢→换面→展开
func flip_to(face_up: bool) -> void:
	if _face_up == face_up:
		return
	# 先停掉 hover 缩放 tween, 避免与翻牌 tween 抢 scale 属性(P2-4)
	if _scale_tween and _scale_tween.is_running():
		_scale_tween.kill()
	if _flip_tween and _flip_tween.is_running():
		_flip_tween.kill()
	# 回弹目标 x 按当前 hover 状态算(hover 中保持放大, 否则回基准)
	var target_x: float = _base_scale.x * (HOVER_SCALE if _hovered else 1.0)
	_flip_tween = create_tween()
	_flip_tween.tween_property(self, "scale:x", 0.0, FLIP_TIME * 0.5)
	_flip_tween.tween_callback(func() -> void:
		_face_up = face_up
		_refresh_face()
	)
	_flip_tween.tween_property(self, "scale:x", target_x, FLIP_TIME * 0.5)
	# 翻牌结束后按当前 hover 状态校正最终缩放(规避翻牌期间 hover 变化造成的不一致)
	_flip_tween.tween_callback(func() -> void:
		scale = _base_scale * (HOVER_SCALE if _hovered else 1.0)
	)

## 在牌面 / 牌背之间切换(S1 样例点击用)
func toggle_flip() -> void:
	flip_to(not _face_up)

## 当前是否牌面朝上(链流程判定用)
func is_face_up() -> bool:
	return _face_up

## 设置聚焦选中态(高亮边框)
func set_selected(on: bool) -> void:
	_selected = on
	queue_redraw()

## 运行时更新正面文字(F1 盲选: 卡背翻开为真实承诺事件时填入 title/body)。
## 标签在 _ready 一次性建, 故除写 export 值外须同步刷新已建标签节点。
func set_face_text(new_title: String, new_body: String) -> void:
	title_text = new_title
	body_text = new_body
	if _title_label != null:
		_title_label.text = new_title
	if _body_label != null:
		_body_label.text = new_body

## 按当前 _face_up 刷新卡面绘制 + 文字显隐
func _refresh_face() -> void:
	_type_label.visible = _face_up
	_title_label.visible = _face_up
	_body_label.visible = _face_up
	_back_label.visible = not _face_up
	queue_redraw()

# ---------- hover / click ----------

func _on_mouse_entered() -> void:
	if _state == State.DISABLED:
		return
	_hovered = true
	z_index = 10  # 抬升避免被邻卡遮挡
	_animate_scale(_base_scale * HOVER_SCALE)

func _on_mouse_exited() -> void:
	if _state == State.DISABLED:
		return
	_hovered = false
	z_index = 0
	_animate_scale(_base_scale)

## hover 放大 / 复位的平滑缩放; 翻牌进行中不抢 scale(P2-4)
func _animate_scale(to: Vector2) -> void:
	if _flip_tween and _flip_tween.is_running():
		return
	if _scale_tween and _scale_tween.is_running():
		_scale_tween.kill()
	_scale_tween = create_tween()
	_scale_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_scale_tween.tween_property(self, "scale", to, 0.12)

## Area2D 输入: 左键按下 = 点击(消费事件, 不触发牌桌平移); 同时通知牌桌"按下落在卡上"(聚焦取消判定)
func _on_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		get_viewport().set_input_as_handled()
		for table in get_tree().get_nodes_in_group("card_table"):
			if table.has_method("notify_pickable_press"):
				table.notify_pickable_press()
		clicked.emit(self)
