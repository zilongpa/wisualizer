extends RefCounted
## A brick of values, as EnSight exports a field: a small header file of
## "KEY: value" lines beside a data file with one byte per cell, x fastest.
## The header says which variable and solver time the brick is, how many
## cells it has, and where it sits.

var variable := ""
var time := 0.0
var cells := Vector3i.ZERO
## The values bytes 1 and 255 stand for.
var range := Vector2(0.0, 1.0)
var origin := Vector3.ZERO
var size := Vector3.ONE
var axes := Basis()
## The data file, next to the header.
var data := ""


## Reads the header at [param path]. Returns null if it isn't one, or if
## its data file isn't beside it with a byte for every cell.
static func read(path: String):
	var lines := {}
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var parts := line.split(":", true, 1)
		if parts.size() == 2:
			lines[parts[0].strip_edges()] = parts[1].strip_edges()
	if not (lines.has("TIME") and lines.has("BRICK ORIGIN") and lines.has("DATA SIZE") and lines.get("DATA FORMAT") == "BYTES"):
		return null
	var bov = new()
	bov.variable = lines.get("VARIABLE", path.get_file())
	bov.time = float(lines["TIME"])
	bov.cells = Vector3i(_vector(lines["DATA SIZE"]))
	bov.range = Vector2(float(lines.get("VARIABLE PALETTE MIN", "0")), float(lines.get("VARIABLE PALETTE MAX", "1")))
	bov.origin = _vector(lines["BRICK ORIGIN"])
	bov.size = _vector(lines.get("BRICK SIZE", "1 1 1"))
	bov.axes = Basis(_vector(lines.get("BRICK X_AXIS", "1 0 0")), _vector(lines.get("BRICK Y_AXIS", "0 1 0")), _vector(lines.get("BRICK Z_AXIS", "0 0 1")))
	# The data file is named by the exporting machine's path; it's beside the header.
	bov.data = path.get_base_dir().path_join(str(lines.get("DATA FILE", "")).replace("\\", "/").get_file())
	var file := FileAccess.open(bov.data, FileAccess.READ)
	if file == null or file.get_length() != bov.cells.x * bov.cells.y * bov.cells.z:
		return null
	return bov


static func _vector(text: String) -> Vector3:
	var numbers := text.split_floats(" ", false)
	return Vector3(numbers[0], numbers[1], numbers[2]) if numbers.size() >= 3 else Vector3.ZERO
