extends Control
## Values over time as lines, one per series, with a mark at the current
## time. A NAN leaves a gap. Tapping or dragging across it picks the
## nearest time.

signal picked(index: int)

const PADDING := Vector2(16, 16)
const LINE_WIDTH := 3.0
const DOT_RADIUS := 5.0
## Above this many times, points are too close to dot.
const MOST_DOTS := 60

## The times along the bottom, in order.
var times := PackedFloat64Array()
## Each series' value at each time.
var series: Array[PackedFloat64Array] = []
var colors: Array[Color] = []
## The time marked, or -1.
var current := -1
## Writes a value for the scale's ends, such as "0.067 T".
var format: Callable = func(value: float) -> String: return String.num(value, 3)
## Shown in place of the chart with nothing to draw.
var placeholder := ""


func show_series(new_times: PackedFloat64Array, new_series: Array[PackedFloat64Array], new_colors: Array[Color]) -> void:
	times = new_times
	series = new_series
	colors = new_colors
	queue_redraw()


func set_current(index: int) -> void:
	if index != current:
		current = index
		queue_redraw()


func _draw() -> void:
	var font := get_theme_font(&"font", &"Label")
	var font_size := get_theme_font_size(&"font_size", &"Caption")
	var dim := get_theme_color(&"font_color", &"Caption")
	draw_style_box(get_theme_stylebox(&"panel", &"PanelContainer"), Rect2(Vector2.ZERO, size))
	var low := INF
	var high := -INF
	for values in series:
		for value in values:
			if not is_nan(value):
				low = minf(low, value)
				high = maxf(high, value)
	if low > high or times.is_empty():
		var text := placeholder
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size).x
		draw_string(font, Vector2((size.x - width) * 0.5, size.y * 0.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, dim)
		return
	if is_equal_approx(low, high):
		low -= 0.5 * maxf(absf(low), 1.0)
		high += 0.5 * maxf(absf(high), 1.0)
	var top := format.call(high) as String
	var bottom := format.call(low) as String
	var ascent := font.get_ascent(font_size)
	var plot := Rect2(PADDING + Vector2(0, ascent + 8), size - PADDING * 2.0 - Vector2(0, (ascent + 8) * 2.0))
	draw_string(font, PADDING + Vector2(0, ascent), top, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, dim)
	draw_string(font, Vector2(PADDING.x, size.y - PADDING.y), bottom, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, dim)
	draw_line(Vector2(plot.position.x, plot.end.y), plot.end, Color(dim, dim.a * 0.5), 1.0)
	if current >= 0 and current < times.size():
		var x := _x(current, plot)
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), dim, 2.0)
	for s in series.size():
		var values := series[s]
		var line := PackedVector2Array()
		for index in values.size():
			if is_nan(values[index]):
				_draw_line(line, colors[s])
				line.clear()
				continue
			var point := Vector2(_x(index, plot), plot.end.y - (values[index] - low) / (high - low) * plot.size.y)
			line.append(point)
			if times.size() <= MOST_DOTS or index == current:
				draw_circle(point, DOT_RADIUS, colors[s])
		_draw_line(line, colors[s])


func _draw_line(points: PackedVector2Array, color: Color) -> void:
	if points.size() > 1:
		draw_polyline(points, color, LINE_WIDTH, true)


## Where time [param index] is across [param plot].
func _x(index: int, plot: Rect2) -> float:
	var first := times[0]
	var last := times[times.size() - 1]
	if is_equal_approx(first, last):
		return plot.get_center().x
	return plot.position.x + (times[index] - first) / (last - first) * plot.size.x


func _gui_input(event: InputEvent) -> void:
	var pressed: bool = (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) \
			or (event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT)
	if not pressed or times.is_empty():
		return
	var plot := Rect2(PADDING, size - PADDING * 2.0)
	var nearest := 0
	for index in times.size():
		if absf(_x(index, plot) - event.position.x) < absf(_x(nearest, plot) - event.position.x):
			nearest = index
	accept_event()
	picked.emit(nearest)
