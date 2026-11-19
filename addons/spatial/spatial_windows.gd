extends Node
## Lays out the app's windows on platforms that don't do it themselves,
## reading the same [member Window.placement] and ornament properties
## visionOS does. Add it as an autoload.
##
## On every platform, a window that keeps the default content scale shows its
## content at the main window's scale, so sizes set in pixels mean the same
## thing everywhere.

const DesktopWindows := preload("desktop/desktop_windows.gd")
const XRLayout := preload("xr/xr_layout.gd")

## The layout for this platform, or null on visionOS, which lays windows out
## itself.
var layout: Node
## On visionOS, window points per pixel as the project sizes windows: the
## project's content scale is for a desktop's two pixels per point, and
## visionOS has one, so there windows shrink by it and show their content at
## a point per unit. The main window gets its size in points from the
## project's visionOS window size, and stretches to it.
var _scale := 1.0


func _enter_tree() -> void:
	get_tree().node_added.connect(_on_node_added)
	match SpatialPlatform.current():
		SpatialPlatform.Kind.DESKTOP:
			layout = DesktopWindows.new()
		SpatialPlatform.Kind.XR:
			layout = XRLayout.new()
		SpatialPlatform.Kind.VISIONOS:
			_scale = DisplayServer.screen_get_scale() / get_tree().root.content_scale_factor
	if layout != null:
		layout.name = "Layout"
		add_child(layout)


func _on_node_added(node: Node) -> void:
	var window := node as Window
	if window == null or window == get_tree().root:
		return
	# Popups scale themselves from the window they open over.
	if not window is Popup and is_equal_approx(window.content_scale_factor, 1.0):
		window.content_scale_factor = get_tree().root.content_scale_factor * _scale
		if not is_equal_approx(_scale, 1.0):
			window.size = Vector2i(Vector2(window.size) * _scale)
			window.min_size = Vector2i(Vector2(window.min_size) * _scale)
			window.max_size = Vector2i(Vector2(window.max_size) * _scale)
	if layout != null:
		layout.add_window(window)
