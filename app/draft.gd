extends RefCounted
## What the workspace edits: the contents of a ZIP, as the workspace builds
## them up from files on disk and from the ZIP it was opened from, until
## they are saved as a ZIP; see docs/zip-format.md.
##
## Each GLB, brick and image is a source: a path on disk, or a path in the
## opened ZIP with the [constant IN_ZIP] prefix. Sources are copied as they
## are when the draft is saved; nothing is decoded.
##
## Nothing here keeps frames: a model's timeline is the solver times of its
## parts' and fields' steps, worked out whenever it is needed, so importing
## or removing steps never shifts anything else.

const Meta := preload("res://app/meta.gd")
const GLBInfo := preload("res://app/glb_info.gd")
const BOV := preload("res://app/bov.gd")
const NotesImages := preload("res://app/notes_images.gd")
const IN_ZIP := "zip://"
const NOTES_FILE := "notes.txt"
const IMAGES_FOLDER := "images"
const MODELS_FOLDER := "models"
## Saving writes beside the target first, so a failure leaves the old ZIP.
const TEMPORARY_SUFFIX := ".saving"


class Part:
	var name := ""
	## Its GLBs in time order, with each one's solver time; or one GLB with no
	## time, for a part that doesn't change.
	var files := PackedStringArray()
	var times := PackedFloat64Array()

	func changes() -> bool:
		return not times.is_empty()


class Field:
	var name := ""
	var quantity := ""
	var unit := ""
	var range := Vector2(0.0, 1.0)
	var cells := Vector3i.ZERO
	var origin := Vector3.ZERO
	var size := Vector3.ONE
	var axes := Basis()
	## Its bricks by solver time.
	var bricks := {}

	## The time among its bricks' that is [param time], or [param time].
	func key_for(time: float) -> float:
		for at: float in bricks:
			if Meta.same_time(at, time):
				return at
		return time


class PointLabel:
	var text := ""
	var position := Vector3.ZERO
	## 0 for the default.
	var radius := 0.0
	## The first and last solver times it shows at; -INF and INF reach the
	## ends of the timeline, however it grows.
	var span := Vector2(-INF, INF)

	## The first line of its text, to list it by.
	func title() -> String:
		var line := text.strip_edges().get_slice("\n", 0)
		return line if not line.is_empty() else "(no text)"


class Model:
	var name := ""
	var parts: Array[Part] = []
	var fields: Array[Field] = []
	var labels: Array[PointLabel] = []
	var first_field := 0

	## The solver time of each frame: every time its parts and fields have.
	func times() -> PackedFloat64Array:
		var all := PackedFloat64Array()
		for part in parts:
			all.append_array(part.times)
		for field in fields:
			all.append_array(PackedFloat64Array(field.bricks.keys()))
		return Meta.timeline(all)

	## The frames, counted from 0, that [param label] shows at, as [first,
	## last]; last is below first if it shows at none.
	func label_frames(label: PointLabel) -> Vector2i:
		var frames := times()
		var first := frames.size()
		var last := -1
		for index in frames.size():
			var time := frames[index]
			var after_first := time >= label.span.x or Meta.same_time(time, label.span.x)
			var before_last := time <= label.span.y or Meta.same_time(time, label.span.y)
			if after_first and before_last:
				first = mini(first, index)
				last = index
		return Vector2i(first, last)

	## The span that shows [param label] from frame [param first] to frame
	## [param last], counted from 0; the ends of the timeline stay open.
	func span_of(first: int, last: int) -> Vector2:
		var frames := times()
		return Vector2(-INF if first <= 0 else frames[first], INF if last >= frames.size() - 1 else frames[last])


var title := ""
var models: Array[Model] = []
var notes := ""
## The images the notes can show, by file name, as sources.
var images := {}

var _zip: ZIPReader
## A ZIPReader reads one file at a time: the notes preview may read while a
## save does.
var _zip_lock := Mutex.new()
## Bounds by GLB source, once read.
var _bounds := {}


## Takes the contents of the ZIP at [param zip_path]. Returns an empty
## string, or what is wrong with it.
func open(zip_path: String) -> String:
	var meta := Meta.new()
	var error := meta.open(zip_path)
	if not error.is_empty():
		meta.close()
		return error
	close()
	var zip := ZIPReader.new()
	zip.open(zip_path)
	_zip_lock.lock()
	_zip = zip
	_zip_lock.unlock()
	title = meta.title
	models = []
	images = {}
	_bounds.clear()
	for entry in meta.models:
		var model := Model.new()
		model.name = entry.name
		for part_entry in entry.parts:
			var part := Part.new()
			part.name = part_entry.name
			part.times = part_entry.step_times.duplicate()
			for file in part_entry.step_files:
				part.files.append(IN_ZIP + file)
			model.parts.append(part)
		for field_entry in entry.fields:
			var field := Field.new()
			field.name = field_entry.name
			field.quantity = field_entry.quantity
			field.unit = field_entry.unit
			field.range = field_entry.range
			field.cells = field_entry.cells
			field.origin = field_entry.box.origin
			field.size = field_entry.box.basis.get_scale()
			field.axes = field_entry.box.basis.orthonormalized()
			for step in field_entry.step_files.size():
				field.bricks[field_entry.step_times[step]] = IN_ZIP + field_entry.step_files[step]
			model.fields.append(field)
		model.first_field = entry.first_field
		for label_entry in entry.labels:
			var label := PointLabel.new()
			label.text = label_entry.text
			label.position = label_entry.position
			label.radius = label_entry.radius
			model.labels.append(label)
			label.span = model.span_of(label_entry.frames.x, label_entry.frames.y)
		models.append(model)
	notes = meta.read(meta.notes).get_string_from_utf8()
	var images_folder := (meta.notes.get_base_dir().path_join(IMAGES_FOLDER) if not meta.notes.is_empty() else IMAGES_FOLDER).trim_prefix("/")
	for file in _zip.get_files():
		if file.get_base_dir() == images_folder and NotesImages.is_image(file):
			images[file.get_file()] = IN_ZIP + file
	meta.close()
	return ""


func close() -> void:
	_zip_lock.lock()
	if _zip:
		_zip.close()
		_zip = null
	_zip_lock.unlock()


## Adds an empty model, named to stand apart from the others, and returns it.
func add_model() -> Model:
	var model := Model.new()
	var number := models.size() + 1
	model.name = "Model %d" % number
	while models.any(func(other: Model) -> bool: return _folder(other.name) == _folder(model.name)):
		number += 1
		model.name = "Model %d" % number
	models.append(model)
	return model


## Adds the GLBs at [param paths] to [param model] as parts. GLBs named alike
## but for a number, as EnSight writes one per time step, become one part
## that changes, at their solver times; any other becomes a part shown at
## every frame. Returns an empty string, or what is wrong with the GLBs.
func add_glbs(model: Model, paths: PackedStringArray) -> String:
	var groups := {}
	for file in paths:
		var stem := file.get_file().get_basename().rstrip("0123456789").rstrip("_-. ")
		if stem.is_empty():
			stem = file.get_file().get_basename()
		if not groups.has(stem):
			groups[stem] = PackedStringArray()
		groups[stem].append(file)
	var added: Array[Part] = []
	for stem: String in groups:
		var files: PackedStringArray = groups[stem]
		files.sort()
		var part := Part.new()
		part.name = stem
		var times := PackedFloat64Array()
		var timed := true
		for file in files:
			var json := GLBInfo.json(FileAccess.get_file_as_bytes(file))
			if json.is_empty():
				return "%s isn't a GLB." % file.get_file()
			if GLBInfo.scene_count(json) > 1:
				return "%s has a scene for each time step. Export a GLB for each time step instead." % file.get_file()
			var time := GLBInfo.time(json)
			timed = timed and not is_nan(time)
			times.append(time)
		part.files = files
		if files.size() > 1:
			# Without solver times, the steps are 0, 1, 2… in name order.
			for index in times.size():
				if not timed:
					times[index] = index
			part.times = times
			_sort_steps(part)
		added.append(part)
	model.parts.append_array(added)
	_bounds.clear()
	return ""


## Orders a part's steps by time, in case its names didn't.
static func _sort_steps(part: Part) -> void:
	var order := range(part.files.size())
	order.sort_custom(func(a: int, b: int) -> bool: return part.times[a] < part.times[b])
	var files := PackedStringArray()
	var times := PackedFloat64Array()
	for index in order:
		files.append(part.files[index])
		times.append(part.times[index])
	part.files = files
	part.times = times


## Adds the bricks whose headers are at [param paths] to [param model], as
## a field per variable, each brick at its solver time: the steps can come
## in any order, a few at a time. A brick at a time its field already has
## replaces that one. Returns an empty string, or what is wrong with the
## bricks.
func add_bovs(model: Model, paths: PackedStringArray) -> String:
	var bovs := []
	for file in paths:
		var bov = BOV.read(file)
		if bov == null:
			return "%s isn't a brick header with its data beside it." % file.get_file()
		bovs.append(bov)
	for bov in bovs:
		var field: Field = null
		for existing in model.fields:
			if existing.name == bov.variable:
				field = existing
		if field == null:
			field = Field.new()
			field.name = bov.variable
			field.range = bov.range
			field.cells = bov.cells
			field.origin = bov.origin
			field.size = bov.size
			field.axes = bov.axes
			model.fields.append(field)
			fit_field(model, field)
		elif field.cells != bov.cells:
			return "%s has %s cells, but %s has %s." % [bov.data.get_file(), bov.cells, field.name, field.cells]
		field.bricks[field.key_for(bov.time)] = bov.data
	return ""


## Grows or shrinks [param field]'s box about its center until it spans
## [param model]'s parts along their longest side. EnSight doesn't say what
## scale it writes bricks at, and it isn't the geometry's: the Hall sensor's
## brick says it is 40 across, around a model 80 across. Does nothing
## without parts.
func fit_field(model: Model, field: Field) -> void:
	var bounds := model_bounds(model)
	if not bounds.has_volume():
		return
	var axis := bounds.size.max_axis_index()
	if field.size[axis] <= 0.0:
		return
	var scale := bounds.size[axis] / field.size[axis]
	var center := field.origin + field.size * 0.5
	field.size *= scale
	field.origin = center - field.size * 0.5


## The bounds of each of [param model]'s parts' first GLB, together.
func model_bounds(model: Model) -> AABB:
	var bounds := AABB()
	for part in model.parts:
		var source := part.files[0]
		if not _bounds.has(source):
			_bounds[source] = GLBInfo.bounds(GLBInfo.json(read_source(source)))
		bounds = GLBInfo.merge(bounds, _bounds[source])
	return bounds


func add_images(paths: PackedStringArray) -> void:
	for file in paths:
		if NotesImages.is_image(file):
			images[file.get_file()] = file


## The bytes of [param file], as the saved ZIP would hold it, for the
## notes' images; none if it isn't an image here.
func read_file(file: String) -> PackedByteArray:
	if file.get_base_dir() == IMAGES_FOLDER and images.has(file.get_file()):
		return read_source(images[file.get_file()])
	return PackedByteArray()


func read_source(source: String) -> PackedByteArray:
	if source.begins_with(IN_ZIP):
		_zip_lock.lock()
		var bytes := _zip.read_file(source.trim_prefix(IN_ZIP)) if _zip else PackedByteArray()
		_zip_lock.unlock()
		return bytes
	return FileAccess.get_file_as_bytes(source)


## What keeps the draft from being saved, or an empty string.
func problems() -> String:
	if models.is_empty():
		return "Add a model."
	var model_names := {}
	for model in models:
		if model.name.strip_edges().is_empty():
			return "A model has no name."
		if model_names.has(_folder(model.name)):
			return "Two models are both named %s." % model.name
		model_names[_folder(model.name)] = true
		if model.parts.is_empty():
			return "%s has no parts: import a GLB." % model.name
		var names := {}
		for part in model.parts:
			if part.name.strip_edges().is_empty():
				return "A part of %s has no name." % model.name
			if names.has(_folder(part.name)):
				return "%s has two parts named %s." % [model.name, part.name]
			names[_folder(part.name)] = true
		names.clear()
		for field in model.fields:
			if field.name.strip_edges().is_empty():
				return "A field of %s has no name." % model.name
			if field.cells.x * field.cells.y * field.cells.z == 0:
				return "%s has no cells." % field.name
			if field.bricks.is_empty():
				return "%s has no bricks." % field.name
			if names.has(_folder(field.name)):
				return "%s has two fields named %s." % [model.name, field.name]
			names[_folder(field.name)] = true
		var problem := label_problems(model)
		if not problem.is_empty():
			return problem
	return ""


func label_problems(model: Model) -> String:
	for label in model.labels:
		if label.text.strip_edges().is_empty():
			return "A label of %s has no text." % model.name
		if not label.position.is_finite() or not is_finite(label.radius) or label.radius < 0.0:
			return "A label needs a finite position and a nonnegative radius."
		var frames := model.label_frames(label)
		if frames.y < frames.x:
			return "The label %s shows at none of %s's frames." % [label.title(), model.name]
	return ""


## Writes the ZIP at [param target]. Returns an empty string, or what went
## wrong. Afterwards the draft reads from that ZIP. Safe to call from a
## thread; nothing else should touch the draft meanwhile.
func save(target: String) -> String:
	var error := problems()
	if not error.is_empty():
		return error
	var temporary := target + TEMPORARY_SUFFIX
	var packer := ZIPPacker.new()
	if packer.open(temporary) != OK:
		return "Couldn't write %s." % target
	var manifest := {title = title, models = []}
	for model in models:
		var model_folder := "%s/%s" % [MODELS_FOLDER, _folder(model.name)]
		var entry := {name = model.name, parts = [], fields = []}
		for part in model.parts:
			var path := "%s/parts/%s" % [model_folder, _folder(part.name)]
			if part.changes():
				for step in part.files.size():
					_store(packer, "%s/%04d.glb" % [path, step + 1], read_source(part.files[step]))
				entry.parts.append({name = part.name, path = path, times = Array(part.times)})
			else:
				_store(packer, path + ".glb", read_source(part.files[0]))
				entry.parts.append({name = part.name, path = path + ".glb"})
		for field in model.fields:
			var path := "%s/fields/%s" % [model_folder, _folder(field.name)]
			var times: Array = field.bricks.keys()
			times.sort()
			for step in times.size():
				_store(packer, "%s/%04d.bin" % [path, step + 1], read_source(field.bricks[times[step]]))
			entry.fields.append({
				name = field.name,
				quantity = field.quantity,
				unit = field.unit,
				range = [field.range.x, field.range.y],
				cells = [field.cells.x, field.cells.y, field.cells.z],
				box = {origin = _array(field.origin), size = _array(field.size), axes = [_array(field.axes.x), _array(field.axes.y), _array(field.axes.z)]},
				path = path,
				times = times,
			})
		if not model.fields.is_empty():
			entry.field = model.fields[clampi(model.first_field, 0, model.fields.size() - 1)].name
		var frame_count := model.times().size()
		if not model.labels.is_empty():
			entry.labels = []
		for label in model.labels:
			var label_entry := {text = label.text.strip_edges(), position = _array(label.position)}
			if label.radius > 0.0:
				label_entry.radius = label.radius
			var frames := model.label_frames(label)
			if frames != Vector2i(0, frame_count - 1):
				label_entry.frames = [frames.x + 1, frames.y + 1]
			entry.labels.append(label_entry)
		manifest.models.append(entry)
	if not notes.strip_edges().is_empty():
		_store(packer, NOTES_FILE, notes.to_utf8_buffer())
		manifest.notes = NOTES_FILE
	for name: String in images:
		_store(packer, IMAGES_FOLDER.path_join(name), read_source(images[name]))
	_store(packer, Meta.MANIFEST, JSON.stringify(manifest, "\t").to_utf8_buffer())
	packer.close()

	close()
	DirAccess.remove_absolute(target)
	if DirAccess.rename_absolute(temporary, target) != OK:
		return "Couldn't replace %s." % target
	# From now on everything is read from the saved ZIP: the files it came
	# from may move, and the ZIP is what the person has.
	return open(target)


static func _folder(name: String) -> String:
	return name.strip_edges().validate_filename()


static func _store(packer: ZIPPacker, file: String, bytes: PackedByteArray) -> void:
	packer.start_file(file)
	packer.write_file(bytes)
	packer.close_file()


static func _array(vector: Vector3) -> Array:
	return [vector.x, vector.y, vector.z]
