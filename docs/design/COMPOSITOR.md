# Compositor

What happens when the canvas redraws. Five Metal pipelines, one render pass, framebuffer-fetch blend math, and a dispatch table that picks the right pipeline per layer kind.

For the *why* of GPU-resident lazy compositing, see [`arch/RENDERING.md`](../arch/RENDERING.md) decisions 4 and 6.

---

## TL;DR

- One file: [CanvasRenderer.swift](../../Sources/Inkwell/CanvasRenderer.swift). It owns the Metal library, all five pipelines, two samplers, and the per-frame `render(...)` method.
- Per frame, the encoder runs (in order):
  1. Clear to dark gray.
  2. Paper pipeline draws a canvas-sized quad in `Canvas.paperColor`.
  3. Walk visible leaf layers via `Canvas.walkVisibleRenderables`. For each:
     - **Background** layer → `solidPipeline` draws one canvas-sized quad with blend-mode math.
     - **Bitmap or vector** layer → `tilePipeline` draws one quad per *visible* tile.
  4. If there's an active selection, `antsPipeline` draws a screen-space dashed-edge overlay.
  5. If `VectorOverlayController.shared.isVisible`, `vectorOverlayPipeline` draws cyan polylines + orange node markers for every vector stroke.
- Blend modes (Normal / Multiply / Screen / Overlay) live entirely in the **fragment shader**. Pipeline-level blending is **disabled** for tile and solid passes — the shader uses framebuffer fetch (`dst [[color(0)]]`) and writes the final composited value.

---

## Five pipelines

All defined in `CanvasRenderer.metalSource` ([CanvasRenderer.swift](../../Sources/Inkwell/CanvasRenderer.swift)) and instantiated in `init`.

| Pipeline | Vertex / fragment | Blending | Used for |
|---|---|---|---|
| `paperPipeline` | `paper_vertex` / `paper_fragment` | off (just writes color) | Canvas paper background |
| `solidPipeline` | `solid_vertex` / `solid_fragment` | off (FB-fetch in shader) | `BackgroundLayer` |
| `tilePipeline` | `tile_vertex` / `tile_fragment` | off (FB-fetch in shader) | `BitmapLayer`, `VectorLayer` tiles |
| `antsPipeline` | `ants_vertex` / `ants_fragment` | alpha-over | Marching-ants selection overlay |
| `vectorOverlayPipeline` | `vector_overlay_vertex` / `vector_overlay_fragment` | alpha-over | Debug overlay (View → Show Vector Path Overlay) |

All pipelines write to the same drawable color attachment (the `MTKView`'s next drawable, format `bgra8Unorm`).

---

## Why no pipeline blending on tile / solid passes

The architecture commitment is to **gamma-space blend math matching Photoshop** (decision 6). Hardware fixed-function blend cannot express Multiply / Screen / Overlay correctly; those need access to both the source and the destination color in the fragment shader.

Metal supports this on Apple Silicon via **framebuffer fetch**: a fragment shader argument `float4 dst [[color(0)]]` reads back the current render-target value at the same pixel. The shader does the blend math and writes the final premultiplied value.

So the tile and solid pipelines:
- Set `isBlendingEnabled = false` (no fixed-function blend).
- Use a fragment shader that takes `dst` and outputs the final composited color.

The ants and vector-overlay pipelines use ordinary alpha-over because they're simple anti-aliased overlays, not blend-mode-aware compositing.

---

## The fragment shader's blend math

`tile_fragment` ([CanvasRenderer.swift](../../Sources/Inkwell/CanvasRenderer.swift), search `tile_fragment`) and `solid_fragment` (search `solid_fragment`) both run the same blend math, just over different sources (sampled tile texture vs. uniform color):

```metal
float3 srcUn = src.a > 0.0001 ? src.rgb / src.a : float3(0);
float3 dstUn = dst.a > 0.0001 ? dst.rgb / dst.a : float3(0);

if (blendMode == 1) {        // Multiply
    blendUn = srcUn * dstUn;
} else if (blendMode == 2) { // Screen
    blendUn = 1.0 - (1.0 - srcUn) * (1.0 - dstUn);
} else if (blendMode == 3) { // Overlay
    blendUn = (dstUn < 0.5)
        ? 2 * srcUn * dstUn
        : 1 - 2 * (1 - srcUn) * (1 - dstUn);
} else {                     // Normal
    blendUn = srcUn;
}

float3 outRgb = src.rgb * (1 - dst.a)        // src outside dst
              + dst.rgb * (1 - src.a)        // dst outside src
              + blendUn * src.a * dst.a;     // overlap region (blended)
float outA  = src.a + dst.a * (1 - src.a);
return float4(outRgb, outA);
```

Notes:
- Tile data is **premultiplied**, so we divide by alpha before the blend math and re-premultiply when writing back.
- The "outside" terms are necessary because blend modes only apply where both layers have coverage; outside that overlap, source-over rules.
- Only Normal/Multiply/Screen/Overlay are wired. The full Photoshop set is a Phase 9 follow-up — see [`PSD_FIDELITY.md`](../PSD_FIDELITY.md) and [`FUTURES.md`](../FUTURES.md).
- `LayerBlendMode.shaderIndex` ([LayerNode.swift](../../Sources/Inkwell/LayerNode.swift)) is the int the shader branches on. Add a case ⇒ extend the enum, the index, *and* the shader.

---

## Two samplers, one rule

```swift
sampler        // minFilter = .linear,  magFilter = .linear   — used for ants overlay
tileSampler    // minFilter = .linear,  magFilter = .nearest  — used for tile composite
```

Why split:
- The **ants overlay** uses `fwidth(s)` to detect the selection edge gradient. That requires linear sampling so adjacent fragments see a smooth transition.
- The **tile composite** wants nearest-neighbor magnification — at 200% zoom the user expects to see crisp pixels, not bilinear blur. Linear minification (zoom-out) is still right because that's the smooth-downscale case.

Metal picks min vs. mag per fragment based on the sampling rate. So `tileSampler` automatically does the right thing across the zoom range.

This is documented inline at [CanvasRenderer.swift:271–275](../../Sources/Inkwell/CanvasRenderer.swift#L271).

---

## The render pass

`render(in:viewTransform:visibleCanvasRect:layerOffsets:)` is the single entry point ([CanvasRenderer.swift](../../Sources/Inkwell/CanvasRenderer.swift), search `func render`).

```
1. Get the next drawable + render pass descriptor from the MTKView.
2. Clear color to dark gray (the off-canvas area).
3. Open one MTLRenderCommandEncoder.

4. Paper pass: paperPipeline, draw 6-vertex canvas-sized triangle pair.

5. Layer compositing:
   for each kind in canvas.walkVisibleRenderables:
     case .background(bg):
        bind solidPipeline
        draw 6-vertex canvas-sized quad with bg.color, opacity, blendMode
     case .compositable(layer):
        bind tilePipeline
        bind tileSampler
        for coord in layer.tilesIntersecting(visibleCanvasRect, offset by layerOffsets[layer.id]):
          guard texture = layer.tile(at: coord)
          bind texture (slot 0)
          bind layer.mask?.tile(at: coord) ?? defaultMask (slot 1)
          set per-tile uniforms (origin, size, opacity, blendMode)
          draw 6-vertex tile quad

6. Marching ants pass (if canvas.selection != nil):
   antsPipeline, canvas-sized quad, time-driven dash phase.

7. Vector debug overlay (if VectorOverlayController.shared.isVisible):
   collect line segments + node positions from canvas.visibleVectorLayers().
   upload to MTLBuffers, drawPrimitives(.line) and (.point).

8. Encode end. Present drawable. Commit.
```

Single render pass, single command buffer, single drawable. No off-screen targets.

---

## `walkVisibleRenderables`: how iteration order is determined

[Canvas.swift](../../Sources/Inkwell/Canvas.swift) (search `walkVisibleRenderables`):

- Yields each visible leaf in **bottom-to-top** stacking order.
- Walks `rootLayers` reversed (panel shows top-first, drawing wants bottom-first).
- Recurses into `GroupLayer` children, multiplying opacity through (pass-through groups; isolated group blending is a Phase 4 follow-up).
- Skips layers with `isVisible == false` or effective opacity < 0.001.
- Dispatches via `RenderLayer` enum: `.background(BackgroundLayer)` or `.compositable(any CompositableLayer)`.

The compositor branches on the case and picks the right pipeline. Keep both branches in sync if you change the iteration semantics.

---

## Per-tile vs. per-canvas draws

| Layer kind | Quads per frame |
|---|---|
| `BitmapLayer` / `VectorLayer` | One per *visible* tile (`tilesIntersecting(visibleCanvasRect)`). Off-canvas / off-viewport tiles are skipped. |
| `BackgroundLayer` | One canvas-sized quad. (The `solidPipeline` exists specifically so we don't try to synthesize tiles for backgrounds.) |
| `paperPipeline` | One canvas-sized quad. |
| `antsPipeline` | One canvas-sized quad. |

So a canvas with 3 bitmap layers, each touching ~16 tiles in the viewport, runs roughly `1 paper + 48 tile + 1 ants ≈ 50 quad draws` per frame. Cheap on Apple Silicon.

---

## The `layerOffsets` parameter

`render(layerOffsets: [UUID: CGPoint])` is used by the **Move Layer tool** for live drag preview. While the user drags, the active layer's id maps to the in-flight pixel offset. The compositor:

- Adds the offset to each tile's `tileOrigin` uniform → the layer appears translated.
- Adjusts the visibility-cull rect (`visibleCanvasRect.offsetBy(dx: -off.x, dy: -off.y)`) so culling accounts for the offset.

No tile data mutates during drag. On `mouseUp` the offset is *baked* into the layer (re-rasterize bitmap content; translate vector samples) and the offset map is cleared. See [`STROKES.md`](STROKES.md) for the move-tool flow.

Backgrounds ignore the offset (they're full-canvas).

---

## Key cross-references

- **Metal source string** — defined as `static let metalSource` at the top of `CanvasRenderer`, single multi-line string for all five vertex/fragment shaders. Compiled once in `init` via `device.makeLibrary(source:options:)`.
- **Shader-side uniform structs** must match the CPU-side ones. The CPU mirrors are at the top of the file (search `private struct PaperUniforms`, `TileUniforms`, `SolidUniforms`, `AntsUniforms`, `VectorOverlayUniforms`). If you add a field, add it to **both** with the same memory layout — Metal will silently misread mismatched padding.
- **Default mask** — `Canvas.defaultMaskTexture` ([Canvas.swift:44](../../Sources/Inkwell/Canvas.swift#L44)) is a 1×1 white `.r8Unorm` shared by all unmasked layers. Lazily created.
- **View transform** is passed in as a `simd_float4x4` per frame; built by `ViewTransform.clipTransform(viewBoundsPt:viewDrawablePx:)`. See [`COORDINATES.md`](COORDINATES.md).

---

## Where the brush engine fits in (it doesn't, here)

Brush stamps do **not** go through `CanvasRenderer`. They use a separate `StampRenderer` ([StampRenderer.swift](../../Sources/Inkwell/StampRenderer.swift)) that opens its own render passes against tile textures, between frames. By the time the compositor runs, the stamp work is already in the tile.

Same story for vector stroke rasterization — `StrokeRibbonRenderer` ([StrokeRibbonRenderer.swift](../../Sources/Inkwell/StrokeRibbonRenderer.swift)) writes into the vector layer's tiles. The compositor reads the result.

See [`STROKES.md`](STROKES.md) for that pipeline.

---

## Known gaps

- **Pass-through groups only.** Group `blendMode` and `opacity` multiply through to children, but the group does not composite into an isolated buffer. Photoshop-style "isolated group blend" is a Phase 4 follow-up.
- **No layer caching.** Every frame re-runs the whole composite from the bottom up. There's no "the bottom 3 layers haven't changed, cache their composite" optimization. Today this is fine because tile-quad draws are cheap; if a document grows past, say, 50 layers it'd be worth profiling.
- **Drawable pixel format is hardcoded** `bgra8Unorm` ([CanvasView.swift](../../Sources/Inkwell/CanvasView.swift), `colorPixelFormat`). HDR / wide-gamut presentation is a Display P3 follow-up (decision 6).
- **Vector debug overlay is debug-only.** Cyan polyline + orange nodes are not styled for production; expect to redo the visual when this becomes a user-facing feature.
