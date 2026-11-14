# ZIP format

What Wisualizer opens is a ZIP with a `meta.json` at its root that says where
everything is. Nothing is found by guessing at file names, sizes or contents,
and every path in `meta.json` is relative to the ZIP's root.

A ZIP holds one or more models. Each model opens in a volume of its own, with
its own controls, timeline, fields and labels, so the person can set models
side by side, such as the bare geometry in one and the same geometry with its
field in another. The notes are the ZIP's, shown beside the first model.

```
hall-sensor.zip
├── meta.json
├── models/
│   ├── sensor/                   a model: a folder of its own
│   │   ├── parts/
│   │   │   ├── housing.glb       a part that doesn't change: one GLB
│   │   │   └── field-lines/      a part that does: one GLB per time step
│   │   │       ├── 0001.glb
│   │   │       └── …
│   │   └── fields/
│   │       └── B/                a field: one brick per time step
│   │           ├── 0001.bin
│   │           └── …
│   └── coil/
│       └── …
├── notes.txt                     optional
└── images/                       optional: what the notes show
```

The desktop build makes and edits these ZIPs in a workspace; see the README.
It copies GLBs and bricks into the ZIP as they are.

## meta.json

```json
{
  "title": "Hall sensor",
  "models": [
    {
      "name": "Sensor",
      "parts": [
        {"name": "Housing", "path": "models/sensor/parts/housing.glb"},
        {"name": "Field lines", "path": "models/sensor/parts/field-lines", "times": [0.0, 0.5, 1.0]}
      ],
      "fields": [
        {
          "name": "B",
          "quantity": "Magnetic flux density",
          "unit": "T",
          "range": [0.0000938, 0.113],
          "cells": [128, 128, 128],
          "box": {"origin": [-40, -40, -40], "size": [80, 80, 80]},
          "path": "models/sensor/fields/B",
          "times": [0.0, 1.0]
        }
      ],
      "field": "B",
      "labels": [
        {"text": "Hall element", "position": [0, 0, 0]},
        {"text": "The field peaks here", "position": [0, 0, 12], "radius": 4, "frames": [2, 3]}
      ]
    }
  ],
  "notes": "notes.txt"
}
```

| Key | Meaning |
| --- | --- |
| `title` | Shown as each volume's title, with its model's name when there are several models. |
| `models` | The models, each opening in its own volume, in this order. |
| `notes` | Optional. The notes, in Godot BBCode; see the README. |

Each model:

| Key | Meaning |
| --- | --- |
| `name` | Shown in its volume's title when there are several models. |
| `parts` | Its geometry, all shown together, each with a switch. |
| `fields` | Optional. Values on a regular grid, which the debug view shows, and controllers and hands feel. |
| `field` | Optional. The name of the field shown first; otherwise the first one. |
| `labels` | Optional. Text shown at points in the volume; see [Labels](#labels). |

### Timeline

Nothing in a ZIP lists frames: each model's timeline is every solver time its
parts and fields have, in order. A part or field that changes is a folder of
files, sorted by name, with `times` giving each file's solver time, as
EnSight writes them. At each frame it shows its step at that time, or else
its last one before it, or its first one before it starts; so parts and
fields needn't share their time steps. A model with nothing that changes has
one frame.

### Parts

Each GLB is an ordinary glTF binary in the model's units, which its parts and
fields share. A part's `path` is a GLB, shown at every frame, or a folder of
GLBs with `times`. A folder is loaded a few steps at a time while it plays,
so the ZIP needn't fit in memory all at once. Parts are listed, and switched,
in the order of `parts`.

### Fields

| Key | Meaning |
| --- | --- |
| `name` | Short, such as `B`; shown in the field picker. |
| `quantity`, `unit` | Optional, shown with values, such as `0.067 T`. |
| `range` | The values the bytes span: byte 1 is `range[0]`, byte 255 is `range[1]`, linearly. Byte 0 is a cell with no value. |
| `cells` | The grid's size, in cells along x, y and z. |
| `box` | Where the grid is, in model units: `origin` is its corner, `size` its extent. Optional `axes`, three unit vectors, turn it; they default to x, y and z. |
| `path`, `times` | A folder of bricks with their solver times, like a part's. Each brick is `cells` bytes in all, x fastest, then y, then z. |

### Labels

A label is a dot at a point in the volume, and text that shows over the dot
while a controller's tip is near it, until the tip is 1.25 times as far; where
labels overlap, the nearest one shows. On a desktop, the text shows while the
pointer is over the dot. On visionOS (including mouse clicks in the simulator),
tap a dot to select its text, tap another to switch, or tap the same dot again
to hide it. Selecting a label does not pause playback. The **Labels** switch
in the options hides them and clears the tap selection.
Visible labels remain selectable through the model's drag bounds; a gesture
that selects a label does not also rotate the model.

| Key | Meaning |
| --- | --- |
| `text` | What the label says, as plain text. Long lines wrap, and `\n` starts a new one. |
| `position` | The point, `[x, y, z]` in model units. |
| `radius` | Optional. How near a controller's tip comes for the text to show, in model units; otherwise 3 cm in the volume. |
| `frames` | Optional. `[first, last]`, counted from 1: the frames of its model's timeline the label shows at. `[n]` is one frame; without `frames`, every frame. Numbers must be whole, within the timeline, and in order; an empty array is invalid. |

The workspace keeps a label at the same solver times as steps are imported or
removed.
