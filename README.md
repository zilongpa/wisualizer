# Hand tracking test

A minimal GodotRealityKit project that checks hand tracking on Apple Vision
Pro. It opens straight into a mixed immersive space, the only place visionOS
tracks hands, and puts a ball on each fingertip (the index fingertip in
orange). A line of text shows whether each hand's tracker is there and tracked,
and the right index fingertip's position is logged once a second as
`[handtest] …`.

## Run it

1. Build GodotRealityKit from `zilongpa/plugins-for-godot` (`arvr4mp`, at
   e5255e8 or later), as for Wisualizer, and copy
   `godotrealitykit/out/addons/GodotRealityKit` into this project's `addons/`.
2. Open the project once in the engine fork's editor so it imports, or run
   `godot --headless --path . --import`.
3. Export with the `visionOS` preset, open `build/handtest.xcodeproj` in Xcode,
   set your signing team, and run it on the device.

## What to check

- visionOS asks for hand tracking permission on the first run.
- Both lines read `tracked` while the hands are in view, and the balls sit on
  the fingertips without drifting or lagging.
- The Xcode console shows `[GDRK] hand tracking started`.

In the simulator the trackers never appear (`no tracker`), as it has no hand
tracking.
