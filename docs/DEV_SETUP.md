# Dev setup

Local build, run, and debug for Inkwell. Targeted at someone cloning the repo for the first time.

## System requirements

| | Required |
|---|---|
| macOS | **Tahoe (26)** or later |
| Mac | **Apple Silicon** (M1 or later) |
| Toolchain | Swift 6 toolchain — bundled with **Xcode 17** or **Command Line Tools** for Tahoe |
| Disk | ~1 GB for SwiftPM build artifacts |

The platform pin lives in [Package.swift](../Package.swift) (`.macOS("26.0")`) and [Resources/Info.plist](../Resources/Info.plist) (`LSMinimumSystemVersion = 26.0`). See [`arch/FOUNDATION.md`](arch/FOUNDATION.md) decision 3 for the *why*.

## Get the source

```bash
git clone https://github.com/TheSevenPens/Inkwell.git
cd Inkwell
```

## Build & run

The simplest path uses the helper scripts — no Xcode project needed:

```bash
./scripts/run.sh            # release build, packages .app, opens it
./scripts/run.sh debug      # debug build (faster compile, slower runtime)
```

What `run.sh` does:
1. Calls `scripts/build.sh` (which runs `swift build -c <config>`).
2. Stages a minimal `build/Inkwell.app` bundle from `Resources/Info.plist` and the built executable.
3. Ad-hoc signs (`codesign --force --sign -`) so it can launch on the local machine.
4. `open build/Inkwell.app`.

If you only want the binary (no .app, no launch):

```bash
swift build -c release        # builds .build/release/Inkwell
swift run                     # debug build + runs the executable directly (no .app bundle)
```

## Working in Xcode

Open `Package.swift` in Xcode (`File → Open…` or `xed Package.swift`). The project is a SwiftPM package, not an `.xcodeproj`, so Xcode opens it directly without conversion. All settings live in `Package.swift`; do not commit a generated `.xcodeproj/`.

To run the app from Xcode: pick the `Inkwell` scheme, hit ⌘R. Xcode handles the .app bundling internally.

## Project layout

```
Inkwell/
├── Package.swift                      # SwiftPM manifest
├── Resources/Info.plist               # bundle metadata (UTI for .inkwell)
├── Sources/Inkwell/                   # all Swift source (one flat target)
├── scripts/
│   ├── build.sh                       # SwiftPM build + .app stage + ad-hoc sign
│   └── run.sh                         # build + open
├── build/                             # gitignored; .app output lands here
└── docs/                              # everything below — start in ARCHITECTURE.md
```

There are **no test targets yet**. See [`TESTING.md`](TESTING.md) for the strategy and what we plan to add.

## Debugging

### LLDB

`./scripts/run.sh debug` builds with debug symbols. Attach LLDB via Xcode (Debug → Attach to Process…) or from the command line:

```bash
lldb -p $(pgrep -x Inkwell)
```

### Metal frame capture

The most useful Metal debugging path on this codebase:

1. Build & run from **Xcode** (`Package.swift` → `Inkwell` scheme → ⌘R).
2. With the app running and a stroke or composited frame visible, click the camera icon in the Xcode debug bar (or **Debug → Capture GPU Frame**).
3. Inspect the per-encoder draw calls in the captured frame:
   - **Paper pass** — one full-canvas quad with `paperPipeline`.
   - **Tile composite** — N quads (one per visible tile per layer) with `tilePipeline`.
   - **Solid fills** — one quad per `BackgroundLayer` with `solidPipeline`.
   - **Marching ants** — only when a selection is active.
   - **Vector overlay** — only when **View → Show Vector Path Overlay** is on.
4. For the brush pipeline, capture during a stroke. `StampRenderer` opens its own command buffer per input event (see [`design/STROKES.md`](design/STROKES.md)).

Shader source is the `static let metalSource` string at the top of each renderer file ([CanvasRenderer.swift](../Sources/Inkwell/CanvasRenderer.swift), [StampRenderer.swift](../Sources/Inkwell/StampRenderer.swift), [StrokeRibbonRenderer.swift](../Sources/Inkwell/StrokeRibbonRenderer.swift)). Compiled at runtime via `device.makeLibrary(source:options:)` — there's no `.metal` file to add a breakpoint to. You can edit the string and rebuild to iterate; Xcode's frame capture shows the resulting Metal IR.

### Stylus telemetry

Toggle **Debug → Show Debug Toolbar** (in the running app). The yellow bar above the canvas shows the latest stylus event's source / position / pressure / tilt / azimuth / altitude / Hz. Most useful for:

- Verifying tablet samples arrive at native rate (~300 Hz on Wacom). If you see ~60 Hz, mouse coalescing didn't disable — see [`design/STROKES.md`](design/STROKES.md).
- Confirming pressure / tilt are reaching the brush engine.

### Vector path overlay

Toggle **View → Show Vector Path Overlay** to render each visible vector layer's raw stylus samples as orange node markers connected by cyan polyline segments on top of the composite. Useful for inspecting how `VectorStrokeBuilder` densifies between samples vs. how the SDF ribbon rasterizes.

## Common failure modes

### "Build failed: macOS 26 is required"

You're on Sequoia or earlier. Either upgrade to Tahoe or bump `Package.swift` and `Resources/Info.plist` down for local exploration (don't commit that).

### Strokes appear polygonal at high speed

Mouse coalescing didn't disable at launch. Check the Console for the line:
```
Inkwell: setMouseCoalescingEnabled: unavailable; tablet rate may be capped at refresh rate
```
The Obj-C runtime call in [AppDelegate.swift](../Sources/Inkwell/AppDelegate.swift) failed; this happens if Apple removes the legacy class method. The architecture decision is documented in [`arch/INPUT.md`](arch/INPUT.md) decision 10.

### Code-sign fails on `./scripts/build.sh`

You don't have a working `codesign` — install Command Line Tools (`xcode-select --install`) or full Xcode. The script uses ad-hoc signing (`-`) so no developer ID is required.

### `open build/Inkwell.app` does nothing

The app crashed at launch. Check **Console.app** → Crash Reports → User Reports for `Inkwell-*.ips`. Most often a Metal pipeline failed to compile (shader syntax error in one of the inline `metalSource` strings).

### "Invalid drawable" or black canvas after fresh build

The MTKView's drawable wasn't ready when `draw(in:)` ran. Usually transient on first frame; if it persists, check for a recent change to `colorPixelFormat` in [CanvasView.swift](../Sources/Inkwell/CanvasView.swift) — it must match the pipeline descriptors' `colorAttachments[0].pixelFormat`.

### `swift build` succeeds but `./scripts/run.sh` says "error: built executable not found"

You ran `swift build` without `-c release` (so binary is in `.build/debug/`), but `./scripts/run.sh` defaults to release. Either pass `debug` or run `swift build -c release`.

## Reading order for the docs

If this is your first day on the codebase:

1. [`OVERVIEW.md`](OVERVIEW.md) — what Inkwell is.
2. [`ARCHITECTURE.md`](ARCHITECTURE.md) → the corpus index in `arch/`.
3. [`design/README.md`](design/README.md) → walk the subsystem docs in order (TILES, COMPOSITOR, STROKES, COORDINATES, UNDO, COLOR).
4. [`CONTRIBUTING.md`](CONTRIBUTING.md) — branching, PRs, style.

Then poke at the code with the debug toolbar on.
