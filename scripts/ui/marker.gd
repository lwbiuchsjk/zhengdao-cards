class_name Marker
extends Node2D
## 自写拖放标记(§1.2) —— 内置 Control 拖放在 Node2D 世界坐标用不了, 故自写(~60 行)。
##
## 关键设计:
## - 离散棋子型(能力/心性/关系) + 数字型(金钱, 后期再做); MVP 棋子用纯色圆占位。
## - 二分: 实体标记(收→加可数池) = 实心圆 / 成长标记(收→喂经验) = 空心圆。
## - 拖拽优先级(B③#1): 按下经 Area2D 拾取并消费事件 → 牌桌 _unhandled_input 不触发平移;
##   拖拽中经 _input 跟随鼠标并持续消费, 镜头不动。
## - 撤回(§1.2): 拖放后可经 return_home() 零惩罚归位。

enum Kind { ENTITY, GROWTH }  # 实体标记 / 成长标记

const RADIUS := 16.0

# 各资源类型占位色
const RES_COLORS: Dictionary = {
	"physique": Color("c97f5a"), "craft": Color("5ac98a"), "insight": Color("5a8fc9"),
	"xinxing": Color("c9b35a"), "social": Color("c95a9f"), "gold": Color("e0c558"),
}

signal drag_started(marker: Marker)
signal dropped(marker: Marker, at_global: Vector2)

@export var res_type: String = "physique"  # physique/craft/insight/xinxing/social/gold
@export var kind: Kind = Kind.ENTITY

var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _home_pos: Vector2 = Vector2.ZERO  # 撤回归位锚点
var _return_tween: Tween

func _ready() -> void:
	_home_pos = position
	z_index = 20  # 标记常在卡之上
	var area := Area2D.new()
	area.input_pickable = true
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS
	shape.shape = circle
	area.add_child(shape)
	add_child(area)
	area.input_event.connect(_on_area_input)
	queue_redraw()

## 绘制标记: 实体 = 实心圆 / 成长 = 空心环; 颜色按资源类型
func _draw() -> void:
	var col: Color = RES_COLORS.get(res_type, Color.GRAY)
	if kind == Kind.ENTITY:
		draw_circle(Vector2.ZERO, RADIUS, col)
		draw_arc(Vector2.ZERO, RADIUS, 0, TAU, 24, Color("1a1a22"), 2.0)
	else:
		draw_arc(Vector2.ZERO, RADIUS, 0, TAU, 24, col, 3.0)

## Area2D 输入: 左键按下 = 起拖(消费事件, 不触发牌桌平移)
func _on_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = true
		_drag_offset = get_global_mouse_position() - global_position
		get_viewport().set_input_as_handled()
		drag_started.emit(self)

## 拖拽中跟随鼠标 + 释放落点; 全程消费输入 → 镜头不平移(B③#1)
func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		global_position = get_global_mouse_position() - _drag_offset
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = false
		get_viewport().set_input_as_handled()
		dropped.emit(self, get_global_mouse_position())

## 窗口失焦时取消拖拽并归位, 避免 _dragging 残留(P2-3)
func _notification(what: int) -> void:
	if (what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_OUT) and _dragging:
		_dragging = false
		return_home()

## 零惩罚撤回到起拖位置(§1.2 确认前可撤); 重入先 kill 旧 tween(P3-5)
func return_home() -> void:
	if _return_tween and _return_tween.is_running():
		_return_tween.kill()
	_return_tween = create_tween()
	_return_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_return_tween.tween_property(self, "position", _home_pos, 0.18)

## 更新撤回锚点(投入承载落定后调用)
func set_home(pos: Vector2) -> void:
	_home_pos = pos
