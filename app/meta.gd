extends RefCounted
## A ZIP's contents, read through its meta.json; see docs/zip-format.md.
## Keeps the ZIP open, so steps can be read as they are needed.

const MANIFEST := "meta.json"


## One of a model's parts.
class Part:
	var name := ""
	## The part's GLB at each frame of its model. A part that doesn't change
	## has the same GLB at every frame.
	var files := PackedStringArray()
	## Its steps as the ZIP has them: a GLB per solver time, in order, or
	## one GLB with no time.
	var step_times := PackedFloat64Array()
	var step_files := PackedStringArray()


## One field in the ZIP.
class Field:
	var name := ""
	var quantity := ""
	var unit := ""
	## The values bytes 1 and 255 stand for.
	var range := Vector2.ZERO
	var cells := Vector3i.ZERO
	## Maps a unit cube onto the grid, in model units.
	var box := Transform3D()
	## The field's brick at each frame of its model.
	var files := PackedStringArray()
	## Its steps as the ZIP has them: a brick per solver time, in order.
	var step_times := PackedFloat64Array()
	var step_files := PackedStringArray()
	## The largest byte in any of its bricks, or 0 until it is measured.
	var peak := 0

	## The value [param byte] stands for, or NAN for a cell with no value.
	func value_of(byte: int) -> float:
		return NAN if byte == 0 else lerpf(range.x, range.y, (byte - 1) / 254.0)

	## A value with its unit, such as "0.067 T".
	func format(value: float) -> String:
		var text := String.num(value, 3) if absf(value) >= 0.01 or value == 0.0 else _scientific(value)
		return text if unit.is_empty() else "%s %s" % [text, unit]

	## [param value] as "9.38e-05". GDScript's % has no %e: it fails the call.
	static func _scientific(value: float) -> String:
		var exponent := floori(log(absf(value)) / log(10.0))
		var mantissa := value / pow(10.0, exponent)
		# Rounding to two decimals can carry 9.996 up to 10.00.
		if absf(mantissa) >= 9.995:
			mantissa /= 10.0
			exponent += 1
		return "%.2fe%s%02d" % [mantissa, "-" if exponent < 0 else "+", absi(exponent)]


## Text shown in the volume at a point, while a controller is near it.
class PointLabel:
	var text := ""
	## The point, in model units.
	var position := Vector3.ZERO
	## How near a controller comes for the text to show, in model units, or
	## 0 for the default.
	var radius := 0.0
	## The first and last frames it shows at, counted from 0.
	var frames := Vector2i.ZERO

	func shows_at(frame: int) -> bool:
		return frame >= frames.x and frame <= frames.y


## One model: its own volume, timeline, parts, fields and labels.
class Model:
	var name := ""
	## The solver time of each frame.
	var times := PackedFloat64Array()
	var parts: Array[Part] = []
	var fields: Array[Field] = []
	var labels: Array[PointLabel] = []
	## The index of the field shown first.
	var first_field := 0


var title := ""
var models: Array[Model] = []
## Where the notes are in the ZIP, or "" without notes.
var notes := ""

var _zip := ZIPReader.new()


## Opens the ZIP at [param path]. Returns an empty string, or what is
## wrong with it.
func open(path: String) -> String:
	if _zip.open(path) != OK:
		return "This file isn't a ZIP."
	if not _zip.file_exists(MANIFEST):
		return "This ZIP has no %s." % MANIFEST
	var manifest = JSON.parse_string(_zip.read_file(MANIFEST).get_string_from_utf8())
	if not manifest is Dictionary:
		return "%s isn't valid JSON." % MANIFEST
	title = str(manifest.get("title", path.get_file().get_basename()))
	for entry in manifest.get("models", []):
		if not entry is Dictionary:
			return "Each model in %s must be an object." % MANIFEST
		var model := Model.new()
		model.name = str(entry.get("name", "Model %d" % (models.size() + 1)))
		var error := _read_model(model, entry)
		if not error.is_empty():
			return error
		models.append(model)
	if models.is_empty():
		return "The ZIP has no models."
	notes = str(manifest.get("notes", ""))
	return ""


func _read_model(model: Model, entry: Dictionary) -> String:
	# Each part's and field's steps, as [times, files], until the timeline
	# they make is known.
	var part_steps := []
	var field_steps := []
	var all_times := PackedFloat64Array()
	for part_entry in entry.get("parts", []):
		var part := Part.new()
		part.name = str(part_entry.get("name", "Part %d" % (model.parts.size() + 1)))
		var steps := _steps(part_entry, "glb")
		if steps.is_empty():
			return "The part %s of %s needs a GLB, or a folder of GLBs with a time for each." % [part.name, model.name]
		all_times.append_array(steps[0])
		part_steps.append(steps)
		model.parts.append(part)
	if model.parts.is_empty():
		return "The model %s has no parts." % model.name
	for field_entry in entry.get("fields", []):
		var field := Field.new()
		field.name = str(field_entry.get("name", "Field %d" % (model.fields.size() + 1)))
		field.quantity = str(field_entry.get("quantity", ""))
		field.unit = str(field_entry.get("unit", ""))
		var span: Array = field_entry.get("range", [0.0, 1.0])
		field.range = Vector2(span[0], span[1])
		var cells: Array = field_entry.get("cells", [])
		field.cells = Vector3i(cells[0], cells[1], cells[2]) if cells.size() == 3 else Vector3i.ZERO
		var box: Dictionary = field_entry.get("box", {})
		var axes: Array = box.get("axes", [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
		var basis := Basis(_vector(axes[0]), _vector(axes[1]), _vector(axes[2])) * Basis.from_scale(_vector(box.get("size", [1, 1, 1])))
		field.box = Transform3D(basis, _vector(box.get("origin", [0, 0, 0])))
		var steps := _steps(field_entry, "bin")
		if steps.is_empty() or field.cells.x * field.cells.y * field.cells.z == 0:
			return "The field %s of %s needs cells, and a folder of bricks with a time for each." % [field.name, model.name]
		all_times.append_array(steps[0])
		field_steps.append(steps)
		model.fields.append(field)
	model.times = timeline(all_times)
	for index in model.parts.size():
		var part := model.parts[index]
		part.step_times = part_steps[index][0]
		part.step_files = part_steps[index][1]
		part.files = _at_frames(part_steps[index], model.times)
	for index in model.fields.size():
		var field := model.fields[index]
		field.step_times = field_steps[index][0]
		field.step_files = field_steps[index][1]
		field.files = _at_frames(field_steps[index], model.times)
	model.first_field = 0
	for index in model.fields.size():
		if model.fields[index].name == str(entry.get("field", "")):
			model.first_field = index
	var frame_count := model.times.size()
	for label_entry in entry.get("labels", []):
		var label := PointLabel.new()
		label.text = str(label_entry.get("text", "")).strip_edges()
		var position: Array = label_entry.get("position", [])
		if label.text.is_empty() or position.size() != 3:
			return "Label %d of %s needs text and a position, [x, y, z]." % [model.labels.size() + 1, model.name]
		label.position = _vector(position)
		label.radius = maxf(float(label_entry.get("radius", 0.0)), 0.0)
		# Counted from 1 in meta.json, as frames are everywhere a person sees.
		var span = label_entry.get("frames", [1, frame_count])
		var frame_error := "Label %d of %s needs frames [n] or [first, last], with whole frame numbers from 1 to %d in order." % [model.labels.size() + 1, model.name, frame_count]
		if not span is Array or span.is_empty() or span.size() > 2:
			return frame_error
		for value in span:
			if not (value is int or value is float):
				return frame_error
			if not is_finite(float(value)) or value < 1 or value > frame_count or value != floor(value):
				return frame_error
		label.frames = Vector2i(int(span[0]) - 1, int(span[-1]) - 1)
		if label.frames.x > label.frames.y:
			return frame_error
		model.labels.append(label)
	return ""


func close() -> void:
	_zip.close()


## The bytes of [param file] in the ZIP, or none if it isn't there.
func read(file: String) -> PackedByteArray:
	return _zip.read_file(file) if not file.is_empty() and _zip.file_exists(file) else PackedByteArray()


## The solver times in [param times], in order, each once: times that differ
## by no more than exporters' rounding count as one. None make one frame.
static func timeline(times: PackedFloat64Array) -> PackedFloat64Array:
	var sorted := times.duplicate()
	sorted.sort()
	var frames := PackedFloat64Array()
	for time in sorted:
		if frames.is_empty() or not same_time(frames[-1], time):
			frames.append(time)
	if frames.is_empty():
		frames.append(0.0)
	return frames


## Whether two solver times are one: exporters round them differently.
static func same_time(a: float, b: float) -> bool:
	return absf(a - b) <= maxf(absf(a), absf(b)) * 1e-6


## The index of the step that shows at [param time], given the steps'
## [param times] in order: the last one at or before it, or the first.
static func step_at(times: PackedFloat64Array, time: float) -> int:
	var step := 0
	for index in times.size():
		if times[index] <= time or same_time(times[index], time):
			step = index
	return step


## A part's or field's steps, [times, files]: one file with no time, or a
## folder of [param extension] files in name order with a time for each.
## Empty if it's neither.
func _steps(entry: Dictionary, extension: String) -> Array:
	var path := str(entry.get("path", ""))
	if path.get_extension().to_lower() == extension and _zip.file_exists(path):
		return [PackedFloat64Array(), PackedStringArray([path])]
	var files := PackedStringArray()
	var folder := path.trim_suffix("/") + "/"
	for file in _zip.get_files():
		if file.begins_with(folder) and file.get_base_dir() + "/" == folder and file.get_extension().to_lower() == extension:
			files.append(file)
	files.sort()
	var times := PackedFloat64Array()
	for time in entry.get("times", []):
		times.append(float(time))
	if files.is_empty() or times.size() != files.size():
		return []
	# Sorted by time, in case the names weren't.
	var order := range(files.size())
	order.sort_custom(func(a: int, b: int) -> bool: return times[a] < times[b])
	var sorted_times := PackedFloat64Array()
	var sorted_files := PackedStringArray()
	for index in order:
		sorted_times.append(times[index])
		sorted_files.append(files[index])
	return [sorted_times, sorted_files]


## The file a part or field shows at each frame of [param frames].
static func _at_frames(steps: Array, frames: PackedFloat64Array) -> PackedStringArray:
	var times: PackedFloat64Array = steps[0]
	var files: PackedStringArray = steps[1]
	var at := PackedStringArray()
	for time in frames:
		at.append(files[0] if times.is_empty() else files[step_at(times, time)])
	return at


static func _vector(values: Array) -> Vector3:
	return Vector3(values[0], values[1], values[2])
