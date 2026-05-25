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

# ---- 因果链(§2.3)状态 ----
const CHAIN_DX := 270.0   # 链阶段横向间距(事件 → 选项 → 结果)
const OPT_DY := 290.0     # 选项纵向间距(≤3 平铺)
var _chain_nodes: Array[Node] = []   # 当前链上的卡, 用于清空
var _chain_origin: Vector2 = Vector2.ZERO
var _options_shown: bool = false     # 选项已展开守卫(同步置位, 防翻牌 tween 期间重复点击)
var _result_shown: bool = false

func _ready() -> void:
	# 启用 2D 物理拾取 → 卡牌 / 标记 的 Area2D hover/click 生效
	get_viewport().physics_object_picking = true
	_build_table()
	_build_camera()
	_build_layers()
	_build_system_buttons()
	_build_anchor_cluster()
	_build_hand_zone()

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

## 创建一张卡(仅配置, 不入树; 调用方设 position/start_face_up 后 add_child)
func _make_card(type: int, title: String, body: String) -> CardScn:
	var c := CardScn.new()
	c.card_type = type
	c.title_text = title
	c.body_text = body
	return c

## 地点锚点簇(§2.3, 持久, 上区左端): 地点卡 + 事件牌库 + 我要走
func _build_anchor_cluster() -> void:
	var loc := _make_card(CardScn.CardType.LOCATION, "青石镇", "你暂居此处，江湖讯息往来。")
	loc.position = Vector2(440, 520)
	_upper_zone.add_child(loc)
	var deck := _make_card(CardScn.CardType.DECK, "事件牌库", "")
	deck.start_face_up = false  # 牌背堆
	deck.back_label = "事件牌库"  # 背面标注, 与抽出的"事件"牌背区分
	deck.position = Vector2(700, 520)
	_upper_zone.add_child(deck)
	deck.clicked.connect(func(_c: CardScn) -> void: _start_chain())  # 点击抽牌起链
	var leave := _make_card(CardScn.CardType.LEAVE, "我要走", "另择去处。")
	leave.position = Vector2(440, 840)
	_upper_zone.add_child(leave)

## 下区手牌资源(§2.4): 资源卡 + 标记, 常驻 CanvasLayer(不随镜头, 决策①)
func _build_hand_zone() -> void:
	var titles: Array[String] = ["武学", "百艺", "学识", "心性", "人际", "银两"]
	var res_types: Array[String] = ["physique", "craft", "insight", "xinxing", "social", "gold"]
	var counts: Array[int] = [3, 1, 2, 3, 2, 0]    # 棋子数; 银两 = 0 走数字(占位文字)
	var bodies: Array[String] = ["", "", "", "", "", "35 两"]
	var n: int = titles.size()
	var spacing := 240.0
	var start_x := 960.0 - (n - 1) * spacing * 0.5
	var y := 920.0
	for i in n:
		var card := _make_card(CardScn.CardType.RESOURCE, titles[i], bodies[i])
		card.position = Vector2(start_x + i * spacing, y)
		_lower_layer.add_child(card)
		# 标记(棋子型)悬于卡上方, §1.2 离散容量呈现
		var cnt: int = counts[i]
		for j in cnt:
			var m := MarkerScn.new()
			m.res_type = res_types[i]
			m.position = card.position + Vector2((j - (cnt - 1) / 2.0) * 36.0, -CardScn.SIZE.y * 0.5 - 26.0)
			_lower_layer.add_child(m)

# ---------- 因果链动态槽位(§2.3, 验 B③#5) ----------

## 抽牌起新链: 清空旧链 → 生成事件卡(牌背, 点击翻开 + 展开选项)
func _start_chain() -> void:
	_clear_chain()
	_chain_origin = Vector2(1010, 620)
	var ev := _make_card(CardScn.CardType.EVENT, "山道遇雨", "雨势渐大，前方有破庙可避。你会如何应对？")
	ev.start_face_up = false
	ev.position = _chain_origin
	_upper_zone.add_child(ev)
	_chain_nodes.append(ev)
	ev.clicked.connect(func(c: CardScn) -> void: _on_event_clicked(c))

## 事件卡点击: 首次翻开并展开选项(同步守卫, 防翻牌 tween 期间重复点击重复展开)
func _on_event_clicked(ev: CardScn) -> void:
	if _options_shown:
		return
	_options_shown = true
	ev.flip_to(true)
	_expand_options()

## 展开选项(≤3 平铺, 纯代码偏移定位 → 槽位均匀、无重叠)
func _expand_options() -> void:
	var titles: Array[String] = ["冒雨赶路", "破庙暂避", "寻人引路"]
	var bodies: Array[String] = ["直接型 · 必有数值成长", "鉴定型 · 体魄 / 心性", "鉴定型 · 人际"]
	var n: int = titles.size()
	var col_x := _chain_origin.x + CHAIN_DX
	for i in n:
		var opt := _make_card(CardScn.CardType.OPTION, titles[i], bodies[i])
		opt.position = Vector2(col_x, _chain_origin.y + (i - (n - 1) / 2.0) * OPT_DY)
		_upper_zone.add_child(opt)
		_chain_nodes.append(opt)
		opt.clicked.connect(func(_c: CardScn) -> void: _expand_result())

## 展开结果(占位; S3 接管聚焦 / 投入 / 揭示循环)
func _expand_result() -> void:
	if _result_shown:
		return
	_result_shown = true
	var res := _make_card(CardScn.CardType.RESULT, "结果", "（S3 揭示循环接管：档位 + 标记领取）")
	res.start_face_up = false
	res.position = Vector2(_chain_origin.x + CHAIN_DX * 2.0, _chain_origin.y)
	_upper_zone.add_child(res)
	_chain_nodes.append(res)
	res.clicked.connect(func(c: CardScn) -> void: c.flip_to(true))

## 清空当前因果链(抽新牌 / 离开时; 锚点簇与手牌不动)
func _clear_chain() -> void:
	for node in _chain_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_chain_nodes.clear()
	_options_shown = false
	_result_shown = false

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
