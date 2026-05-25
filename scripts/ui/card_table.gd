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

# 显式 preload 卡 / 标记 / mock 脚本(不依赖全局 class_name 缓存 → 全新克隆 / headless 运行均稳健)
const CardScn := preload("res://scripts/ui/card.gd")
const MarkerScn := preload("res://scripts/ui/marker.gd")
const MockDataScn := preload("res://scripts/ui/mock_data.gd")

# 牌桌尺寸(略大于 1920x1080 视口, 留平移空间)
const TABLE_SIZE := Vector2(2560, 1600)
const PAN_MARGIN := 80.0  # 镜头可越过牌桌边缘的余量

var _camera: Camera2D
var _upper_zone: Node2D       # 上区(外境): 受镜头
var _lower_layer: CanvasLayer # 下区(内境): 手牌, 不受镜头(决策①)
var _ui_layer: CanvasLayer    # 系统按钮等, 不受镜头

var _panning: bool = false

# ---- 因果链(§2.3)状态 ----
const SLOT_DX := 220.0    # 因果链横向间距(事件→选项→结果 始终向右; 卡宽 200 + 间隙)
var _chain_nodes: Array[Node] = []   # 当前链上的卡, 用于清空
var _option_cards: Array[Node] = []  # 当前选项卡(选定后清除未选中的)
var _chain_origin: Vector2 = Vector2.ZERO
var _options_shown: bool = false     # 选项已展开守卫(同步置位, 防翻牌 tween 期间重复点击)
var _result_shown: bool = false
var _result_revealed: bool = false   # 结果已揭示守卫(防屏息窗口内重复点击)
var _hand_cards: Dictionary = {}     # res_type -> 手牌资源卡(标记领取飞向目标)

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
		_hand_cards[res_types[i]] = card  # 领取标记飞向目标
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
	_chain_origin = Vector2(1010, 620)  # 事件在锚点簇右侧; 选项/结果向右依次展开(始终左→右)
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

## 展开选项(≤3, 水平排在事件左侧; 纯代码偏移 → 均匀无重叠)
func _expand_options() -> void:
	var titles: Array[String] = ["冒雨赶路", "破庙暂避", "寻人引路"]
	var bodies: Array[String] = ["直接型 · 必有数值成长", "鉴定型 · 体魄 / 心性", "鉴定型 · 人际"]
	var types: Array[int] = [MockDataScn.OptType.DIRECT, MockDataScn.OptType.CHECK, MockDataScn.OptType.CHECK]
	var n: int = titles.size()
	_option_cards.clear()
	for i in n:
		var opt := _make_card(CardScn.CardType.OPTION, titles[i], bodies[i])
		opt.position = Vector2(_chain_origin.x + (i + 1) * SLOT_DX, _chain_origin.y)  # 紧邻事件向右依次排
		_upper_zone.add_child(opt)
		_chain_nodes.append(opt)
		_option_cards.append(opt)
		var t: int = types[i]  # 按值捕获该选项类型
		opt.clicked.connect(func(c: CardScn) -> void: _on_option_chosen(c, t))

## 选定一个选项: 未选中的淡出消失 + 选中项归到事件左侧固定槽 + 出结果(更聚焦)
func _on_option_chosen(chosen: CardScn, opt_type: int) -> void:
	if _result_shown:
		return
	for opt in _option_cards:
		if opt != chosen and is_instance_valid(opt):
			_fade_and_free(opt)
	_option_cards.clear()
	var slot := Vector2(_chain_origin.x + SLOT_DX, _chain_origin.y)  # 选中项归到事件右侧紧邻槽
	var tw := chosen.create_tween()
	tw.tween_property(chosen, "position", slot, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_expand_result(opt_type)

## 淡出并释放一张卡(从链清单移除)
func _fade_and_free(node: Node2D) -> void:
	_chain_nodes.erase(node)
	var tw := node.create_tween()
	tw.tween_property(node, "modulate:a", 0.0, 0.15)
	tw.tween_callback(node.queue_free)

## 选定选项 → 展开结果卡(牌背, 点击揭示)。
## tier: 直接型固定小成功; 鉴定型 S3a 暂随机(S3b 起由投入读数决定)。
func _expand_result(opt_type: int) -> void:
	if _result_shown:
		return
	_result_shown = true
	var tier: String = "success"
	if opt_type == MockDataScn.OptType.CHECK:
		var roll: Array[String] = ["great_success", "success", "fail", "great_fail"]
		tier = roll[randi() % roll.size()]
	var outcome: Dictionary = MockDataScn.outcome_for(tier)
	var res := _make_card(CardScn.CardType.RESULT, MockDataScn.tier_label(tier), "点击牌背揭示。")
	res.start_face_up = false
	res.position = Vector2(_chain_origin.x + SLOT_DX * 2.0, _chain_origin.y)  # 结果在选中选项右侧
	_upper_zone.add_child(res)
	_chain_nodes.append(res)
	res.clicked.connect(func(c: CardScn) -> void: _reveal_result(c, outcome))

## 揭示结果(§3): 封缄 → 屏息 → 翻牌 → 显式档位 → 生成可领取标记
func _reveal_result(card: CardScn, outcome: Dictionary) -> void:
	if _result_revealed:
		return
	_result_revealed = true
	await get_tree().create_timer(0.35).timeout  # 封缄→翻牌的基础屏息(§3.1)
	if not is_instance_valid(card):
		return
	card.flip_to(true)  # 翻开后显式露出 tier(卡标题)
	await get_tree().create_timer(CardScn.FLIP_TIME).timeout
	if not is_instance_valid(card):
		return
	_spawn_claimable_markers(card, outcome)

## 在结果卡旁生成可领取标记(实体 + 经验成长); 放世界(UpperZone), 与结果卡相对位置固定、随镜头一起动
func _spawn_claimable_markers(result_card: CardScn, outcome: Dictionary) -> void:
	var base: Vector2 = result_card.position  # 世界坐标(牌桌上), 锚定结果卡
	var idx: int = 0
	var markers: Array = outcome.get("markers", [])
	for entry in markers:
		var d: Dictionary = entry
		var count: int = int(d.get("count", 1))
		for k in count:
			_make_claimable(String(d["type"]), String(d["kind"]), base, idx)
			idx += 1
	var exps: Array = outcome.get("exp_deltas", [])
	for entry in exps:
		var d: Dictionary = entry
		_make_claimable(String(d["line"]), "growth", base, idx)  # 经验 → 成长标记(单独通道)
		idx += 1

## 生成单个可领取标记(结果卡下方排开; 计入 _chain_nodes 以便清链时回收未领取的)
func _make_claimable(res_type: String, kind: String, base: Vector2, idx: int) -> void:
	var m := MarkerScn.new()
	m.res_type = res_type
	m.kind = MarkerScn.Kind.GROWTH if kind == "growth" else MarkerScn.Kind.ENTITY
	m.claimable = true
	m.position = base + Vector2(float(idx % 4) * 42.0 - 63.0, 165.0 + float(idx / 4) * 42.0)
	_upper_zone.add_child(m)  # 世界(随牌桌), 与结果卡相对固定
	_chain_nodes.append(m)
	m.claimed.connect(_claim_marker)

## 领取标记(§3.1): 标记在世界, 飞向手牌(把手牌屏幕坐标转世界坐标作终点) → 收入后释放
func _claim_marker(m: Marker) -> void:
	_chain_nodes.erase(m)
	var target: Vector2 = m.position + Vector2(0, 220)  # 兜底(无对应手牌时下沉)
	var target_card: Node2D = _hand_cards.get(m.res_type, null)
	if target_card != null:
		# 手牌在 CanvasLayer(屏幕坐标), 标记在世界 → 屏幕坐标逆变换回世界坐标
		var canvas_xform := get_viewport().get_canvas_transform()
		target = canvas_xform.affine_inverse() * target_card.position
	var tw := m.create_tween()
	tw.set_parallel(true)
	tw.tween_property(m, "position", target, 0.40).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(m, "scale", Vector2(0.3, 0.3), 0.40)
	tw.chain().tween_callback(m.queue_free)

## 清空当前因果链(抽新牌 / 离开时; 锚点簇与手牌不动)
func _clear_chain() -> void:
	for node in _chain_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_chain_nodes.clear()
	_option_cards.clear()
	_options_shown = false
	_result_shown = false
	_result_revealed = false

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
