# Schema reference

Cheat-sheet for the `.inkwell` document bundle. Field dictionary, enum values, version handling. The authoritative byte-level spec is [`FILEFORMAT.md`](FILEFORMAT.md); this file is the lookup-table summary.

## At a glance

| Constant | Value | Where defined |
|---|---|---|
| Document UTI | `com.thesevenpens.inkwell-document` | [FileFormat.swift](../Sources/Inkwell/FileFormat.swift), `FileFormat.inkwellUTI` |
| Manifest format version | **1** | `FileFormat.currentVersion` |
| `tiles.bin` chunk version | **1** | `TilesFile.version`, magic `INKTILES` |
| `selection.bin` chunk version | **1** | `SelectionFile.version`, magic `INKSELC ` |
| Tile pixel size | **256 × 256** | `Canvas.tileSize` |
| Tile pixel format (bitmap / vector) | `.rgba8Unorm` premultiplied | `BitmapLayer.ensureTile`, `VectorLayer.ensureTile` |
| Tile pixel format (mask) | `.r8Unorm`, white-default | `LayerMask.ensureTile` |

## Bundle layout

A `.inkwell` document is a macOS bundle (a directory Finder presents as a single file):

```
MyDoc.inkwell/
├── manifest.json        (required)
├── tiles.bin            (optional; absent if no bitmap-layer / mask tiles)
├── selection.bin        (optional; absent if no active selection)
├── thumbnail.png        (always written; for Finder QuickLook)
└── assets/              (reserved; not yet emitted)
```

`history.bin` is **reserved** in [FileFormat.swift](../Sources/Inkwell/FileFormat.swift) (`historyFilename`) but not written. See [`FUTURES.md`](FUTURES.md).

## Manifest fields (`manifest.json`)

Top level:

```json
{
  "formatVersion": 1,
  "document": { "width": 2048, "height": 1536, "colorSpace": "sRGB" },
  "activeLayerId": "<uuid>",
  "layers": [ <layer-node>, ... ]
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `formatVersion` | int | yes | Migration gate. Reader rejects values > `currentVersion`. |
| `document.width` / `document.height` | int (pixels) | yes | Mutable across save/load via Image transform ops. |
| `document.colorSpace` | string | yes | `"sRGB"` for v1; `"DisplayP3"` reserved per architecture decision 6. Currently the engine ignores this and always treats content as sRGB — see [`design/COLOR.md`](design/COLOR.md). |
| `activeLayerId` | string (UUID) | optional | Identifies which layer is selected on reopen. |
| `layers` | array of layer-node | yes | Ordered top-to-bottom in the panel (root layer 0 is the topmost; drawn last during compositing). |

### Layer-node discriminator

Every entry in `layers` (including children inside a group) is one of:

```json
{ "type": "bitmap" | "vector" | "background" | "group", "data": <type-specific> }
```

| `type` | Layer kind | Has tiles in `tiles.bin`? |
|---|---|---|
| `"bitmap"` | `BitmapLayer` (painted pixels) | yes |
| `"vector"` | `VectorLayer` (strokes; tile cache rebuilt on load) | no |
| `"background"` | `BackgroundLayer` (solid color) | no |
| `"group"` | `GroupLayer` (folder of children) | no (children may have their own) |

### `bitmap` data

```json
{
  "id": "<uuid>",
  "name": "Layer 1",
  "visible": true,
  "opacity": 1.0,
  "blendMode": "normal" | "multiply" | "screen" | "overlay",
  "hasMask": true | false | null
}
```

`hasMask` is optional and forward-compatible: missing / false ⇒ no mask. `true` ⇒ a mask is attached; mask tiles (if any) appear in `tiles.bin` keyed by `(layerId, isMask=1, tileX, tileY)`.

### `vector` data

```json
{
  "id": "<uuid>",
  "name": "Vector Layer",
  "visible": true,
  "opacity": 1.0,
  "blendMode": "normal",
  "strokes": [ <vector-stroke>, ... ]
}
```

Each `vector-stroke`:

```json
{
  "kind": "gPen",
  "color": { "r": 0.04, "g": 0.04, "b": 0.07, "a": 1.0 },
  "opacity": 1.0,
  "minRadius": 0.9,
  "maxRadius": 6.0,
  "samples": [
    { "x": 120.5, "y": 84.3, "pressure": 0.42 },
    { "x": 122.1, "y": 84.7, "pressure": 0.55 }
  ],
  "bounds": {
    "origin": { "x": 112.5, "y": 76.3 },
    "size": { "width": 18, "height": 18 }
  }
}
```

| Field | Notes |
|---|---|
| `kind` | V1 only `"gPen"`. Soft-edged vector brushes are deferred. |
| `color` | sRGB straight RGBA, components 0..1. |
| `opacity` | Constant per-stroke alpha. |
| `minRadius` / `maxRadius` | Linearly interpolated by per-sample pressure. |
| `samples` | Raw stylus samples (sparse). Densified at render time via Catmull-Rom. |
| `bounds` | Cached canvas-space bbox padded by `maxRadius + 2 px`. Re-derivable from samples. |

### `background` data

```json
{
  "id": "<uuid>",
  "name": "Background",
  "visible": true,
  "opacity": 1.0,
  "blendMode": "normal",
  "color": { "r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0 }
}
```

No tiles in `tiles.bin` for background layers.

### `group` data

```json
{
  "id": "<uuid>",
  "name": "Group",
  "visible": true,
  "opacity": 1.0,
  "blendMode": "normal",
  "expanded": true,
  "children": [ <layer-node>, ... ]
}
```

Pass-through groups in v1 (decision 7) — `blendMode` is recorded but ignored at composite time. `opacity` multiplies through to children.

## Enum values

### `LayerBlendMode` (`blendMode` field on every layer-node)

| String | Shader index | Status |
|---|---|---|
| `"normal"` | 0 | Default. |
| `"multiply"` | 1 | Implemented. |
| `"screen"` | 2 | Implemented. |
| `"overlay"` | 3 | Implemented. |

The full Photoshop set is a Phase 9 Pass 2 follow-up. Adding modes requires:
1. New `LayerBlendMode` case + `displayName` + `shaderIndex`.
2. New branch in `tile_fragment` and `solid_fragment` in [CanvasRenderer.swift](../Sources/Inkwell/CanvasRenderer.swift).
3. PSD blend-mode key mapping in [PSD_FIDELITY.md](PSD_FIDELITY.md).

### `VectorStroke.Kind`

| String | Status |
|---|---|
| `"gPen"` | Implemented. |

(Soft-edged vector brushes — `marker`, `airbrush` — are deferred; see [`FUTURES.md`](FUTURES.md).)

### Brush IDs

Used in code (`Brush.id`) and in `BrushPalette.builtins`, but **not persisted in the file format**. Strokes carry a snapshot of the relevant brush settings (color, radii, opacity), not the brush ID.

| ID | Display name |
|---|---|
| `"g-pen"` | G-Pen |
| `"marker"` | Marker |
| `"airbrush"` | Airbrush |
| `"eraser"` | Eraser |

## Binary chunks

### `tiles.bin`

```
header (16 bytes):
  +0  magic        8 bytes  "INKTILES"
  +8  version      4 bytes  uint32 LE = 1
  +12 reserved     4 bytes

records (repeated until EOF):
  +0  layerId      16 bytes UUID
  +16 tileX        4 bytes  int32 LE
  +20 tileY        4 bytes  int32 LE
  +24 flags        4 bytes  uint32 LE  (bit 0: 1 = mask tile, 0 = pixel tile)
  +28 reserved     4 bytes
  +32 length       4 bytes  uint32 LE  (size of the tile data that follows)
  +36 data         <length> bytes
```

Tile data bytes:
- **Bitmap pixel tile**: `Canvas.tileSize × Canvas.tileSize × 4` bytes (`.rgba8Unorm` premultiplied, top-down rows).
- **Mask tile**: `Canvas.tileSize × Canvas.tileSize` bytes (`.r8Unorm`, top-down rows).

A record's `(layerId, tileX, tileY, isMask)` tuple is the join key with the manifest's layer entries. Vector and background layers contribute **no** records.

### `selection.bin`

```
header (16 bytes):
  +0  magic        8 bytes  "INKSELC " (note trailing space)
  +8  version      4 bytes  uint32 LE = 1
  +12 reserved     4 bytes
  +16 width        4 bytes  uint32 LE  (canvas pixels)
  +20 height       4 bytes  uint32 LE
  +24 pixelData    width*height bytes (single-channel coverage, top-down rows)
```

Top-down rows: row 0 corresponds to canvas y = `height − 1`. See [`design/COORDINATES.md`](design/COORDINATES.md) for the full Y-axis convention.

If absent → no selection active. If all bytes are zero → file may still be present from an older save; reader treats as no selection.

## Compatibility & error handling

### Version negotiation

`FormatMigrator.migrate(_:)` reads the manifest's `formatVersion` and:

| Manifest version | Reader behavior |
|---|---|
| `< currentVersion` | Throws `FileFormatError.migrationRequired(from:to:)`. **No migrators registered yet** — files from earlier versions cannot be opened by newer builds until a migrator is added. |
| `== currentVersion` | Decodes normally. |
| `> currentVersion` | Throws `FileFormatError.unsupportedVersion(_:)`. User-facing message: "This document was created with a newer version of Inkwell." |

When you change the wire format:

1. Bump `FileFormat.currentVersion`.
2. Add a migrator — read the older shape, return a `DocumentManifest` at the current version.
3. **Don't remove old-format readers.** Migration code stays in the codebase indefinitely.

### Per-chunk versions

`tiles.bin` and `selection.bin` carry their own `version` uint32 in the header, separate from the manifest version. This lets us evolve binary chunks without bumping the manifest version, *or* bump the manifest while keeping binaries compatible. Today both are at **1**.

### Error surface

[`FileFormatError`](../Sources/Inkwell/FileFormat.swift):

| Case | Trigger |
|---|---|
| `invalidFile(String)` | Truncated record, missing magic, unexpected byte length, malformed UUID, dimension mismatch with the in-memory canvas. |
| `unsupportedVersion(Int)` | Newer-than-known manifest or chunk version. |
| `missingManifest` | Bundle has no `manifest.json`. |
| `notABundle` | The file at the URL isn't a directory bundle. |
| `thumbnailFailed` | Couldn't render or encode the thumbnail PNG. |
| `migrationRequired(from:to:)` | Older manifest version with no registered migrator. |

All errors propagate up through `Canvas.deserializeFromBundle` to `Document.read(from:ofType:)`. NSDocument shows the error description in a sheet.

### Forward compatibility

Two design choices that buy compatibility:

- **Type discriminator in `LayerNodeData`.** Adding a new layer kind requires adding a new `case` and string. Older builds will reject files containing the new kind (the `default` case in the decoder throws), so this is a *breaking* change at the manifest version level. Older builds **don't silently skip** unknown layer types — that's intentional today, see "Forward extension mechanism" in [`FUTURES.md`](FUTURES.md).
- **`BitmapLayerData.hasMask: Bool?`.** Optional — older files without the field decode cleanly as "no mask."

When adding a new optional field to existing `*LayerData` structs, mark it as `Optional` and ensure the decoder handles missing values. Don't change the JSON shape of existing fields — that breaks the file format.

## Reserved fields and chunks

| | Reserved for |
|---|---|
| `manifest.json.document.colorSpace = "DisplayP3"` | Phase 9 Pass 2 |
| `assets/` directory | Custom brush textures, embedded ICC profiles |
| `history.bin` | Phase 5 deferred undo / timelapse persistence |
| Tile record's second `reserved` 4-byte field | Future flags |
| Selection / tile chunk's header `reserved` 4 bytes | Future flags |

## Where to look in the code

- [FileFormat.swift](../Sources/Inkwell/FileFormat.swift) — manifest types, binary encoders, migrator scaffold.
- [Canvas.swift](../Sources/Inkwell/Canvas.swift) — `serializeToBundle` / `deserializeFromBundle`.
- [BitmapLayer.swift](../Sources/Inkwell/BitmapLayer.swift), [VectorLayer.swift](../Sources/Inkwell/VectorLayer.swift), [BackgroundLayer.swift](../Sources/Inkwell/BackgroundLayer.swift), [GroupLayer.swift](../Sources/Inkwell/GroupLayer.swift) — the model types these structs serialize to/from.
- [`FILEFORMAT.md`](FILEFORMAT.md) — full byte-level spec.
- [`design/TILES.md`](design/TILES.md) — what tiles look like in memory and on disk.
