extends MarginContainer
## The app's first window: a library of the ZIPs added so far. Each ZIP opens
## a volume per model, so several can be open at once.

const Document := preload("res://app/document.tscn")
const Workspace := preload("res://app/workspace.tscn")
const Meta := preload("res://app/meta.gd")
const Playback := preload("res://app/playback.gd")
const NativeDialogs := preload("res://app/native_dialogs.gd")
## Added ZIPs are copied here, so they can be opened again after the app
## restarts without access to where they came from.
const LIBRARY := "user://library"
## When each ZIP in the library was last opened, by file name.
const OPENED_FILE := "user://opened.cfg"
const COPY_CHUNK := 1 << 20
## How many recently opened ZIPs the sidebar lists.
const RECENT := 8

@onready var library_list: HFlowContainer = %Library
## A hidden tile, copied for each ZIP so its look is set in the editor.
@onready var tile_template: VBoxContainer = %Tile
## The same for the sidebar's recent ZIPs.
@onready var recent_list: VBoxContainer = %Recent
@onready var recent_template: Button = %RecentRow
@onready var confirm_delete: ConfirmationDialog = %ConfirmDelete

var _pending_delete := ""
## The ZIP picked with Open, while the person decides whether to add it.
var _pending_open := ""
## ZIPs are made on a computer, where EnSight's exports are.
var _editing := OS.has_feature("pc")


func _ready() -> void:
	%Version.text = "Version %s" % ProjectSettings.get_setting("application/config/version", "")
	DirAccess.make_dir_recursive_absolute(LIBRARY)
	%New.visible = _editing
	# The system's alert has all three answers; Godot's own dialog adds one.
	%ConfirmAdd.add_button("Open Only", true, "open_only")
	NativeDialogs.apply_to(self)
	show_library()
	# ZIPs passed on the command line, after "--", are added to the library.
	for argument in OS.get_cmdline_user_args():
		if argument.get_extension().to_lower() == "zip" and FileAccess.file_exists(argument):
			import_zip(argument)


## Opens a picked ZIP, asking first whether to add it to the library.
func pick_zip(path: String) -> void:
	if not _check(path):
		return
	if _in_library(path):
		open_zip(path)
		return
	_pending_open = path
	var message := "Added ZIPs are copied into the library, so they open again from here, even when %s is gone." % path.get_file()
	var title := "Add %s to the library?" % path.get_file().get_basename()
	var buttons := PackedStringArray(["Add to Library", "Open Only", "Cancel"])
	if NativeDialogs.alerts():
		DisplayServer.dialog_show(title, message, buttons, _on_add_answered, -1, 2)
	else:
		var ask: ConfirmationDialog = %ConfirmAdd
		ask.title = title
		ask.dialog_text = message
		ask.popup_centered()


func _on_add_answered(button: int) -> void:
	match button:
		0:
			import_zip(_pending_open)
		1:
			open_zip(_pending_open)
	_pending_open = ""


func _on_add_custom(_action: StringName) -> void:
	%ConfirmAdd.hide()
	_on_add_answered(1)


## Copies a ZIP into the library and opens it.
func import_zip(path: String) -> void:
	if not _check(path):
		return
	# Writing a ZIP that is already in the library over itself would empty it.
	if _in_library(path):
		open_zip(path)
		return
	var copy := _free_name(path.get_file())
	var source := FileAccess.open(path, FileAccess.READ)
	var target := FileAccess.open(copy, FileAccess.WRITE)
	if source == null or target == null:
		push_error("Couldn't copy %s into the library." % path)
		return
	while source.get_position() < source.get_length():
		target.store_buffer(source.get_buffer(COPY_CHUNK))
	target.close()
	open_zip(copy)


## Opens the ZIP at [param path], from the library or from anywhere.
func open_zip(path: String) -> void:
	if _in_library(path):
		var opened := ConfigFile.new()
		opened.load(OPENED_FILE)
		opened.set_value("opened", path.get_file(), Time.get_unix_time_from_system())
		opened.save(OPENED_FILE)
		show_library()

	# A volume for each of its models, side by side and playing by one clock;
	# the first has the notes.
	var check := Meta.new()
	var error := check.open(path)
	if not error.is_empty():
		check.close()
		show_error("Can't open %s" % path.get_file().get_basename(), error)
		return
	var count := check.models.size()
	var clock := Playback.new()
	var times := PackedFloat64Array()
	for model in check.models:
		times.append_array(model.times)
	clock.times = Meta.timeline(times)
	add_child(clock)
	check.close()
	var previous: Window = null
	for index in count:
		var document := Document.instantiate()
		add_child(document)
		error = document.open(path, index, index == 0, previous, clock)
		if not error.is_empty():
			document.queue_free()
			break
		previous = document.model
	if previous == null:
		clock.queue_free()
	if not error.is_empty():
		show_error("Can't open %s" % path.get_file().get_basename(), error)


## Whether [param path] is a ZIP this app can open; tells the person if not.
func _check(path: String) -> bool:
	var check := Meta.new()
	var error := check.open(path)
	check.close()
	if not error.is_empty():
		show_error("Can't open %s" % path.get_file(), error)
	return error.is_empty()


## Where a ZIP named [param file] goes in the library: under that name, or
## numbered after the ZIPs already there with it, as "hall 2.zip".
static func _free_name(file: String) -> String:
	var copy := LIBRARY.path_join(file)
	var number := 2
	while FileAccess.file_exists(copy):
		copy = LIBRARY.path_join("%s %d.%s" % [file.get_basename(), number, file.get_extension()])
		number += 1
	return copy


func _in_library(path: String) -> bool:
	return ProjectSettings.globalize_path(path).simplify_path().get_base_dir() == ProjectSettings.globalize_path(LIBRARY).simplify_path()


## Asks for a new ZIP's name, then opens an empty workspace for it.
func ask_new() -> void:
	%NewName.text = ""
	%ConfirmNew.popup_centered()
	%NewName.grab_focus()


func create_new() -> void:
	var name: String = %NewName.text.strip_edges().validate_filename()
	if name.is_empty():
		return
	edit_zip(LIBRARY.path_join(name + ".zip"))


## Opens the ZIP at [param path] in a workspace; a new one if it isn't there yet.
func edit_zip(path: String) -> void:
	var workspace := Workspace.instantiate()
	add_child(workspace)
	workspace.saved.connect(_on_workspace_saved)
	var error: String = workspace.start(path)
	if not error.is_empty():
		workspace.queue_free()
		show_error("Can't edit %s" % path.get_file().get_basename(), error)


func _on_workspace_saved(path: String, play: bool) -> void:
	if play:
		open_zip(path)
	else:
		show_library()


## Tells the person what went wrong, with the system's alert where there is one.
func show_error(title: String, message: String) -> void:
	if NativeDialogs.alerts():
		DisplayServer.dialog_show(title, message, PackedStringArray(["OK"]), func(_button: int) -> void: pass)
	else:
		var alert := AcceptDialog.new()
		alert.title = title
		alert.dialog_text = message
		alert.dialog_autowrap = true
		alert.size = Vector2i(880, 200)
		add_child(alert)
		alert.confirmed.connect(alert.queue_free)
		alert.popup_centered()


## Asks before deleting a ZIP from the library; the file it came from stays.
## Uses the system's own alert where there is one.
func ask_delete(path: String) -> void:
	_pending_delete = path
	var message := "%s is removed from the library. The original file isn't affected." % path.get_file().get_basename()
	if NativeDialogs.alerts():
		DisplayServer.dialog_show(confirm_delete.title, message, PackedStringArray(["Delete", "Cancel"]), _on_delete_answered, 0, 1)
	else:
		confirm_delete.dialog_text = message
		confirm_delete.popup_centered()


func _on_delete_answered(button: int) -> void:
	if button == 0:
		delete_pending()


func delete_pending() -> void:
	DirAccess.remove_absolute(_pending_delete)
	var opened := ConfigFile.new()
	opened.load(OPENED_FILE)
	if opened.has_section_key("opened", _pending_delete.get_file()):
		opened.erase_section_key("opened", _pending_delete.get_file())
		opened.save(OPENED_FILE)
	_pending_delete = ""
	show_library()


## The library's ZIPs, most recently opened first; never-opened ones by when
## they were added.
func read_library() -> Array[String]:
	var opened := ConfigFile.new()
	opened.load(OPENED_FILE)
	var paths: Array[String] = []
	for file in DirAccess.get_files_at(LIBRARY):
		if file.get_extension().to_lower() == "zip":
			paths.append(LIBRARY.path_join(file))
	var last_used := func(path: String) -> float:
		return opened.get_value("opened", path.get_file(), FileAccess.get_modified_time(path))
	paths.sort_custom(func(a: String, b: String) -> bool: return last_used.call(a) > last_used.call(b))
	return paths


## Shows a tile for each ZIP in the library: its preview, or its title's
## first letter, and its title. ZIPs with the same title go by their file
## names instead, which the library keeps apart.
func show_library() -> void:
	for child in library_list.get_children():
		if child != tile_template:
			child.queue_free()
	var paths := read_library()
	%Caption.text = "Most recently opened first." if not paths.is_empty() \
			else "Open a ZIP to start, and add it to the library to open it again later."
	var summaries := {}
	var counts := {}
	for path in paths:
		summaries[path] = Meta.summary(path)
		var title: String = summaries[path].get("title", path.get_file().get_basename())
		counts[title] = counts.get(title, 0) + 1
	var titles := {}
	for path in paths:
		var summary: Dictionary = summaries[path]
		var title: String = summary.get("title", path.get_file().get_basename())
		if counts[title] > 1:
			title = path.get_file().get_basename()
		titles[path] = title
		var tile := tile_template.duplicate() as VBoxContainer
		tile.visible = true
		var open_button := tile.get_node("Open") as Button
		open_button.tooltip_text = "Open %s" % title
		open_button.pressed.connect(open_zip.bind(path))
		# A preview is clipped to the tile's shape; its letter needs no clipping,
		# which on visionOS leaves the clipped area opaque.
		var preview: Image = summary.get("preview")
		if preview:
			(open_button.get_node("Mask/Preview") as TextureRect).texture = ImageTexture.create_from_image(preview)
		open_button.get_node("Mask").visible = preview != null
		open_button.get_node("Back").visible = preview == null
		(open_button.get_node("Back/Initial") as Label).text = title.left(1).to_upper()
		(tile.get_node("Footer/Name") as Label).text = title
		var edit_button := tile.get_node("Footer/Edit") as Button
		edit_button.visible = _editing
		edit_button.pressed.connect(edit_zip.bind(path))
		(tile.get_node("Footer/Delete") as Button).pressed.connect(ask_delete.bind(path))
		library_list.add_child(tile)
	_show_recent(paths, titles)


## Lists the ZIPs opened most recently, of [param paths] in the library,
## in the sidebar, by their [param titles].
func _show_recent(paths: Array[String], titles: Dictionary) -> void:
	for child in recent_list.get_children():
		if child != recent_template:
			child.queue_free()
	var opened := ConfigFile.new()
	opened.load(OPENED_FILE)
	var recent: Array[String] = []
	for path in paths:
		if opened.has_section_key("opened", path.get_file()) and recent.size() < RECENT:
			recent.append(path)
	%RecentTitle.visible = not recent.is_empty()
	for path in recent:
		var row := recent_template.duplicate() as Button
		row.visible = true
		row.text = titles[path]
		row.tooltip_text = "Open %s" % row.text
		row.pressed.connect(open_zip.bind(path))
		recent_list.add_child(row)
