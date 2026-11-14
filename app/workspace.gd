extends Window
## The desktop's editor for a ZIP: a window where models are made from
## imported GLBs and bricks, their parts, fields and labels are set, and the
## notes are written with a live preview, then saved as a ZIP in the library.
## The pages but Images and Notes show the model picked in the sidebar. Edits
## a [Draft]; see docs/zip-format.md for what it saves.

const Draft := preload("res://app/draft.gd")
const NotesImages := preload("res://app/notes_images.gd")
const NativeDialogs := preload("res://app/native_dialogs.gd")
## Seconds after the last keystroke before the notes preview refreshes.
const PREVIEW_DELAY := 0.3

## The ZIP was saved; the library may show it, or open it as it plays.
signal saved(path: String, play: bool)

var draft := Draft.new()
## The model the pages show, or null without any.
var model: Draft.Model
## Where the ZIP is saved.
var target := ""
var _save_thread: Thread
## The textures the notes preview and the image preview show.
var _preview_images := NotesImages.new()
var _image_preview := NotesImages.new()
var _preview_timer: SceneTreeTimer
## Set while the forms show a draft, so their edits aren't taken as changes.
var _filling := false
var _label_inputs := {}
var _label_errors := {}


## Starts on the ZIP at [param path], or empty for a new one saved there.
## Returns an empty string, or what is wrong with the ZIP.
func start(path: String) -> String:
	NativeDialogs.apply_to(self)
	target = path
	if FileAccess.file_exists(path):
		var error := draft.open(path)
		if not error.is_empty():
			return error
	else:
		draft.title = path.get_file().get_basename()
		draft.add_model().name = draft.title
	_show_target()
	_show_draft()
	show_page("Parts")
	show()
	return ""


func _show_draft() -> void:
	_label_inputs.clear()
	_label_errors.clear()
	_filling = true
	%Title.text = draft.title
	%Editor.text = draft.notes
	_filling = false
	show_models(0)
	show_images()
	refresh_preview()


## Shows the page called [param page_name], one of the sidebar's sections.
func show_page(page_name: String) -> void:
	for page in %Pages.get_children():
		page.visible = page.name == page_name
	if page_name == "Labels":
		_show_model_bounds()
	# Through its group, so the other sections let go; only toggled fires.
	(%Pages.get_node("../../Sidebar/Column/%sSection" % page_name) as Button).button_pressed = true


func close() -> void:
	if _save_thread:
		return
	draft.close()
	queue_free()


func edit_title(text: String) -> void:
	draft.title = text


## Writes the ZIP on a thread, so a big one doesn't freeze the window.
func save(play := false) -> void:
	if _save_thread:
		return
	var problem: String = _label_errors.values()[0] if not _label_errors.is_empty() else draft.problems()
	if not problem.is_empty():
		_show_status(problem)
		return
	_set_busy(true, "Saving…")
	_save_thread = Thread.new()
	_save_thread.start(func() -> void:
		var error := draft.save(ProjectSettings.globalize_path(target))
		_finish_save.call_deferred(error, play))


func _finish_save(error: String, play: bool) -> void:
	_save_thread.wait_to_finish()
	_save_thread = null
	_set_busy(false, error if not error.is_empty() else "Saved")
	if error.is_empty():
		_label_inputs.clear()
		_label_errors.clear()
		# Sources now point into the saved ZIP.
		show_models()
		show_images()
		refresh_preview()
		saved.emit(target, play)


func preview() -> void:
	save(true)


func ask_save_as() -> void:
	var dialog: FileDialog = %SaveAsFile
	dialog.current_file = target.get_file()
	dialog.popup_centered()


## Saves to [param path] instead, and keeps working on that ZIP.
func save_as(path: String) -> void:
	if path.get_extension().to_lower() != "zip":
		path += ".zip"
	target = path
	_show_target()
	save()


func _show_target() -> void:
	title = "%s – Workspace" % target.get_file().get_basename()
	%File.text = target.get_file()


func _set_busy(busy: bool, status: String) -> void:
	if busy:
		gui_release_focus()
	$Root.process_mode = Node.PROCESS_MODE_DISABLED if busy else Node.PROCESS_MODE_INHERIT
	%Save.disabled = busy
	%SaveAs.disabled = busy
	%Preview.disabled = busy
	%Pages.modulate.a = 0.6 if busy else 1.0
	_show_status(status)


func _show_status(message: String) -> void:
	%Status.text = message


# Models

func add_model() -> void:
	draft.add_model()
	show_models(draft.models.size() - 1)
	%ModelName.grab_focus()
	%ModelName.select_all()


func show_models(selected := -1) -> void:
	var list: ItemList = %ModelList
	if selected < 0 and list.is_anything_selected():
		selected = list.get_selected_items()[0]
	list.clear()
	for each in draft.models:
		list.add_item(each.name)
	selected = clampi(selected, -1, draft.models.size() - 1)
	if selected >= 0:
		list.select(selected)
	show_model(selected)


## Shows model [param index] on the pages, or none.
func show_model(index: int) -> void:
	model = draft.models[index] if index >= 0 else null
	_label_inputs.clear()
	_label_errors.clear()
	_filling = true
	%ModelName.text = model.name if model else ""
	%ModelName.editable = model != null
	_filling = false
	show_frames()
	show_parts()
	show_fields()
	show_labels()
	if %Pages.get_node("Labels").visible:
		_show_model_bounds()


func rename_model(text: String) -> void:
	if _filling or model == null:
		return
	model.name = text
	%ModelList.set_item_text(draft.models.find(model), text)


func remove_model() -> void:
	var index := draft.models.find(model)
	if index >= 0:
		draft.models.remove_at(index)
		show_models(maxi(index - 1, 0))


func move_model(by: int) -> void:
	var index := draft.models.find(model)
	var to := index + by
	if index < 0 or to < 0 or to >= draft.models.size():
		return
	draft.models.remove_at(index)
	draft.models.insert(to, model)
	show_models(to)


# Timeline

## The model's frames: every solver time its parts and fields have, with
## which of them has a step there.
func show_frames() -> void:
	var tree: Tree = %FrameList
	tree.clear()
	tree.set_column_title(0, "Frame")
	tree.set_column_title(1, "Time")
	tree.set_column_title(2, "Steps at this time")
	for column in 3:
		tree.set_column_title_alignment(column, HORIZONTAL_ALIGNMENT_LEFT)
	tree.set_column_expand(0, false)
	tree.set_column_custom_minimum_width(0, 100)
	tree.set_column_expand(1, false)
	tree.set_column_custom_minimum_width(1, 160)
	var root := tree.create_item()
	if model == null:
		%FramesCaption.text = "Add a model."
		return
	var times := model.times()
	for index in times.size():
		var item := tree.create_item(root)
		item.set_text(0, str(index + 1))
		item.set_text(1, _number(times[index]))
		var names := PackedStringArray()
		for part in model.parts:
			if _has_time(Array(part.times), times[index]):
				names.append(part.name)
		for field in model.fields:
			if _has_time(field.bricks.keys(), times[index]):
				names.append(field.name)
		item.set_text(2, ", ".join(names))
	%FramesCaption.text = "%d frames, from the solver times of the parts' GLBs and the fields' bricks, in order; there is nothing to set. Where a part or field has no step, it shows its last one before." % times.size()


static func _has_time(times: Array, time: float) -> bool:
	return times.any(func(each: float) -> bool: return Draft.Meta.same_time(each, time))


# Parts

func import_glbs(paths: PackedStringArray) -> void:
	if model == null:
		return
	var error := draft.add_glbs(model, paths)
	if not error.is_empty():
		_show_status(error)
		return
	show_frames()
	show_parts(model.parts.size() - 1)
	# Bricks imported before the parts are scaled to them now.
	for field in model.fields:
		draft.fit_field(model, field)
	show_fields()


func show_parts(selected := -1) -> void:
	var list: ItemList = %PartList
	if selected < 0 and list.is_anything_selected():
		selected = list.get_selected_items()[0]
	list.clear()
	var count := model.parts.size() if model else 0
	for index in count:
		list.add_item(model.parts[index].name)
	selected = clampi(selected, -1, count - 1)
	if selected >= 0:
		list.select(selected)
	show_part(selected)


func show_part(index: int) -> void:
	%PartForm.get_parent().visible = index >= 0
	if index < 0:
		return
	var part: Draft.Part = model.parts[index]
	_filling = true
	%PartName.text = part.name
	_filling = false
	if part.changes():
		%PartInfo.text = "%d, one per time step from %s to %s, from %s" % [part.files.size(), _number(part.times[0]), _number(part.times[-1]), _describe(part.files[0])]
	else:
		%PartInfo.text = "One, shown at every frame: %s" % _describe(part.files[0])


func rename_part(text: String) -> void:
	if _filling:
		return
	var index := _selected(%PartList)
	if index >= 0:
		model.parts[index].name = text
		%PartList.set_item_text(index, text)


func remove_part() -> void:
	var index := _selected(%PartList)
	if index >= 0:
		model.parts.remove_at(index)
		show_parts(index - 1)
		show_frames()


func move_part(by: int) -> void:
	var index := _selected(%PartList)
	var to := index + by
	if index < 0 or to < 0 or to >= model.parts.size():
		return
	var part: Draft.Part = model.parts[index]
	model.parts.remove_at(index)
	model.parts.insert(to, part)
	show_parts(to)


# Fields

func import_bovs(paths: PackedStringArray) -> void:
	if model == null:
		return
	var error := draft.add_bovs(model, paths)
	if not error.is_empty():
		_show_status(error)
		return
	show_frames()
	show_fields(model.fields.size() - 1)


func show_fields(selected := -1) -> void:
	var list: ItemList = %FieldList
	if selected < 0 and list.is_anything_selected():
		selected = list.get_selected_items()[0]
	list.clear()
	var count := model.fields.size() if model else 0
	for index in count:
		list.add_item(model.fields[index].name)
	selected = clampi(selected, -1, count - 1)
	if selected >= 0:
		list.select(selected)
	show_field(selected)


func show_field(index: int) -> void:
	%FieldForm.get_parent().visible = index >= 0
	if index < 0:
		return
	var field: Draft.Field = model.fields[index]
	_filling = true
	%FieldName.text = field.name
	%Quantity.text = field.quantity
	%Unit.text = field.unit
	%Range.text = "%s, %s" % [_number(field.range.x), _number(field.range.y)]
	%Origin.text = _vector_text(field.origin)
	%Size.text = _vector_text(field.size)
	%First.button_pressed = index == model.first_field
	_filling = false
	var times: Array = field.bricks.keys()
	times.sort()
	%FieldInfo.text = "%d × %d × %d cells; %d bricks, one per time step from %s to %s" % [field.cells.x, field.cells.y, field.cells.z, times.size(), _number(times[0]), _number(times[-1])]


func edit_field() -> void:
	if _filling:
		return
	var index := _selected(%FieldList)
	if index < 0:
		return
	var field: Draft.Field = model.fields[index]
	field.name = %FieldName.text
	%FieldList.set_item_text(index, field.name)
	field.quantity = %Quantity.text
	field.unit = %Unit.text
	var span := _numbers(%Range.text)
	if span.size() == 2:
		field.range = Vector2(span[0], span[1])
	var origin := _numbers(%Origin.text)
	if origin.size() == 3:
		field.origin = Vector3(origin[0], origin[1], origin[2])
	var size := _numbers(%Size.text)
	if size.size() == 3:
		field.size = Vector3(size[0], size[1], size[2])


func fit_field() -> void:
	var index := _selected(%FieldList)
	if index < 0:
		return
	if not draft.model_bounds(model).has_volume():
		_show_status("Import a GLB first: the box is fitted to the model's parts.")
		return
	draft.fit_field(model, model.fields[index])
	show_field(index)


func set_first_field(pressed: bool) -> void:
	if _filling:
		return
	var index := _selected(%FieldList)
	if pressed and index >= 0:
		model.first_field = index
	elif not pressed and index == model.first_field:
		model.first_field = 0
		%First.set_pressed_no_signal(index == 0)


func remove_field() -> void:
	var index := _selected(%FieldList)
	if index >= 0:
		model.fields.remove_at(index)
		if model.first_field >= model.fields.size():
			model.first_field = 0
		show_fields(index - 1)
		show_frames()


# Labels

## Adds a label at the parts' center, and starts on its text.
func add_label() -> void:
	if model == null:
		return
	var label := Draft.PointLabel.new()
	var bounds := draft.model_bounds(model)
	if bounds.has_volume():
		label.position = bounds.get_center()
	model.labels.append(label)
	show_labels(model.labels.size() - 1)
	%LabelText.grab_focus()


func show_labels(selected := -1) -> void:
	var labels: Array[Draft.PointLabel] = []
	if model:
		labels = model.labels
	for label in _label_errors.keys():
		if not labels.has(label):
			_label_errors.erase(label)
			_label_inputs.erase(label)
	var list: ItemList = %LabelList
	if selected < 0 and list.is_anything_selected():
		selected = list.get_selected_items()[0]
	list.clear()
	for label in labels:
		list.add_item(label.title())
	selected = clampi(selected, -1, labels.size() - 1)
	if selected >= 0:
		list.select(selected)
	show_label(selected)


func show_label(index: int) -> void:
	%LabelForm.get_parent().visible = index >= 0
	if index < 0:
		return
	var label: Draft.PointLabel = model.labels[index]
	_filling = true
	var inputs: Dictionary = _label_inputs.get(label, {})
	%LabelText.text = inputs.get("text", label.text)
	%LabelPosition.text = inputs.get("position", _vector_text(label.position))
	%LabelRadius.text = inputs.get("radius", _number(label.radius) if label.radius > 0.0 else "")
	var frames := model.label_frames(label)
	if label.span == Vector2(-INF, INF):
		%LabelFrames.text = ""
	else:
		%LabelFrames.text = "%d, %d" % [frames.x + 1, frames.y + 1]
	%LabelFrames.text = inputs.get("frames", %LabelFrames.text)
	_filling = false
	_show_status(_label_errors.get(label, ""))


func edit_label() -> void:
	if _filling:
		return
	var index := _selected(%LabelList)
	if index < 0:
		return
	var label: Draft.PointLabel = model.labels[index]
	_label_inputs[label] = {text = %LabelText.text, position = %LabelPosition.text, radius = %LabelRadius.text, frames = %LabelFrames.text}
	label.text = %LabelText.text
	%LabelList.set_item_text(index, label.title())
	var problem := _label_form_problem()
	if not problem.is_empty():
		_label_errors[label] = problem
		_show_status(problem)
		return
	_label_errors.erase(label)
	_show_status("")
	var position := _label_numbers(%LabelPosition.text)
	label.position = Vector3(position[0], position[1], position[2])
	var radius: String = %LabelRadius.text.strip_edges()
	label.radius = radius.to_float() if not radius.is_empty() else 0.0
	# Counted from 1, as the controls show them; one number is one frame.
	# Kept as solver times, which stay put as steps come and go.
	var frames := _label_numbers(%LabelFrames.text)
	if frames.is_empty():
		label.span = Vector2(-INF, INF)
	elif frames.size() <= 2:
		label.span = model.span_of(int(frames[0]) - 1, int(frames[-1]) - 1)


func _label_form_problem() -> String:
	if %LabelText.text.strip_edges().is_empty():
		return "Enter text for the label."
	if _label_numbers(%LabelPosition.text).size() != 3:
		return "Point needs three finite numbers: x, y, z."
	var radius: String = %LabelRadius.text.strip_edges()
	if not radius.is_empty() and (not radius.is_valid_float() or not is_finite(radius.to_float()) or radius.to_float() < 0.0):
		return "Radius must be a nonnegative number, or blank for 3 cm."
	if not %LabelFrames.text.strip_edges().is_empty():
		var frames := _label_numbers(%LabelFrames.text)
		if frames.is_empty() or frames.size() > 2:
			return "Frames needs one number, or first, last; leave blank for all frames."
		for value in frames:
			var count := model.times().size()
			if value != floor(value) or value < 1 or value > count:
				return "Frames must be whole numbers from 1 to %d." % count
		if frames[0] > frames[-1]:
			return "The first frame must not come after the last."
	return ""


static func _label_numbers(text: String) -> PackedFloat64Array:
	var values := PackedFloat64Array()
	if text.strip_edges().is_empty():
		return values
	for part in text.split(","):
		var value: String = part.strip_edges()
		if not value.is_valid_float() or not is_finite(value.to_float()):
			return PackedFloat64Array()
		values.append(value.to_float())
	return values


func remove_label() -> void:
	var index := _selected(%LabelList)
	if index >= 0:
		_label_inputs.erase(model.labels[index])
		_label_errors.erase(model.labels[index])
		model.labels.remove_at(index)
		show_labels(index - 1)


## Where the model's parts are, to place labels by. Reading every part's
## bounds takes a while, so only while the labels show.
func _show_model_bounds() -> void:
	var bounds := draft.model_bounds(model) if model else AABB()
	if bounds.has_volume():
		%LabelBounds.text = "From %s to %s, in the model's units" % [_vector_text(bounds.position), _vector_text(bounds.end)]
	else:
		%LabelBounds.text = "Import a GLB to see where the parts are."


# Images

func import_images(paths: PackedStringArray) -> void:
	draft.add_images(paths)
	show_images(draft.images.size() - 1)
	refresh_preview()


func show_images(selected := -1) -> void:
	var list: ItemList = %ImageList
	if selected < 0 and list.is_anything_selected():
		selected = list.get_selected_items()[0]
	list.clear()
	for name: String in draft.images:
		list.add_item(name)
	selected = clampi(selected, -1, draft.images.size() - 1)
	if selected >= 0:
		list.select(selected)
	show_image(selected)


func show_image(index: int) -> void:
	var preview: TextureRect = %ImagePreview
	if index < 0:
		preview.texture = null
		return
	var name: String = draft.images.keys()[index]
	var images := NotesImages.new()
	images.embed("[img]%s[/img]" % Draft.IMAGES_FOLDER.path_join(name), draft.read_file, Draft.NOTES_FILE, "image", %NotesPreview.get_theme_color(&"default_color"), %NotesPreview.get_theme_font_size(&"normal_font_size"))
	preview.texture = images.textures[0] if not images.textures.is_empty() else null
	_image_preview = images


func remove_image() -> void:
	var index := _selected(%ImageList)
	if index >= 0:
		draft.images.erase(draft.images.keys()[index])
		show_images(index - 1)
		refresh_preview()


## Puts an [img] tag for the picked image at the notes' cursor.
func insert_image() -> void:
	var index := _selected(%ImageList)
	if index < 0:
		return
	var editor: CodeEdit = %Editor
	editor.insert_text_at_caret("[img]%s[/img]" % Draft.IMAGES_FOLDER.path_join(draft.images.keys()[index]))
	show_page("Notes")
	editor.grab_focus()


# Notes

func edit_notes() -> void:
	if _filling:
		return
	draft.notes = %Editor.text
	if _preview_timer and _preview_timer.time_left > 0.0:
		return
	_preview_timer = get_tree().create_timer(PREVIEW_DELAY)
	_preview_timer.timeout.connect(refresh_preview)


func refresh_preview() -> void:
	# A save reopens the ZIP the images come from; it refreshes when done.
	if _save_thread:
		return
	var preview: RichTextLabel = %NotesPreview
	var images := NotesImages.new()
	preview.text = images.embed(draft.notes, draft.read_file, Draft.NOTES_FILE, "workspace", preview.get_theme_color(&"default_color"), preview.get_theme_font_size(&"normal_font_size"))
	_preview_images = images


static func _selected(list: ItemList) -> int:
	return list.get_selected_items()[0] if list.is_anything_selected() else -1


static func _describe(source: String) -> String:
	return source.trim_prefix(Draft.IN_ZIP)


static func _vector_text(vector: Vector3) -> String:
	return "%s, %s, %s" % [_number(vector.x), _number(vector.y), _number(vector.z)]


## [param value] to six significant digits, which is all the 32-bit floats
## fields keep, so they don't show noise like 0.11310999840498.
static func _number(value: float) -> String:
	if value == 0.0 or not is_finite(value):
		return String.num(value)
	return String.num(value, maxi(5 - floori(log(absf(value)) / log(10.0)), 0))


static func _numbers(text: String) -> PackedFloat64Array:
	return text.split_floats(",", false)
