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
##
## 升格/收拢动效(UE pass · 方案乙三段式 · 2026-06-28): 外框 morph + 内容淡入, 纯色块避免信息拉伸。
## 展开三段: ①卡→纯色块(外框以【事件卡底色】登场盖住卡位, 卡同帧隐 → 信息褪为纯色) → ②纯色块扩展
## (外框 size/pos morph 到满面板 + 色渐变到面板底色, 纯色插值不糊) → ③信息浮现(内容 _clip alpha 淡入)。
## 收拢三段逆向: 信息淡出 → 纯色块缩回卡 rect + 色回卡色 → 纯色块消失、事件卡现身(card_table 完成回调)。

const PANEL_SIZE := Vector2(1500, 820)
const ART_DIR := "res://assets/art/backgrounds/"
const BODY_AREA_H := 360.0   # 上部叙事区高度; 下部留给选项 / 结果卡(card_table 在面板范围内布局)
const PANEL_BG_COLOR := Color("1c1e26")   # 面板底色: 纯色块扩展【终点】色 / 收拢【起点】色 / 美术缺失兜底色

# 升格/收拢动效时长(秒)。三段式分段编排, 各段时长独立可调。
const SEG1_HOLD := 0.09            # 展开①: 卡→纯色块后的短暂停顿(让"变纯色"这步可辨, 非一闪而过)
const EXPAND_TIME := 0.22          # 展开②: 纯色块扩展到满面板(size/pos/color 并行 morph)
const CONTENT_FADE_IN := 0.16      # 展开③: 面板信息淡入
const EXPAND_CONTENT_DELAY := 0.12 # 展开③ 相对②起点的延迟(②后段才浮现信息, 避免信息随外框被拉伸观感)
const CONTENT_FADE_OUT := 0.12     # 收拢③逆: 信息先淡出
const COLLAPSE_TIME := 0.20        # 收拢②逆: 纯色块缩回卡 rect(size/pos/color 并行)

# MSDF 字体(多通道有向距离场): 任意缩放保持锐利, 仅升格叙事面板用(卡面小字仍用普通 SystemFont)。
static var _msdf_font: SystemFont = null

var _clip: Control          # 内容层(clip_contents): 美术/遮罩/文字裁到面板矩形内; 恒面板布局, 仅 alpha 淡入
var _frame: ColorRect       # 外框层(morph): 直接挂 stage, 不在 clip 内 → 独立做位置/尺寸形变("从卡长大成面板")+ 兜底底框
var _art: TextureRect       # 16:9 场景美术(KEEP_ASPECT_COVERED 满铺, 溢出由 _clip 裁掉)
var _scrim: ColorRect       # 暗化遮罩(压暗美术保证文字可读)
var _title_label: Label
var _body_label: Label
var _morph_tween: Tween     # 当前升格/收拢 tween; 切换前 kill, 防"收拢 callback 误隐已重聚焦舞台"(P2-1)

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

## 构建面板视觉。两层结构(为支持升格 morph):
## - 外框层 _frame(直接挂 stage, 居中): 纯色底框, 独立做位置/尺寸形变; 也兼美术缺失时的兜底色。
## - 内容层 _clip(clip_contents, 居中): 美术 → 遮罩 → 标题 → 叙事正文, 恒面板布局; 子节点坐标相对 _clip 局部空间。
func _build() -> void:
	var tl: Vector2 = -PANEL_SIZE * 0.5

	# 外框层: 先加 → 居 _clip 之后(渲染在内容之下); rest 态铺满面板(position=tl, size=PANEL)。
	_frame = ColorRect.new()
	_frame.color = PANEL_BG_COLOR
	_frame.position = tl
	_frame.size = PANEL_SIZE
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_frame)

	# 内容层: 后加 → 叠于外框之上; clip_contents 裁美术到面板矩形(防 16:9 图溢出, P2-2)。
	_clip = Control.new()
	_clip.position = tl
	_clip.size = PANEL_SIZE
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clip)

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

## kill 待定的 morph tween(切换前调, 防"收拢 callback 误隐已重聚焦舞台" / 淡入淡出互抢)。
func _kill_morph() -> void:
	if _morph_tween != null and _morph_tween.is_valid():
		_morph_tween.kill()

## 升格展开(三段式): ①卡→纯色块(外框以卡底色登场盖住卡位; card_table 同帧隐卡) → 短暂停顿 →
## ②纯色块扩展(size/pos morph 到满面板 + 色渐变到面板底色) → ③信息浮现(②后段起内容淡入)。
## card_center_world / card_size / card_color 由 card_table 传入(事件卡 global_position + Card.SIZE + 卡底色)。
func expand_from(card_center_world: Vector2, card_size: Vector2, card_color: Color) -> void:
	_kill_morph()
	visible = true
	modulate.a = 1.0
	var c0: Vector2 = to_local(card_center_world)   # 卡中心 → stage 局部(stage 无旋转/缩放, 等价 world 差)
	# ① 外框起始态 = 卡的位置/尺寸/底色 → 与隐去的事件卡无缝交接, 化为纯色块
	_frame.color = card_color
	_frame.size = card_size
	_frame.position = c0 - card_size * 0.5
	_clip.modulate.a = 0.0   # 内容起始隐藏(②后段才浮现)
	_morph_tween = create_tween()
	_morph_tween.tween_interval(SEG1_HOLD)   # ① 纯色块短暂停顿(让"变纯色"可辨)
	# ② 扩展: size/pos/color 并行 morph(color 卡色 → 面板底色)
	_morph_tween.tween_property(_frame, "size", PANEL_SIZE, EXPAND_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_morph_tween.parallel().tween_property(_frame, "position", -PANEL_SIZE * 0.5, EXPAND_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_morph_tween.parallel().tween_property(_frame, "color", PANEL_BG_COLOR, EXPAND_TIME)
	# ③ 信息浮现: 与②并行但延迟到②后段起(避开"信息随框拉伸"观感)
	_morph_tween.parallel().tween_property(_clip, "modulate:a", 1.0, CONTENT_FADE_IN).set_delay(EXPAND_CONTENT_DELAY)

## 升格收拢(三段式逆向): ③逆信息淡出 → ②逆纯色块缩回卡 rect + 色回卡色 → 纯色块消失 + on_done 回调。
## on_done 在纯色块完全缩回后才触发(card_table 据此显示事件卡 + 恢复盘面余背) → 卡不会浮在大色块上。
func collapse_to(card_center_world: Vector2, card_size: Vector2, card_color: Color, on_done: Callable) -> void:
	_kill_morph()
	var c0: Vector2 = to_local(card_center_world)
	_morph_tween = create_tween()
	_morph_tween.tween_property(_clip, "modulate:a", 0.0, CONTENT_FADE_OUT)   # ③逆 信息先淡出
	# ②逆 纯色块缩回卡 rect + 色回卡色(size/pos/color 并行)
	_morph_tween.tween_property(_frame, "size", card_size, COLLAPSE_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_morph_tween.parallel().tween_property(_frame, "position", c0 - card_size * 0.5, COLLAPSE_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_morph_tween.parallel().tween_property(_frame, "color", card_color, COLLAPSE_TIME)
	_morph_tween.tween_interval(SEG1_HOLD)   # ①逆 纯色块短暂停顿(对称展开①)
	# 收尾: 同帧先让 card_table 显示事件卡(on_done), 再隐纯色块 → 颜色/位置一致, 无缝接管
	_morph_tween.tween_callback(func() -> void:
		if on_done.is_valid():
			on_done.call()
		visible = false)
