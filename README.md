# ThreeDee

Internal iOS tool for opening, inspecting, converting and exporting 3D files. CAD parts, scans and meshes are shown at true metric scale in a white / cobalt technical-drawing style.

## Features

- **Import** from Files, AirDrop or any app's share sheet ("Open in ThreeDee"). The originals go to *Files › On My iPhone › ThreeDee › Models*.
- **Viewer** (Metal):
  - one finger orbits (with inertia), two fingers pan, pinch zooms, double tap re-frames;
  - Solid / Edges / Wire / Points styles, ISO/Top/Front/Right presets, original file colours on demand.
- **Metric grid** in mm or cm (Settings). Geometry is always held in millimetres, so a 10 mm cell is exactly 10 mm. Live X/Y/Z dimensions and the grid legend use the same unit.
- **Head-tracked parallax**: the front camera follows your face (Vision, on-device, frames discarded). The camera orbits slightly as you move and dollies in/out as you lean. The neutral position re-centres slowly, like the Home Screen effect. Strength is adjustable and the feature can be switched off.
- **Inspector**: size, surface area, volume (watertight meshes), vertex/triangle counts, STEP header data. Per-file overrides for source unit and up axis.
- **Convert / export** a single file or a batch selection. Results are written to *ThreeDee › Exports* and can be shared or saved to Files.
- Two themes: **Paper** (cobalt on white) and **Blueprint** (white on cobalt).

## Formats

| Format | Import | Export | Units & axis convention |
| --- | --- | --- | --- |
| STEP `.stp .step .p21` (AP203/214/242) | B-rep, faceted B-rep, AP242 tessellation, assemblies, colours | AP214 faceted B-rep | declared unit → mm · Z up |
| PLY `.ply` (ASCII / binary LE/BE) | meshes & point clouds, normals, colours | binary / ASCII | unitless* · Z up |
| STL `.stl` (ASCII / binary) | ✓ | binary / ASCII | unitless* · Z up |
| OBJ `.obj` | ✓ (incl. vertex colours) | ✓ | unitless* · Y up |
| OFF `.off` | ✓ (COFF/NOFF) | ✓ | unitless* · Z up |
| glTF `.glb .gltf` | ✓ (embedded buffers; no Draco/meshopt) | GLB | metres · Y up |
| USD `.usdz .usd .usda .usdc` | via Model I/O | USDZ | centimetres · Y up |

\* "Unitless files" setting, default millimetres. The viewer flags models whose size looks implausible and links to the unit override.

## Architecture

```
ThreeDee/
  Core/            platform-independent; compiles on macOS too (see Tools/)
    Geometry/      Mesh, welding, crease-aware normals, feature edges, statistics
    Formats/       format registry, units, axis conventions
    Import/        STL · PLY · OBJ · OFF · glTF · Model I/O loaders, ModelLoader
    Import/STEP/   Part 21 reader, NURBS/analytic geometry, earcut, face mesher
    Export/        all writers + stored-zip writer for USDZ
  Viewer/          Metal renderer & shaders, orbit camera, grid, face tracker, SwiftUI bridge
  Library/         file storage, metadata sidecars, stippled thumbnails
  UI/              SwiftUI screens and the white/cobalt design system
  App/             entry point and settings
Tools/             modelcheck.sh: CLI round-trip regression test for Core
```

**STEP tessellation.** Each face's trimming loops are mapped into the surface's parameter space. Seams, poles, cone apexes and full revolutions are handled by unwrapping, banding and capping. The loops are triangulated with earcut, then refined by constrained-Delaunay insertion until every chord is within tolerance of the true surface. The tolerance is set by *Settings › STEP tessellation*. Straight surface directions (cylinders, cones, extrusions) use an anisotropic metric, so they stay as long strips. Edges are discretised once and shared between faces, so solids come out watertight. Assembly placements (`ITEM_DEFINED_TRANSFORMATION`, `MAPPED_ITEM`) and `STYLED_ITEM` colours are applied.

## Development

- Open `ThreeDee.xcodeproj` (Xcode 26, iOS 26.2+).
- **The Debug configuration builds with `-O`.** Unoptimised Swift is roughly 40× slower at STEP tessellation (a 2 MB part takes about 20 s instead of 0.5 s). Set `SWIFT_OPTIMIZATION_LEVEL` back to `-Onone` if you need full debugger fidelity.
- Format regression check, no simulator needed:
  ```sh
  Tools/modelcheck.sh part.stp scan.ply mesh.stl
  ```
  It imports each file, exports it to every format, re-imports the result and compares bounding boxes. Exits non-zero on failure.
- Debug-only launch arguments (Scheme › Arguments, or `simctl launch`):
  - `-open <name prefix>`: open a library item at launch.
  - `-present info|export|settings|convert|select`: show a sheet or mode.
  - `-fakeHead`: synthetic head motion to check parallax without a camera (the Simulator has none).
  - Any setting via UserDefaults, e.g. `-appearance blueprint`, `-gridUnit cm`, `-renderStyle wireframe`.

## Known limitations

- STEP export writes one planar face per triangle (faceted B-rep), not the original NURBS. Colours aren't exported to STL, STEP or USDZ.
- STEP PMI, annotations and wireframe-only geometry are ignored. Faces on unsupported surface types fall back to a best-fit plane. Faces that still can't be meshed are counted in the inspector ("Faces not meshed").
- glTF with external `.bin` files only loads when the buffer is reachable next to the file. Use `.glb` or an embedded `.gltf`.
