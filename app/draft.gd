extends RefCounted
## What the workspace edits: the contents of a ZIP, as the workspace builds
## them up from files on disk and from the ZIP it was opened from, until
## they are saved as a ZIP; see docs/zip-format.md.
##
## Each GLB, brick and image is a source: a path on disk, or a path in the
## opened ZIP with the [constant IN_ZIP] prefix. Sources are copied as they
## are when the draft is saved; nothing is decoded.

const Meta := preload("res://app/meta.gd")
const GLBInfo := preload("res://app/glb_info.gd")
const BOV := preload("res://app/bov.gd")
const NotesImages := preload("res://app/notes_images.gd")
const IN_ZIP := "zip://"
const NOTES_FILE := "notes.txt"
const IMAGES_FOLDER := "images"
## Saving writes beside the target first, so a failure leaves the old ZIP.
const TEMPORARY_SUFFIX := ".saving"


class Model:
	var name := ""
	## One source, shown at every frame, or one per frame.
	var files := PackedStringArray()

	func changes() -> bool:
		return files.size() > 1


class Field:
	var name := ""
	var quantity := ""
	var unit := ""
	var range := Vector2(0.0, 1.0)
	var cells := Vector3i.ZERO
	var origin := Vector3.ZERO
	var size := Vector3.ONE
	var axes := Basis()
	## The brick source at each frame that has one.
	var bricks := {}


class PointLabel:
	var text := ""
	var position := Vector3.ZERO
	## 0 for the default.
	var radius := 0.0
	## The first and last frames it shows at, counted from 0; a last frame of
	## -1 is the last there is.
	var frames := Vector2i(0, -1)

	## The first line of its text, to list it by.
	func title() -> String:
		var line := text.strip_edges().get_slice("\n", 0)
		return line if not line.is_empty() else "(no text)"


var title := ""
var times := PackedFloat64Array()
var models: Array[Model] = []
var fields: Array[Field] = []
var labels: Array[PointLabel] = []
var first_field := 0
var notes := ""
## The images the notes can show, by file name, as sources.
var images := {}

var _zip: ZIPReader
## A ZIPReader reads one file at a time: the notes preview may read while a
## save does.
var _zip_lock := Mutex.new()
## Model bounds by GLB source, once read.
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
	times = meta.times.duplicate()
	models = []
	fields = []
	labels = []
	images = {}
	_bounds.clear()
	for entry in meta.models:
		var model := Model.new()
		model.name = entry.name
		# A model shown at every frame has the same file at each.
		var files := entry.files if entry.files.count(entry.files[0]) < entry.files.size() else PackedStringArray([entry.files[0]])
		for file in files:
			model.files.append(IN_ZIP + file)
		models.append(model)
	for entry in meta.fields:
		var field := Field.new()
		field.name = entry.name
		field.quantity = entry.quantity
		field.unit = entry.unit
		field.range = entry.range
		field.cells = entry.cells
		field.origin = entry.box.origin
		field.size = entry.box.basis.get_scale()
		field.axes = entry.box.basis.orthonormalized()
		for frame in entry.files.size():
			# A brick with no values is the same as none.
			if read_source(IN_ZIP + entry.files[frame]).count(0) < field.cells.x * field.cells.y * field.cells.z:
				field.bricks[frame] = IN_ZIP + entry.files[frame]
		fields.append(field)
	for entry in meta.labels:
		var label := PointLabel.new()
		label.text = entry.text
		label.position = entry.position
		label.radius = entry.radius
		# Through the last frame stays so as frames are added.
		label.frames = Vector2i(entry.frames.x, -1 if entry.frames.y >= times.size() - 1 else entry.frames.y)
		labels.append(label)
	first_field = meta.first_field
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


## Adds the GLBs at [param paths] as models. GLBs named alike but for a
## number, as EnSight writes one per time step, become one model with a GLB
## per frame; any other becomes a model shown at every frame. Without frames
## yet, the frames come from the GLBs' solver times. Returns an empty string,
## or what is wrong with the GLBs.
func add_glbs(paths: PackedStringArray) -> String:
	var groups := {}
	for file in paths:
		var stem := file.get_file().get_basename().rstrip("0123456789").rstrip("_-. ")
		if stem.is_empty():
			stem = file.get_file().get_basename()
		if not groups.has(stem):
			groups[stem] = PackedStringArray()
		groups[stem].append(file)
	var added: Array[Model] = []
	for stem: String in groups:
		var files: PackedStringArray = groups[stem]
		files.sort()
		var model := Model.new()
		model.name = stem
		var frame_times := PackedFloat64Array()
		for file in files:
			var json := GLBInfo.json(FileAccess.get_file_as_bytes(file))
			if json.is_empty():
				return "%s isn't a GLB." % file.get_file()
			if GLBInfo.scene_count(json) > 1:
				return "%s has a scene for each time step. Export a GLB for each time step instead." % file.get_file()
			var time := GLBInfo.time(json)
			frame_times.append(time if not is_nan(time) else frame_times.size())
			model.files.append(file)
		if model.changes():
			if times.is_empty():
				times = frame_times
			elif times.size() != model.files.size():
				return "%s has %d GLBs, but there are %d frames." % [stem, model.files.size(), times.size()]
		added.append(model)
	models.append_array(added)
	_bounds.clear()
	return ""


## Adds the bricks whose headers are at [param paths] as fields, one per
## variable. Each brick goes to the frame at its solver time; a time no
## frame has yet becomes a frame of its own, in order, unless a model's GLBs
## set the frames. Returns an empty string, or what is wrong with the
## bricks.
func add_bovs(paths: PackedStringArray) -> String:
	var bovs := []
	for file in paths:
		var bov = BOV.read(file)
		if bov == null:
			return "%s isn't a brick header with its data beside it." % file.get_file()
		bovs.append(bov)
	for model in models:
		if not model.changes():
			continue
		for bov in bovs:
			if _frame_of(bov.time) < 0:
				return "%s is at time %s, but %s's GLBs set the frames, and none is at that time." % [bov.data.get_file(), bov.time, model.name]
	for bov in bovs:
		var field: Field = null
		for existing in fields:
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
			fields.append(field)
			fit_field(field)
		elif field.cells != bov.cells:
			return "%s has %s cells, but %s has %s." % [bov.data.get_file(), bov.cells, field.name, field.cells]
		var frame := _frame_of(bov.time)
		if frame < 0:
			frame = _add_frame(bov.time)
		field.bricks[frame] = bov.data
	return ""


## Grows or shrinks [param field]'s box about its center until it spans
## the models along their longest side. EnSight doesn't say what scale it
## writes bricks at, and it isn't the geometry's: the Hall sensor's brick
## says it is 40 across, around a model 80 across. Does nothing without
## models.
func fit_field(field: Field) -> void:
	var bounds := model_bounds()
	if not bounds.has_volume():
		return
	var axis := bounds.size.max_axis_index()
	if field.size[axis] <= 0.0:
		return
	var scale := bounds.size[axis] / field.size[axis]
	var center := field.origin + field.size * 0.5
	field.size *= scale
	field.origin = center - field.size * 0.5


## The bounds of every model's first GLB, together.
func model_bounds() -> AABB:
	var bounds := AABB()
	for model in models:
		var source := model.files[0]
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
	if times.is_empty():
		return "Add a frame, or import GLBs or bricks that have solver times."
	if models.is_empty():
		return "Import a GLB."
	var names := {}
	for model in models:
		if model.name.strip_edges().is_empty():
			return "A model has no name."
		if model.changes() and model.files.size() != times.size():
			return "%s has %d GLBs, but there are %d frames." % [model.name, model.files.size(), times.size()]
		if names.has(_folder(model.name)):
			return "Two models are both named %s." % model.name
		names[_folder(model.name)] = true
	names.clear()
	for field in fields:
		if field.name.strip_edges().is_empty():
			return "A field has no name."
		if field.cells.x * field.cells.y * field.cells.z == 0:
			return "%s has no cells." % field.name
		if names.has(_folder(field.name)):
			return "Two fields are both named %s." % field.name
		names[_folder(field.name)] = true
	return label_problems()


func label_problems() -> String:
	for label in labels:
		if label.text.strip_edges().is_empty():
			return "A label has no text."
		if not label.position.is_finite() or not is_finite(label.radius) or label.radius < 0.0:
			return "A label needs a finite position and a nonnegative radius."
		var last := label.frames.y if label.frames.y >= 0 else times.size() - 1
		if label.frames.x < 0 or last < label.frames.x or last >= times.size():
			return "The label %s shows at frames %d to %d, but there are %d frames." % [label.title(), label.frames.x + 1, last + 1, times.size()]
	return ""


func _write_labels(manifest: Dictionary) -> void:
	manifest.erase("labels")
	if not labels.is_empty():
		manifest.labels = []
	for label in labels:
		var entry := {text = label.text.strip_edges(), position = _array(label.position)}
		if label.radius > 0.0:
			entry.radius = label.radius
		if label.frames != Vector2i(0, -1):
			entry.frames = [label.frames.x + 1, (label.frames.y if label.frames.y >= 0 else times.size() - 1) + 1]
		manifest.labels.append(entry)


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
	var manifest := {title = title, frames = [], models = [], fields = []}
	for time in times:
		manifest.frames.append({time = time})
	for model in models:
		var folder := "models/%s" % _folder(model.name)
		if model.changes():
			for frame in model.files.size():
				_store(packer, "%s/%04d.glb" % [folder, frame + 1], read_source(model.files[frame]))
			manifest.models.append({name = model.name, path = folder})
		else:
			_store(packer, folder + ".glb", read_source(model.files[0]))
			manifest.models.append({name = model.name, path = folder + ".glb"})
	for field in fields:
		var folder := "fields/%s" % _folder(field.name)
		# Every frame has a brick; one with no values where there is none.
		var empty := PackedByteArray()
		empty.resize(field.cells.x * field.cells.y * field.cells.z)
		for frame in times.size():
			_store(packer, "%s/%04d.bin" % [folder, frame + 1], read_source(field.bricks[frame]) if field.bricks.has(frame) else empty)
		manifest.fields.append({
			name = field.name,
			quantity = field.quantity,
			unit = field.unit,
			range = [field.range.x, field.range.y],
			cells = [field.cells.x, field.cells.y, field.cells.z],
			box = {origin = _array(field.origin), size = _array(field.size), axes = [_array(field.axes.x), _array(field.axes.y), _array(field.axes.z)]},
			path = folder,
		})
	if not fields.is_empty():
		manifest.field = fields[clampi(first_field, 0, fields.size() - 1)].name
	_write_labels(manifest)
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


## The frame at [param time], or -1. Times written by different exporters
## differ a little, so a time counts as a frame's when it is much nearer to
## it than to the frames beside it.
func _frame_of(time: float) -> int:
	if times.is_empty():
		return -1
	var best := 0
	for index in times.size():
		if absf(times[index] - time) < absf(times[best] - time):
			best = index
	var gap := INF
	if best > 0:
		gap = times[best] - times[best - 1]
	if best < times.size() - 1:
		gap = minf(gap, times[best + 1] - times[best])
	if is_inf(gap):
		gap = maxf(absf(times[best]), absf(time))
	return best if absf(times[best] - time) <= gap * 1e-3 else -1


## Adds a frame at [param time], in order, and returns it. Whatever has a
## file per frame shifts past it; a model's GLB from the frame before also
## shows at it.
func _add_frame(time: float) -> int:
	var frame := times.bsearch(time)
	times.insert(frame, time)
	for model in models:
		if model.changes():
			model.files.insert(frame, model.files[maxi(frame - 1, 0)])
	for field in fields:
		var bricks := {}
		for at: int in field.bricks:
			bricks[at + 1 if at >= frame else at] = field.bricks[at]
		field.bricks = bricks
	for label in labels:
		if frame <= label.frames.x and label.frames.x > 0:
			label.frames.x += 1
		if frame <= label.frames.y:
			label.frames.y += 1
	return frame


static func _folder(name: String) -> String:
	return name.strip_edges().validate_filename()


static func _store(packer: ZIPPacker, file: String, bytes: PackedByteArray) -> void:
	packer.start_file(file)
	packer.write_file(bytes)
	packer.close_file()


static func _array(vector: Vector3) -> Array:
	return [vector.x, vector.y, vector.z]
