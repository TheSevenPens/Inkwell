# Export / import guide

What flows through Inkwell's PNG / JPEG / PSD pipelines, where lossy steps are, and how to validate a round-trip. The byte-level details belong in [`FILEFORMAT.md`](FILEFORMAT.md) and [`PSD_FIDELITY.md`](PSD_FIDELITY.md); this doc is the practical implementer's guide.

## Format support matrix

| Format | Save (Cmd+S) | Export | Import (File → Open) | Import (drag-drop) |
|---|---|---|---|---|
| `.inkwell` | ✅ native, full-fidelity | — | ✅ | ✅ |
| PNG | — | ✅ flat | ✅ as single bitmap layer | ✅ |
| JPEG | — | ✅ flat (white-fill) | ✅ as single bitmap layer | ✅ |
| PSD | — | ✅ flat 8-bit | ✅ flattened (composite only) | ✅ |

`Save` writes only `.inkwell`. PNG / JPEG / PSD reach the user via **File → Export → …**. PSD as a save format is rejected by architecture decision 7.

## Pipeline shapes

### Native save (`.inkwell`)

```
Canvas
   ↓ Canvas.serializeToBundle()
   ├── manifest.json     (DocumentManifest, JSON)
   ├── tiles.bin         (TilesFile.encode([TileRecord]))
   ├── selection.bin     (SelectionFile.encode + bytes)   if selection active
   └── thumbnail.png     (Canvas.flattenToCGImage at ≤ 512 px max-dim)
```

[Canvas.swift](../Sources/Inkwell/Canvas.swift), `serializeToBundle()`. Each entry's `preferredFilename` is set so `NSFileWrapper` writes them with the right names.

Atomicity: `NSDocument` writes the bundle to a temp directory, fsyncs, and atomically renames into place. A crash mid-save leaves either the previous good bundle or the temp; never a half-written final bundle.

### Native load (`.inkwell`)

```
NSFileWrapper (the directory)
   ↓ Document.read(from:ofType:)
   ↓ Canvas.deserializeFromBundle(wrapper)
   ├── Read manifest.json → FormatMigrator.migrate(_:)
   ├── Validate document.width/height match the in-memory canvas
   ├── Build the layer tree from manifest.layers
   ├── Apply tiles.bin records to bitmap-layer / mask tiles
   ├── Re-rasterize every VectorLayer's tile cache from its strokes
   └── Apply selection.bin if present
```

If the manifest version is older than `currentVersion`, `FormatMigrator` is consulted. Today the migrator scaffold rejects older versions because there's been only one version — see [`SCHEMA_REFERENCE.md`](SCHEMA_REFERENCE.md).

### PNG export

```
Canvas
   ↓ Canvas.flattenToCGImage()      // walks visible renderables on CPU via Core Graphics
   ↓ ImageIO via CGImageDestinationCreateWithData(type: .png)
   ↓ Data
```

[Canvas.swift](../Sources/Inkwell/Canvas.swift), `encodePNGData()`. Properties:
- `premultipliedLast` alpha; sRGB color space.
- ImageIO tags the output with sRGB.
- Transparency preserved.
- Pixel dimensions match the canvas exactly (no resizing).

### JPEG export

```
Canvas
   ↓ Canvas.flattenToCGImage()
   ↓ Render onto an opaque background (white by default) → second CGContext
   ↓ ImageIO via CGImageDestinationCreateWithData(type: .jpeg) at quality 0.9
```

[Canvas.swift](../Sources/Inkwell/Canvas.swift), `encodeJPEGData(backgroundColor:quality:)`. Properties:
- `noneSkipLast` (no alpha); sRGB.
- Default background is white; configurable via the param.
- Quality 0.9 — visually lossless for most content; users can change in a future Export Options sheet.

### PSD export

```
Canvas
   ↓ Canvas.flattenToCGImage()
   ↓ Render to a fresh premultipliedLast sRGB CGContext
   ↓ Read raw bytes → PSDFormat.encodeFlat(width:height:premultipliedRGBA:)
   ↓ Data
```

[PSDFormat.swift](../Sources/Inkwell/PSDFormat.swift), `encodeFlat(...)`. Properties:
- 8 bits per channel.
- One layer (the composite).
- sRGB color tag (no embedded ICC profile).
- Bitmap layers and groups round-trip via composite only — **layer hierarchy is not preserved on export today.**

Layer-aware PSD export is a Phase 9 Pass 2 follow-up. See [`PSD_FIDELITY.md`](PSD_FIDELITY.md) for what's preserved exactly, what's approximated, and what's lost.

### PNG / JPEG / PSD import

All three go through the same import path:

```
Data (read by NSDocument as fileWrapper.regularFileContents)
   ↓ Canvas.loadPNG(from: data)        // misnamed; handles PNG, JPEG, PSD
   ↓ CGImageSourceCreateWithData → CGImageSourceCreateImageAtIndex
   ↓ Render onto a canvas-sized premultipliedLast sRGB CGContext
   ↓ Replace the layer tree with a single BitmapLayer named "Imported"
```

[Canvas.swift](../Sources/Inkwell/Canvas.swift), `loadPNG(from:)`. The function name is historical — `CGImageSource` decodes PNG, JPEG, and PSD (PSD comes back as the flattened composite, not the layer tree).

Properties:
- ImageIO performs ColorSync conversion from the source's embedded profile (or assumed sRGB if absent) into the destination's sRGB.
- Source is centered + scaled to fit the canvas dimensions, preserving aspect ratio.
- The previous layer tree is replaced; you can't import-as-a-new-layer today.

Layer-aware PSD import is a Phase 9 Pass 2 follow-up.

## Color profile handling

Today: **everything is sRGB**. Imports convert into sRGB; exports emit as sRGB. Architecture decision 6 commits to Display P3 internally with gamut-mapped sRGB export, but the engine ships sRGB throughout. See [`design/COLOR.md`](design/COLOR.md) for the full color story.

For the planned P3 pipeline:

- **Import**: read the embedded ICC profile via `CGImageSource.copyProperties`. Convert source → working space (P3) using `CGContext` with the working color space.
- **Export PNG / JPEG**:
  - Default: tag with the working profile (P3).
  - Optional sRGB output: gamut-map P3 → sRGB at output. Default mapping policy is perceptual; relative-colorimetric is a user choice exposed in the export sheet.
- **Export PSD**: write the embedded profile as image resource 1039.

Until then, the gamut-mapping path is a future task.

## Known lossy paths

### Export

| Path | Loss | Severity |
|---|---|---|
| Vector layer → PNG / JPEG / PSD | Strokes flattened to pixels | Expected; lossless re-export only via `.inkwell`. |
| Vector layer → PSD round-trip | Strokes flattened to pixels (one-way) | Same. |
| Layer tree → PSD | Hierarchy collapsed to a single composite layer | V1 only. Phase 9 Pass 2 ships layer-aware export. |
| Layer mask → PSD | Mask is composited into the layer's alpha | Until layer-aware export, masks bake on PSD output. |
| Document with a Background Layer → PSD | The implicit `Canvas.paperColor` shows through if the BG layer has alpha < 1 | Match the user manual's caveat about paper color. |
| `BackgroundLayer` color slightly different in export vs. live | The implicit paper draws first; BG composites on top. With opacity = 1 / Normal blend (default), they match. | Working as designed, see [`design/COLOR.md`](design/COLOR.md). |
| Display P3 colors → PNG / JPEG | Tagged sRGB, may appear less saturated on wide-gamut displays vs. live | Won't happen until P3 lands. |

### Import

| Path | Loss | Severity |
|---|---|---|
| PSD layer tree | Flattened to a single bitmap layer on import. Text, smart objects, adjustment layers all rasterize. | V1 only; Phase 9 Pass 2 reads the layer tree. |
| PNG / JPEG with non-sRGB profile | ColorSync converts to sRGB at decode | Lossless if the source is within sRGB gamut; perceptually mapped if outside. |
| PSD with embedded ICC profile | Decoded as sRGB by `CGImageSource`; profile not preserved | Until layer-aware import. |
| 16-bit PSD | Quantized to 8-bit at decode | Until 16-bit tiles land. |

## PSD round-trip validation

When changing anything in the PSD codec ([PSDFormat.swift](../Sources/Inkwell/PSDFormat.swift)) or the flatten path, validate by hand:

1. Pick a representative test document with: multiple layers, a mask, a non-Normal blend mode, partial opacity, an active selection, and a non-white background.
2. **File → Export → Photoshop (PSD)** to disk.
3. Open the exported `.psd` in Photoshop or Preview.
4. Compare visually to the live composite. Differences should match the [PSD_FIDELITY.md](PSD_FIDELITY.md) table:
   - Layer hierarchy: **collapsed** (expected V1).
   - Pixel-perfect composite: **yes** within the sRGB gamut.
   - Color fidelity: sRGB-tagged; should display correctly on color-managed apps.
5. **File → Open** the `.psd` back into Inkwell.
6. Verify it loads as a single `BitmapLayer` matching the exported composite.

Round-trip via `.inkwell` is identity-by-construction:

1. Document → Cmd+S → close → reopen.
2. Document state should be byte-for-byte the same in memory (modulo tile alpha rounding from premultiplication, which is handled).

When an `.inkwell` round-trip fails, look at:

- `FileFormat.currentVersion` — did the manifest version change without a migrator?
- New optional fields on `*LayerData` Codable types — did decoding default them correctly?
- New `LayerNodeData` cases — did encode/decode of all four cases stay in sync?

## Acceptance thresholds

For PSD round-trip:

- **Color delta**: ≤ 1 in 8-bit RGB per pixel (rounding from premultiplication).
- **Alpha delta**: ≤ 1 in 8-bit per pixel.
- **Pixel-count threshold**: < 0.1% of pixels may differ if at all (typically: 0%).

Larger differences indicate a real bug — usually in the flatten path, the PSD encoder, or a blend-mode mismatch.

For PNG / JPEG export:

- **PNG**: bit-perfect against the flattened composite.
- **JPEG**: lossy by definition; visual inspection only.

## Round-trip fixtures

`tests/fixtures/` is **not yet populated**. The plan is to add:

- `simple-stroke.inkwell` — single bitmap layer with one G-Pen stroke.
- `multi-layer.inkwell` — three bitmap layers, blend modes, masks, opacities.
- `vector-layer.inkwell` — a vector layer with multiple G-Pen strokes.
- `background-and-layers.inkwell` — Background Layer + bitmap + group.
- `selection-active.inkwell` — document with an active rectangle selection.
- `psd-import-photoshop.psd` — a Photoshop-saved file we know we can flatten correctly.

When CI lands, these fixtures gate the file-format and PSD codec PRs.

## Where to look in the code

- [FileFormat.swift](../Sources/Inkwell/FileFormat.swift) — bundle layout, encoders/decoders.
- [Canvas.swift](../Sources/Inkwell/Canvas.swift) — `serializeToBundle`, `deserializeFromBundle`, `flattenToCGImage`, PNG/JPEG/PSD encoders.
- [PSDFormat.swift](../Sources/Inkwell/PSDFormat.swift) — PSD codec.
- [Document.swift](../Sources/Inkwell/Document.swift) — NSDocument integration; `runExportPanel(...)` for the export sheet.
- [`SCHEMA_REFERENCE.md`](SCHEMA_REFERENCE.md) — manifest field dictionary and binary chunk layouts.
- [`PSD_FIDELITY.md`](PSD_FIDELITY.md) — what survives PSD round-trip.
