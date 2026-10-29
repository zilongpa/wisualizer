extends Node3D
## Shows where each controller feels the field, like a game engine's light
## probe debug view: the brick cell at the controller's tip as a translucent
## cube colored by its value, and a white label over it with the cell's
## position and value, in the field's unit. Only shows while visible.
##
## Lives beside the Window's content, with no transform of its own, so its
## local coordinates are the model's.

const Meta := preload("res://app/meta.gd")
const OPACITY := 0.55
const FONT_SIZE := 48
## The label's height and its gap above the cube, in meters.
const LABEL_HEIGHT := 0.02
const LABEL_GAP := 0.01

## Samples the field for us, as it does for haptics.
var touch: Node
var volume: SpatialVolume3D
## Its global transform maps a unit cube onto the current brick.
var field: Node3D
## The field shown, for its values' units.
var shown_field: Meta.Field

var _colors := Gradient.new()
## Per controller: its cube, its label, and the cell and brick revision
## they show.
var _probes := {}


func _init() -> void:
	# Blue to red through cyan, green and yellow, as EnSight's default palette.
	_colors.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
	_colors.colors = PackedColorArray([Color(0, 0, 1), Color(0, 1, 1), Color(0, 1, 0), Color(1, 1, 0), Color(1, 0, 0)])


func _process(_delta: float) -> void:
	if not visible or volume == null:
		return
	for controller in volume.get_controllers():
		var probe: Dictionary = _probes.get(controller, {})
		if probe.is_empty():
			probe = _add_probe()
			_probes[controller] = probe
		var cell: Vector3i = touch.cell_at(touch.tip_of(controller)) if controller.get_has_tracking_data() else touch.NO_CELL
		# Like the haptics, only a cell with a value counts.
		var shown: bool = touch.value_of(cell) > 0.0
		probe.cube.visible = shown
		probe.label.visible = shown
		if shown and (cell != probe.cell or touch.revision != probe.revision):
			probe.cell = cell
			probe.revision = touch.revision
			_show(probe, cell)


func _add_probe() -> Dictionary:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cube := MeshInstance3D.new()
	cube.mesh = BoxMesh.new()
	cube.material_override = material
	add_child(cube)
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = FONT_SIZE
	label.outline_size = 12
	# The label grows up from its position, so it stays clear of the cube.
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	add_child(label)
	return {cube = cube, label = label, cell = touch.NO_CELL, revision = -1}


## Places the cube on [param cell] and labels it.
func _show(probe: Dictionary, cell: Vector3i) -> void:
	# From the brick's unit cube to our coordinates, which are the model's.
	var unit := global_transform.affine_inverse() * field.global_transform
	var cells := Vector3(touch.cells)
	var center := unit * ((Vector3(cell) + Vector3.ONE * 0.5) / cells)
	var cube: MeshInstance3D = probe.cube
	cube.transform = Transform3D(unit.basis * Basis.from_scale(Vector3.ONE / cells), center)
	var value: float = touch.value_of(cell)
	var color := _colors.sample(value)
	(cube.material_override as StandardMaterial3D).albedo_color = Color(color, OPACITY)

	# The label keeps its physical size, whatever the volume's scale.
	var meters_per_unit := volume.get_measured_size()[volume.keep_aspect] / volume.size
	var label: Label3D = probe.label
	label.pixel_size = LABEL_HEIGHT / meters_per_unit / FONT_SIZE
	label.position = center + Vector3.UP * ((unit.basis.get_scale().y / cells.y) * 0.5 + LABEL_GAP / meters_per_unit)
	var reading: String = shown_field.format(shown_field.value_of(touch.byte_of(cell))) if shown_field else "%.2f" % value
	label.text = "(%.1f, %.1f, %.1f)\nstrength %s" % [center.x, center.y, center.z, reading]
