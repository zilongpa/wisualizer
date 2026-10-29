extends Node
## One opened ZIP, shown as a volume the person can place anywhere; see
## docs/zip-format.md. Its notes, if it has any, open in a window of their
## own beside the volume, which the person can move and resize, and its
## controls sit along the volume's bottom front edge.

const FPS := 4.0
const PLAY_ICON := preload("res://app/icons/play.svg")
const PAUSE_ICON := preload("res://app/icons/pause.svg")
const SPEEDS := [0.5, 1.0, 2.0, 4.0]
const Meta := preload("res://app/meta.gd")
const ModelFrames := preload("res://app/model_frames.gd")
const NotesImages := preload("res://app/notes_images.gd")
## Seconds a volume takes to open before the resize hint shows.
const HINT_DELAY := 0.6
## Radians the model turns as the hand moves by its radius. More than one,
## so a small movement of the hand turns it well round.
const TURN_GAIN := 3.0
## How far the model tilts toward or away from the person at most; it eases
## toward this, and springs back upright when let go.
const TILT_LIMIT := deg_to_rad(75.0)
## How quickly the model follows the hand, and settles once let go: the
## inverse of the time it takes to cover most of the way.
const FOLLOW_RATE := 14.0
const SETTLE_RATE := 6.0
## Seconds of the hand's last speed that carry on turning the model after
## it is let go, like a globe given a spin.
const SPIN_TIME := 0.3
## A spatial event's kind for a finger touching, not pinching:
## InputEventSpatialTouch.KIND_TOUCH, a class that exists only on visionOS.
const KIND_TOUCH := 0

@onready var model: Window = $Model
## The 3D nodes are found by unique name: platforms may move them within
## the Window.
@onready var content: Node3D = %Content
## Holds the model, the field box, the probes and the labels, and turns them together.
@onready var turntable: Node3D = %Turntable
## Where pinching and dragging the model turns it.
@onready var grab: StaticBody3D = %Grab
@onready var volume: SpatialVolume3D = %Volume
@onready var field: Node3D = %Field
@onready var controls: Window = $Model/Controls
@onready var options: Window = $Model/Options
@onready var notes: Window = $Model/Notes
@onready var play_button: Button = %Play
@onready var slider: HSlider = %Frame
@onready var counter: Label = %Count
@onready var debug_button: CheckButton = %Debug
@onready var probes: Node3D = %FieldProbes
@onready var labels: Node3D = %Labels
@onready var labels_button: CheckButton = %ShowLabels
@onready var notes_button: Button = %NotesButton
@onready var options_button: Button = %OptionsButton
@onready var touch: Node = $FieldTouch
@onready var speed_group: ButtonGroup = $Model/Options/Bar/Speeds/Row/Speed0.button_group

var meta := Meta.new()
## One per model, showing it at the current frame.
var models: Array[ModelFrames] = []
## The field the debug view shows and controllers feel.
var field_index := 0
var frame_count := 0
var frame := 0
var playing := false
var elapsed := 0.0
## The images the notes show, kept for as long as the document is open.
var notes_images := NotesImages.new()
## How far the model is turned about the vertical, and tilted toward the
## person about [member _tilt_axis], now and where it is heading.
var yaw := 0.0
var tilt := 0.0
var _yaw_target := 0.0
var _tilt_target := 0.0
var _tilt_axis := Vector3.RIGHT
## The drag turning the model: its touch index, or -1; where the hand was
## when it began, the turn and the tilt then, and how fast the yaw was
## changing. The tilt is kept before its easing toward the limit.
var _drag := -1
## The horizontal across the person's view, as the drag began: sideways
## movement along it turns the model.
var _drag_across := Vector3.RIGHT
## A gesture that selected a label must not also turn the model.
var _label_touch := -1
var _drag_start := Vector3.ZERO
var _drag_yaw := 0.0
var _drag_tilt := 0.0
var _yaw_speed := 0.0
## The model's center and the radius of a sphere around it, in its own
## coordinates, from the last fit.
var _center := Vector3.ZERO
var _radius := 1.0


func _ready() -> void:
	for window: Window in [model, controls, options, notes]:
		window.window_input.connect(_on_window_input)
	# The bars are pointed at, not tabbed through, so the keyboard stays with
	# the shortcuts: a focused button would also take Space.
	for window: Window in [controls, options]:
		for control in window.find_children("*", "Control", true, false):
			if control is BaseButton or control is Range:
				control.focus_mode = Control.FOCUS_NONE


## Space plays or pauses, and the arrow keys step a frame, in any of this
## document's windows.
func _on_window_input(event: InputEvent) -> void:
	if frame_count == 0:
		return
	if event.is_action_pressed(&"play_pause"):
		toggle_play()
	elif event.is_action_pressed(&"previous_frame", true):
		step(-1)
	elif event.is_action_pressed(&"next_frame", true):
		step(1)


## Opens the ZIP at [param path]. Returns an empty string, or what is
## wrong with it.
func open(path: String) -> String:
	var error := meta.open(path)
	if not error.is_empty():
		return error
	frame_count = meta.times.size()
	field_index = meta.first_field
	for entry in meta.models:
		var frames := ModelFrames.new()
		frames.setup(path, entry)
		content.add_child(frames)
		models.append(frames)
	_add_model_switches()
	_add_field_picker()
	debug_button.disabled = meta.fields.is_empty()
	touch.volume = volume
	touch.field = field
	probes.touch = touch
	probes.volume = volume
	probes.field = field
	labels.touch = touch
	labels.volume = volume
	labels.set_labels(meta.labels)
	labels_button.visible = not meta.labels.is_empty()
	_fit_options()
	slider.max_value = frame_count - 1
	seek(0)

	var text := ""
	if not meta.notes.is_empty():
		var notes_text: RichTextLabel = %Text
		text = notes_images.embed(meta.read(meta.notes).get_string_from_utf8(), meta.read, meta.notes, str(get_instance_id()), notes_text.get_theme_color(&"default_color"), notes_text.get_theme_font_size(&"normal_font_size"))
	model.title = meta.title
	%Text.text = text
	notes_button.visible = not text.is_empty()
	fit()
	model.show()
	controls.show()
	show_options(options_button.button_pressed)
	show_notes(notes_button.visible)
	# Show that the volume can be resized, once it has finished opening.
	create_tween().tween_callback(show_resize_hint).set_delay(HINT_DELAY)
	set_playing(true)
	return ""


## A switch for each model, in the options, when there's more than one.
func _add_model_switches() -> void:
	if models.size() < 2:
		return
	var bar: HBoxContainer = %Separator.get_parent()
	for frames in models:
		var switch := CheckButton.new()
		switch.text = frames.name
		switch.button_pressed = true
		switch.focus_mode = Control.FOCUS_NONE
		switch.custom_minimum_size.y = 44
		switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		switch.toggled.connect(func(shown: bool) -> void: frames.visible = shown)
		bar.add_child(switch)
		bar.move_child(switch, %Separator.get_index())


## A button for each field, in the options, when there's more than one.
func _add_field_picker() -> void:
	if meta.fields.size() < 2:
		return
	var bar: HBoxContainer = %Separator.get_parent()
	var group := ButtonGroup.new()
	for index in meta.fields.size():
		var button := Button.new()
		button.text = meta.fields[index].name
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = index == field_index
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(64, 44)
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		button.pressed.connect(func() -> void:
			field_index = index
			update_field())
		bar.add_child(button)


func show_notes(shown: bool) -> void:
	notes.visible = shown


## The person closed the notes window; the notes button opens it again.
func close_notes() -> void:
	notes.hide()
	notes_button.set_pressed_no_signal(false)


## Sizes the options to what they hold, which depends on the ZIP: a switch
## per model, a button per field, the labels switch.
func _fit_options() -> void:
	var bar: Control = %Separator.get_parent()
	var margins := bar.offset_left - bar.offset_right
	options.size.x = ceili((bar.get_combined_minimum_size().x + margins) * options.content_scale_factor)


func show_options(shown: bool) -> void:
	options.visible = shown


func show_resize_hint() -> void:
	%ResizeHint.play(volume.get_region_size())


func close() -> void:
	meta.close()
	queue_free()


func toggle_play() -> void:
	set_playing(not playing)


## Pauses and moves [param frames_by] frames, staying within the frames.
func step(frames_by: int) -> void:
	set_playing(false)
	seek(clampi(frame + frames_by, 0, frame_count - 1))


## Follows a link in the notes. [code][url=frame:9]frame 9[/url][/code]
## pauses on the ninth frame; other links open as usual.
func open_link(target: Variant) -> void:
	var link := str(target)
	if link.begins_with("frame:"):
		set_playing(false)
		seek(clampi(link.trim_prefix("frame:").to_int() - 1, 0, frame_count - 1))
	else:
		OS.shell_open(link)


func set_playing(value: bool) -> void:
	playing = value
	elapsed = 0.0
	play_button.icon = PAUSE_ICON if playing else PLAY_ICON


func seek(value: float) -> void:
	frame = int(value)
	for frames in models:
		frames.show_frame(frame)
	slider.set_value_no_signal(frame)
	counter.text = "%d / %d" % [frame + 1, frame_count]
	labels.frame = frame
	update_field()


## Shows the field box, and the field around each controller, if the debug
## switch is on. The field can be felt with a controller either way.
func update_field() -> void:
	if meta.fields.is_empty():
		field.visible = false
		probes.visible = false
		return
	var current: Meta.Field = meta.fields[field_index]
	field.visible = debug_button.button_pressed
	probes.visible = field.visible
	probes.shown_field = current
	field.transform = current.box
	touch.set_brick(meta.read(current.files[frame]), current.cells, 255)


## Turns the model as the person pinches and drags it, like Apple's globe:
## moving the hand sideways turns it about the vertical without limit, and
## moving it up or down tilts it toward or away from the person, up to
## [constant TILT_LIMIT]. Both follow how far the hand has moved since the
## pinch began, so small jitters don't add up, and the model eases after the
## hand. On release the tilt springs back and the turn carries on a little.
## Only a pinch turns it: a finger brushing the model leaves it be.
## Spatial events only come from visionOS; on desktop, the orbit camera
## turns the view instead.
func turn_by_drag(camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape: int) -> void:
	if event.is_class("InputEventSpatialTouch"):
		if _label_touch != -1 and event.get("index") == _label_touch:
			if not event.get("pressed") or event.get("canceled"):
				_label_touch = -1
			return
		if event.get("canceled"):
			if event.get("index") == _drag:
				_drag = -1
				_tilt_target = 0.0
			return
		if event.get("pressed") and _drag < 0 and labels.select_from_spatial_touch(camera, event):
			_label_touch = event.get("index")
			return
		if event.get("pressed") and _drag < 0 and event.get("kind") != KIND_TOUCH:
			_begin_drag(event.get("index"), event.get("world_position"))
		elif not event.get("pressed") and event.get("index") == _drag:
			_drag = -1
			_tilt_target = 0.0
			_yaw_target += clampf(_yaw_speed * SPIN_TIME, -PI, PI)
		return
	if not event.is_class("InputEventSpatialDrag"):
		return
	if _label_touch != -1 and event.get("index") == _label_touch:
		return
	var at: Vector3 = event.get("world_position")
	if _drag < 0 and event.get("kind") != KIND_TOUCH:
		_begin_drag(event.get("index"), at - (event.get("world_relative") as Vector3))
	if event.get("index") != _drag:
		return
	var moved := at - _drag_start
	var turned := _yaw_target
	_yaw_target = _drag_yaw + moved.dot(_drag_across) / _radius * TURN_GAIN
	var delta := maxf(get_process_delta_time(), 0.001)
	_yaw_speed = lerpf(_yaw_speed, (_yaw_target - turned) / delta, 0.5)
	_tilt_target = _ease_tilt(_drag_tilt - moved.y / _radius * TURN_GAIN)


## Starts a drag at [param at]: tilting turns about the horizontal axis
## across the person's view, taken as facing the side of the model held.
func _begin_drag(index: int, at: Vector3) -> void:
	_drag = index
	_drag_start = at
	_drag_yaw = _yaw_target
	_yaw_speed = 0.0
	# A drag soon after another picks up the tilt where it is, as it springs
	# back, about the same axis.
	_drag_tilt = _unease_tilt(tilt)
	var facing := Vector3(_center.x - at.x, 0.0, _center.z - at.z)
	if not facing.is_zero_approx():
		_drag_across = facing.normalized().cross(Vector3.UP)
	if absf(tilt) < deg_to_rad(1.0):
		_tilt_axis = _drag_across


## Eases [param raw] toward [constant TILT_LIMIT] rather than stopping at it:
## one for one near upright, slower and slower toward the limit.
static func _ease_tilt(raw: float) -> float:
	return TILT_LIMIT * atan(raw / TILT_LIMIT * PI / 2.0) * 2.0 / PI


static func _unease_tilt(eased: float) -> float:
	return TILT_LIMIT * tan(clampf(eased / TILT_LIMIT, -0.99, 0.99) * PI / 2.0) * 2.0 / PI


## Eases the turn toward where it is heading.
func _ease_turn(delta: float) -> void:
	var rate := FOLLOW_RATE if _drag >= 0 else SETTLE_RATE
	var weight := 1.0 - exp(-rate * delta)
	yaw = lerpf(yaw, _yaw_target, weight)
	tilt = lerpf(tilt, _tilt_target, weight)
	_place_turntable()


## Turns the turntable by [member yaw] and [member tilt] about the model's
## center.
func _place_turntable() -> void:
	var turn := Basis(_tilt_axis, tilt) * Basis(Vector3.UP, yaw)
	turntable.transform = Transform3D(turn, _center - turn * _center)


## Frames the volume on the model and labels so they can turn without leaving
## the volume or changing size: on a sphere about its center that reaches
## its farthest vertex. The field box, shown only while debugging, may reach
## past it.
func fit() -> void:
	var bounds := AABB()
	for frames in models:
		var box := frames.get_bounds()
		if box.has_volume():
			bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
	var boxes: Array[AABB] = []
	for entry: Meta.Field in meta.fields:
		boxes.append(entry.box * AABB(Vector3.ZERO, Vector3.ONE))
	if bounds.size == Vector3.ZERO:
		for box in boxes:
			bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
	# A document can contain just labels, with no model or field to frame.
	if bounds.size == Vector3.ZERO and not meta.labels.is_empty():
		bounds = AABB(meta.labels[0].position, Vector3.ZERO)
		for label: Meta.PointLabel in meta.labels:
			bounds = bounds.expand(label.position)
	_center = bounds.get_center()
	_radius = 0.0
	for frames in models:
		_radius = maxf(_radius, frames.get_radius(_center))
	if is_zero_approx(_radius):
		_radius = maxf(bounds.size.length() * 0.5, 0.001)
	for label: Meta.PointLabel in meta.labels:
		_radius = maxf(_radius, label.position.distance_to(_center))
	# The model is grabbed by its bounds, which stay inside the volume and
	# leave the space around the model for moving the window.
	grab.position = _center
	(grab.get_node("Shape").shape as BoxShape3D).size = bounds.size.max(Vector3.ONE * maxf(bounds.size[bounds.size.max_axis_index()] * 0.02, 0.001))
	_place_turntable()
	var volume_size := volume.get_measured_size()
	# Before the native window reports its size, use the size it opens at.
	if volume_size == Vector3.ZERO:
		volume_size = volume.window_size
	volume.position = _center
	var smallest := volume_size[volume_size.min_axis_index()]
	volume.size = _radius * 2.0 / smallest * volume_size[volume.keep_aspect] * 1.1


func _process(delta: float) -> void:
	_ease_turn(delta)
	if not playing or frame_count == 0:
		return
	elapsed += delta * FPS * SPEEDS[speed_group.get_pressed_button().get_index()]
	# Playback starts over after the last frame.
	while elapsed >= 1.0:
		elapsed -= 1.0
		seek((frame + 1) % frame_count)
