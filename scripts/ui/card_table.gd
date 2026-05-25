extends Node2D
## 牌桌根(§1.4 + 技术基础节) —— Node2D + Camera2D 主体, 有界平移; CanvasLayer 做覆盖层。
##
## S1 范围: 底座 + 原语验证 ——
## - 牌桌 + Camera2D 有界平移(拖空白处"推牌桌", limit_* 原生裁剪)
## - 统一卡牌(hover 放大 / 点击翻牌)
## - 标记自写拖放
## - 系统按钮占位(右上, §2.7 卡牌化豁免)
## 验证: B③#1 拖拽优先级(卡隙拖=平移, 标记上拖=拖标记, 互不冲突)。
## S2 起以锚点簇 + 因果链 + 手牌区替代 _build_s1_sample。

# 显式 preload 卡 / 标记脚本(不依赖全局 class_name 缓存 → 全新克隆 / headless 运行均稳健)
const CardScn := preload("res://scripts/ui/card.gd")
const MarkerScn := preload("res://scripts/ui/marker.gd")

# 牌桌尺寸(略大于 1920x1080 视口, 留平移空间)
const TABLE_SIZE := Vector2(2560, 1600)
const PAN_MARGIN := 80.0  # 镜头可越过牌桌边缘的余量

var _camera: Camera2D
var _upper_zone: Node2D       # 上区(外境): 受镜头
var _lower_layer: CanvasLayer # 下区(内境): 手牌, 不受镜头(决策①)
var _ui_layer: CanvasLayer    # 系统按钮等, 不受镜头

var _panning: bool = false

func _ready() -> void:
	# 启用 2D 物理拾取 → 卡牌 / 标记 的 Area2D hover/click 生效
	get_viewport().physics_object_picking = true
	_build_table()
	_build_camera()
	_build_layers()
	_build_system_buttons()
	_build_s1_sample()

## 牌桌底纹(世界空间, 随镜头平移); mouse_filter=IGNORE → 空白拖拽落到 _unhandled_input
func _build_table() -> void:
	var bg := ColorRect.new()
	bg.color = Color("23252e")
	bg.size = TABLE_SIZE
	bg.position = Vector2.ZERO
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_index = -100
	add_child(bg)
	# 边框 + 中线参考, 便于肉眼判断平移(占位)
	var border := Line2D.new()
	border.width = 3.0
	border.default_color = Color("3a3d4a")
	border.points = PackedVector2Array([
		Vector2.ZERO, Vector2(TABLE_SIZE.x, 0), TABLE_SIZE,
		Vector2(0, TABLE_SIZE.y), Vector2.ZERO,
	])
	border.z_index = -99
	add_child(border)

## 摄像机: 居中 + limit_* 有界平移(技术基础节: Camera2D 原生有界)
func _build_camera() -> void:
	_camera = Camera2D.new()
	_camera.position = TABLE_SIZE * 0.5
	_camera.limit_left = int(-PAN_MARGIN)
	_camera.limit_top = int(-PAN_MARGIN)
	_camera.limit_right = int(TABLE_SIZE.x + PAN_MARGIN)
	_camera.limit_bottom = int(TABLE_SIZE.y + PAN_MARGIN)
	_camera.position_smoothing_enabled = false
	add_child(_camera)
	_camera.make_current()

## 分区节点: 上区(世界) / 下区(覆盖层) / UI(覆盖层)
func _build_layers() -> void:
	_upper_zone = Node2D.new()
	_upper_zone.name = "UpperZone"
	add_child(_upper_zone)
	_lower_layer = CanvasLayer.new()
	_lower_layer.name = "LowerZone"
	add_child(_lower_layer)
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "UILayer"
	add_child(_ui_layer)

## 系统按钮(右上角常规按钮, §2.7 明确豁免卡牌化)
func _build_system_buttons() -> void:
	var hbox := HBoxContainer.new()
	hbox.anchor_left = 1.0
	hbox.anchor_right = 1.0
	hbox.offset_left = -260
	hbox.offset_right = -16
	hbox.offset_top = 16
	hbox.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	hbox.add_theme_constant_override("separation", 8)
	_ui_layer.add_child(hbox)
	var menu_btn := Button.new()
	menu_btn.text = "⚙ 菜单"
	menu_btn.add_theme_font_override("font", CardScn.get_cjk_font())
	hbox.add_child(menu_btn)
	var quit_btn := Button.new()
	quit_btn.text = "退出"
	quit_btn.add_theme_font_override("font", CardScn.get_cjk_font())
	quit_btn.pressed.connect(func() -> void: get_tree().quit())
	hbox.add_child(quit_btn)

## S1 验证样例: 一张事件卡(点击翻牌) + 三个标记(拖拽验优先级)
func _build_s1_sample() -> void:
	var center: Vector2 = TABLE_SIZE * 0.5
	var card := CardScn.new()
	card.card_type = CardScn.CardType.EVENT
	card.title_text = "山道遇雨"
	card.body_text = "雨势渐大，前方有破庙可避。你会如何应对？"
	card.position = center + Vector2(0, -110)
	_upper_zone.add_child(card)
	card.clicked.connect(func(c: CardScn) -> void: c.toggle_flip())
	# 三个实体标记, 拖拽验 B③#1(拖标记时镜头不动)
	var types: Array[String] = ["physique", "craft", "insight"]
	for i in types.size():
		var m := MarkerScn.new()
		m.res_type = types[i]
		m.position = center + Vector2(-60 + i * 60, 150)
		_upper_zone.add_child(m)

## 牌桌平移(B③#1): 仅空白处的左键拖拽到达此处(卡/标记已消费各自事件)
##
## 守卫(修 P1): Godot 2D 拾取(Area2D.input_event)晚于 _unhandled_input, 故按下标记时
## 牌桌可能已置 _panning=true; 标记又吞掉松手事件 → _panning 残留, 无按键也平移。
## 解法对拾取时序免疫 —— 平移恒以"左键确实按住"为前提, 无按键移动时主动清残留。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_panning = event.pressed
	elif event is InputEventMouseMotion:
		if _panning and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			# 屏幕位移 → 世界位移; 反向移动镜头 = "推牌桌"手感; limit_* 已做有界裁剪
			_camera.position -= event.relative / _camera.zoom
		elif not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_panning = false  # 清除残留(如标记拖拽吞掉了松手)
