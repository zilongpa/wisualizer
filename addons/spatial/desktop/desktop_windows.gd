extends Node
## Desktop layout: windows stay ordinary OS windows, and a window placed
## beside another opens next to it. Ornaments are drawn by Godot inside the
## window they belong to, on a rounded backdrop, so they look and work the
## same on every desktop: an OS window floating outside another can end up
## off screen, and some systems, such as Wayland, don't let apps place them.

const Placement := preload("../placement.gd")
## visionOS points per meter, as used for the gap between windows.
const POINTS_PER_METER := 1360.0
## How far ornaments sit inside their window's edge, in the window's units.
const ORNAMENT_INSET := 12.0
const ORNAMENT_BACKDROP := Color(0.11, 0.11, 0.12, 0.82)

var _ornaments: Array[Window] = []
## Screen pixels per window pixel: windows are sized for the main window's
## content scale, which may differ from this screen's.
var _scale := 1.0


func _ready() -> void:
	var root := get_tree().root
	_scale = DisplayServer.screen_get_scale(root.current_screen) / root.content_scale_factor
	if not is_equal_approx(_scale, 1.0):
		# The main window's content stretches with it.
		root.size = Vector2i(Vector2(root.size) * _scale)


## Called for each new window, after it takes the main window's content scale.
func add_window(window: Window) -> void:
	# The OS places popups.
	if window is Popup:
		return
	if window.placement == Window.PLACEMENT_ORNAMENT:
		_add_ornament(window)
		return
	# Only ornaments go inside the window they belong to; a window that hosts
	# them still opens the others as windows of their own.
	window.force_native = true
	# A window's position is its content's, so one left at the corner would
	# hide its title bar above the screen: it opens centered, or beside the
	# window it is placed by.
	window.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	if not is_equal_approx(_scale, 1.0):
		window.size = Vector2i(Vector2(window.size) * _scale)
		window.content_scale_factor *= _scale
	window.visibility_changed.connect(_fit_on_screen.bind(window), CONNECT_ONE_SHOT)
	if Placement.side(window.placement) != Vector2.ZERO:
		window.visibility_changed.connect(_place_beside.bind(window), CONNECT_ONE_SHOT)


## Embeds [param ornament] in the window it belongs to. Its size, set in
## window pixels at the main window's scale like any window's, becomes the
## target's units, which already carry that scale.
func _add_ornament(ornament: Window) -> void:
	var target := Placement.target_of(ornament)
	if target == null:
		return
	target.gui_embed_subwindows = true
	ornament.borderless = true
	ornament.unresizable = true
	ornament.transparent = true
	ornament.transparent_bg = true
	ornament.size = Vector2i(Vector2(ornament.size) / ornament.content_scale_factor)
	ornament.content_scale_factor = 1.0
	var backdrop := Panel.new()
	backdrop.name = "Backdrop"
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = ORNAMENT_BACKDROP
	style.set_corner_radius_all(int(minf(ornament.size.x, ornament.size.y) * 0.5))
	style.corner_detail = 16
	style.anti_aliasing_size = 0.5
	backdrop.add_theme_stylebox_override(&"panel", style)
	ornament.add_child(backdrop, false, Node.INTERNAL_MODE_FRONT)
	_ornaments.append(ornament)
	ornament.tree_exiting.connect(_ornaments.erase.bind(ornament))


func _process(_delta: float) -> void:
	for ornament in _ornaments:
		if ornament.visible:
			_place_ornament(ornament)


## Shrinks [param window], title bar and all, to its screen if it is
## larger, as a window sized for visionOS can be, and centers it there.
func _fit_on_screen(window: Window) -> void:
	var id := window.get_window_id()
	if id == DisplayServer.INVALID_WINDOW_ID:
		return
	var screen := DisplayServer.screen_get_usable_rect(window.current_screen)
	var frame := DisplayServer.window_get_size_with_decorations(id) - window.size
	var room := screen.size - frame
	if window.size.x <= room.x and window.size.y <= room.y:
		return
	window.min_size = window.min_size.min(room)
	window.size = window.size.min(room)
	var title := window.position - DisplayServer.window_get_position_with_decorations(id)
	window.position = screen.position + title + (room - window.size) / 2


func _place_beside(window: Window) -> void:
	var target := Placement.target_of(window)
	if target == null:
		return
	var gap := _gap(target)
	var side := Placement.side(window.placement)
	var center := Vector2(target.position) + Vector2(target.size) * 0.5
	center += side * ((Vector2(target.size) + Vector2(window.size)) * 0.5 + Vector2(gap, gap))
	var rect := Rect2(center - Vector2(window.size) * 0.5, window.size)
	# Stay on the target's screen, overlapping it if there's no room beside it.
	var screen := Rect2(DisplayServer.screen_get_usable_rect(target.current_screen))
	rect.position = rect.position.clamp(screen.position, screen.end - rect.size)
	window.position = Vector2i(rect.position)


## Puts [param ornament] where its anchor says, inside its window: the
## window's edge stands in for the space around it on visionOS.
func _place_ornament(ornament: Window) -> void:
	var target := Placement.target_of(ornament)
	if target == null:
		return
	var area := target.get_visible_rect().size
	var own := Vector2(ornament.size)
	var anchor := Vector2(ornament.ornament_anchor.x, ornament.ornament_anchor.y)
	# The point of the ornament on its anchor: the edge it is anchored to.
	var center := anchor * area - (anchor - Vector2(0.5, 0.5)) * own
	center -= (anchor * 2.0 - Vector2.ONE).snapped(Vector2.ONE) * ORNAMENT_INSET
	var position := Vector2i((center - own * 0.5).round())
	if ornament.position != position:
		ornament.position = position


func _gap(window: Window) -> float:
	return Placement.GAP * POINTS_PER_METER * DisplayServer.screen_get_scale(window.current_screen)
