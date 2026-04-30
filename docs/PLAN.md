# Inkwell Implementation Plan

This document proposes a phased path from zero to a shippable v1 of Inkwell. The guiding principle is **build something small that works, then add incrementally**. Every phase ends with a runnable, useful app — not a half-implemented engine.

The plan is *delivery order*, not *redesign*. The architectural decisions in `ARCHITECTURE.md` are committed; phases describe the order in which we realize them.

---

## Phase status (at a glance)

| Phase | Title                          | Status                        |
|-------|--------------------------------|-------------------------------|
| 0     | Project skeleton               | ✅ Complete                   |
| 1     | Draw something                 | ✅ Complete                   |
| 2     | Tile-based rendering           | ✅ Complete                   |
| 3     | Brush engine                   | ✅ Complete                   |
| 4     | Layers                         | ✅ Complete                   |
| 5     | Native bundle format           | ✅ Pass 1 (history persistence deferred) |
| 6     | Layer masks                    | ✅ Complete                   |
| 7     | Selections                     | ✅ Pass 1 (3 tools, see deferrals) |
| 8     | View control polish            | ✅ Complete                   |
| 9     | Export and import              | ✅ Pass 1 (flat PSD; layer-aware deferred) |
| 10    | Document operations            | ✅ Pass 1 (rotate / flip; scale + resize + new-doc dialog deferred) |
| 11    | Color, swatches, polish        | ✅ Pass 1 (status bar / swatches / hex; custom picker + prefs deferred) |
| 12    | Pre-launch hardening           | ⏳ Not started                 |

Pass-2 deferrals are tracked in [`FUTURES.md`](FUTURES.md). Architectural decisions remain stable across passes; deferrals are scope, not redesign.

---

## Guiding principles

1. **Each phase ends with a runnable app.** No phase leaves the codebase in a non-compiling or non-launchable state.
2. **Smallest valuable thing first.** Phase 1 is "draw something." Everything else extends that.
3. **Replace naive internals later.** It is acceptable to ship a simpler implementation in an early phase and rebuild it correctly in a later phase, if doing so unblocks earlier UX validation.
4. **UX checkpoints are not skippable.** When a phase ends with a checkpoint, sit with the app for at least one real session before starting the next phase. The whole reason to start small is to course-correct early.
5. **Architecture decisions are stable.** If a phase reveals a real architectural problem, capture it as a new decision in `ARCHITECTURE.md` before changing course — do not silently drift.
6. **Each phase explicitly lists what is deferred.** Scope creep stays visible.
7. **Phases are not weeks.** They are scoped by what is true at the end. Some phases are large; some are small.

---

## Phase 0 — Project skeleton ✅

**Goal.** Stand up the project so subsequent phases have a place to land.

**Scope.**
- Swift / AppKit project, Apple Silicon only, macOS Tahoe target.
- Single-window `NSDocument`-based app structure.
- Custom `NSView` canvas, Metal-backed, clears to a flat color.
- Build, sign, and run on the developer's machine.
- Basic menu bar (File → New / Open / Save stubs, Edit → Undo / Redo stubs).

**End state.** A blank window opens; nothing draws yet.

---

## Phase 1 — Draw something ✅

**Goal.** Stylus input → strokes on canvas. The smallest end-to-end version of the app.

**Scope.**
- Single bitmap layer, full-bitmap representation (not tile-based yet).
- One round stamp brush, fixed size, no pressure mapping.
- `NSEvent` stylus and mouse input wired through to stamp placement.
- Basic pan and zoom (rotate deferred to Phase 8).
- Save/load as PNG only (no native bundle format yet).
- Undo as full-image snapshots (one snapshot per stroke).
- Held tool: pencil cursor reflecting the current brush.

**End state.** The user can pick up a stylus, draw on the canvas, undo a stroke, save a PNG, and reopen it.

---

## Phase 2 — Tile-based rendering ✅

**Goal.** Replace the full-bitmap layer with the tile-based engine from `ARCHITECTURE.md` decision 4.

**Scope.**
- Sparse tile cache (256×256, GPU-resident as `MTLTexture`).
- Stamp rasterizer writes into tile textures via Metal compute shader.
- Per-tile dirty tracking.
- Lazy viewport composition.
- Replace full-image undo snapshots with per-tile delta capture (decision 9).
- Disable mouse coalescing on the canvas window (decision 10).

**End state.** Phase 1's drawing experience preserved or improved, now backed by a real tile engine.

---

## Phase 3 — Brush engine ✅

**Goal.** Real brushes. The moment Inkwell starts to feel like a paint app.

**Scope.**
- Brush settings as data files (Swift `Codable`), one core engine, brushes as data (decision 11).
- Pressure → size and pressure → opacity, with provisional cubic-Bézier pressure curves.
- Tilt-aware sizing and stamp angle.
- Spacing and per-stamp jitter (size, opacity).
- Four brushes built on the same engine: **G-Pen**, **Marker**, **Airbrush**, **Eraser**.
- Brush settings panel UI: pick a brush, edit its settings live.
- Tip texture loading; an initial set of well-made tip textures.
- Cursor preview reflects current brush (size, tilt-aware).

**End state.** The user can pick from four brushes, tune them, and feel the difference.

---

## Phase 4 — Layers ✅

**Goal.** Multiple layers with the document model from decision 7 — but in memory only.

**Scope.**
- `Layer` as a sum type / protocol from day one (decision 5's commitments).
- Multiple bitmap layers, per-layer opacity, visibility, blend mode.
- Layer panel UI: list, drag-to-reorder, rename, duplicate, delete.
- Layer groups (tree compositing on the GPU).
- Initial blend modes: Normal, Multiply, Screen, Overlay. (Full set planned for a future Phase 9 follow-up.)

**End state.** The user can build a layered illustration in a single session. Multi-layer state does not survive between sessions until Phase 5.

---

## Phase 5 — Native bundle format ✅ (Pass 1)

**Goal.** Save and reload everything Inkwell can produce, losslessly. Multi-layer documents persist across sessions.

**Scope (Pass 1, shipped).**
- `.inkwell` bundle structure (manifest, packed `tiles.bin`, `thumbnail.png`) per decision 14.
- Atomic save via `NSFileWrapper` (temp + rename).
- Format version field; migration framework set up even with no migrations to run yet.
- `FILEFORMAT.md` authored alongside the implementation.
- Recent documents UI in File menu.

**Pass 2 deferred (in `FUTURES.md`).**
- Persisted undo / timelapse delta stream (`history.bin`). The format reserves the chunk; readers ignore its absence.

---

## Phase 6 — Layer masks ✅

**Goal.** Non-destructive editing per decision 7.

**Scope.**
- Per-layer optional mask, mirroring the layer's tile structure (sparse `.r8Unorm` tiles).
- Paint on mask: route brush input to the mask tile grid via the Edit-target toggle.
- Mask UI in the layer panel: add / remove mask, mask "M" badge, edit-target segmented control.
- Bundle format extension (optional `hasMask` field, mask tiles flagged in `tiles.bin`).

---

## Phase 7 — Selections ✅ (Pass 1)

**Goal.** Constrain operations to a region per decision 12.

**Scope (Pass 1, shipped).**
- Document-level raster selection (canvas-sized `.r8Unorm`).
- Tools: rectangle, ellipse, lasso.
- Selection arithmetic via Shift / Option / Shift+Option.
- Anti-aliased edges.
- Marching-ants Metal overlay shader, animated; live preview during drag.
- Constraint application: all three stamp pipelines (normal / erase / mask) sample the selection.
- Persist selection in the bundle (`selection.bin`).
- Menu items: Select All (Cmd+A), Deselect (Cmd+D), Invert Selection (Cmd+Shift+I).

**Pass 2 deferred (in `FUTURES.md`).**
- Polygonal lasso, magic wand, color range tools.
- Quick Mask mode.
- Floating-selection transforms (move / scale / rotate).
- Per-selection feather slider.
- Selection-state undo (selection edits are not yet on the undo stack).
- Vector path retention for shape selections.

---

## Phase 8 — View control polish ✅

**Goal.** Match decision 13 fully.

**Scope.**
- Rotation: trackpad gesture (cursor-anchored), R + drag (anchored at view center), Shift snap to 15°, Shift+R reset.
- Cursor-anchored zoom for pinch and Cmd+scroll.
- Mid-stroke navigation (works without explicit pause/resume since nav events don't disrupt mouseDragged sample flow).
- Held-modifier tool switches: Cmd → eyedropper, Option → eraser.
- Tab toggles all panels.
- Hand tool as a selectable persistent pan tool.

---

## Phase 9 — Export and import ✅ (Pass 1)

**Goal.** Interop with the rest of the world.

**Scope (Pass 1, shipped).**
- Export PNG (transparency preserved, sRGB-tagged via ImageIO).
- Export JPEG (configurable background flatten, sRGB-tagged).
- Export PSD (flat 8-bit composite via custom PSD writer).
- Import PSD / PNG / JPEG via macOS `ImageIO` as a single bitmap layer.
- [`PSD_FIDELITY.md`](PSD_FIDELITY.md) documents what survives round-trip.

**Pass 2 deferred (in `FUTURES.md`).**
- Layer-aware PSD export (groups, masks, opacity, blend modes preserved as PSD layers).
- Layer-aware PSD import (parsing the layer-and-mask-info section).
- Embedded ICC color profile in PSD output (image resource 1039).
- Optional 16-bit / 32-bit channel depth.
- Expanded blend mode set in PSD round-trip mapping.
- Display P3 working color space + gamut mapping on sRGB export (deferred until decision 6 is fully realized in the engine).

---

## Phase 10 — Document operations ✅ (Pass 1)

**Goal.** Document-level transforms.

**Scope (Pass 1, shipped).**
- Image rotation: 180°, 90° CW, 90° CCW.
- Image flipping: horizontal, vertical.
- All transforms walk every layer + each layer's mask + the active selection; canvas dimensions update; tiles rebuild from a transformed flat image at the new dimensions.

**Pass 2 deferred (in `FUTURES.md`).**
- Document scaling (resample, both up and down, at high quality).
- Crop / resize canvas (without resampling), with anchor.
- Arbitrary-angle rotation.
- New-document dialog with size, color profile, and DPI presets.
- Document-level undo for image transforms (Pass 1 clears the undo stack on transform).

---

## Phase 11 — Color, swatches, and UX polish ✅ (Pass 1)

**Goal.** Pleasant color workflow and final ergonomics.

**Scope (Pass 1, shipped).**
- 12-color built-in swatch palette in the brush inspector.
- Hex input field (#RRGGBB or #RGB) next to the color well.
- Status bar at the bottom of the canvas: zoom %, view rotation (when non-zero), cursor canvas-pixel position, document dimensions.

**Pass 2 deferred (in `FUTURES.md`).**
- Custom in-app color picker UI (the system `NSColorPanel` reached via the color well already covers HSB / RGB / wheel / palettes; building an in-app duplicate is low value).
- Persistent user-saved swatches with "Add Current Color".
- Preferences panel (autosave interval, history budget, gamut mapping policy, defaults).
- Cursor preview improvements: brush silhouette, tilt indicator, rotation indicator. Most useful when non-circular tip previews ship.

---

## Phase 12 — Pre-launch hardening ⏳

**Goal.** Ready to ship.

**Scope.**
- First-launch onboarding flow.
- Crash reporting integration.
- Code signing and notarization (via Xcode once installed).
- Distribution packaging (DMG; Mac App Store path is a separate decision).
- Final brush asset set finalized (tip textures, presets).
- App icon and marketing assets.
- User manual completion: installation, tutorial, and feature walkthroughs added to [`USERMANUAL.md`](USERMANUAL.md).
- Final pass on [`FILEFORMAT.md`](FILEFORMAT.md) and the [`PSD_FIDELITY.md`](PSD_FIDELITY.md) table.

**End state.** Inkwell v1 is shippable.

---

## Out of scope for v1

Tracked in [`FUTURES.md`](FUTURES.md):

- Vector layers.
- ABR brush import.
- Distortion brushes (blur, liquify, smudge).
- Timelapse playback UI (the underlying delta stream is captured from Phase 5 onward, pending `history.bin` write).
- Disk-spill for the tile cache (very large documents).
- Linear-light blending mode option.
- Active DPI (brush sizes in mm, document dimensions in inches).
- Text layers.
- Adjustment layers.
- Animation / multi-frame.
- Plugin system.

---

## Notes on using this plan

- **Architectural decisions are not up for renegotiation in a phase.** If a phase reveals a real architectural problem, pause, write a new decision in `ARCHITECTURE.md`, and resume.
- **UX checkpoints are the heart of "start small."** Skipping them defeats the plan's purpose.
- **Format extensions across phases bump the format version** when they are breaking. Backward-compatible additions (new optional fields, new chunks readers can ignore) keep the version stable. Phase 6 (`hasMask`) and Phase 7 (`selection.bin`) were both backward-compatible additions to format v1.
- **The plan is a guide, not a contract.** If reality reveals that two adjacent phases should be merged or split, do that — but document the deviation.
