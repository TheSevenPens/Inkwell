# Inkwell File Format

This document specifies the layout of the `.inkwell` native document bundle. It is the authoritative reference for implementers; the high-level shape decisions live in `ARCHITECTURE.md` decision 14.

**Current format version: 1.**

---

## Bundle structure

An `.inkwell` document is a macOS document bundle — a directory presented as a single file in Finder. The directory contains:

```
MyDocument.inkwell/
├── manifest.json     # required
├── tiles.bin         # optional; absent if every layer is empty
├── selection.bin     # optional; absent if no document-level selection is active (Phase 7+)
├── thumbnail.png     # required
├── history.bin       # reserved for a future version (not written by v1)
└── assets/           # reserved for embedded brushes, ICC profiles, etc. (not written by v1)
```

Files not listed above must be ignored by the reader. New chunks may be added in future versions; readers must tolerate their presence.

Atomicity is provided by the underlying `NSFileWrapper` save path: macOS writes to a temporary directory and atomically renames it into place. A crash mid-save leaves either the previous good bundle or the temp directory; never a half-written final bundle.

---

## `manifest.json`

UTF-8 JSON. Pretty-printed with sorted keys for diff-friendliness.

### Top-level shape (v1)

```json
{
  "formatVersion": 1,
  "document": {
    "width": 2048,
    "height": 1536,
    "colorSpace": "sRGB"
  },
  "activeLayerId": "<uuid>",
  "layers": [ <layer-node>, ... ]
}
```

- **`formatVersion`** (integer, required). Bumped on any breaking change. Readers must compare against their supported version: equal = read directly; smaller = run the migrator chain (see Migration); larger = refuse with a "newer Inkwell required" error.
- **`document.width`, `document.height`** (integers, required). Canvas pixel dimensions.
- **`document.colorSpace`** (string, required). v1 supports only `"sRGB"`. Future values reserved: `"DisplayP3"` (per `ARCHITECTURE.md` decision 6).
- **`activeLayerId`** (string, optional). UUID of the layer that should be active on open. If absent or invalid, the reader picks the first selectable layer.
- **`layers`** (array of layer nodes). The top-level layer list. Index 0 is topmost in the panel and rendered last (on top of everything below).

### Layer node

A discriminated union by the `type` field:

```json
{
  "type": "bitmap" | "group",
  "data": <bitmap-data | group-data>
}
```

### Bitmap layer data

```json
{
  "id": "<uuid>",
  "name": "Layer 1",
  "visible": true,
  "opacity": 1.0,
  "blendMode": "normal",
  "hasMask": true
}
```

- **`id`** (string, required). UUID. Used as the join key with `tiles.bin` records.
- **`name`** (string, required). User-visible name.
- **`visible`** (bool, required).
- **`opacity`** (float, required). 0.0 – 1.0.
- **`blendMode`** (string, required). One of: `"normal"`, `"multiply"`, `"screen"`, `"overlay"`. The full Photoshop set arrives in Phase 9 with the PSD fidelity table.
- **`hasMask`** (bool, optional, added in Phase 6). When `true`, the layer has an attached mask; mask tiles for this layer (if any are painted) appear in `tiles.bin` with the mask flag bit set. Absent / `false` / missing field = no mask. Backward-compatible with Phase 5 files.

### Group layer data

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

- **`expanded`** (bool, required). Whether the group is expanded in the panel.
- **`children`** (array). Nested layer nodes.
- v1 groups are pass-through: `blendMode` is recorded but ignored at composite time. Isolated group compositing is a future addition (see `FUTURES.md`).

---

## `tiles.bin`

Binary, all integers little-endian.

### Header (16 bytes)

| Offset | Size | Field        | Notes                       |
|--------|------|--------------|-----------------------------|
| 0      | 8    | magic        | ASCII bytes `INKTILES`      |
| 8      | 4    | version      | uint32. Currently `1`.      |
| 12     | 4    | reserved     | uint32. Must be 0 in v1.    |

### Records (concatenated)

Each tile record:

| Offset | Size | Field         | Notes                                                         |
|--------|------|---------------|---------------------------------------------------------------|
| 0      | 16   | layerId       | UUID raw bytes (Apple `uuid_t` order)                         |
| 16     | 4    | tileX         | int32. Column in the tile grid.                               |
| 20     | 4    | tileY         | int32. Row in the tile grid.                                  |
| 24     | 4    | flags         | uint32. Bit 0: `1` = mask tile (Phase 6+). v1 always writes 0.|
| 28     | 4    | reserved      | uint32. Must be 0 in v1.                                      |
| 32     | 4    | length        | uint32. Byte length of the data field. Always 262144 in v1.   |
| 36     | N    | data          | RGBA8 premultiplied alpha pixel bytes, 256 × 256 tile, top-down row order.|

The reader stops at end-of-file. A truncated final record (insufficient bytes for the declared length) is an error.

### Tile data layout

- 256 × 256 pixels.
- 4 bytes per pixel: R, G, B, A. Premultiplied alpha.
- Rows stored top-down (row 0 of stored data corresponds to the **highest canvas Y** in the tile region — `canvasY = (tileY + 1) × 256 − 1`). This matches how `tile.replace(region:withBytes:)` reads bytes and how `getBytes` writes them.

### Multiple tiles per layer

There is no ordering guarantee within `tiles.bin`. The reader builds a map of `(layerId, tileX, tileY) → bytes` and assigns to layers found in the manifest. Records whose `layerId` does not match any layer in the manifest are silently dropped (forward compatibility for layers that may exist in newer manifest schemas).

### Mask tiles

When `flags & 1 == 1`, the record is a mask tile attached to the layer identified by `layerId`.

Mask tile data:
- 256 × 256 pixels.
- 1 byte per pixel (single channel, `.r8Unorm`).
- `length` = 65536 (256 × 256).
- Rows top-down; pixel value 255 = fully visible, 0 = fully hidden.
- Default for any tile not present in the file: 255 (fully visible). Painting a mask tile that hides nothing is a no-op; no record is written.

Phase 5 readers (which lacked mask support) silently dropped these records. Phase 6 readers consume them; if a layer's manifest entry has `hasMask: true` but no mask tiles are present, the reader still attaches an empty `LayerMask`.

---

## `selection.bin` (optional, Phase 7+)

Document-level selection mask. Absent when no selection is active.

### Header (16 bytes)

| Offset | Size | Field        | Notes                       |
|--------|------|--------------|-----------------------------|
| 0      | 8    | magic        | ASCII bytes `INKSELC ` (note trailing space) |
| 8      | 4    | version      | uint32. Currently `1`.      |
| 12     | 4    | reserved     | uint32. Must be 0 in v1.    |

### Body

| Offset | Size  | Field   | Notes                                       |
|--------|-------|---------|---------------------------------------------|
| 16     | 4     | width   | uint32. Must equal manifest `document.width`.  |
| 20     | 4     | height  | uint32. Must equal manifest `document.height`. |
| 24     | W·H   | pixels  | Raw `.r8Unorm` bytes, top-down. 255 = fully selected, 0 = not selected. |

Phase 5 / Phase 6 readers ignore this file (treat as no selection). The selection
must be all-zero to omit the file; non-zero ⇒ selection is active and the file
is written.

---

## `thumbnail.png`

Standard PNG. Maximum 512 px on the longer side; aspect ratio preserved. Premultiplied alpha. sRGB. Used for Finder QuickLook and the macOS recent-documents UI.

---

## `history.bin` (reserved)

The undo / timelapse delta stream described in `ARCHITECTURE.md` decision 9 will live here. v1 does not write this file. Readers in v1 ignore its presence.

When implemented, the file will store an append-only sequence of delta records (per-layer, per-tile, plus structural ops), each length-prefixed for crash-safe recovery, with a header analogous to `tiles.bin`.

---

## `assets/` (reserved)

Reserved for embedded brushes (custom user brushes saved with the document), ICC profiles, and other auxiliary content. v1 does not write this directory. Readers in v1 ignore its presence.

---

## Migration

Each format version has an integer. When opening a document:

1. Read the manifest's `formatVersion`.
2. If equal to the reader's supported version, decode normally.
3. If smaller, run the chain of migrators from the document's version up to the reader's. Each migrator transforms the on-disk JSON shape into the next version's shape. The migrated manifest is then re-encoded on the next save.
4. If larger, refuse to open with a clear "this document was created with a newer Inkwell" error.

The migration framework is set up in v1 with no migrators registered (there is only one version). The structure exists so v2 can ship a v1→v2 migrator without retrofitting the framework.

Old-format readers are kept in the codebase indefinitely. We do not remove migration paths.

---

## Forward compatibility

Within a major format version, additions are made backward-compatible where possible:

- Unknown JSON keys in the manifest are ignored (Swift's `Decodable` skips them).
- Unknown chunks (extra files in the bundle) are ignored by the reader.
- Reserved bits in `tiles.bin` flags must be 0 in v1; v2 may use them.
- Unknown layer types in the manifest fail loudly today — a forward-extension mechanism (e.g. a `"unknown"` fallback layer that the reader preserves on round-trip) is a future improvement.

Breaking changes (renamed keys, restructured chunks, new mandatory fields) bump the format version.

---

## Atomicity guarantees

- Bundle-level: macOS atomically renames the temp directory into place. A crash mid-save leaves either the previous good bundle or the temp directory.
- Within the bundle: v1 writes all files in full each save. There is no append-only or partial-update mechanism in v1. (Decision 14 anticipates append-only `tiles.bin` with periodic compaction; that is a future version.)

---

## Reserved behavior for future versions

- **Append-only `tiles.bin`** with a header index, periodic compaction.
- **`history.bin`** for undo / timelapse.
- **`assets/`** for embedded brushes and ICC profiles.
- **Layer masks** (Phase 6).
- **Display P3** color space.
- **New layer kinds** (vector, text, adjustment) added as new `type` discriminator values.
- **PSD round-trip metadata** preserved across save/load.

These features will arrive in their respective phases (`PLAN.md`) and their on-disk shape will be specified here at that time.
