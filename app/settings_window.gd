extends Window
## Edits the app's settings: the debug view, and how the field sounds. Its
## pitch sliders move in semitones, on a scale of octaves, as the ear hears
## pitch.

@onready var _debug: CheckButton = %Debug
@onready var _sound: CheckButton = %Sound
@onready var _waveforms: Array[Node] = %Waveforms.get_children()
@onready var _loudness: HSlider = %Loudness
@onready var _low_pitch: HSlider = %LowPitch
@onready var _high_pitch: HSlider = %HighPitch


func _ready() -> void:
	close_requested.connect(hide)
	_debug.toggled.connect(func(on: bool) -> void: Settings.change(&"debug", on))
	_sound.toggled.connect(func(on: bool) -> void: Settings.change(&"sound", on))
	for button: Button in _waveforms:
		button.pressed.connect(func() -> void: Settings.change(&"waveform", button.get_index()))
	_loudness.value_changed.connect(func(value: float) -> void: Settings.change(&"loudness", value))
	_low_pitch.value_changed.connect(func(value: float) -> void: Settings.change(&"low_pitch", _hertz(value)))
	_high_pitch.value_changed.connect(func(value: float) -> void: Settings.change(&"high_pitch", _hertz(value)))
	# Pointed at, not tabbed through, like the document's bars.
	for control in find_children("*", "Control", true, false):
		if control is BaseButton or control is Range:
			control.focus_mode = Control.FOCUS_NONE
	Settings.changed.connect(_show)
	_show()


func _show() -> void:
	_debug.set_pressed_no_signal(Settings.debug)
	_sound.set_pressed_no_signal(Settings.sound)
	for button: Button in _waveforms:
		button.set_pressed_no_signal(button.get_index() == Settings.waveform)
	_loudness.set_value_no_signal(Settings.loudness)
	_low_pitch.set_value_no_signal(log(Settings.low_pitch) / log(2.0))
	_high_pitch.set_value_no_signal(log(Settings.high_pitch) / log(2.0))
	%LoudnessValue.text = "%d dB" % roundi(Settings.loudness)
	%LowPitchValue.text = "%d Hz" % roundi(Settings.low_pitch)
	%HighPitchValue.text = "%d Hz" % roundi(Settings.high_pitch)
	# The sound's details apply only while it plays.
	for button: Button in _waveforms:
		button.disabled = not Settings.sound
	for slider: HSlider in [_loudness, _low_pitch, _high_pitch]:
		slider.editable = Settings.sound


static func _hertz(octaves: float) -> float:
	return pow(2.0, octaves)
