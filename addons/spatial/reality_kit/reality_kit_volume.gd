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
##
## The same Window can instead open as the app's immersive space: the plugin
## does so for a Window holding an XRCamera3D. The volume then swaps its
## camera for one under its origin, which places the box around the person.

signal resized(size: Vector3)
signal immersive_changed(immersive: bool)

## Where the box goes in the immersive space, in meters from the floor
## below the person as it opens: its center at about chest height, and its
## near face this far in front of them.
const IMMERSIVE_HEIGHT := 1.1
const IMMERSIVE_GAP := 0.5
## The bar under the box that moves it in the immersive space, like a
## window's: its size, its gap below the box's front edge, and how far below
## the box's center it goes at most, so a tall box keeps it in reach; in
## meters.
const HANDLE_SIZE := Vector2(0.16, 0.024)
const HANDLE_GAP := 0.05
const HANDLE_DROP := 0.4

const CAMERA_CLASS := &"RealityVolumeCamera3D"

var _volume: SpatialVolume3D
## The plugin's camera. Untyped, because its class exists only where the
## plugin is built.
var _camera
var _origin := XROrigin3D.new()
var _controllers: Array[XRController3D] = []
## Stands for the person's head while the Window is the immersive space.
var _head: XRCamera3D
var _immersive := false
## The volume's physical size as it became immersive, kept there.
var _immersive_size := Vector3.ZERO
## True while this backend reopens the Window itself.
var _switching := false
## Where the box's center is in the immersive space, in meters from where
## the person's space starts.
var _space_center := Vector3.ZERO
## The bar that moves the box there, the touch dragging it, and where that
## touch holds the box: the center's offset from it, in meters.
var _handle: StaticBody3D
var _handle_touch := -1
var _handle_grab := Vector3.ZERO


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
	volume.get_window().visibility_changed.connect(_on_visibility_changed)


func update() -> void:
	_camera.size = _volume.size
	_camera.keep_aspect = _volume.keep_aspect
	_camera.window_size = _volume.window_size
	_camera.window_min_size = _volume.window_min_size
	_camera.window_max_size = _volume.window_max_size
	if _immersive:
		_place_in_space()


func get_measured_size() -> Vector3:
	if _immersive:
		return _immersive_size
	return _camera.get_window_measured_size()


func is_immersive() -> bool:
	return _immersive


## The person's hands, while immersive: only there does visionOS track them.
## GodotRealityKit publishes them on the standard hand trackers, relative to
## the current origin, which is ours.
func get_hands() -> Array[XRHandTracker]:
	var hands: Array[XRHandTracker] = []
	if not _immersive:
		return hands
	for tracker_name in [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]:
		var hand := XRServer.get_tracker(tracker_name) as XRHandTracker
		if hand != null and hand.has_tracking_data:
			hands.append(hand)
	return hands


## As XRNode3D places a pose: its position is in meters, so it takes the
## world scale.
func get_hand_joint(hand: XRHandTracker, joint: XRHandTracker.HandJoint) -> Transform3D:
	var pose := hand.get_hand_joint_transform(joint)
	pose.origin *= _origin.world_scale
	return _origin.global_transform * pose


func set_immersive(immersive: bool) -> void:
	if immersive == _immersive:
		return
	var window := _volume.get_window()
	var shown := window.visible
	_switching = true
	# Closes the volume or the space; showing the Window again opens the other.
	window.hide()
	_immersive = immersive
	if immersive:
		_immersive_size = _camera.get_window_measured_size()
		if _immersive_size == Vector3.ZERO:
			_immersive_size = _volume.window_size
		_volume.remove_child(_camera)
		_head = XRCamera3D.new()
		_head.name = "Head"
		_origin.add_child(_head)
		_origin.current = true
		_space_center = Vector3(0.0, IMMERSIVE_HEIGHT, -(IMMERSIVE_GAP + _immersive_size.z * 0.5))
		_handle = _make_handle()
		_volume.add_child(_handle)
		_place_in_space()
	else:
		_origin.remove_child(_head)
		_head.free()
		_head = null
		_volume.remove_child(_handle)
		_handle.free()
		_handle = null
		_handle_touch = -1
		_origin.world_scale = 1.0
		_origin.transform = Transform3D.IDENTITY
		_volume.add_child(_camera)
	if shown:
		window.show()
	_switching = false
	immersive_changed.emit(immersive)


## Puts the box in front of the person at its physical size: the origin
## stands where the person's space starts, and its world scale turns the
## volume's units into meters.
func _place_in_space() -> void:
	var meters_per_unit := _immersive_size[_volume.keep_aspect] / _volume.size
	_origin.world_scale = 1.0 / meters_per_unit
	_origin.global_transform = Transform3D(Basis(), _volume.global_position - _space_center / meters_per_unit)
	# The bar is built in meters, under the box's front edge, or in front of
	# the box when that is out of reach.
	var below := Vector3(0.0, -minf(_immersive_size.y * 0.5 + HANDLE_GAP, HANDLE_DROP), _immersive_size.z * 0.5)
	_handle.transform = Transform3D(Basis.from_scale(Vector3.ONE / meters_per_unit), below / meters_per_unit)


## A pill the person pinches and drags to move the box, with the system's
## hover highlight.
func _make_handle() -> StaticBody3D:
	var handle := StaticBody3D.new()
	handle.name = "Handle"
	var pill := CapsuleMesh.new()
	pill.radius = HANDLE_SIZE.y * 0.5
	pill.height = HANDLE_SIZE.x
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1, 1, 1, 0.6)
	pill.material = material
	var mesh := MeshInstance3D.new()
	mesh.mesh = pill
	mesh.rotation.z = PI / 2.0
	handle.add_child(mesh)
	# Easier to catch than the pill itself.
	var box := BoxShape3D.new()
	box.size = Vector3(HANDLE_SIZE.x + 0.04, HANDLE_SIZE.y + 0.04, HANDLE_SIZE.y + 0.04)
	var shape := CollisionShape3D.new()
	shape.shape = box
	handle.add_child(shape)
	if ClassDB.class_exists(&"RealityHoverEffect3D"):
		handle.add_child(ClassDB.instantiate(&"RealityHoverEffect3D"))
	handle.input_event.connect(_on_handle_input)
	return handle


## Moves the box with the hand that pinches the bar, keeping where the hand
## holds it.
func _on_handle_input(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape: int) -> void:
	if event.is_class("InputEventSpatialTouch"):
		var index: int = event.get("index")
		if event.get("pressed") and not event.get("canceled"):
			if _handle_touch < 0:
				_handle_touch = index
				_handle_grab = _space_center - _to_space(event.get("world_position"))
		elif index == _handle_touch:
			_handle_touch = -1
	elif event.is_class("InputEventSpatialDrag") and event.get("index") == _handle_touch:
		_space_center = _to_space(event.get("world_position")) + _handle_grab
		_place_in_space()


## Where [param point], in the Window's world, is in the immersive space,
## in meters.
func _to_space(point: Vector3) -> Vector3:
	return (point - _origin.global_position) / _origin.world_scale


## The person left the immersive space, which hid the Window: bring the
## volume back.
func _on_visibility_changed() -> void:
	if _immersive and not _switching and not _volume.get_window().visible:
		_leave_space.call_deferred()


func _leave_space() -> void:
	if not _immersive:
		return
	set_immersive(false)
	_volume.get_window().show()


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
