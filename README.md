# Inkwell

A native macOS drawing app for pressure-sensitive stylus input.

See [`docs/OVERVIEW.md`](docs/OVERVIEW.md) for project vision. Full design and planning documents are in [`docs/`](docs/).

## Status

**Phase 0** — project skeleton. The app launches a window with an empty Metal-backed canvas. No drawing yet.

## Requirements

- macOS Tahoe (26) on Apple Silicon (per [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) decision 3)
- Either Xcode, or Command Line Tools with Swift 6.0+

## Build and run

The project is currently bootstrapped on **SwiftPM + a small build script** that wraps the binary in a `.app` bundle. This works without Xcode.

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
- [`docs/PLAN.md`](docs/PLAN.md) — phased implementation plan
- [`docs/FUTURES.md`](docs/FUTURES.md) — deferred work and revisit points
