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

# 显式 preload 卡 / 标记 / 数据源脚本(不依赖全局 class_name 缓存 → 全新克隆 / headless 运行均稳健)
const CardScn := preload("res://scripts/ui/card.gd")
const MarkerScn := preload("res://scripts/ui/marker.gd")
const MockDataScn := preload("res://scripts/ui/mock_data.gd")
const EngineDataSourceScn := preload("res://scripts/ui/engine_data_source.gd")
const MockDataSourceScn := preload("res://scripts/ui/mock_data_source.gd")
# E0 卡牌实体地基: 权威态 + 前端镜像(弱类型 preload 持有, 不依赖 class_name 缓存)
const CardZoneStoreScn := preload("res://scripts/systems/card_zone_store.gd")
const CardRegistryScn := preload("res://scripts/ui/card_registry.gd")

# E0 MVP Zone 清单(逻辑区域, 与视觉父节点解耦): 锚点簇 / 资源手牌 / 因果链 / 弃牌堆
const ZONE_ANCHOR := "anchor"
const ZONE_HAND := "hand_resource"
const ZONE_CHAIN := "causal_chain"
const ZONE_DISCARD := "discard"
# E0 结构性卡的固定 logical_id(无引擎 def, 用约定常量)
const LID_LOCATION := "loc_anchor"
const LID_LEAVE := "leave"

# Line B S8.3: USE_ENGINE 开关 — true = 走真引擎 (EngineDataSource), false = 走 Line A 原 mock (MockDataSource)。
# 接口形状对齐, card_table 调用点零分支; 调试 / 回归测试时改为 false 快速 fallback。
const USE_ENGINE := true

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
const BOARD_DX := 220.0   # 持久盘面卡背横向间距(待办盘面一排)
var _chain_nodes: Array[Node] = []   # 当前 active 事件链的卡/标记(事件→选项→结果), 单事件粒度清场
var _option_cards: Array[Node] = []  # 当前选项卡(选定后清除未选中的)
# ---- 持久盘面(批次一: 待办盘面跨事件留桌; 真源 [[事件包交互流程_持久盘面与流程驱动_MVP]]) ----
var _board_cards: Array[Node] = []   # 待办盘面卡背(镜像引擎 handQueue): 盲选一张少一张, 余背留桌
var _board_active: bool = false      # 盲选守卫: 已有 active 事件结算中 → 余背暂不可选(批次二继续后解锁)
var _location_locked: bool = false   # F2: 地点卡开包瞬间锁定, MVP 单程不恢复
var _board_origin: Vector2 = Vector2.ZERO   # 盘面区起点(卡背横排基准; §五边原型边定)
var _chain_origin: Vector2 = Vector2.ZERO   # 因果链区起点(选中卡飞抵此处翻开+展开)
var _options_shown: bool = false     # 选项已展开守卫(同步置位, 防翻牌 tween 期间重复点击)
var _result_shown: bool = false
var _result_revealed: bool = false   # 结果已揭示守卫(防屏息窗口内重复点击)
var _hand_cards: Dictionary = {}     # res_type -> 手牌资源卡(标记领取飞向目标)
var _hand_home: Dictionary = {}      # res_type -> 手牌 home 屏幕坐标(聚焦后归位)
# ---- 聚焦状态机(§2.9 F: 总览/挂起 → L1 事件焦点 → L2 选项焦点 → 结果态) ----
# 三状态律: ① 点任一因果链卡=聚焦它 ② 拍桌空白=解除回总览(事件挂起非退出) ③ 确定不解除、继续才解除。
const FOCUS_ZOOM := Vector2(1.6, 1.6)   # 聚焦放大倍率(手感, 可调; 精调留 UE pass)
var _event_card: CardScn = null         # F3: 当前 active 事件卡(L1 聚焦目标 + 总览挂起态点它重聚焦入口)
var _sealed: bool = false               # F5 封缄态: 确定后置位, 此后选项/事件不可再聚焦改选
var _focus_active: bool = false         # L2: 选项级聚焦中(可投入/确定); L1 与总览均为 false
var _focused_option: CardScn = null     # 当前聚焦的选项卡
var _focus_opt_type: int = 0            # 当前聚焦选项类型(确定时定 tier)
var _focus_whitelist: Array = []        # 当前聚焦白名单(投入校验用)
var _focus_threshold: int = 0           # 当前聚焦阈值(读数 + 确定时算 tier)
var _invested_markers: Array[Node] = [] # 已投入(绑定到选项)的标记; 切换/取消飞回, 确定消耗
var _pre_focus_cam_pos: Vector2 = Vector2.ZERO
var _pre_focus_cam_zoom: Vector2 = Vector2.ONE
var _pre_focus_saved: bool = false      # 仅首次进入聚焦时记录镜头(切换不覆盖)
var _restore_cam_tween: Tween = null    # 解除聚焦的还原 tween 句柄: 中途重聚焦须 kill(防 chained callback 竞态)
var _confirm_btn: Button = null         # 确定按钮(聚焦期)
var _difficulty_label: Label = null     # 难度提示(鉴定型)
var _press_screen: Vector2 = Vector2.ZERO  # 左键按下屏幕位置(判定点击 vs 拖动)
var _press_moved: bool = false          # 本次按下是否移动过(拖动=平移, 点击=取消聚焦)
var _press_on_pickable: bool = false    # 本次按下是否落在卡/标记上(picking 阶段通知 → 不取消聚焦)

# Line B S8.3: 数据源 (与 mock 同形接口的引擎适配器 / mock 包装器, 由 USE_ENGINE 选择)
var _data_source: RefCounted = null
# E0: 卡实例 + Zone 权威态(前端暂持; E1 移交 world_state) + 前端镜像注册表(弱类型持有)
var _zone_store: RefCounted = null
var _registry: RefCounted = null
# 当前 pending 事件的 selected option_id (聚焦时记下, 确定时传给 outcome_for_option)
var _focus_option_id: String = ""

func _ready() -> void:
	add_to_group("card_table")  # 供卡/标记 picking 时回查通知本表(聚焦取消判定)
	# 启用 2D 物理拾取 → 卡牌 / 标记 的 Area2D hover/click 生效
	get_viewport().physics_object_picking = true
	_init_data_source()
	_init_card_system()
	_build_table()
	_build_camera()
	_build_layers()
	_build_system_buttons()
	_build_anchor_cluster()
	_build_hand_zone()

## Line B S8.3: 按 USE_ENGINE 实例化数据源 (EngineDataSource 或 MockDataSource, 同形接口)。
func _init_data_source() -> void:
	if USE_ENGINE:
		_data_source = EngineDataSourceScn.new(0)
	else:
		_data_source = MockDataSourceScn.new()

## E0 卡牌实体地基: 初始化前端暂持的权威态(store)+ 镜像(registry)+ 登记 MVP Zone。
## E1 引擎接入后 store 移交 world_state, 此处改为取引擎持有的 store(registry 接口不变)。
func _init_card_system() -> void:
	_zone_store = CardZoneStoreScn.new()
	_registry = CardRegistryScn.new()
	for z: String in [ZONE_ANCHOR, ZONE_HAND, ZONE_CHAIN, ZONE_DISCARD]:
		_zone_store.register_zone(z)

## E0 统一 spawn: store 分配 uid + Zone 归属 → 建 Card 持 model → add_child(触发 _ready, 故
## face_up / back 须在此前设)→ register 入镜像。position 由调用方在返回后设(不受 _ready 影响)。
## uid_override: 预留参数(透传 create_card 检重路径)。F1 暂不使用——前端/引擎双 store 同 cN 空间
##   会撞号; uid 对齐随持久盘面用"手牌卡只镜像引擎 store"做对(见 [[事件包交互流程_持久盘面与流程驱动_MVP]])。
##   当前所有卡均走前端自动分配(空 override)。
func _spawn_card(logical_id: String, kind: int, zone_id: String, parent: Node,
		title: String = "", body: String = "", face_up: bool = true, back: String = "",
		uid_override: String = "") -> CardScn:
	var data: CardData = _zone_store.create_card(logical_id, kind, {}, zone_id, [], uid_override)
	var c := CardScn.new()
	c.model = data
	c.card_type = kind
	c.title_text = title
	c.body_text = body
	c.start_face_up = face_up
	c.back_label = back
	parent.add_child(c)
	_registry.register(c)
	return c

## E0 数据层注销: Card 转入目标 Zone(数据留档)+ 注销前端镜像。不负责视觉回收(非卡 no-op)。
## DD1 镜像安全: 镜像卡(引擎 store 持有、前端 _zone_store 无)只注销镜像、不动前端 store
##   (否则 move_card 对不存在 uid 会 push_warning); 引擎侧 store 的清理由引擎 _clear_pack_context
##   负责(批次二继续推进时触发)。前端自持卡照常转 discard 留档。
func _detach_card_data(node: Node, to_zone: String = ZONE_DISCARD) -> void:
	if node == null or not (node is CardScn):
		return
	var model: CardData = node.get("model")
	if model != null and not model.card_uid.is_empty():
		if _zone_store.has_card(model.card_uid):
			_zone_store.move_card(model.card_uid, to_zone)
		_registry.unregister(node)

## E0 统一 despawn: 数据注销 + 立即视觉回收。
func _despawn_card(node: Node, to_zone: String = ZONE_DISCARD) -> void:
	_detach_card_data(node, to_zone)
	if is_instance_valid(node):
		node.queue_free()

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

## 地点锚点簇(§2.3, 持久, 上区左端): 地点卡 + 我要走
## 批次一: 移除【事件牌库】卡 —— 开包入口并入【地点卡】(语义自洽: 事件本由地点调度产出)。
func _build_anchor_cluster() -> void:
	var loc := _spawn_card(LID_LOCATION, CardScn.CardType.LOCATION, ZONE_ANCHOR, _upper_zone,
		"青石镇", "你暂居此处，江湖讯息往来。", true)
	loc.position = Vector2(440, 520)
	loc.clicked.connect(func(_c: CardScn) -> void: _open_pack())  # 点地点卡 = 开本地点事件包
	var leave := _spawn_card(LID_LEAVE, CardScn.CardType.LEAVE, ZONE_ANCHOR, _upper_zone,
		"我要走", "另择去处。", true)
	leave.position = Vector2(440, 840)

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
		# E0: 资源卡 logical_id = res_type; 属"资源手牌"Zone; 视觉常驻下区 CanvasLayer
		var card := _spawn_card(res_types[i], CardScn.CardType.RESOURCE, ZONE_HAND, _lower_layer,
			titles[i], bodies[i], true)
		card.position = Vector2(start_x + i * spacing, y)
		card.set_meta("res_type", res_types[i])
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

# ---------- 持久盘面 + 因果链(批次一; §2.3, 验 B③#5) ----------

## 开包(批次一): 点【地点卡】触发。调 pack_window_for_pile 拿承诺窗口 → 摊出 K 张(blind)/
## 1 张(single skeleton)卡背作【待办盘面】横排 → 地点卡锁定。盘面卡背跨事件留桌, 由 _on_board_pick
## 逐张盲选, 余背不消散。真源: [[事件包交互流程_持久盘面与流程驱动_MVP]] §二/§九批次一。
func _open_pack() -> void:
	if _location_locked:
		return  # F2: 地点卡开包后锁定, MVP 单程不恢复, 再点无反应
	# 防御性整桌清场(单程下仅首次开包跑, 盘面/链均空 → 实为 no-op; 防异常重入残留)。
	_clear_board()
	_clear_event_chain()
	_board_origin = Vector2(760, 480)   # 盘面横排起点: 地点卡右侧偏上(§五边原型边定)
	_chain_origin = Vector2(760, 900)   # 因果链区起点: 盘面下方; 选中卡飞抵此处翻开+向右展开
	var window: Dictionary = _data_source.pack_window_for_pile()
	if not window.get("ok", false):
		push_error("[card_table] pack_window_for_pile failed: %s" % str(window.get("error", "")))
		return
	var cards: Array = window.get("cards", [])
	if cards.is_empty():
		push_error("[card_table] pack_window_for_pile 返回空窗口")
		return
	_location_locked = true   # 开包即锁(F2)
	_populate_board(window)

## 摊出待办盘面(批次二抽出, 开包 + 玩满 C 骨架登场 + 自省终点共用): 按 window.mode spawn 卡背横排,
## 接 _on_board_pick, 复位 _board_active。blind = K 张镜像引擎 store(DD1); single = 1 张前端自分配
## (skeleton / sys_reflection, uid 空, pick 走 stash)。调用前盘面须已清(_open_pack 锁后调 / 继续时
## _clear_board 后调)。
func _populate_board(window: Dictionary) -> void:
	var cards: Array = window.get("cards", [])
	var mode := str(window.get("mode", ""))
	_board_cards.clear()
	_board_active = false
	for i in cards.size():
		var cd: Dictionary = cards[i]
		var uid := str(cd.get("uid", ""))          # blind: 引擎 handQueue uid; single: 空串
		var event_id := str(cd.get("event_id", "")) # 卡背 logical_id(盲选时不可见, 翻开才显文字)
		# DD1 镜像派: blind 卡背是引擎预抽的 handQueue 实例 → 镜像引擎 store(前端卡 uid == 引擎 uid,
		# 不进前端 _zone_store, 杜绝双 store 撞号)。single(uid 空, skeleton/自省)无引擎 handQueue 实例
		# → 退前端自分配; pick 走 pack_window 暂存的 stash(uid 空闭包)。
		var back: CardScn
		if mode == "blind" and not uid.is_empty():
			back = _spawn_mirror_card(uid, event_id, _upper_zone)
			if back == null:
				continue  # 不变量违例(引擎取数失败), 已报错 → 跳过此卡(盘面会少一张, 故意暴露而非静默)
		else:
			back = _spawn_card(event_id, CardScn.CardType.EVENT, ZONE_CHAIN, _upper_zone, "", "", false, "")
		back.position = Vector2(_board_origin.x + i * BOARD_DX, _board_origin.y)  # 待办盘面横排
		_board_cards.append(back)
		# 闭包按值捕获引擎下发的 uid + 节点(blind 传 uid / single 传空串给 pick_hand)。
		var pick_uid := uid
		back.clicked.connect(func(c: CardScn) -> void: _on_board_pick(c, pick_uid))

## 镜像 spawn(DD1): 手牌卡背只持引擎 store 的 CardData + 进 registry 镜像, 不进前端 _zone_store。
## 故前端卡 uid 即引擎 uid, registry 可按引擎 uid 寻址持久手牌卡节点(为"引擎指定操作某张持久卡 →
## 前端联动"铺路)。引擎取数失败属不变量违例(uid 来自引擎刚预抽进 handQueue 的同一 store, get_card
## 必命中)→ 响亮报错 + 返回 null(由调用方跳过), 不静默退前端自建(否则 uid 错配难诊断, 违 DD1)。
func _spawn_mirror_card(uid: String, _logical_id: String, parent: Node) -> CardScn:
	var data: CardData = null
	if _data_source.has_method("engine_card_data"):
		data = _data_source.engine_card_data(uid)
	if data == null:
		push_error("[card_table] 镜像取引擎 CardData 失败 uid=%s (不变量违例: handQueue uid 应在引擎 store)" % uid)
		return null
	var c := CardScn.new()
	c.model = data                  # 持引擎 CardData → 前端卡 uid == 引擎 uid
	c.card_type = data.card_kind
	c.title_text = ""
	c.body_text = ""
	c.start_face_up = false
	c.back_label = ""
	parent.add_child(c)
	_registry.register(c)           # 只镜像引擎 store, 不进前端 _zone_store(避免双 store 撞号)
	return c

## 盲选盘面一张(批次一): 调 pick_hand → 翻开为真实事件; 余背【留桌】不消散; 选中卡转因果链区
## 展开选项。守卫 _board_active: active 事件结算中余背暂不可选(继续清场后解锁 → 批次二)。
func _on_board_pick(chosen: CardScn, pick_uid: String) -> void:
	if _board_active:
		# 已有 active 事件: 点的若是当前事件卡 → 总览挂起态重聚焦 L1(§2.9 F「点卡重聚焦」);
		# 封缄后不再重聚焦; 其余余背一律不可选(防并发, 防误触 forced 打乱调度)。
		if chosen == _event_card and not _sealed:
			_refocus_event()
		return
	_board_active = true
	var event_info: Dictionary = _data_source.pick_hand(pick_uid)
	if not event_info.get("ok", false):
		push_error("[card_table] pick_hand failed: %s" % str(event_info.get("error", "")))
		_board_active = false  # 失败放守卫, 允许重试(异常恢复)
		return
	# 持久盘面: 余背【不消散、留桌】; 仅把选中卡从盘面摘出、转入 active 事件链。
	_board_cards.erase(chosen)
	_chain_nodes.append(chosen)   # 计入事件链 → 继续清场时随链回收(非盘面回收)
	_relayout_board()             # DD-B2: 其后余背向前补齐, 平滑滑动填空洞(与选中卡飞出同时)
	# 选中卡: 填真实事件文字 → 飞到因果链起点 → 翻开 → 进 L1 事件聚焦 → 展开选项。
	chosen.set_face_text(str(event_info.get("title", "")), str(event_info.get("body", "")))
	if chosen.position != _chain_origin:
		var tw := chosen.create_tween()
		tw.tween_property(chosen, "position", _chain_origin, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	chosen.flip_to(true)
	_event_card = chosen          # F3: 记 active 事件卡(L1 聚焦目标 + 重聚焦入口; chosen.clicked 已连 _on_board_pick)
	# F3 L1 事件级聚焦: 镜头聚焦事件卡 → 再展开选项(§2.9 F: 总览 → L1)。
	# 传 _chain_origin(事件卡飞行终点)而非读飞行中 global_position(codex P2)。
	_focus_camera_on(_chain_origin)
	if not _options_shown:
		_options_shown = true
		_expand_options()

## 余背向前补齐(DD-B2): 剩余盘面卡按新序号紧凑左对齐, 平滑滑动填被选走的空洞。
## 被选走位置之前的卡序号不变 → 目标位 == 现位 → 跳过(无谓 tween); 之后的卡向前滑一格。
func _relayout_board() -> void:
	for i in _board_cards.size():
		var node: Node2D = _board_cards[i]
		if not is_instance_valid(node):
			continue
		var target := Vector2(_board_origin.x + i * BOARD_DX, _board_origin.y)
		if node.position.is_equal_approx(target):
			continue  # 已在位(空洞之前的卡) → 不动
		var tw := node.create_tween()
		tw.tween_property(node, "position", target, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

## 展开选项: 调 _data_source 拿选项数据 (≤3, 水平排在事件右侧; 纯代码偏移 → 均匀无重叠)
func _expand_options() -> void:
	var options: Array = _data_source.options_for_event()
	var n: int = options.size()
	_option_cards.clear()
	for i in n:
		var opt_data: Dictionary = options[i]
		var option_id := str(opt_data.get("id", ""))
		var opt_text := str(opt_data.get("text", ""))
		var opt_type: int = int(opt_data.get("opt_type", 0))
		var whitelist: Array = opt_data.get("whitelist", [])
		var threshold: int = int(opt_data.get("threshold", 0))
		var body := _option_body_hint(opt_type, whitelist)
		# E0: 选项 logical_id = option_id; opt_type/whitelist/threshold 属"本次结算上下文"
		# (非卡静态身份), 仍按值闭包捕获(见 §三决策① 最小迁移)
		var opt := _spawn_card(option_id, CardScn.CardType.OPTION, ZONE_CHAIN, _upper_zone, opt_text, body, true)
		opt.position = Vector2(_chain_origin.x + (i + 1) * SLOT_DX, _chain_origin.y)  # 紧邻事件向右依次排
		_chain_nodes.append(opt)
		_option_cards.append(opt)
		# 闭包按值捕获 option_id / opt_type / whitelist / threshold (后续聚焦+确定都用)
		var oid := option_id
		var t := opt_type
		var wl: Array = whitelist
		var th := threshold
		opt.clicked.connect(func(c: CardScn) -> void: _on_option_chosen(c, oid, t, wl, th))

## 选项卡正文文案 (鉴定型显示白名单, 直接型显示固定提示)
func _option_body_hint(opt_type: int, whitelist: Array) -> String:
	if opt_type == EngineDataSourceScn.OptType.DIRECT:
		return "直接型 · 必有数值成长"
	if whitelist.is_empty():
		return "鉴定型"
	return "鉴定型 · " + " / ".join(whitelist)

## 选定一个选项(直接型 / 鉴定型都进入聚焦); 已聚焦时点另一选项 = 切换
func _on_option_chosen(chosen: CardScn, option_id: String, opt_type: int, whitelist: Array, threshold: int) -> void:
	if _sealed or _result_shown:
		return  # F5 封缄后选项不可改(§2.9 F)
	if _focus_active and chosen == _focused_option:
		return
	_enter_focus(chosen, option_id, opt_type, whitelist, threshold)

## 提交选项: 未选中的淡出消失 + 选中项归到事件右侧固定槽(此后不可改选)
func _commit_option(chosen: CardScn) -> void:
	for opt in _option_cards:
		if opt != chosen and is_instance_valid(opt):
			_fade_and_free(opt)
	_option_cards.clear()
	var slot := Vector2(_chain_origin.x + SLOT_DX, _chain_origin.y)  # 选中项归到事件右侧紧邻槽
	var tw := chosen.create_tween()
	tw.tween_property(chosen, "position", slot, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# ---------- 聚焦状态机公共原语(§2.9 F) ----------

## 聚焦到某世界坐标(F3 通用子函数, L1 事件级 / L2 选项级 / 重聚焦 共用):
## 传目标世界坐标(非读节点 global_position — 避免目标卡仍在飞行中 tween 时取到旧位, codex P2)。
## 入口先 kill 待定的还原 tween(防其 chained callback 误清 _pre_focus_saved, codex P1)。
## 首次进入聚焦时记录总览镜头(切换/重聚焦不覆盖, 供解除时还原)→ 镜头 zoom + 居中到目标。
func _focus_camera_on(world_pos: Vector2) -> void:
	if _restore_cam_tween != null and _restore_cam_tween.is_valid():
		_restore_cam_tween.kill()   # 中途重聚焦: 杀还原 tween → 其 _pre_focus_saved=false callback 不再触发
	_restore_cam_tween = null
	if not _pre_focus_saved:
		_pre_focus_cam_pos = _camera.position
		_pre_focus_cam_zoom = _camera.zoom
		_pre_focus_saved = true
	var cam_tw := _camera.create_tween()
	cam_tw.set_parallel(true)
	cam_tw.tween_property(_camera, "position", world_pos, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	cam_tw.tween_property(_camera, "zoom", FOCUS_ZOOM, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

## 仅平移镜头到世界坐标(保持当前 zoom): 封缄后呈现结果卡用(§2.9 F: 结果态仍聚焦)。
func _pan_camera_to(world_pos: Vector2) -> void:
	var tw := _camera.create_tween()
	tw.tween_property(_camera, "position", world_pos, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

## 重聚焦事件卡(§2.9 F: 总览挂起态/L1 点事件卡 → L1; 若当前在 L2 则先退选项回 L1, 镜头转事件不回总览)。
func _refocus_event() -> void:
	if _event_card == null or not is_instance_valid(_event_card):
		return
	if _focus_active:
		_flyback_invested_markers()   # L2 → L1: 未确定的投入飞回(可逆)
		_clear_option_focus_ui()
	_focus_camera_on(_chain_origin)   # 事件卡恒在 _chain_origin(已落位)

## 清选项级(L2)UI: 取消选中 + 释放确定按钮/难度 + 手牌归位 + 复位 L2 标志。不动镜头、不飞回标记
## (飞回/消耗由调用方按场景决定: 切换/取消飞回, 确定消耗)。
func _clear_option_focus_ui() -> void:
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

# ---------- 选项聚焦(L2; §2.5 镜头 zoom 驱动) ----------

## 进入/切换 L2 选项聚焦: 镜头收紧到该选项 + 选中高亮 + 手牌前推(白名单)/收起 + 难度提示 + 确定按钮。
## 由 L1 / 总览(挂起)点选项卡进入(§2.9 F)。切换 = 已聚焦时点另一选项(旧投入飞回)。点桌面空白解除(见 _unhandled_input)。
func _enter_focus(option: CardScn, option_id: String, opt_type: int, whitelist: Array, threshold: int) -> void:
	# 切换: 先把已投入旧选项的标记飞回手牌, 再取消旧选项选中 + 释放旧选项上的确定按钮(后面在新选项上重建)
	if _focused_option != null and is_instance_valid(_focused_option) and _focused_option != option:
		_flyback_invested_markers()
		_focused_option.set_selected(false)
		if _confirm_btn != null and is_instance_valid(_confirm_btn):
			_confirm_btn.queue_free()
			_confirm_btn = null
	_focus_active = true
	_focused_option = option
	_focus_option_id = option_id
	_focus_opt_type = opt_type
	_focus_whitelist = whitelist
	_focus_threshold = threshold
	option.set_selected(true)
	_focus_camera_on(option.global_position)   # L2: 镜头收紧到选项(选项已落位, global_position 即终点)
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

## 拍桌空白解除聚焦(§2.9 F): L1/L2 均回总览(事件挂起、非退出, 点因果链卡可重聚焦);
## 封缄态不解除(确定后镜头随结果, 由点继续才解除)。
func _cancel_focus() -> void:
	if _sealed:
		return
	if _pre_focus_saved:
		_unfocus_to_overview()

## 确定 = 封缄(F5): 算 tier → 消耗投入标记(不飞回)→ 置封缄态 → 退 L2 UI → 提交 + 出结果。
## 不解除聚焦(§2.9 F: 确定不回总览, 镜头保持聚焦态并平移呈现结果; 解除留到点继续)。
func _confirm_focus() -> void:
	if not _focus_active:
		return
	var option: CardScn = _focused_option
	var option_id: String = _focus_option_id
	var opt_type: int = _focus_opt_type
	var invested: int = _invested_markers.size()
	var threshold: int = _focus_threshold
	var tier := str(_data_source.tier_from_invest(opt_type, invested, threshold))
	# 封缄(F5): 投入标记消耗释放, 不飞回; 此后选项不可改、投入不可撤。
	for m in _invested_markers:
		if is_instance_valid(m):
			m.queue_free()
	_invested_markers.clear()
	_sealed = true
	_clear_option_focus_ui()   # 退 L2 UI(确定按钮/难度/手牌归位/取消选中), 镜头保持聚焦态(不还原总览)
	if is_instance_valid(option):
		_commit_option(option)
		_expand_result(option_id, opt_type, tier)  # 内部 _pan_camera_to 结果卡(仍聚焦)

## 解除聚焦回总览(§2.9 F: 拍桌空白 / 点继续 触发): 投入标记飞回 → 镜头还原总览 → 退 L2 UI。
## 事件状态保留(挂起, 非退出); pre_focus 还原 tween 完成后才清标志(中途再聚焦仍用原总览镜头)。
func _unfocus_to_overview() -> void:
	_flyback_invested_markers()
	if _pre_focus_saved:
		var cam_tw := _camera.create_tween()
		cam_tw.set_parallel(true)
		cam_tw.tween_property(_camera, "position", _pre_focus_cam_pos, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		cam_tw.tween_property(_camera, "zoom", _pre_focus_cam_zoom, 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		cam_tw.chain().tween_callback(func() -> void: _pre_focus_saved = false)
		_restore_cam_tween = cam_tw   # 存句柄: 还原途中若重聚焦, _focus_camera_on 会 kill 它(防 callback 误清标志)
	_clear_option_focus_ui()

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
	_detach_card_data(node)  # E0: Card → 转 discard + 注销镜像(非卡 no-op), 再视觉淡出回收
	var tw := node.create_tween()
	tw.tween_property(node, "modulate:a", 0.0, 0.15)
	tw.tween_callback(node.queue_free)

## 选定选项 → 展开结果卡(牌背, 点击揭示)。
## option_id / tier: 调用方传(_confirm_focus 算好); 经 _data_source 取 §3.2 stub 账单。
func _expand_result(option_id: String, opt_type: int, tier: String) -> void:
	if _result_shown:
		return
	_result_shown = true
	var _unused_opt_type := opt_type  # 占位: tier 已由 _confirm_focus 决定, opt_type 不再分支
	var outcome: Dictionary = _data_source.outcome_for_option(option_id, tier)
	# E0: 结果卡 logical_id 由 option_id 合成(同一选项的结果可寻址)
	var res := _spawn_card("result:" + option_id, CardScn.CardType.RESULT, ZONE_CHAIN, _upper_zone,
		str(_data_source.tier_label(tier)), "点击牌背揭示。", false)
	res.position = Vector2(_chain_origin.x + SLOT_DX * 2.0, _chain_origin.y)  # 结果在选中选项右侧
	_chain_nodes.append(res)
	res.clicked.connect(func(c: CardScn) -> void: _reveal_result(c, outcome))
	# §2.9 F 结果态: 仍聚焦, 镜头平移呈现结果(选中选项与结果之间, 兼顾两者); 解除留到点继续。
	_pan_camera_to(Vector2(_chain_origin.x + SLOT_DX * 1.5, _chain_origin.y))

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
	_spawn_continue_card()  # F4: 结果揭示后出现【继续】卡(DD-B1: 领取可选, 不强制领完)

## 在结果卡旁生成可领取标记(实体 + 经验成长); 放世界(UpperZone), 与结果卡相对位置固定、随镜头一起动
## Line B S8.4: dir 字段处理 —— gain 走可领取通道; loss 暂走 print 提示(已扣除展示由后续 playtest 决议视觉)。
func _spawn_claimable_markers(result_card: CardScn, outcome: Dictionary) -> void:
	var base: Vector2 = result_card.position  # 世界坐标(牌桌上), 锚定结果卡
	var idx: int = 0
	var markers: Array = outcome.get("markers", [])
	for entry in markers:
		var d: Dictionary = entry
		var count: int = int(d.get("count", 1))
		var dir := str(d.get("dir", "gain"))
		var rt := String(d["type"])
		if dir == "loss":
			# Line B S8.4 占位: loss 标记不可领取(引擎已在 world_state 扣除),
			# 仅打印提示供调试; 视觉表现 (从资源卡飞出 / 红字提示等) 待 playtest 决议。
			print("[card_table] loss marker (already deducted): type=%s count=%d kind=%s" % [
				rt, count, String(d["kind"])
			])
			continue
		for k in count:
			_make_claimable(rt, String(d["kind"]), base, idx)
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

## F4【继续】卡(批次二): 结果揭示后出现, 排结果卡右侧。点击 = 推进(_on_continue)。
## 复用前端自分配卡(ZONE_CHAIN, CONTINUE 类型), 随事件链由 _clear_event_chain 回收。
func _spawn_continue_card() -> void:
	var cont := _spawn_card("continue", CardScn.CardType.CONTINUE, ZONE_CHAIN, _upper_zone,
		"继续", "推进。", true)
	cont.position = Vector2(_chain_origin.x + SLOT_DX * 3.0, _chain_origin.y)  # 结果卡(SLOT_DX*2)右侧
	_chain_nodes.append(cont)
	cont.clicked.connect(func(_c: CardScn) -> void: _on_continue())

## F4 推进(批次二, 持久盘面统一推进入口): 清当前事件链 → 重对账 pack_window_for_pile → 按 mode 三分支。
## 实测信号(2026-06-09 探针): blind=仍普通容量(回盘面) / single=玩满 C 骨架登场 或 包结束自省。
## 骨架与自省走同一 single 通道, pick 后 has_choice 自然分流(骨架有选项→事件流程; 自省 0 选项→停住=终点)。
func _on_continue() -> void:
	_clear_event_chain()
	var window: Dictionary = _data_source.pack_window_for_pile()
	if not window.get("ok", false):
		# 包结束 / 世界终止: 无更多事件可推进 → 流程停住(MVP 单程自然终点, 不再开下一包)。
		push_warning("[card_table] 继续: pack_window 无更多事件 → 终点 (%s)" % str(window.get("error", "")))
		return
	var mode := str(window.get("mode", ""))
	if mode == "blind":
		# 回持久盘面: 余背 pick 时已向前补齐、紧凑在桌, 仅解除 active 守卫 → 可盲选下一张。
		# 对账(调试): 返回的剩余 handQueue uid 集合应与现存盘面镜像卡一致。
		_debug_assert_board_sync(window)
		_board_active = false
	else:
		# single: 玩满 C(骨架)或包结束(自省)。§四.3 余牌须消散且不可点(防误触 forced 打乱末位调度) →
		# _clear_board 物理回收余背节点; 再摊出 1 张卡背(骨架/自省同通道)。
		_clear_board()
		_populate_board(window)

## 盘面 ↔ 引擎 handQueue 对账(调试断言): 继续回盘面时, pack_window 返回的剩余 uid 集合
## 应与现存盘面镜像卡的 uid 集合一致(持久盘面不重摊, 仅复用既有节点)。不一致只告警, 不中断。
func _debug_assert_board_sync(window: Dictionary) -> void:
	var win_uids: Dictionary = {}
	for c_v in window.get("cards", []):
		var u := str((c_v as Dictionary).get("uid", ""))
		if not u.is_empty():
			win_uids[u] = true
	var board_uids: Dictionary = {}
	for node in _board_cards:
		if not is_instance_valid(node):
			continue
		var model: CardData = node.get("model")
		if model != null and not model.card_uid.is_empty():
			board_uids[model.card_uid] = true
	if win_uids.size() != board_uids.size():
		push_warning("[card_table] 盘面对账不一致: 引擎余 %d 张, 前端盘面 %d 张" % [win_uids.size(), board_uids.size()])
		return
	for u in win_uids:
		if not board_uids.has(u):
			push_warning("[card_table] 盘面对账缺 uid=%s (引擎有、前端盘面无)" % u)

## 清空【当前 active 事件链】(单事件粒度; 盘面卡背不动)。
## 触发点: 【继续】卡推进时调(_on_continue, 普通→回盘面 / single→骨架·自省前先清当前链); 开包防御性调用。
## 回收范围: 事件卡 + 选项卡 + 结果卡 + 【继续】卡 + 未领取标记(_chain_nodes), 不含 _board_cards。
func _clear_event_chain() -> void:
	# §2.9 F「点继续 → 解除聚焦回总览」: 事件结束清场前先解除聚焦(L1/L2/结果态/封缄态均还原镜头)。
	if _pre_focus_saved:
		_unfocus_to_overview()
	for node in _chain_nodes:
		if not is_instance_valid(node):
			continue
		if node is CardScn:      # Card → despawn(前端卡转 discard / 镜像卡仅注销镜像)
			_despawn_card(node)
		else:                    # Marker 等非卡 → 裸回收
			node.queue_free()
	_chain_nodes.clear()
	_option_cards.clear()
	_event_card = null       # F3: 复位事件聚焦目标
	_sealed = false          # F5: 复位封缄态(下一事件重新可聚焦/改选)
	_options_shown = false
	_result_shown = false
	_result_revealed = false

## 清空【整个待办盘面】(批次一拆分: 包结束 / 玩满 C 余牌消散时调; 批次二接线触发)。
## 回收范围: 盘面卡背(_board_cards), 不含 active 事件链(_chain_nodes 各自由 _clear_event_chain 回收)。
func _clear_board() -> void:
	for node in _board_cards:
		if not is_instance_valid(node):
			continue
		if node is CardScn:      # 镜像卡: _despawn_card → _detach 仅注销镜像(前端 store 无)+ 裸回收
			_despawn_card(node)
		else:
			node.queue_free()
	_board_cards.clear()
	_board_active = false

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
			# 松手: 解除聚焦的判定 = 处于聚焦态(L1 或 L2) 且 本次按下既未落在卡/标记上 也未拖动。
			# 2D picking 晚于 _unhandled press, 故由卡/标记在 picking 阶段调 notify_pickable_press()
			# 主动告知 → 释放时这里能正确区分"卡上按下"vs"空白按下"。封缄态由 _cancel_focus 内部守卫挡住。
			if _pre_focus_saved and not _press_on_pickable and not _press_moved:
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
