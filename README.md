# Wisualizer

An Apple Vision Pro teaching app (GaTech VIP): open a ZIP of Ansys EnSight
results and play its frames in a 3D volume, with notes beside it. The same
scenes run on desktop with an orbit camera, where a workspace also makes the
ZIPs, and are meant to run on Quest later.

## Run

Wisualizer needs a custom Godot 4.7 build and the GodotRealityKit plugin, both
from the `arvr4mp` branch of these forks:

- Engine: [zilongpa/godot](https://github.com/zilongpa/godot/tree/arvr4mp).
  Build the macOS editor and the visionOS export template with SCons.
- Plugin: [zilongpa/plugins-for-godot](https://github.com/zilongpa/plugins-for-godot/tree/arvr4mp).
  Build it with SCons as in its `godotrealitykit/documentation/Building.md`,
  then copy `godotrealitykit/out/addons/GodotRealityKit` into this project's
  `addons/`. The addon is local and not tracked; it also supplies the visionOS
  export template.

Open the project in that editor and press F5 for the desktop view, or export
with the `visionOS` preset and run the generated Xcode project on Apple Vision
Pro or the visionOS Simulator (set your signing team in Xcode).

The `Windows` preset exports the desktop view as one `.exe`, without
GodotRealityKit. Its template has to come from the same engine build, as the
notes' formulas need its MathJax module. On a Mac, cross-compile it with
MinGW (`brew install mingw-w64`):

```sh
scons platform=windows target=template_release arch=x86_64 use_mingw=yes d3d12=no accesskit=no
```

and copy (or link) `bin/godot.windows.template_release.x86_64.exe` into the
editor's export templates as `4.7.dev/windows_release_x86_64.exe`.

## Use

The first window is the library. **Open…** opens a ZIP, after asking whether
to add it to the library, which keeps a copy to open again later; pick one
there to open it again, or delete it from the library (the original file
stays). Each ZIP opens as its own volume, so several can be open at once. A
ZIP with notes shows them beside the volume; see [ZIPs](#zips). Dots mark
the points a ZIP has labels for: bring a controller to one, or the pointer on a
desktop, to read it. On visionOS, tap a dot (or click it in the simulator) to
show its text; tap the same dot again to hide it, or another dot to switch.

Resize the volume from its bottom corners; marks there show where when it
opens. On Apple Vision Pro, pinch and drag the model to turn it, like Apple's
globe: sideways turns it about the vertical, up and down tilts it, and the tilt
springs back when you let go. The volume makes room for it to turn any way. On
desktop, drag to orbit the view. The bar below it plays, pauses and scrubs the
frames, and shows or hides the notes and the options (speed, labels, debug
view); playback starts over after the last frame. With a keyboard, Space plays
or pauses and the arrow keys step a frame.

## ZIPs

A ZIP has a `meta.json` that says where its models, fields, notes and images
are; [docs/zip-format.md](docs/zip-format.md) describes it. A model is one
GLB, or a folder with a GLB per frame, which plays a few frames at a time
without the whole ZIP in memory. A ZIP can have several models and several
fields.

### Making one

The desktop build makes ZIPs in a workspace: **New…** in the library starts an
empty one, and the pencil beside a ZIP opens it there.

- **Frames**: the timeline. Importing GLBs or bricks with solver times fills
  it in when it's empty; times can be changed, and frames added or removed.
- **Models**: **Import GLBs…** takes the GLBs EnSight exports. Pick all of a
  model's GLBs, one per time step, named alike but for the step's number,
  and they become a model that changes; a GLB on its own becomes one that
  doesn't. Rename and reorder them here.
- **Fields**: **Import bricks…** takes the brick headers EnSight writes beside
  each brick (`*_meta0001` and so on), one field per variable. Set the name,
  quantity, unit and range. EnSight doesn't say what scale its bricks are at,
  so the box is fitted to the models; it can also be typed in.
- **Labels**: text at points in the volume. **Add label** puts one at the
  models' center; type its text and its point, in the models' units, which the
  page shows the extent of. A radius and the frames it shows at are optional.
- **Images**: what the notes show. **Insert into notes** adds an `[img]` tag.
- **Notes**: BBCode on the left, as it will look on the right.

**Save** writes the ZIP into the library, **Save As…** somewhere else, and
**Preview** saves and opens it.

### Notes

In `notes.txt`, `[img]images/flow.png[/img]` shows an image from the ZIP, with
any of Godot's `[img]` options, such as `[img width=320]…[/img]`. Paths are
relative to `notes.txt`. PNG, JPEG, WebP and SVG work.

Formulas are TeX: `[math]\frac{\partial u}{\partial t}[/math]` sets one in the
line, on the text's baseline, and `[math=display]…[/math]` on a line of its own.
MathJax typesets them, with all of its packages, such as `ams`, `physics` and
`mhchem`. A formula that doesn't typeset shows its source and what's wrong.
Short formulas can also be plain text, such as `Re = ρUD/μ`.

SVG images, such as formulas exported from LaTeX, stay sharp at any size, and
their `currentColor` takes the notes' text color.

`[url=frame:9]frame 9[/url]` is a link that pauses on frame 9.

## Code

| Path | Purpose |
| --- | --- |
| `app/launcher.gd`, `app/launcher.tscn` | Library: add, make, edit, open and delete ZIPs |
| `app/meta.gd` | Reads a ZIP through its `meta.json` |
| `app/workspace.gd`, `app/workspace.tscn` | Desktop editor for a ZIP: frames, models, fields, images and notes |
| `app/draft.gd` | What the workspace edits, and saves as a ZIP |
| `app/glb_info.gd`, `app/bov.gd` | Read what the workspace needs from a GLB's JSON and an EnSight brick header |
| `app/native_dialogs.gd` | Whether alerts and file pickers are the system's or Godot's |
| `app/document.gd`, `app/document.tscn` | One opened ZIP: volume, notes, controls and options ornaments |
| `app/model_frames.gd` | One model, loaded a few frames at a time |
| `app/labels.gd` | A volume's labels: a dot at each point, and its text while a controller or the pointer is near |
| `app/resize_hint.gd` | Corner marks that show the volume can be resized |
| `app/icons/` | Button icons ([IconPark](https://iconpark.oceanengine.com/)) |
| `ui/` | The app's look: `theme.tres` (SwiftUI-style buttons, sliders and scroll bars), the Inter font it uses on every platform, and custom controls such as `Scrubber` |
| `branding/` | App icon layers, the rounded macOS icon, boot splash and `generate.gd`, which draws them from `branding/assets/` (`godot --path . -s branding/generate.gd`) |
| `addons/spatial/` | `SpatialVolume3D`: a RealityKit volume on visionOS, an orbit camera elsewhere |

Shared scenes use `Window` and `SpatialVolume3D` only; platform differences stay
inside `addons/spatial/`. On desktop, a window's ornaments are drawn inside it.
Alerts and file pickers are the system's where the platform has them; run with
`-- --godot-dialogs` to try Godot's own, which other platforms get.
