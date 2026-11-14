extends Node3D
## One of a model's parts: shows its GLB for the current frame, and keeps
## only the frames near it in memory. Upcoming frames load on worker threads
## and wait hidden, so a frame is ready, on visionOS in RealityKit too, by
## the time it shows. A part that doesn't change is one GLB, kept loaded.

const Meta := preload("res://app/meta.gd")
## How many frames after and before the current one are kept loaded.
const AHEAD := 3
const BEHIND := 1

var _zip_path := ""
var _part: Meta.Part
## Loaded GLBs by file, and the worker tasks loading the others.
var _scenes := {}
var _tasks := {}
## Scenes the tasks have finished, by file, until the main thread adds them.
var _finished := {}
var _mutex := Mutex.new()
## The first frame's geometry: its center and how far its farthest vertex is
## from it, in its scene's coordinates. Measured once, as it takes a while.
var _reach := []


func setup(zip_path: String, part: Meta.Part) -> void:
	_zip_path = zip_path
	_part = part
	name = part.name.validate_node_name()


## Shows frame [param frame], loading it now if it isn't yet, and starts
## loading the frames around it.
func show_frame(frame: int) -> void:
	var count := _part.files.size()
	var wanted := {}
	for offset in range(-BEHIND, AHEAD + 1):
		# Playback loops, so the frames after the last are the first ones.
		wanted[_part.files[posmod(frame + offset, count)]] = true
	var current := _part.files[frame]
	if not _scenes.has(current):
		if _tasks.has(current):
			WorkerThreadPool.wait_for_task_completion(_tasks[current])
			_tasks.erase(current)
		else:
			_load_into(current, _reach.is_empty())
		_collect()
	for file in wanted:
		if not _scenes.has(file) and not _tasks.has(file):
			_tasks[file] = WorkerThreadPool.add_task(_load_into.bind(file))
	for file in _scenes.keys():
		if not wanted.has(file):
			_scenes[file].visible = false
			_scenes[file].queue_free()
			_scenes.erase(file)
	for file in _scenes:
		_scenes[file].visible = file == current


## The bounds of the frame showing, in this node's coordinates.
func get_bounds() -> AABB:
	var bounds := AABB()
	var first := true
	for scene: Node3D in _scenes.values():
		if not scene.visible:
			continue
		for mesh: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
			var box := scene.transform * _local_transform(mesh, scene) * mesh.get_aabb()
			bounds = box if first else bounds.merge(box)
			first = false
	return bounds


## How far the model reaches from [param pivot], in this node's
## coordinates, going by its first frame: the radius of a sphere it can turn
## in. Zero until that frame has loaded.
func get_radius(pivot: Vector3) -> float:
	return _reach[1] + (_reach[0] as Vector3).distance_to(pivot) if not _reach.is_empty() else 0.0


func _process(_delta: float) -> void:
	_collect()


## Frames still loading finish first: their tasks report back to this node.
func _exit_tree() -> void:
	for file in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[file])
	_tasks.clear()
	for scene in _finished.values():
		if scene:
			scene.free()
	_finished.clear()


## Adds the scenes the workers have finished, hidden until they show.
func _collect() -> void:
	_mutex.lock()
	var finished := _finished
	_finished = {}
	_mutex.unlock()
	for file: String in finished:
		if _tasks.has(file):
			WorkerThreadPool.wait_for_task_completion(_tasks[file])
			_tasks.erase(file)
		var scene: Node3D = finished[file]
		if scene == null or _scenes.has(file):
			if scene:
				scene.free()
			continue
		scene.visible = false
		add_child(scene)
		_scenes[file] = scene


func _load_into(file: String, measure := false) -> void:
	var scene := _load(_zip_path, file, measure)
	if measure and scene:
		_reach = scene.get_meta(&"reach")
	_mutex.lock()
	_finished[file] = scene
	_mutex.unlock()


## Reads one GLB from the ZIP. Runs on any thread: it opens the ZIP itself.
static func _load(zip_path: String, file: String, measure := false) -> Node3D:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return null
	var bytes := zip.read_file(file)
	zip.close()
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_buffer(bytes, "", state) != OK:
		return null
	var scene := document.generate_scene(state) as Node3D
	if measure:
		scene.set_meta(&"reach", _measure_reach(state))
	for mesh: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		for surface in mesh.mesh.get_surface_count():
			var material = mesh.get_active_material(surface)
			# RealityKit needs ordinary blending for imported transparent materials.
			if material is BaseMaterial3D and material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return scene


## [center, radius] of the sphere around a glTF's vertices, read from the
## imported data on this thread rather than from GPU buffers. Bounding boxes
## would do, but a box's corners reach well past a disc or a ring of arrows.
static func _measure_reach(state: GLTFState) -> Array:
	var nodes := state.get_nodes()
	var meshes := state.get_meshes()
	var transforms: Array[Transform3D] = []
	transforms.resize(nodes.size())
	var resolved := PackedByteArray()
	resolved.resize(nodes.size())
	var points := PackedVector3Array()
	var bounds := AABB()
	for index in nodes.size():
		var node: GLTFNode = nodes[index]
		if node.mesh < 0:
			continue
		var transform := _node_transform(nodes, transforms, resolved, index)
		var mesh: ImporterMesh = meshes[node.mesh].mesh
		for surface in mesh.get_surface_count():
			for vertex: Vector3 in mesh.get_surface_arrays(surface)[Mesh.ARRAY_VERTEX]:
				var point := transform * vertex
				bounds = AABB(point, Vector3.ZERO) if points.is_empty() else bounds.expand(point)
				points.append(point)
	var center := bounds.get_center()
	var radius := 0.0
	for point in points:
		radius = maxf(radius, point.distance_squared_to(center))
	return [center, sqrt(radius)]


static func _node_transform(nodes: Array[GLTFNode], transforms: Array[Transform3D], resolved: PackedByteArray, index: int) -> Transform3D:
	if resolved[index] == 0:
		var node := nodes[index]
		transforms[index] = (_node_transform(nodes, transforms, resolved, node.parent) if node.parent >= 0 else Transform3D()) * node.xform
		resolved[index] = 1
	return transforms[index]


static func _local_transform(node: Node3D, root: Node3D) -> Transform3D:
	var transform := Transform3D()
	while node != root and node != null:
		transform = node.transform * transform
		node = node.get_parent() as Node3D
	return transform
