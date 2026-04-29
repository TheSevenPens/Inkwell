# Inkwell Implementation Plan

This document proposes a phased path from zero to a shippable v1 of Inkwell. The guiding principle is **build something small that works, then add incrementally**. Every phase ends with a runnable, useful app — not a half-implemented engine.

The plan is *delivery order*, not *redesign*. The architectural decisions in `ARCHITECTURE.md` are committed; phases describe the order in which we realize them.

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

## Phase 0 — Project skeleton

**Goal.** Stand up the project so subsequent phases have a place to land.

**Scope.**
- Swift / AppKit project, Apple Silicon only, macOS Tahoe target.
- Single-window `NSDocument`-based app structure.
- Custom `NSView` canvas, Metal-backed, clears to a flat color.
- Build, sign, and run on the developer's machine.
- Basic menu bar (File → New / Open / Save stubs, Edit → Undo / Redo stubs).

**End state.** A blank window opens; nothing draws yet.

**Deferred.** Everything else.

---

## Phase 1 — Draw something

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

**UX checkpoint.** Sit with the app for at least one real drawing session.
- Does input feel responsive? Any perceptible latency?
- Is the cursor where I expect?
- Are pan and zoom natural?
- Are there visible quality issues with the stroke (jagged edges, missed samples)?

Adjust input handling, render presentation, or basic UX before adding complexity.

**Deferred.** Tile-based rendering, brush variety, pressure-mapped settings, layers, native format, all polish.

---

## Phase 2 — Tile-based rendering

**Goal.** Replace the full-bitmap layer with the tile-based engine from `ARCHITECTURE.md` decision 4.

**Scope.**
- Sparse tile cache (256×256, GPU-resident as `MTLTexture`).
- Stamp rasterizer writes into tile textures via Metal compute shader.
- Per-tile dirty tracking.
- Lazy viewport composition.
- Replace full-image undo snapshots with per-tile delta capture (decision 9).
- Disable mouse coalescing on the canvas window (decision 10).

**End state.** Phase 1's drawing experience is preserved or improved, now backed by a real tile engine.

**Validation.** No visible regressions. No tile-boundary seams when strokes cross tile edges. Memory cost scales with painted area, not document size.

**Deferred.** Multiple layers (still single layer), brush variety, native format.

---

## Phase 3 — Brush engine

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

**UX checkpoint — most important of the plan.**
- Does each brush feel like its name? G-Pen should feel decisive; Marker should layer translucently; Airbrush should breathe.
- Are pressure curves controllable? Editable?
- Do brushes feel responsive on a real tablet at 120 Hz?
- This is where we validate (or revise) the provisional pressure-curve representation per decision 11's note.

Iterate brush settings and tip textures until each brush feels right before moving on.

**Deferred.** Grain textures, color jitter, custom brush save/load, layers.

---

## Phase 4 — Layers

**Goal.** Multiple layers with the document model from decision 7 — but in memory only.

**Scope.**
- `Layer` as a sum type / protocol from day one (decision 5's commitments).
- Multiple bitmap layers, per-layer opacity, visibility, blend mode.
- Layer panel UI: list, drag-to-reorder, rename, duplicate, delete.
- Layer groups (tree compositing on the GPU).
- Initial blend modes: Normal, Multiply, Screen, Overlay. (Full set in Phase 9.)

**End state.** The user can build a layered illustration in a single session. Saving still flattens to PNG; multi-layer state does not survive between sessions.

**UX checkpoint.**
- Layer panel ergonomics: is reordering smooth?
- Do thumbnails update fast enough?
- Are blend modes clearly named and predictable?
- Adjust before adding the persistence layer.

**Deferred.** Persistence of multi-layer state (next phase), masks, selections.

---

## Phase 5 — Native bundle format

**Goal.** Save and reload everything Inkwell can produce, losslessly. Multi-layer documents persist across sessions.

**Scope.**
- `.inkwell` bundle structure (manifest, packed `tiles.bin`, `history.bin`, `assets/`, `thumbnail.png`) per decision 14.
- Atomic save (temp directory + atomic rename).
- Format version field; migration framework set up even with no migrations to run yet.
- Persist undo history sidecar with the document (decision 9).
- Author the first version of `FILEFORMAT.md` alongside the implementation.
- Recent documents UI in File menu.

**End state.** The user can save a layered Inkwell document, close the app, reopen it, and find every layer, blend mode, and undo step exactly as left.

**Deferred.** Layer masks (next phase), selections, PSD/PNG/JPG export polish.

---

## Phase 6 — Layer masks

**Goal.** Non-destructive editing per decision 7.

**Scope.**
- Per-layer optional mask, mirroring the layer's tile structure.
- Paint on mask: route brush input to the mask tile grid when the mask is the active editing target.
- Mask UI in layer panel: add/remove, link/unlink to layer, mask thumbnail, mask-active indicator.
- Mask preview overlay on canvas.
- Extend the bundle format to persist masks; bump format version, run no migration (new field).

**End state.** Users can hide parts of layers non-destructively; masks persist.

**UX checkpoint.** Is the mask edit mode discoverable? Is it clear which target (layer vs mask) the brush is painting on?

**Deferred.** Group masks, vector masks (future), selections.

---

## Phase 7 — Selections

**Goal.** Constrain operations to a region per decision 12.

**Scope.**
- Raster selection mask infrastructure (reuses mask tile structure).
- Tools: rectangle, ellipse, lasso, polygonal lasso, magic wand, color range.
- Selection arithmetic via Shift / Option / Shift+Option.
- Anti-aliasing and per-selection feather amount.
- Marching-ants Metal overlay shader.
- Quick Mask mode (paint the selection with brushes).
- Floating selection transforms (move, scale, rotate; commit/cancel).
- Constraint application in the GPU compositor (alpha multiply per decision 12).
- Persist selection in the bundle (extend format).

**End state.** The full selection toolset is usable, persistent, and constrains every pixel-writing operation.

**UX checkpoint.**
- Does each selection tool behave as expected?
- Is the marching-ants animation crisp on shape selections?
- Are floating-selection transforms intuitive?

**Deferred.** Vector path retention for shape selections (raster-only acceptable here if marching ants look good; can be added later).

---

## Phase 8 — View control polish

**Goal.** Match decision 13 fully.

**Scope.**
- Rotation (trackpad gesture, R + drag, Shift snap to 15°, Shift + R reset).
- Cursor-anchored zoom for pinch and Cmd+scroll.
- Mid-stroke navigation pause-and-resume.
- Held-modifier tool switches: Cmd → eyedropper, Option → eraser.
- Cursor preview reflects view rotation.
- Tab toggles all panels.
- Hand tool as a selectable persistent pan tool.

**End state.** Navigation is at full pro-tool quality.

**Deferred.** None — this phase fully matches the architecture.

---

## Phase 9 — Export and import

**Goal.** Interop with the rest of the world.

**Scope.**
- Export PNG (transparency preserved, profile-tagged Display P3 or sRGB, gamut mapping for sRGB).
- Export JPG (background flatten, profile-tagged).
- Export PSD: 8/16/32-bit options; bitmap layers, groups, masks; the full blend mode set agreed in this phase.
- Import PSD (layer tree, blend mode mapping, color profile conversion, unsupported-feature flagging).
- Import PNG / JPG as single-layer documents.
- Author the **PSD fidelity table** (referenced from both `ARCHITECTURE.md` and `USERMANUAL.md`).

**End state.** Inkwell can interoperate with the broader pro tool ecosystem.

**Deferred.** Document operations (next phase).

---

## Phase 10 — Document operations

**Goal.** Document-level transforms.

**Scope.**
- Document scaling (resample, both up and down, at high quality).
- Image rotation (90°, 180°, 270°, arbitrary angle).
- Image flipping (horizontal, vertical).
- Crop and resize canvas (without resampling).
- New-document dialog with size, color profile, and DPI presets.

**End state.** Users can transform and reshape their documents.

**Deferred.** Color picker upgrades, swatches, polish.

---

## Phase 11 — Color, swatches, and UX polish

**Goal.** Pleasant color workflow and final ergonomics.

**Scope.**
- Color picker UI (HSB and RGB sliders, color wheel, hex input).
- Swatch palette (built-in + user-defined, save/load).
- Cursor color indicator.
- Status bar / readouts (canvas position, document size, current zoom).
- Preferences panel (defaults, history budget, gamut mapping policy, autosave interval).
- Cursor preview improvements (brush silhouette, tilt, rotation).

**UX checkpoint.** Final ergonomics pass. Walk through every common workflow and adjust friction.

**Deferred.** None — this is the last feature phase.

---

## Phase 12 — Pre-launch hardening

**Goal.** Ready to ship.

**Scope.**
- First-launch onboarding flow.
- Crash reporting integration.
- Code signing and notarization.
- Distribution packaging (DMG; Mac App Store path is a separate decision).
- Final brush asset set finalized (tip textures, presets).
- App icon and marketing assets.
- User manual completion: installation, tutorial, and feature walkthroughs added to `USERMANUAL.md`.
- Final pass on `FILEFORMAT.md` and the PSD fidelity table.

**End state.** Inkwell v1 is shippable.

---

## Out of scope for v1

Tracked in `FUTURES.md`:

- Vector layers.
- ABR brush import.
- Distortion brushes (blur, liquify, smudge).
- Timelapse playback UI (the underlying delta stream is captured from Phase 5 onward).
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
- **Format extensions across phases bump the format version.** Even minor additions in Phase 6 (masks), Phase 7 (selections), and Phase 9 (whatever PSD interop adds) increment the version field.
- **The plan is a guide, not a contract.** If reality reveals that two adjacent phases should be merged or split, do that — but document the deviation.
