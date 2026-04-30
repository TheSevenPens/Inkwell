# Stroke pipeline

What happens between a stylus moving on the tablet and pixels appearing on a layer. Two parallel paths — bitmap (stamp engine) and vector (SDF ribbon engine) — share an event-capture layer and an emitter pattern.

For the *why* of the rasterize-and-discard model, see [`arch/DOCUMENT.md`](../arch/DOCUMENT.md) decision 5; for tablet input fidelity, [`arch/INPUT.md`](../arch/INPUT.md) decision 10.

---

## TL;DR

```
hardware tablet
   ↓ macOS NSEvent (mouseDown/Dragged/Up + tabletPoint subtype)
CanvasView (NSResponder overrides)
   ↓ sampleFor(event:) → StylusSample (canvas-space, pressure, tilt)
   ↓
   ├── Bitmap path:
   │     StrokeEmitter (Catmull-Rom densifier, fixed stamp spacing)
   │       → dispatchSample(_) → StampRenderer.applyStamp(...)
   │         → MTLRenderCommandEncoder writes one quad per affected tile
   │
   └── Vector path:
         VectorStrokeBuilder (same Catmull-Rom densifier)
           → drawSegment closure → StrokeRibbonRenderer.drawCapsule(...)
             → MTLRenderCommandEncoder writes capsule SDF per affected tile
         + raw samples accumulate; on mouseUp, VectorStroke commits to layer
```

Both paths use **per-event command buffer batching**: `beginBatch()` at the start of each event handler, `commitBatch()` at the end. All Metal work for one input event commits in one buffer.

---

## Files

| File | Role |
|---|---|
| [CanvasView.swift](../../Sources/Inkwell/CanvasView.swift) | The MTKView. Owns input handlers (`mouseDown` / `mouseDragged` / `mouseUp` / `tabletPoint`), the active `StrokeEmitter` or `VectorStrokeBuilder`, and dispatches between bitmap and vector paths based on the active layer kind. |
| [StylusSample (in StrokeEmitter.swift)](../../Sources/Inkwell/StrokeEmitter.swift) | Value type carrying canvas-pixel position, pressure 0..1, tilt-X/Y. |
| [StrokeEmitter.swift](../../Sources/Inkwell/StrokeEmitter.swift) | Bitmap-path emitter. Catmull-Rom densification with one-sample lookahead; fixed stamp spacing along the path. |
| [VectorStrokeBuilder.swift](../../Sources/Inkwell/VectorStrokeBuilder.swift) | Vector-path emitter. Same densifier, but emits capsule segments for live preview instead of stamps. |
| [StampRenderer.swift](../../Sources/Inkwell/StampRenderer.swift) | Bitmap rasterizer: stamps a tip texture into bitmap-layer tiles or mask tiles. Three pipelines (normal / erase / mask). |
| [StrokeRibbonRenderer.swift](../../Sources/Inkwell/StrokeRibbonRenderer.swift) | Vector rasterizer: draws variable-width capsule SDF segments into vector-layer tiles. |
| [Brush.swift](../../Sources/Inkwell/Brush.swift) | Brush definition (radius, hardness, spacing, jitter, pressure-curve strengths, blend mode). The four built-ins (G-Pen, Marker, Airbrush, Eraser) live here. |
| [BrushPalette.swift](../../Sources/Inkwell/BrushPalette.swift) | Singleton holding the active brush + observers. |

---

## Event capture

### High-frequency tablet input requires two non-default settings

1. **Mouse coalescing disabled.** macOS by default coalesces tablet/mouse events to one per refresh (~60Hz). Tablets can deliver 200–300+ Hz; coalescing drops samples and produces visibly polygonal strokes. We disable it via the legacy Obj-C class method `+[NSEvent setMouseCoalescingEnabled:]` at app launch.

   Implementation: [AppDelegate.swift](../../Sources/Inkwell/AppDelegate.swift), `disableMouseCoalescingViaRuntime`. Uses `NSObject.method(for:)` and an `unsafeBitCast` to a C function pointer because the Swift importer doesn't expose that selector. Documented gotcha: this is **process-global** — it also applies to ordinary mouse moves and trackpad gestures. Hasn't bitten us; tracked in [`FUTURES.md`](../FUTURES.md).

2. **`tabletPoint(with:)` override.** With coalescing off, tablet sub-samples that *don't* fit into the standard `mouseDragged` cadence arrive via the `tabletPoint` NSResponder event. `CanvasView.tabletPoint` ([CanvasView.swift](../../Sources/Inkwell/CanvasView.swift), search `tabletPoint(with:)`) feeds them into the active emitter so we don't lose intermediate reports.

The combination jumps Wacom input from coalesced ~60Hz to native ~300Hz.

### `sampleFor(event:)`

[CanvasView.swift](../../Sources/Inkwell/CanvasView.swift), `sampleFor(event:)`:

```swift
let local = convert(event.locationInWindow, from: nil)
let canvasPoint = viewTransform.windowToCanvas(local)
let isStylus = (event.subtype == .tabletPoint)
return StylusSample(
    canvasPoint: canvasPoint,
    pressure: isStylus ? CGFloat(event.pressure) : 1.0,
    tiltX: isStylus ? CGFloat(event.tilt.x) : 0,
    tiltY: isStylus ? CGFloat(event.tilt.y) : 0
)
```

Coordinate transformation happens **here**, so everything downstream (emitters, renderers) sees canvas pixels. See [`COORDINATES.md`](COORDINATES.md).

---

## Path selection: bitmap vs vector

`mouseDown` ([CanvasView.swift](../../Sources/Inkwell/CanvasView.swift), search `override func mouseDown`):

```
1. recordEventForDebug(event)
2. Held-modifier shortcuts: spaceHeld → pan, rHeld → rotate, return early.
3. Switch on ToolState.shared.tool:
   .brush:
     - Cmd-click → eyedropper, return.
     - forceErase = optionEraser || stylusEraserTipEngaged
     - sample = sampleFor(event)
     - if canvas.activeVectorLayer != nil:
         if brush is "eraser" or forceErase: beginVectorEraser(at: sample)
         else:                               beginVectorStroke(at: sample)
       else:
         beginStroke(at: sample, forceErase: forceErase)  // bitmap path
   .moveLayer:    beginMoveLayer(with: event)
   .hand:         beginPan(with: event)
   .selectRect/Ellipse/Lasso: beginSelectionGesture(...)
```

Each branch wraps its work in a `beginBatch()` / `commitBatch()` pair on the appropriate renderer (stamp or ribbon) so the batch contains exactly one input event's worth of GPU work.

---

## Bitmap path: `StrokeEmitter` → `StampRenderer`

### `StrokeEmitter`

[StrokeEmitter.swift](../../Sources/Inkwell/StrokeEmitter.swift)

The emitter walks the path between raw stylus samples and emits stamps at fixed canvas-pixel spacing. Implementation details:

- **Catmull-Rom curve** between samples — fast strokes whose samples land sparsely don't appear as polyline corners.
- **One-sample lookahead.** A segment from `samples[i]` to `samples[i+1]` is drawn only after `samples[i+2]` arrives, so the curve has both shaping neighbors. The final segment of a stroke is flushed in `end(_:)` with the last sample duplicated as the ghost lookahead.
- **Sub-sample stepping.** Each segment is subdivided based on chord length (more sub-steps for longer/faster segments). Stamps land at `brush.spacing * brush.radius * 2` pixel intervals, with `nextStampOffset` carried across segments so spacing is continuous.
- The dispatch closure is set by the caller — typically `CanvasView.dispatchSample(_:)`, which builds a `StampDispatch` and calls `StampRenderer.applyStamp`.

### `StampRenderer`

[StampRenderer.swift](../../Sources/Inkwell/StampRenderer.swift)

Three Metal pipelines:
- `normalPipeline` — premultiplied source-over for normal painting.
- `erasePipeline` — destination-out so painted strokes *remove* pixels (Eraser brush + Option-modifier path).
- `maskPipeline` — writes to `.r8Unorm` mask tiles using a different fragment shader (`mask_stamp_fragment`) that does in-shader blending via framebuffer fetch.

Each `applyStamp` / `applyMaskStamp` call:
1. Computes the stamp's bounding box in canvas space (`radius * 1.42` square — covers the rotated-tip case).
2. Calls `layer.tilesIntersecting(bbox)` for the affected tiles.
3. For each tile: `ensureTile(at:)`, open a render encoder, draw the stamp quad with the appropriate pipeline, end encoding.
4. Returns the set of dirty tile coords.

The stamp shader (`stamp_fragment`) reads:
- The brush **tip texture** (`.rgba8Unorm`, soft-edge gradient based on `brush.hardness`) — see `Brush.makeTipTexture`.
- The document **selection texture** (`.r8Unorm`, canvas-sized) — the stamp output is multiplied by the selection sample at the canvas pixel, so any pixel-writing op respects the active selection automatically. When no selection is active, the caller passes `Canvas.defaultMaskTexture` (1×1 white) and the multiply is a no-op.

Output is premultiplied: `(color.rgb * coverage*opacity, coverage*opacity)`.

### Per-event command buffer batching

`StampRenderer.beginBatch()` / `commitBatch()` ([StampRenderer.swift](../../Sources/Inkwell/StampRenderer.swift), search `currentBatch`):

While a batch is active, `applyStamp` / `applyMaskStamp` encode into the **shared** command buffer rather than allocating one per call. Without this, at 300Hz × Catmull-Rom sub-stamps × per-stamp commits, the GPU's command queue would saturate and the display present would stall mid-stroke.

`CanvasView` wraps each stroke-producing event handler with the pair:
- `mouseDown` (brush case) → `beginBatch` ... `beginStroke(at:)` ... `commitBatch`
- `mouseDragged` (brush case) → `beginBatch` ... `emitter?.continueTo(...)` ... `commitBatch`
- `mouseUp` (brush case) → `beginBatch` ... `emitter?.end(...)` ... `commitBatch`
- `tabletPoint` → `beginBatch` ... `emitter.continueTo(...)` ... `commitBatch`
- `airbrushTick` (timer) → same pattern

Every Metal dispatch from one event collapses into one buffer commit. This was the fix for the bitmap stroke-stall bug at 300Hz; it's now applied symmetrically to the vector path.

---

## Vector path: `VectorStrokeBuilder` → `StrokeRibbonRenderer`

### `VectorStrokeBuilder`

[VectorStrokeBuilder.swift](../../Sources/Inkwell/VectorStrokeBuilder.swift)

Mirrors `StrokeEmitter`'s Catmull-Rom-with-lookahead pattern, but instead of dispatching stamps, it emits **capsule segments** (variable-width line segments with rounded ends) for live preview.

Critical correctness detail: `VectorStrokeBuilder.renderRawSegment` and `StrokeRibbonRenderer.densify` use **identical math**, so:
- Live drawing renders the same dense polyline that the committed-stroke re-rasterization would produce.
- `undo` → `redo` is pixel-identical to the original draw.

The builder seeds `lastDensePoint = (sample.point, r)` in `begin(_:)` without emitting, so the first emit is the segment from the first raw sample to the first densified point — matching `densify`'s output exactly.

### `StrokeRibbonRenderer`

[StrokeRibbonRenderer.swift](../../Sources/Inkwell/StrokeRibbonRenderer.swift)

One pipeline. Each capsule = one quad. Fragment shader computes the signed distance from the pixel to the capsule's centerline (with linearly-interpolated radius along the segment), produces an anti-aliased coverage value, outputs premultiplied `(color.rgb * a, a)` where `a = coverage * opacity`. Standard "over" blending.

Three entry points:
- **`drawCapsule(from:radiusA:to:radiusB:color:opacity:into:)`** — one capsule, used by the in-flight builder for live preview.
- **`renderStrokeIntoTile(_ stroke, layer, coord)`** — bake one stroke into one tile by densifying and drawing every segment that hits the tile.
- **`renderStroke(_ stroke, into layer)`** — convenience that walks all tiles intersecting the stroke's bounds.

Each respects the same `beginBatch` / `commitBatch` pair as the stamp renderer.

### What gets stored

Authoritative state on `VectorLayer`:
- `strokes: [VectorStroke]` — raw stylus samples + brush snapshot (color, opacity, min/max radius).

Tiles are a **derived cache**. They get rebuilt from strokes on:
- File load (`VectorLayer.rebuildAllTilesFromStrokes`).
- Undo/redo of stroke list (`VectorLayer.setStrokes` clears + re-renders).
- Eraser ops that split or remove strokes (`VectorLayer.applyStrokeReplacements` does targeted rebuild).

So `tiles.bin` does **not** carry vector-layer pixels — only the strokes JSON in `manifest.json`.

---

## The four bitmap brushes

All from one engine (decision 11). [Brush.swift](../../Sources/Inkwell/Brush.swift):

| Brush | Distinguishing settings |
|---|---|
| **G-Pen** | `hardness: 0.85`, `spacing: 0.05`, `pressureToSizeStrength: 0.85`, `pressureToOpacityStrength: 0.40`, `emissionHz: 0` (motion-driven). |
| **Marker** | `hardness: 0.45`, `spacing: 0.18`, `pressureToOpacityStrength: 0.85`. Soft, pressure-on-opacity. |
| **Airbrush** | `hardness: 0`, `spacing: 0.04`, `opacity: 0.10`, `emissionHz: 60`. Continuously emits while held still — see "Airbrush timer" below. |
| **Eraser** | `blendMode: .erase`. Same engine, destination-out blend. |

### Airbrush timer

`emissionHz > 0` brushes need stamps to keep emitting even when the stylus is stationary. `CanvasView.startAirbrushTimerIfNeeded` ([CanvasView.swift](../../Sources/Inkwell/CanvasView.swift)) starts a `Timer.scheduledTimer` at `1.0 / emissionHz`. Each tick re-dispatches the most recent sample via `dispatchSample(lastSample)`. The timer is started in `beginStroke` and stopped in `mouseUp`.

---

## What's not in this pipeline

- **Image transforms** (rotate / flip): handled in [CanvasTransforms.swift](../../Sources/Inkwell/CanvasTransforms.swift) by reading every tile to a `CGImage`, drawing into a transformed `CGContext`, and rebuilding tiles. Not the stamp/ribbon path.
- **Selection edits** (rect / ellipse / lasso): rasterized to `Selection.bytes` ([Selection.swift](../../Sources/Inkwell/Selection.swift)), not via the stamp engine. The selection mask then constrains future stamp ops automatically.
- **Move Layer tool**: a per-layer transient pixel offset goes through `CanvasRenderer.render(layerOffsets:)` for live preview, then bakes by re-rasterizing on `mouseUp` — see the move-tool flow in `CanvasView` ([CanvasView.swift](../../Sources/Inkwell/CanvasView.swift), search `beginMoveLayer`). Not the stamp path either.
- **Vector eraser**: dispatches to `applyEraserSample` which calls into `VectorEraserOps` — see [VectorEraserOps.swift](../../Sources/Inkwell/VectorEraserOps.swift). Three modes (whole stroke / touched region / to intersection); separate from the painting path.

---

## Stylus eraser tip auto-swap

When the user flips the stylus to its eraser end, `CanvasView.tabletProximity(with:)` ([CanvasView.swift](../../Sources/Inkwell/CanvasView.swift), search `tabletProximity(with:)`) detects `pointingDeviceType == .eraser` on entering proximity and:
1. Saves the current `BrushPalette.activeIndex` in `brushIndexBeforeEraserSwap`.
2. Switches to the Eraser brush.

On disengage (lift / pen tip back), the previous brush is restored — *unless* the user manually picked a different brush mid-engagement (then we leave their choice alone).

The status bar shows `● Eraser (stylus tip)` while engaged, via `StatusSnapshot.stylusEraserTipEngaged` ([CanvasView.swift](../../Sources/Inkwell/CanvasView.swift), search `StatusSnapshot`).

---

## Known gaps

- **No motion prediction.** Architecture decision 10 explicitly defers it. We render from raw samples; on systems with unusual GPU latency, perceived lag may appear.
- **Bitmap brush engine is not GPU-compute-batched.** Architecture decision 11 specifies one Metal compute dispatch per stylus sample with N stamps batched inside; today it's one render-pass-per-stamp inside a per-event command buffer. Per-event batching plus Apple Silicon's command-queue throughput keep this comfortably within budget; revisit if profiling shows otherwise.
- **Pressure curves are placeholder.** `Brush.pressureToSize` / `Brush.pressureToOpacity` use a 2-control-point cubic Bézier ([PressureCurve.swift](../../Sources/Inkwell/PressureCurve.swift)) — provisional per architecture decision 11 pending the project owner's design input on curve UX. The runtime path through curves works; the editing UI doesn't yet expose curve shape (only strength sliders).
- **Stroke stabilization is just Catmull-Rom densification.** No user-adjustable stabilization (correction strength, lag) yet.
