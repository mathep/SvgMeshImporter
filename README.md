# SVG Mesh Importer

A Roblox Studio plugin that turns an SVG file into a 3D mesh. Pick an SVG, set how wide and thick you want it, and it shows up in front of your camera as MeshParts. When you like how it looks, hit save and it uploads the meshes to your account so they stick around.

Good for logos, signs, icons, cutouts, that kind of thing.

## Installing

Download [`SvgMeshImporter.rbxmx`](SvgMeshImporter.rbxmx) from this repo and drop it in your local plugins folder:

```
%LOCALAPPDATA%\Roblox\Plugins
```

Restart Studio. You'll see **SVG Import** in the Plugins tab.

## Using it

1. Click **SVG Import** to open the panel.
2. Click **Choose SVG file** and pick your file. A preview gets built in front of your camera.
3. Change the settings if you want. The preview rebuilds as you go.
4. Click **Save as mesh assets** when you're happy with it.

You get one part for each fill color, grouped in a Model, so you can recolor or change materials on each piece separately.

**The preview won't save with your place.** It's built from an EditableMesh, and those don't get saved. If you close Studio without clicking save, the parts come back empty. Saving uploads each mesh as a real Mesh asset and swaps it in, so after that it saves and publishes like any other mesh.

If an upload goes through but the mesh doesn't load yet (new uploads sometimes take a minute), just click save again. It won't upload the same mesh twice.

## Settings

| Setting | What it does |
|---|---|
| Width | How wide the whole thing is in studs. Height follows the SVG's shape. |
| Thickness | How far it's pushed out. Set it to 0 for a flat plate. |
| Layer gap | Shapes that overlap get pushed forward a tiny bit so they don't flicker. This is how much. |
| Curve quality | How smooth curves are. Higher means smoother and more triangles. |
| Collision | Collision fidelity for the parts. Hull is a good default. |
| Upload to group ID | Leave empty to upload to your own account, or put a group ID to upload there. |

## What works and what doesn't

Works:
- paths (every command, including arcs), rects (rounded too), circles, ellipses, polygons
- holes, like the middle of an O, using either fill rule
- transforms, groups, `<use>`, CSS classes in `<style>` blocks (Illustrator exports use these a lot)
- opacity, which becomes part transparency

Doesn't work (the plugin will tell you when it skips something):
- **Strokes / outlines.** Turn them into shapes first. In Illustrator that's Object > Path > Outline Stroke, in Inkscape it's Path > Stroke to Path.
- **Text.** Convert it to paths first (Create Outlines / Object to Path).
- **Images** inside the SVG.
- **Gradients** become a single flat color, the average of the gradient.

Roblox caps a single mesh at 20,000 triangles, so big or detailed colors get split across a few parts. If one shape is too detailed on its own, turn Curve quality down.

## Building from source

The code is in `src/`. You need [Rojo](https://rojo.space) to build it:

```
rojo build default.project.json -o SvgMeshImporter.rbxmx
```

That overwrites the plugin file in the root. Copy it into your plugins folder like above.

There are tests for the SVG parsing and mesh building. They run outside Studio with [Lune](https://lune-org.github.io/docs):

```
lune run tests/run.luau
```

Any SVGs you drop in `tests/samples/` get run through the importer too.

## Credits

The triangulation code (`src/Earcut.luau`) is a Luau port of [earcut](https://github.com/mapbox/earcut) by Mapbox, which is under the ISC license.
