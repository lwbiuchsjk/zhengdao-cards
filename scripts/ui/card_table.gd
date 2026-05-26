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
var _hand_home: Dictionary = {}      # res_type -> 手牌 home 屏幕坐标(聚焦后归位)
# ---- 选项聚焦(§2.5 改: 镜头 zoom 驱动)状态 ----
const FOCUS_ZOOM := Vector2(1.6, 1.6)   # 聚焦放大倍率(手感, 可调)
var _focus_active: bool = false
var _focused_option: CardScn = null     # 当前聚焦的选项卡
var _focus_opt_type: int = 0            # 当前聚焦选项类型(确定时定 tier)
var _focus_whitelist: Array = []        # 当前聚焦白名单(投入校验用)
var _focus_threshold: int = 0           # 当前聚焦阈值(读数 + 确定时算 tier)
var _invested_markers: Array[Node] = [] # 已投入(绑定到选项)的标记; 切换/取消飞回, 确定消耗
var _pre_focus_cam_pos: Vector2 = Vector2.ZERO
var _pre_focus_cam_zoom: Vector2 = Vector2.ONE
var _pre_focus_saved: bool = false      # 仅首次进入聚焦时记录镜头(切换不覆盖)
var _confirm_btn: Button = null         # 确定按钮(聚焦期)
var _difficulty_label: Label = null     # 难度提示(鉴定型)
var _press_screen: Vector2 = Vector2.ZERO  # 左键按下屏幕位置(判定点击 vs 拖动)
var _press_moved: bool = false          # 本次按下是否移动过(拖动=平移, 点击=取消聚焦)
var _press_on_pickable: bool = false    # 本次按下是否落在卡/标记上(picking 阶段通知 → 不取消聚焦)

func _ready() -> void:
	add_to_group("card_table")  # 供卡/标记 picking 时回查通知本表(聚焦取消判定)
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
		card.set_meta("res_type", res_types[i])
		_lower_layer.add_child(card)
		_hand_cards[res_types[i]] = card  # 领取标记飞向目标
		_hand_home[res_types[i]] = card.position  # 聚焦后归位锚点
		card.clicked.connect(_on_hand_card_clicked)  # 聚焦+白名单时点击 → 投入一个该卡标记
		# 标记(棋子型)作资源卡子节点, 聚焦移动卡时一起动; §1.2 离散容量呈现
		var cnt: int = counts[i]
		for j in cnt:
			var m := MarkerScn.new()
			m.res_type = res_types[i]
			m.position = Vector2((j - (cnt - 1) / 2.0) * 36.0, -CardScn.SIZE.y * 0.5 - 26.0)  # 相对卡(子节点)
			card.add_child(m)
			m.dropped.connect(_on_marker_dropped)  # 投入处理: 拖到选项上 → 绑定到选项

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

## 展开选项(≤3, 水平排在事件右侧; 纯代码偏移 → 均匀无重叠)
func _expand_options() -> void:
	var titles: Array[String] = ["冒雨赶路", "破庙暂避", "寻人引路"]
	var bodies: Array[String] = ["直接型 · 必有数值成长", "鉴定型 · 体魄 / 心性", "鉴定型 · 人际"]
	var types: Array[int] = [MockDataScn.OptType.DIRECT, MockDataScn.OptType.CHECK, MockDataScn.OptType.CHECK]
	var whitelists: Array[Array] = [[], ["physique", "xinxing"], ["insight", "social"]]  # 鉴定型白名单(§2.5)
	var thresholds: Array[int] = [0, 3, 2]  # 鉴定难度(需投入标记数); 直接型 0
	var n: int = titles.size()
	_option_cards.clear()
	for i in n:
		var opt := _make_card(CardScn.CardType.OPTION, titles[i], bodies[i])
		opt.position = Vector2(_chain_origin.x + (i + 1) * SLOT_DX, _chain_origin.y)  # 紧邻事件向右依次排
		_upper_zone.add_child(opt)
		_chain_nodes.append(opt)
		_option_cards.append(opt)
		var t: int = types[i]  # 按值捕获该选项类型
		var wl: Array = whitelists[i]
		var th: int = thresholds[i]
		opt.clicked.connect(func(c: CardScn) -> void: _on_option_chosen(c, t, wl, th))

## 选定一个选项(直接型 / 鉴定型都进入聚焦); 已聚焦时点另一选项 = 切换
func _on_option_chosen(chosen: CardScn, opt_type: int, whitelist: Array, threshold: int) -> void:
	if _result_shown:
		return
	if _focus_active and chosen == _focused_option:
		return
	_enter_focus(chosen, opt_type, whitelist, threshold)

## 提交选项: 未选中的淡出消失 + 选中项归到事件右侧固定槽(此后不可改选)
func _commit_option(chosen: CardScn) -> void:
	for opt in _option_cards:
		if opt != chosen and is_instance_valid(opt):
			_fade_and_free(opt)
	_option_cards.clear()
	var slot := Vector2(_chain_origin.x + SLOT_DX, _chain_origin.y)  # 选中项归到事件右侧紧邻槽
	var tw := chosen.create_tween()
	tw.tween_property(chosen, "position", slot, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# ---------- 选项聚焦(§2.5 改: 镜头 zoom 驱动) ----------

## 进入/切换聚焦: 镜头 zoom + 居中该选项 + 选中高亮 + 手牌前推(白名单)/收起(非白名单) + 难度提示 + 确定。
## 首次进入记录镜头(切换不覆盖); 点桌面空白取消(见 _unhandled_input)。
func _enter_focus(option: CardScn, opt_type: int, whitelist: Array, threshold: int) -> void:
	if not _pre_focus_saved:
		_pre_focus_cam_pos = _camera.position
		_pre_focus_cam_zoom = _camera.zoom
		_pre_focus_saved = true
	# 切换: 先把已投入旧选项的标记飞回手牌, 再取消旧选项选中 + 释放旧选项上的确定按钮(后面在新选项上重建)
	if _focused_option != null and is_instance_valid(_focused_option) and _focused_option != option:
		_flyback_invested_markers()
		_focused_option.set_selected(false)
		if _confirm_btn != null and is_instance_valid(_confirm_btn):
			_confirm_btn.queue_free()
			_confirm_btn = null
	_focus_active = true
	_focused_option = option
	_focus_opt_type = opt_type
	_focus_whitelist = whitelist
	_focus_threshold = threshold
	option.set_selected(true)
	# 镜头 zoom + 居中(world); limit_* 会按 zoom 裁剪
	var cam_tw := _camera.create_tween()
	cam_tw.set_parallel(true)
	cam_tw.tween_property(_camera, "position", option.global_position, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	cam_tw.tween_property(_camera, "zoom", FOCUS_ZOOM, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_apply_hand_focus(whitelist)
	_update_difficulty(opt_type, threshold)
	if _confirm_btn == null:
		_build_confirm_button()

## 手牌响应: 非白名单收起(下沉+缩小+变暗); 白名单维持原位(靠 zoom + 他卡收起已足够凸显)。
## 直接型(空白名单) → 任何 rt 均不在白名单 → 所有手牌都收起。
func _apply_hand_focus(whitelist: Array) -> void:
	for key in _hand_cards:
		var rt: String = key
		var card: Node2D = _hand_cards[rt]
		var home: Vector2 = _hand_home[rt]
		var to_pos: Vector2 = home
		var to_scale: Vector2 = Vector2.ONE
		var to_alpha: float = 1.0
		if not (rt in whitelist):  # 非白名单(含 DIRECT 全部) → 收起
			to_pos = home + Vector2(0, 150)
			to_scale = Vector2(0.7, 0.7)
			to_alpha = 0.4
		var tw := card.create_tween()
		tw.set_parallel(true)
		tw.tween_property(card, "position", to_pos, 0.25)
		tw.tween_property(card, "scale", to_scale, 0.25)
		tw.tween_property(card, "modulate:a", to_alpha, 0.25)

## 难度提示(鉴定型): 顶部居中显示需投入标记数; 直接型无
func _update_difficulty(opt_type: int, threshold: int) -> void:
	if _difficulty_label != null and is_instance_valid(_difficulty_label):
		_difficulty_label.queue_free()
		_difficulty_label = null
	if opt_type != MockDataScn.OptType.CHECK:
		return
	_difficulty_label = Label.new()
	_difficulty_label.text = "鉴定难度：需 %d 个标记 ｜ 已投 %d" % [threshold, _invested_markers.size()]
	_difficulty_label.add_theme_font_override("font", CardScn.get_cjk_font())
	_difficulty_label.add_theme_font_size_override("font_size", 22)
	_difficulty_label.add_theme_color_override("font_color", Color("ffd86a"))
	_difficulty_label.position = Vector2(720, 40)
	_ui_layer.add_child(_difficulty_label)

## 确定按钮: 作选项的世界子节点 → 与选项同层级(在手牌 CanvasLayer 之下) + 自动跟随选项 + 受 zoom 加持视觉变大。
## 显眼样式: 黄底深边, 字号大, 圆角。位于选项上方。
func _build_confirm_button() -> void:
	_confirm_btn = Button.new()
	_confirm_btn.text = "确定"
	_confirm_btn.add_theme_font_override("font", CardScn.get_cjk_font())
	_confirm_btn.add_theme_font_size_override("font_size", 32)
	_confirm_btn.custom_minimum_size = Vector2(180, 64)
	_confirm_btn.size = Vector2(180, 64)  # 显式 size: 非 Container 子节点, 避免 size 为 0 不可点
	_confirm_btn.add_theme_color_override("font_color", Color("1a1a22"))
	# 醒目: 黄底 + 深棕边框 + 圆角
	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = Color("ffd86a")
	sb_normal.border_color = Color("8a6a1f")
	sb_normal.set_border_width_all(3)
	sb_normal.corner_radius_top_left = 8
	sb_normal.corner_radius_top_right = 8
	sb_normal.corner_radius_bottom_left = 8
	sb_normal.corner_radius_bottom_right = 8
	_confirm_btn.add_theme_stylebox_override("normal", sb_normal)
	var sb_hover: StyleBoxFlat = sb_normal.duplicate()
	sb_hover.bg_color = Color("ffe79a")
	_confirm_btn.add_theme_stylebox_override("hover", sb_hover)
	var sb_pressed: StyleBoxFlat = sb_normal.duplicate()
	sb_pressed.bg_color = Color("e0b840")
	_confirm_btn.add_theme_stylebox_override("pressed", sb_pressed)
	# 选项-本地坐标: x = -宽/2 (居中); y = 卡顶上方留空
	_confirm_btn.position = Vector2(-90.0, -240.0)
	_confirm_btn.pressed.connect(_confirm_focus)
	_focused_option.add_child(_confirm_btn)

## 取消聚焦(点桌面空白触发): 镜头 + 手牌 + 选中 全部还原
func _cancel_focus() -> void:
	if _focus_active:
		_restore_focus()

## 确定: 算 tier(鉴定型由投入定, 直接型固定 success) → 消耗投入标记 → 还原 → 提交 → 出结果
func _confirm_focus() -> void:
	if not _focus_active:
		return
	var option: CardScn = _focused_option
	var opt_type: int = _focus_opt_type
	var invested: int = _invested_markers.size()
	var threshold: int = _focus_threshold
	var tier: String = "success"
	if opt_type == MockDataScn.OptType.CHECK:
		tier = _tier_from_invest(invested, threshold)
	# 消耗(封缄): 投入标记释放, 不再飞回(_restore_focus 中的 flyback 会跑在空列表上 → no-op)
	for m in _invested_markers:
		if is_instance_valid(m):
			m.queue_free()
	_invested_markers.clear()
	_restore_focus()
	if is_instance_valid(option):
		_commit_option(option)
		_expand_result(opt_type, tier)

## 由投入数 vs 阈值算 tier(mock 公式; Line B 完成后由引擎规则替代)
func _tier_from_invest(invested: int, threshold: int) -> String:
	if threshold <= 0:
		return "success"
	if invested >= int(ceil(threshold * 1.5)):
		return "great_success"
	if invested >= threshold:
		return "success"
	if invested * 2 >= threshold:
		return "fail"
	return "great_fail"

## 还原聚焦: 投入标记飞回手牌 → 镜头回原位 → 手牌全部归位 + 取消选中 + 清 UI + 复位状态
func _restore_focus() -> void:
	_flyback_invested_markers()
	if _pre_focus_saved:
		var cam_tw := _camera.create_tween()
		cam_tw.set_parallel(true)
		cam_tw.tween_property(_camera, "position", _pre_focus_cam_pos, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		cam_tw.tween_property(_camera, "zoom", _pre_focus_cam_zoom, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		# 还原 tween 完成后才清 → 中途若再聚焦仍用原 pre_focus(避免记录到 mid-restore 镜头位置)
		cam_tw.chain().tween_callback(func() -> void: _pre_focus_saved = false)
	for key in _hand_cards:
		var rt: String = key
		var card: Node2D = _hand_cards[rt]
		var home: Vector2 = _hand_home[rt]
		var tw := card.create_tween()
		tw.set_parallel(true)
		tw.tween_property(card, "position", home, 0.25)
		tw.tween_property(card, "scale", Vector2.ONE, 0.25)
		tw.tween_property(card, "modulate:a", 1.0, 0.25)
	if _focused_option != null and is_instance_valid(_focused_option):
		_focused_option.set_selected(false)
	if _confirm_btn != null and is_instance_valid(_confirm_btn):
		_confirm_btn.queue_free()
	_confirm_btn = null
	if _difficulty_label != null and is_instance_valid(_difficulty_label):
		_difficulty_label.queue_free()
	_difficulty_label = null
	_focus_active = false
	_focused_option = null

## 卡/标记在 picking 阶段(_unhandled 之后)通知本表"本次按下落在卡上";
## 释放时 _unhandled 据此跳过取消(空白按下才取消)。
func notify_pickable_press() -> void:
	_press_on_pickable = true

# ---------- 投入(§2.6, B③#2 跨坐标): 拖标记到选项 → 绑定到选项世界 ----------

## 手牌标记拖放结束: 仅"实拖到选项附近"才投入; "点击 marker (未拖动)" 不视作投入(用户: 投入只走点击手牌)
func _on_marker_dropped(marker: Marker, _at_global: Vector2) -> void:
	# 几乎没动 = 点击 marker, 不投入 → 静默归位(已在 home, 无需动作)
	if (marker.position - marker.get_home_pos()).length() < 6.0:
		return
	if not _focus_active or not is_instance_valid(_focused_option):
		marker.return_home()
		return
	if not (marker.res_type in _focus_whitelist):
		marker.return_home()
		return
	# 邻近判定: 标记当前屏幕位置 vs 选项屏幕投影
	var marker_screen: Vector2 = marker.global_position  # 在 CanvasLayer(identity) 下 = 屏幕坐标
	var option_screen: Vector2 = _focused_option.get_global_transform_with_canvas().origin
	if marker_screen.distance_to(option_screen) > 200.0:
		marker.return_home()
		return
	_invest_marker(marker)

## 把标记从手牌(CanvasLayer 屏幕) reparent 到选项(世界); 保持视觉位置 → 动画到选项的整齐槽
func _invest_marker(marker: Marker) -> void:
	var marker_screen: Vector2 = marker.global_position
	var canvas_xform := get_viewport().get_canvas_transform()
	var marker_world: Vector2 = canvas_xform.affine_inverse() * marker_screen
	# option-local = inverse(option global transform) * world; 考虑选项当前 scale(如 hover 放大 1.12×)
	var option_local_now: Vector2 = _focused_option.get_global_transform().affine_inverse() * marker_world
	marker.get_parent().remove_child(marker)
	_focused_option.add_child(marker)
	marker.position = option_local_now
	marker.set_pickable(false)  # 投入后不可再拖; 切换/取消 flyback 时恢复
	# 动画到选项下半的整齐槽位
	var idx: int = _invested_markers.size()
	var slot_local: Vector2 = Vector2(-90.0 + float(idx % 4) * 45.0, 110.0 + float(idx / 4) * 35.0)
	var tw := marker.create_tween()
	tw.tween_property(marker, "position", slot_local, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_invested_markers.append(marker)
	# 刷新读数
	_update_difficulty(_focus_opt_type, _focus_threshold)

## 聚焦+鉴定+白名单时点手牌 → 投入该卡上的第一个 marker(主投入入口; 标记拖入选项作为备选保留)
func _on_hand_card_clicked(card: CardScn) -> void:
	if not _focus_active or _focused_option == null or not is_instance_valid(_focused_option):
		return
	if _focus_opt_type != MockDataScn.OptType.CHECK:
		return
	var rt: String = card.get_meta("res_type", "")
	if not (rt in _focus_whitelist):
		return
	# 找该卡的第一个 marker 子节点(未投入的均在此)
	for child in card.get_children():
		if child is MarkerScn:
			_invest_marker(child)
			return

## 已投标记飞回手牌: reparent 回对应资源卡(CanvasLayer 屏幕), 恢复拾取;
## 然后对受影响的卡按当前 marker 总数**重排槽位**, 避免全部 tween 到同一 home 而堆叠。
func _flyback_invested_markers() -> void:
	var affected_cards: Array[Node] = []
	for marker in _invested_markers:
		if not is_instance_valid(marker):
			continue
		var rt: String = marker.res_type
		var hand_card: Node2D = _hand_cards.get(rt, null)
		if hand_card == null:
			marker.queue_free()
			continue
		# 视觉连续: 用当前屏幕位置反算 reparent 后的起点(再由 relayout 动画到槽位)
		var marker_screen: Vector2 = marker.get_global_transform_with_canvas().origin
		marker.get_parent().remove_child(marker)
		hand_card.add_child(marker)
		# hand-card local = inverse(hand_card global w/ canvas) * marker_screen; 处理手牌当前 scale(如还原 tween 中)
		marker.position = hand_card.get_global_transform_with_canvas().affine_inverse() * marker_screen
		marker.set_pickable(true)
		if not (hand_card in affected_cards):
			affected_cards.append(hand_card)
	_invested_markers.clear()
	# 对受影响的卡重排所有 marker(包括原有的+新返回的) → 均匀一行, 每个标记一个槽
	for card in affected_cards:
		_relayout_hand_markers(card)

## 按卡上实际 marker 数量重排槽位(均匀一行, 居中); 同步更新各 marker 的 home
func _relayout_hand_markers(card: Node2D) -> void:
	var markers: Array[Node] = []
	for child in card.get_children():
		if child is MarkerScn:
			markers.append(child)
	var n: int = markers.size()
	for i in n:
		var m: Node = markers[i]
		var slot_local: Vector2 = Vector2((float(i) - (float(n) - 1.0) / 2.0) * 36.0, -CardScn.SIZE.y * 0.5 - 26.0)
		var tw := m.create_tween()
		tw.tween_property(m, "position", slot_local, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		if m.has_method("set_home"):
			m.set_home(slot_local)

## 淡出并释放一张卡(从链清单移除)
func _fade_and_free(node: Node2D) -> void:
	_chain_nodes.erase(node)
	var tw := node.create_tween()
	tw.tween_property(node, "modulate:a", 0.0, 0.15)
	tw.tween_callback(node.queue_free)

## 选定选项 → 展开结果卡(牌背, 点击揭示)。
## tier: 调用方传(_confirm_focus 鉴定型由投入算, 直接型固定 success); forced_tier 空时回退随机(防御)。
func _expand_result(opt_type: int, forced_tier: String = "") -> void:
	if _result_shown:
		return
	_result_shown = true
	var tier: String = forced_tier
	if tier.is_empty():
		tier = "success"
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
	if _focus_active:
		_restore_focus()  # 聚焦中抽新牌: 先还原镜头 + 手牌 + 清 UI
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
		if event.pressed:
			_panning = true
			_press_screen = event.position
			_press_moved = false
			_press_on_pickable = false  # 新一轮按下: 默认空白, 拾取阶段会改写
		else:
			# 松手: 取消聚焦的判定 = 聚焦中 且 本次按下既未落在卡/标记上 也未拖动。
			# 2D picking 晚于 _unhandled press, 故由卡/标记在 picking 阶段调 notify_pickable_press()
			# 主动告知 → 释放时这里能正确区分"卡上按下"vs"空白按下"。
			if _focus_active and not _press_on_pickable and not _press_moved:
				_cancel_focus()
			_panning = false
	elif event is InputEventMouseMotion:
		if _panning and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			if event.position.distance_to(_press_screen) > 6.0:
				_press_moved = true  # 判定为拖动(平移), 非点击
			# 屏幕位移 → 世界位移; 反向移动镜头 = "推牌桌"手感; limit_* 已做有界裁剪
			_camera.position -= event.relative / _camera.zoom
		elif not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_panning = false  # 清除残留(如标记拖拽吞掉了松手)
