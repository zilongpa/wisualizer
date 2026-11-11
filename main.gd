extends Node3D
## Shows a ball on each fingertip of each tracked hand, and logs the right
## index fingertip once a second, to check hand tracking on a device.

const TIPS := [
	XRHandTracker.HAND_JOINT_THUMB_TIP,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
	XRHandTracker.HAND_JOINT_RING_FINGER_TIP,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP,
]
const TRACKERS := [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]

var _origin := XROrigin3D.new()
var _balls := {}
var _status := Label3D.new()
var _since_log := 0.0


func _ready() -> void:
	add_child(_origin)
	for tracker_name in TRACKERS:
		var balls: Array[MeshInstance3D] = []
		for tip in TIPS:
			var ball := MeshInstance3D.new()
			var sphere := SphereMesh.new()
			sphere.radius = 0.008
			sphere.height = 0.016
			var material := StandardMaterial3D.new()
			material.albedo_color = Color(1, 0.6, 0.2) if tip == XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP else Color(0.3, 0.8, 1)
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			sphere.material = material
			ball.mesh = sphere
			ball.visible = false
			_origin.add_child(ball)
			balls.append(ball)
		_balls[tracker_name] = balls
	_status.position = Vector3(0, 1.4, -1)
	_status.pixel_size = 0.001
	_status.font_size = 48
	_status.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_status.text = "Waiting for hands"
	_origin.add_child(_status)


func _process(delta: float) -> void:
	var lines := PackedStringArray()
	for tracker_name in TRACKERS:
		var tracker := XRServer.get_tracker(tracker_name) as XRHandTracker
		var tracked := tracker != null and tracker.has_tracking_data
		for i in TIPS.size():
			var ball: MeshInstance3D = _balls[tracker_name][i]
			ball.visible = tracked
			if tracked:
				ball.position = tracker.get_hand_joint_transform(TIPS[i]).origin
		lines.append("%s: %s" % [tracker_name.get_file(), "tracked" if tracked else ("no tracker" if tracker == null else "not tracked")])
	_status.text = "\n".join(lines)

	_since_log += delta
	if _since_log >= 1.0:
		_since_log = 0.0
		var right := XRServer.get_tracker(&"/user/hand_tracker/right") as XRHandTracker
		if right != null and right.has_tracking_data:
			print("[handtest] right index tip ", right.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin)
		else:
			print("[handtest] ", " | ".join(lines))
