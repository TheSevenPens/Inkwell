# PSD Fidelity Table

This document tracks what survives the round-trip between Inkwell and the PSD
file format (Adobe Photoshop and other PSD-aware tools).

It is referenced from [`USERMANUAL.md`](USERMANUAL.md) and from
[`ARCHITECTURE.md`](ARCHITECTURE.md) decision 14, which calls for a published
fidelity table.

**Last updated: Phase 9 Pass 1.**

## What works today

### Export (Inkwell → PSD)

Phase 9 Pass 1 writes a flat 8-bit RGB+A PSD with **no layer hierarchy, no
embedded color profile, no image resources.** The composite pixels are
identical to what `Export As PNG` would produce.

| Inkwell feature                  | PSD round-trip                | Notes                                                          |
|----------------------------------|-------------------------------|----------------------------------------------------------------|
| Multi-layer documents            | ❌ Lost (flattened)           | Layer-aware export is Phase 9 Pass 2.                          |
| Layer groups                     | ❌ Lost                       | Same.                                                          |
| Layer masks                      | ❌ Lost                       | Same.                                                          |
| Per-layer opacity                | ⚠ Baked into composite       | Effects appear in flattened pixels but aren't separable.       |
| Per-layer blend modes            | ⚠ Baked into composite       | Same.                                                          |
| Selections                       | ❌ Not embedded               | PSD saved selections (alpha channels) are deferred.            |
| Color profile                    | ⚠ Untagged (sRGB assumed)    | Profile embedding (image resource 1039) deferred.              |
| Bit depth                        | 8-bit only                    | 16-bit and 32-bit float channel options deferred.              |
| Premultiplied alpha              | ✅ Un-premultiplied on output | We invert the premultiplication before writing.                |

### Import (PSD → Inkwell)

PSD files are read via macOS `ImageIO`, which returns the **flattened
composite** as a CGImage. The result is loaded as a single bitmap layer in a
new document, exactly as the user-visible image would appear in Photoshop.

| PSD feature                      | Imports as                  | Notes                                                          |
|----------------------------------|-----------------------------|----------------------------------------------------------------|
| Flat composite                   | ✅ Single bitmap layer      | The visible pixels.                                            |
| Layer hierarchy                  | ❌ Discarded                | Phase 9 Pass 2 work — needs a real PSD parser.                 |
| Layer masks                      | ❌ Discarded                | Same.                                                          |
| Embedded color profile           | ⚠ Read but assumed sRGB    | Non-sRGB profiles aren't yet honored on import.                |
| 8 / 16 / 32-bit input            | ⚠ Quantized to 8-bit        | Internal storage is 8-bit per channel until we move to 16-bit. |
| Adjustment layers / smart objects| ❌ Discarded                | Only the flat composite is read.                               |
| Text layers                      | ❌ Discarded                | Rasterized into the composite by Photoshop before save.        |

## Phase 9 Pass 2 work

The Pass 2 commit will tackle layer-aware PSD round-trip. Concretely:

- Write the layer-and-mask-info section of the PSD with one record per Inkwell
  bitmap layer, including its name, opacity, blend mode, and channel data.
- Map the v1 blend mode set (Normal / Multiply / Screen / Overlay) to PSD's
  blend-mode keys, with Pass 2 also expanding to a fuller Photoshop set.
- Write the embedded ICC color profile as image resource 1039.
- Optionally support 16-bit channels.
- Implement a PSD parser for import that reads the layer tree back as Inkwell
  bitmap layers + groups (deferring text / smart-object / adjustment layers).
- Document export: optionally include masks (`hasMask` per `FILEFORMAT.md`) as
  PSD layer masks.

## Out-of-scope for v1

The following PSD features are deliberately not planned for v1, even in
Pass 2:

- Adjustment layers (Curves, Levels, Hue/Saturation, etc.).
- Smart objects, smart filters.
- Layer styles (drop shadow, glow, bevel).
- Editable type / text layers.
- Slices, guides, paths.
- Animation / video frames.

These features either involve persistent non-pixel state Inkwell doesn't yet
have a place for, or they're out of scope of `OVERVIEW.md`. They round-trip as
"rasterized into the composite" on import and aren't preserved on export.

## See also

- [`ARCHITECTURE.md`](ARCHITECTURE.md) decision 14 (file format and export/import pipeline).
- [`USERMANUAL.md`](USERMANUAL.md) — feature reference for end users.
- [`FUTURES.md`](FUTURES.md) — broader roadmap including PSD fidelity refinements.
