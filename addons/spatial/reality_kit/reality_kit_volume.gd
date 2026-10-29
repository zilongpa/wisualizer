extends RefCounted
## visionOS backend: GodotRealityKit opens a Window as a volume when the
## Window holds a RealityVolumeCamera3D, so the volume adds one and keeps it
## in step.
##
## It also adds an XROrigin3D with a controller per hand. GodotRealityKit
## tracks spatial controllers, such as PlayStation VR2 Sense, in every volume
## whose Window holds an XROrigin3D, on trackers named after the Window's ID,
## so each open volume sees them in its own space. These nodes exist only on
## visionOS; the XR layout brings its own origin and controllers.

signal resized(size: Vector3)

const CAMERA_CLASS := &"RealityVolumeCamera3D"

var _volume: SpatialVolume3D
## The plugin's camera. Untyped, because its class exists only where the
## plugin is built.
var _camera
var _origin := XROrigin3D.new()
var _controllers: Array[XRController3D] = []


func _init(volume: SpatialVolume3D) -> void:
	_volume = volume
	_camera = ClassDB.instantiate(CAMERA_CLASS)
	_camera.name = "RealityVolumeCamera3D"
	_camera.preview_camera_enabled = false
	_camera.window_resized.connect(resized.emit)
	# The plugin looks for an ordinary child, not an internal one.
	volume.add_child(_camera)

	_origin.name = "Controllers"
	volume.add_child(_origin)
	for hand in [&"left_hand", &"right_hand"]:
		var controller := XRController3D.new()
		controller.name = "LeftHand" if hand == &"left_hand" else "RightHand"
		controller.pose = &"aim"
		controller.show_when_tracked = true
		controller.add_child(_ray_mesh())
		if OS.is_debug_build():
			controller.button_pressed.connect(_on_button.bind(controller, true))
			controller.button_released.connect(_on_button.bind(controller, false))
		_origin.add_child(controller)
		_controllers.append(controller)
	# A Window gets its ID when it opens.
	volume.get_window().visibility_changed.connect(_name_trackers, CONNECT_DEFERRED)


func update() -> void:
	_camera.size = _volume.size
	_camera.keep_aspect = _volume.keep_aspect
	_camera.window_size = _volume.window_size
	_camera.window_min_size = _volume.window_min_size
	_camera.window_max_size = _volume.window_max_size


func get_measured_size() -> Vector3:
	return _camera.get_window_measured_size()


func get_controllers() -> Array[XRController3D]:
	return _controllers


## Follows the plugin's naming of a Window's trackers: "left_hand_<id>".
func _name_trackers() -> void:
	var id := _volume.get_window().get_window_id()
	if id == DisplayServer.INVALID_WINDOW_ID:
		return
	_controllers[0].tracker = StringName("left_hand_%d" % id)
	_controllers[1].tracker = StringName("right_hand_%d" % id)
	# Setting a tracker resets its pose to "default" in Godot.
	for controller in _controllers:
		controller.pose = &"aim"


## Lets a device test confirm that button input arrives, in the Xcode console.
func _on_button(button: String, controller: XRController3D, pressed: bool) -> void:
	print("[spatial] %s %s %s" % [controller.tracker, button, "pressed" if pressed else "released"])


## A short ray along the aim pose. The pose carries the volume's scale, so
## the ray keeps its physical size, in meters.
func _ray_mesh() -> MeshInstance3D:
	var ray := BoxMesh.new()
	ray.size = Vector3(0.003, 0.003, 0.1)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1, 0.6, 0.2)
	ray.material = material
	var mesh := MeshInstance3D.new()
	mesh.mesh = ray
	mesh.position.z = -0.05
	return mesh
