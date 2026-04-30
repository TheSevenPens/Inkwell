# Inkwell Overview

Inkwell is a macOS native drawing application that takes advantage of a pressure-sensitive stylus to draw strokes.

## Initial key features

- Layers (bitmap layers now, vector layers in the future)
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
- Vector layers
- Group masks, branching undo, polygonal lasso / magic wand / color range, floating-selection transforms

See [`FUTURES.md`](FUTURES.md) for the full deferred-work list and architectural readiness notes.

## Supporting docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — components, roles, relationships, and key technical decisions
- [`USERMANUAL.md`](USERMANUAL.md) — user-facing feature reference
- [`PLAN.md`](PLAN.md) — phased implementation plan with per-phase status
- [`FUTURES.md`](FUTURES.md) — things deferred to future releases
- [`FILEFORMAT.md`](FILEFORMAT.md) — specification of the `.inkwell` native bundle format
- [`PSD_FIDELITY.md`](PSD_FIDELITY.md) — what survives the round-trip through PSD
