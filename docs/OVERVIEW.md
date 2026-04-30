# Inkwell Overview

Inkwell is a macOS native drawing application that takes advantage of a pressure-sensitive stylus to draw strokes.

## Initial key features

- Layers — bitmap and **vector** (V1 vector layers ship with G-Pen rendering as a continuous swept-path SDF ribbon; soft-edged vector brushes and per-stroke editing are deferred to V2 — see `FUTURES.md`)
- Layer blend modes (Photoshop-style)
- Layer opacity
- Selections (rectangle, ellipse, lasso; arithmetic via Shift / Option)
- Save and export: `.inkwell` (native), PSD, PNG, JPEG
- Basic brushes: Marker, G-Pen, Airbrush, Eraser
- Brush settings: name, size, pressure → size and pressure → opacity (with editable curves), tilt response, per-stamp jitter
- Image rotation and flipping (rotate 180° / 90° / 90°, flip H / V)
- Scaling the document (up/down) — deferred
- View control: pan, zoom, rotate (cursor-anchored)
- Undo / redo

## Features to talk about later

- Load ABR format for brushes
- Distortion brushes (blur, liquify, smudge)
- Timelapse recording
- Vector layer follow-ups: soft-edged vector brushes, vector eraser, per-stroke selection / move / restyle, true zoom-aware re-rasterization
- Group masks, branching undo, polygonal lasso / magic wand / color range, floating-selection transforms

See [`FUTURES.md`](FUTURES.md) for the full deferred-work list and architectural readiness notes.

## Supporting docs

**Architecture & subsystems**
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — index of numbered architectural decisions across the corpus in `arch/`
- [`design/README.md`](design/README.md) — subsystem design docs (tiles, compositor, strokes, coordinates, undo, color)

**Contributor onboarding**
- [`DEV_SETUP.md`](DEV_SETUP.md) — local build / run / debug
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — branch / PR workflow and style
- [`TESTING.md`](TESTING.md) — testing strategy and manual scenarios

**Engineering contracts**
- [`PERFORMANCE.md`](PERFORMANCE.md) — perf targets and profiling workflow
- [`THREADING_MODEL.md`](THREADING_MODEL.md) — concurrency rules for contributors
- [`UNDO_GUARANTEES.md`](UNDO_GUARANTEES.md) — policy for what must be undoable
- [`UI_STATE_MODEL.md`](UI_STATE_MODEL.md) — tool / modifier state machine

**References**
- [`USERMANUAL.md`](USERMANUAL.md) — user-facing feature reference
- [`PLAN.md`](PLAN.md) — phased implementation plan with per-phase status
- [`FUTURES.md`](FUTURES.md) — things deferred to future releases
- [`ROADMAP_OWNERSHIP.md`](ROADMAP_OWNERSHIP.md) — `FUTURES.md` items mapped to code entry points
- [`SCHEMA_REFERENCE.md`](SCHEMA_REFERENCE.md) — `.inkwell` schema cheat-sheet
- [`FILEFORMAT.md`](FILEFORMAT.md) — full `.inkwell` byte-level specification
- [`EXPORT_IMPORT_GUIDE.md`](EXPORT_IMPORT_GUIDE.md) — PNG / JPEG / PSD interop
- [`PSD_FIDELITY.md`](PSD_FIDELITY.md) — what survives the round-trip through PSD
- [`UI_COMPONENTS.md`](UI_COMPONENTS.md) — catalog of reusable UI building blocks
