class_name EventStage
extends Node2D
## 焦点升格舞台(乙方案 · 2026-06-16) ——
## 事件聚焦时在【世界内】放大成一块场景面板: 16:9 美术做底 + 暗化遮罩 + 标题 + 叙事正文。
## 选项 / 结果卡(由 card_table 持有, 仍是世界内 Card 节点)布局在本面板范围内, 形成
## "事件升格、包裹选项与结果"的观感(真源 [[卡牌前端交互设计]] §2.9 F · B 升格)。
##
## 关键设计:
## - 以原点为中心绘制(-SIZE/2 ~ +SIZE/2), 便于 card_table 居中放置 + 镜头取景。
## - 受镜头 zoom(挂在 UpperZone 世界层); 叙事正文用 **MSDF 字体**, zoom 放大仍锐利(解决"拉近撑字发虚")。
## - 美术 / 遮罩 / 文字均挂在 clip_contents 容器内 → 16:9 图满铺(COVERED)且裁到面板矩形, 不溢出。
## - z_index 调低(由 card_table 设)→ 选项 / 结果卡叠在面板之上。

const PANEL_SIZE := Vector2(1500, 820)
const ART_DIR := "res://assets/art/backgrounds/"
const BODY_AREA_H := 360.0   # 上部叙事区高度; 下部留给选项 / 结果卡(card_table 在面板范围内布局)

# MSDF 字体(多通道有向距离场): 任意缩放保持锐利, 仅升格叙事面板用(卡面小字仍用普通 SystemFont)。
static var _msdf_font: SystemFont = null

var _clip: Control          # 裁剪容器(clip_contents): 美术/遮罩/文字裁到面板矩形内
var _frame: ColorRect       # 兜底底框(美术缺失时露此色)
var _art: TextureRect       # 16:9 场景美术(KEEP_ASPECT_COVERED 满铺, 溢出由 _clip 裁掉)
var _scrim: ColorRect       # 暗化遮罩(压暗美术保证文字可读)
var _title_label: Label
var _body_label: Label
var _fade_tween: Tween      # 当前淡入/淡出 tween; 切换前 kill, 防"淡出 callback 误隐已重聚焦舞台"(P2-1)

## MSDF 字体单例(zoom 下恒锐)。
static func get_msdf_font() -> SystemFont:
	if _msdf_font == null:
		_msdf_font = SystemFont.new()
		_msdf_font.font_names = PackedStringArray([
			"Microsoft YaHei", "Microsoft YaHei UI", "SimHei", "Noto Sans CJK SC", "sans-serif",
		])
		_msdf_font.multichannel_signed_distance_field = true
	return _msdf_font

func _ready() -> void:
	_build()

## 构建面板视觉(全部挂 clip 容器: 底框 → 美术 → 遮罩 → 标题 → 叙事正文, 按此序叠放)。
## 子节点坐标相对 _clip 局部空间(0,0 = 面板左上)。
func _build() -> void:
	var tl: Vector2 = -PANEL_SIZE * 0.5
	_clip = Control.new()
	_clip.position = tl
	_clip.size = PANEL_SIZE
	_clip.clip_contents = true   # 美术 / 遮罩裁到面板矩形, 防 16:9 图溢出(P2-2)
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clip)

	_frame = ColorRect.new()
	_frame.color = Color("1c1e26")
	_frame.position = Vector2.ZERO
	_frame.size = PANEL_SIZE
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.add_child(_frame)

	_art = TextureRect.new()
	_art.position = Vector2.ZERO
	_art.size = PANEL_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED   # 满铺保比例; 溢出部分被 _clip 裁掉
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art.visible = false   # 缺图时不显示, 露底框色
	_clip.add_child(_art)

	_scrim = ColorRect.new()
	_scrim.color = Color(0.05, 0.06, 0.09, 0.55)
	_scrim.position = Vector2.ZERO
	_scrim.size = PANEL_SIZE
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.add_child(_scrim)

	_title_label = _make_label(34, Vector2(48, 36), PANEL_SIZE.x - 96)
	_title_label.add_theme_color_override("font_color", Color("ffe9b0"))
	_clip.add_child(_title_label)

	_body_label = _make_label(26, Vector2(48, 110), PANEL_SIZE.x - 96)
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.size = Vector2(PANEL_SIZE.x - 96, BODY_AREA_H)  # 上部叙事区; 下部留给选项卡
	_clip.add_child(_body_label)

## 创建套 MSDF 字体的 Label(坐标相对 _clip 局部空间)。
func _make_label(font_size: int, pos: Vector2, width: float) -> Label:
	var l := Label.new()
	l.position = pos
	l.custom_minimum_size = Vector2(width, 0)
	l.size = Vector2(width, 0)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", get_msdf_font())
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", Color("ece7da"))
	return l

## 配置面板内容: 标题 + 美术文件名(仅文件名, 内部拼 res 路径)+ 叙事正文。
func setup(title_text: String, art_filename: String, narrative: String) -> void:
	_title_label.text = title_text
	_body_label.text = narrative
	_load_art(art_filename)

## 切换叙事正文(结果揭示时换成反馈文字; 标题/美术保持不变 —— 仍是同一事件舞台)。
func set_narrative(narrative: String) -> void:
	_body_label.text = narrative

## 加载 16:9 美术(满铺保比例, 溢出由 _clip 裁); 缺图 / 加载失败 → 露底框色, 不报错(冒烟 #5)。
func _load_art(art_filename: String) -> void:
	if art_filename.is_empty():
		_art.visible = false
		return
	var path: String = ART_DIR + art_filename
	if not ResourceLoader.exists(path):
		_art.visible = false
		return
	var tex: Texture2D = load(path)
	if tex == null:
		_art.visible = false
		return
	_art.texture = tex
	_art.visible = true

## 升格淡入(先 kill 旧 tween 防竞态: 淡出途中重聚焦 → 旧淡出 callback 不再误隐)。
func fade_in() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	modulate.a = 0.0
	visible = true
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 1.0, 0.25)

## 收拢淡出(解除聚焦时调; 末尾置 visible=false。先 kill 旧 tween 防与淡入抢)。
func fade_out() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 0.0, 0.2)
	_fade_tween.tween_callback(func() -> void: visible = false)
