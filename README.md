# Inkwell

A native macOS drawing app for pressure-sensitive stylus input.

See [`docs/OVERVIEW.md`](docs/OVERVIEW.md) for project vision. Full design and planning documents are in [`docs/`](docs/).

## Status

**All major feature phases (0–11) have shipped.** Inkwell is feature-complete for v1 with documented deferrals for second passes. Remaining work is **Phase 12 — pre-launch hardening** (onboarding, crash reporting, code signing, distribution packaging, app icon, manual completion). See [`docs/PLAN.md`](docs/PLAN.md) for per-phase status.

What works today:

- Tile-based painting on Apple Silicon GPU, sparse-allocated, with full undo/redo at gesture granularity.
- Four brushes (G-Pen, Marker, Airbrush, Eraser) over a single data-driven engine, with pressure / tilt response and per-stamp jitter.
- Multi-layer documents with groups, per-layer non-destructive masks, blend modes (Normal / Multiply / Screen / Overlay), and per-layer opacity.
- Selection tools: rectangle, ellipse, lasso. Add / subtract / intersect via Shift / Option. Marching-ants overlay. Selections persist with the document and constrain every pixel-writing operation.
- Native `.inkwell` bundle save/load with format versioning and migration scaffold; PNG / JPEG / PSD export and import.
- View control: cursor-anchored zoom, trackpad rotate gesture, R+drag rotation with Shift snap, Hand tool, Tab to toggle panels.
- Image transforms: rotate 180° / 90° CW / 90° CCW, flip horizontal / vertical.
- Color: 12 built-in swatches, hex input, system color picker via the color well; Cmd-click eyedropper; Option-modifier eraser.
- Status bar with zoom %, view rotation, cursor position, document size.

Documented deferrals for second passes are tracked in [`docs/FUTURES.md`](docs/FUTURES.md).

## Requirements

- macOS Tahoe (26) on Apple Silicon (per [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) decision 3)
- Either Xcode, or Command Line Tools with Swift 6.0+

## Build and run

The project is bootstrapped on **SwiftPM + a small build script** that wraps the binary in a `.app` bundle. This works without Xcode.

```bash
./scripts/run.sh           # build (release) and launch
./scripts/build.sh         # build only (release)
./scripts/build.sh debug   # build with debug config
```

Build artifacts land in `.build/` (SwiftPM) and `build/Inkwell.app` (staged bundle). Both are gitignored.

When Xcode is installed later, the same source layout will transition cleanly to an `.xcodeproj`.

## Documentation

- [`docs/OVERVIEW.md`](docs/OVERVIEW.md) — vision and feature list
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — engineering decisions with rationale
- [`docs/USERMANUAL.md`](docs/USERMANUAL.md) — feature reference
- [`docs/PLAN.md`](docs/PLAN.md) — phased implementation plan with per-phase status
- [`docs/FUTURES.md`](docs/FUTURES.md) — deferred work and revisit points
- [`docs/FILEFORMAT.md`](docs/FILEFORMAT.md) — `.inkwell` bundle specification
- [`docs/PSD_FIDELITY.md`](docs/PSD_FIDELITY.md) — what survives PSD round-trip
