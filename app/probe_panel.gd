extends Window
## Compares the field at two cells the person pins with a fingertip, A and
## B: their values at the frame showing, the difference, and both over the
## model's timeline, which a tap on the chart goes to. A pin takes the cell
## at the index fingertip of a tracked hand, or the tip of a controller,
## inside the field; the pins stay on their cells as the model turns, moves
## and plays, until the field shown changes.

const Meta := preload("res://app/meta.gd")
const ProbePins := preload("res://app/probe_pins.gd")
## A hand whose thumb and index fingertips are closer than this, in meters,
## is pinching, likely to tap a pin button: the other hand is the one in
## the field.
const PINCH := 0.025

## The document this panel belongs to.
var document: Node
var pins: ProbePins

@onready var _status: Label = %Status
@onready var _cells: Array[Label] = [%CellA, %CellB]
@onready var _values: Array[Label] = [%ValueA, %ValueB]
@onready var _difference: Label = %Difference
@onready var _chart: Control = %Chart
@onready var _clear: Button = %Clear

## The field the pins are on, by index; changing it lets go of them.
var _field_index := -1
## Each pin's value at each frame of the model, read on a worker thread.
var _history: Array[PackedFloat64Array] = [PackedFloat64Array(), PackedFloat64Array()]
## Readings still running, waited for on leaving.
var _tasks: Array[int] = []
## Counts readings of the history, so a stale one is dropped.
var _reading := 0


func _ready() -> void:
	%PinA.pressed.connect(pin.bind(0))
	%PinB.pressed.connect(pin.bind(1))
	_clear.pressed.connect(clear)
	_chart.picked.connect(func(index: int) -> void:
		document.clock.set_playing(false)
		document.seek(index))
	for index in ProbePins.NAMES.size():
		_cells[index].add_theme_color_override(&"font_color", ProbePins.COLORS[index])
	for control in find_children("*", "Control", true, false):
		if control is BaseButton:
			control.focus_mode = Control.FOCUS_NONE


## Pins A, for 0, or B to the cell at a fingertip in the field.
func pin(index: int) -> void:
	var tip := _fingertip()
	if tip.is_empty():
		_status.text = "Put a fingertip or a controller in the field, then pin." if _can_point() \
				else "Pinning needs tracked hands, in the immersive space, or a controller."
		return
	pins.cells[index] = tip.cell
	_status.text = "%s is at the %s." % [ProbePins.NAMES[index], tip.name]
	_read_history()
	update()


func clear() -> void:
	pins.cells.fill(ProbePins.NO_CELL)
	_status.text = ""
	_read_history()
	update()


## Shows the pins' values at the frame showing; called as it changes.
func update() -> void:
	if document.field_index != _field_index:
		_field_index = document.field_index
		if _pinned():
			pins.cells.fill(ProbePins.NO_CELL)
			_status.text = "The field changed, so the pins were let go."
		_read_history()
	var field: Meta.Field = document.entry.fields[_field_index]
	for index in ProbePins.NAMES.size():
		var cell := pins.cells[index]
		var pinned := cell != ProbePins.NO_CELL
		_cells[index].text = "%s  (%d, %d, %d)" % [ProbePins.NAMES[index], cell.x, cell.y, cell.z] if pinned \
				else "%s  not pinned" % ProbePins.NAMES[index]
		_values[index].text = pins.reading(index) if pinned else ""
	var a := pins.value_at(0)
	var b := pins.value_at(1)
	_difference.text = "" if is_nan(a) or is_nan(b) else field.format(b - a)
	_clear.disabled = not _pinned()
	_chart.set_current(document.frame)


## The cell at the fingertip or controller tip in the field, and what it
## is, such as {cell = Vector3i(3, 9, 1), name = "right index fingertip"};
## empty with none there. A hand that isn't pinching comes first, then a
## controller, then a pinching hand.
func _fingertip() -> Dictionary:
	var volume: SpatialVolume3D = document.volume
	var touch: Node = document.touch
	var found := {}
	var best := -1
	for controller in volume.get_controllers():
		if not controller.get_has_tracking_data():
			continue
		var cell: Vector3i = touch.cell_at(touch.tip_of(controller))
		if cell != touch.NO_CELL and best < 1:
			best = 1
			found = {cell = cell, name = "tip of the %s controller" % ("left" if controller.tracker.begins_with("left") else "right")}
	for hand in volume.get_hands():
		var cell: Vector3i = touch.cell_at(volume.get_hand_joint(hand, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin)
		if cell == touch.NO_CELL:
			continue
		# In meters, as the tracker has the joints.
		var gap := hand.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin.distance_to(
				hand.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin)
		var rank := 0 if gap < PINCH else 2
		if rank > best:
			best = rank
			found = {cell = cell, name = "%s index fingertip" % ("left" if hand.hand == XRPositionalTracker.TRACKER_HAND_LEFT else "right")}
	return found


## Whether a hand or controller is tracked to point with.
func _can_point() -> bool:
	if not document.volume.get_hands().is_empty():
		return true
	return document.volume.get_controllers().any(func(controller: XRController3D) -> bool: return controller.get_has_tracking_data())


## Reads the pins' values at every frame of the model, from each brick
## once, on a worker thread that opens the ZIP itself.
func _read_history() -> void:
	_reading += 1
	_history = [PackedFloat64Array(), PackedFloat64Array()]
	var field: Meta.Field = document.entry.fields[_field_index]
	var offsets := PackedInt64Array()
	for cell in pins.cells:
		offsets.append(-1 if cell == ProbePins.NO_CELL else cell.x + field.cells.x * (cell.y + field.cells.y * cell.z))
	if offsets[0] < 0 and offsets[1] < 0:
		_chart.placeholder = "Pin A or B to see it over time."
		_show_history()
		return
	_chart.placeholder = "Reading…"
	_show_history()
	_tasks = _tasks.filter(func(task: int) -> bool:
		if not WorkerThreadPool.is_task_completed(task):
			return true
		WorkerThreadPool.wait_for_task_completion(task)
		return false)
	_tasks.append(WorkerThreadPool.add_task(_read_bytes.bind(document.zip_path, field.files, offsets, _reading)))


func _read_bytes(path: String, files: PackedStringArray, offsets: PackedInt64Array, reading: int) -> void:
	var bytes: Array[PackedByteArray] = []
	for offset in offsets:
		var row := PackedByteArray()
		row.resize(files.size())
		bytes.append(row)
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return
	# A field holds its last brick through frames without one of their own.
	var file := ""
	var brick := PackedByteArray()
	for frame in files.size():
		if files[frame] != file:
			file = files[frame]
			brick = zip.read_file(file)
		for p in offsets.size():
			bytes[p][frame] = brick[offsets[p]] if offsets[p] >= 0 and offsets[p] < brick.size() else 0
	zip.close()
	_take_history.call_deferred(bytes, offsets, reading)


func _take_history(bytes: Array[PackedByteArray], offsets: PackedInt64Array, reading: int) -> void:
	if reading != _reading:
		return
	var field: Meta.Field = document.entry.fields[_field_index]
	for p in offsets.size():
		var values := PackedFloat64Array()
		if offsets[p] >= 0:
			for byte in bytes[p]:
				values.append(field.value_of(byte))
		_history[p] = values
	_chart.placeholder = "No data at these cells."
	_show_history()


func _show_history() -> void:
	var field: Meta.Field = document.entry.fields[_field_index]
	_chart.format = field.format
	_chart.show_series(document.entry.times, _history, [ProbePins.COLORS[0], ProbePins.COLORS[1]] as Array[Color])
	_chart.set_current(document.frame)


func _pinned() -> bool:
	return pins.cells.any(func(cell: Vector3i) -> bool: return cell != ProbePins.NO_CELL)


func _exit_tree() -> void:
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()
