extends Node3D
## Marks the cells pinned to compare, A and B: a dot at each cell's center,
## at a physical size, with its letter and its value at the frame showing
## over it. Lives beside the field box, with no transform of its own, so the
## marks turn and move with the model.

const Meta := preload("res://app/meta.gd")
const NAMES := ["A", "B"]
const COLORS := [Color(1.0, 0.62, 0.04), Color(0.39, 0.82, 1.0)]
## The dot's diameter, the label's height and its gap above the dot, in
## meters.
const DOT_SIZE := 0.012
const LABEL_HEIGHT := 0.018
const LABEL_GAP := 0.008
const FONT_SIZE := 48

## Samples the field for us.
var touch: Node
var volume: SpatialVolume3D
## Its global transform maps a unit cube onto the current brick.
var field: Node3D
## The field shown, for its values and units.
var shown_field: Meta.Field
## The pinned cells, A's and B's, or NO_CELL for one not pinned.
var cells: Array[Vector3i] = [NO_CELL, NO_CELL]

const NO_CELL := Vector3i(-1, -1, -1)

var _dots: Array[MeshInstance3D] = []
var _labels: Array[Label3D] = []


func _ready() -> void:
	for index in NAMES.size():
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = COLORS[index]
		# Seen inside the model and the field, as the labels are.
		material.no_depth_test = true
		material.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX
		var dot := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.5
		sphere.height = 1.0
		dot.mesh = sphere
		dot.material_override = material
		dot.visible = false
		add_child(dot)
		_dots.append(dot)
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX
		label.outline_render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX - 1
		label.font_size = FONT_SIZE
		label.outline_size = 12
		label.modulate = COLORS[index]
		label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		label.visible = false
		add_child(label)
		_labels.append(label)


func _process(_delta: float) -> void:
	if volume == null:
		return
	var meters_per_unit := volume.get_measured_size()[volume.keep_aspect] / volume.size
	if not meters_per_unit > 0.0:
		return
	# From the brick's unit cube to our coordinates, which are the model's.
	var unit := global_transform.affine_inverse() * field.global_transform
	var size := Vector3(touch.cells)
	for index in NAMES.size():
		var shown: bool = cells[index] != NO_CELL and touch.is_inside(cells[index])
		_dots[index].visible = shown
		_labels[index].visible = shown
		if not shown:
			continue
		var center := unit * ((Vector3(cells[index]) + Vector3.ONE * 0.5) / size)
		_dots[index].transform = Transform3D(Basis.from_scale(Vector3.ONE * DOT_SIZE / meters_per_unit), center)
		var label := _labels[index]
		label.pixel_size = LABEL_HEIGHT / meters_per_unit / FONT_SIZE
		label.position = center + Vector3.UP * (DOT_SIZE * 0.5 + LABEL_GAP) / meters_per_unit
		label.text = "%s  %s" % [NAMES[index], reading(index)]


## Pin [param index]'s value at the frame showing, with its unit, or
## "No data" where its cell has none.
func reading(index: int) -> String:
	var value := value_at(index)
	if is_nan(value):
		return "No data"
	return shown_field.format(value) if shown_field else String.num(value, 3)


## Pin [param index]'s value at the frame showing, or NAN.
func value_at(index: int) -> float:
	if cells[index] == NO_CELL or shown_field == null:
		return NAN
	return shown_field.value_of(touch.byte_of(cells[index]))
