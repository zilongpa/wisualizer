extends Node
## The app's settings, kept between launches and shared by every open
## document. Added as the Settings autoload; the settings window edits them.

signal changed

## The shapes a fingertip's tone can take, as in Hyposelenia's
## SignalGenerator.
enum Waveform { SINE, SAWTOOTH, SQUARE, TRIANGLE, NOISE }

const FILE := "user://settings.cfg"
const SECTION := "settings"

## Shows the field box, and the field around each controller and hand.
var debug := false
## Plays the field under each index fingertip, in the immersive space.
var sound := true
var waveform := Waveform.SINE
## How loud a tone is, in decibels below full scale.
var loudness := -12.0
## The tone at the field's weakest and strongest values, in hertz.
var low_pitch := 220.0
var high_pitch := 880.0


func _ready() -> void:
	var file := ConfigFile.new()
	if file.load(FILE) != OK:
		return
	for key in file.get_section_keys(SECTION) if file.has_section(SECTION) else PackedStringArray():
		if key in self:
			set(key, file.get_value(SECTION, key))


## Changes the setting named [param key], keeps it, and tells whoever shows
## or uses it.
func change(key: StringName, value: Variant) -> void:
	if get(key) == value:
		return
	set(key, value)
	var file := ConfigFile.new()
	file.load(FILE)
	file.set_value(SECTION, key, value)
	file.save(FILE)
	changed.emit()
