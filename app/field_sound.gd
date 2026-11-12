extends Node
## Lets the person hear the field with their hands. A tone follows each
## tracked hand's index fingertip: higher where the field there is stronger,
## and silent outside it. Each hand's tone leans toward its own side. Works
## with whatever hands the volume has, which on visionOS means while it is
## immersive. Its waveform, loudness and pitch range are in the settings;
## pitch rises evenly in octaves between the lowest and highest.
## How far each hand's tone leans toward its side, from 0 to 1.
const PAN := 0.6
## How quickly pitch and loudness follow the fingertip, per second: fast
## enough to feel immediate, slow enough not to click.
const GLIDE := 30.0
## Seconds of sound kept ready ahead.
const BUFFER := 0.1

## Samples the field for us, as it does for haptics.
var touch: Node
var volume: SpatialVolume3D

## Per hand tracker: its player and where its tone is.
var _voices := {}


func _process(_delta: float) -> void:
	if volume == null:
		return
	# Turning the sound off lets every tone fade out.
	var hands: Array[XRHandTracker] = []
	if Settings.sound:
		hands = volume.get_hands()
	var loudness := db_to_linear(Settings.loudness)
	for hand in hands:
		if not _voices.has(hand):
			_voices[hand] = _add_voice(hand)
	for hand: XRHandTracker in _voices:
		var voice: Dictionary = _voices[hand]
		var value := 0.0
		if hand in hands:
			var tip := volume.get_hand_joint(hand, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
			value = touch.value_of(touch.cell_at(tip))
		voice.target_loudness = loudness if value > 0.0 else 0.0
		if value > 0.0:
			voice.target_pitch = Settings.low_pitch * pow(Settings.high_pitch / Settings.low_pitch, value)
		_fill(voice, Settings.waveform)


func _add_voice(hand: XRHandTracker) -> Dictionary:
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = AudioServer.get_mix_rate()
	stream.buffer_length = BUFFER
	var player := AudioStreamPlayer.new()
	player.stream = stream
	add_child(player)
	player.play()
	var side := -1.0 if hand.hand == XRPositionalTracker.TRACKER_HAND_LEFT else 1.0
	return {
		playback = player.get_stream_playback(),
		rate = stream.mix_rate,
		# Equal-power gains for the left and right channels.
		gains = Vector2(cos((1.0 + side * PAN) * PI / 4.0), sin((1.0 + side * PAN) * PI / 4.0)),
		phase = 0.0,
		pitch = Settings.low_pitch,
		target_pitch = Settings.low_pitch,
		loudness = 0.0,
		target_loudness = 0.0,
	}


## Writes as much of the voice's tone as its player has room for, easing
## toward the target pitch and loudness sample by sample. Each waveform
## peaks at about one, and starts its cycle as a sine does.
func _fill(voice: Dictionary, waveform: int) -> void:
	var playback: AudioStreamGeneratorPlayback = voice.playback
	var frames := playback.get_frames_available()
	if frames == 0:
		return
	var rate: float = voice.rate
	var follow := 1.0 - exp(-GLIDE / rate)
	var phase: float = voice.phase
	var pitch: float = voice.pitch
	var loudness: float = voice.loudness
	var target_pitch: float = voice.target_pitch
	var target_loudness: float = voice.target_loudness
	var gains: Vector2 = voice.gains
	var buffer := PackedVector2Array()
	buffer.resize(frames)
	for i in frames:
		pitch += (target_pitch - pitch) * follow
		loudness += (target_loudness - loudness) * follow
		var step := pitch / rate
		phase = fmod(phase + step, 1.0)
		var sample := 0.0
		match waveform:
			Settings.Waveform.SINE:
				sample = sin(phase * TAU)
			Settings.Waveform.SAWTOOTH:
				sample = 1.0 - 2.0 * phase + _blep(phase, step)
			Settings.Waveform.SQUARE:
				sample = (1.0 if phase < 0.5 else -1.0) + _blep(phase, step) - _blep(fmod(phase + 0.5, 1.0), step)
			Settings.Waveform.TRIANGLE:
				sample = 4.0 * absf(fmod(phase + 0.75, 1.0) - 0.5) - 1.0
			Settings.Waveform.NOISE:
				sample = randf_range(-1.0, 1.0)
		buffer[i] = gains * (sample * loudness)
	playback.push_buffer(buffer)
	voice.phase = phase
	voice.pitch = pitch
	voice.loudness = loudness


## Rounds off a jump of two at the start of a cycle, so a sawtooth's or a
## square's edges don't alias at high pitch: PolyBLEP, which keeps mostly
## the harmonics the sample rate can carry, as Hyposelenia's additive
## waveforms do. [param step] is the cycle's share of one sample.
static func _blep(phase: float, step: float) -> float:
	if phase < step:
		var x := phase / step
		return x + x - x * x - 1.0
	if phase > 1.0 - step:
		var x := (phase - 1.0) / step
		return x * x + x + x + 1.0
	return 0.0
