extends Node
## The clock an opened ZIP's volumes play by, so they play, pause, step and
## scrub together. It counts every solver time any of its models has, in
## order; each volume shows its model's step at the clock's time, or the
## last one before it.

const Meta := preload("res://app/meta.gd")
## Frames per second at 1× speed.
const FPS := 4.0

## Something changed: the time, whether it plays, or its speed.
signal changed

## Every solver time the volumes have, in order.
var times := PackedFloat64Array([0.0])
var frame := 0
var playing := true
var speed := 1.0

var _elapsed := 0.0
## The volumes playing by this clock; it goes when the last one does.
var _users := 0


## The solver time it is at.
func time() -> float:
	return times[frame]


func set_playing(value: bool) -> void:
	playing = value
	_elapsed = 0.0
	changed.emit()


func set_speed(value: float) -> void:
	speed = value
	changed.emit()


## Goes to [param time], or the last time before it.
func seek_time(time: float) -> void:
	frame = Meta.step_at(times, time)
	changed.emit()


func hold() -> void:
	_users += 1


func release() -> void:
	_users -= 1
	if _users <= 0:
		queue_free()


func _process(delta: float) -> void:
	if not playing or times.size() < 2:
		return
	_elapsed += delta * FPS * speed
	if _elapsed < 1.0:
		return
	# Playback starts over after the last frame.
	while _elapsed >= 1.0:
		_elapsed -= 1.0
		frame = (frame + 1) % times.size()
	changed.emit()
