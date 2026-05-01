# Coordinate systems

Four spaces, several Y-axis conventions, and one matrix that maps directly from canvas pixels to Metal clip space. The bugs hidden here are vicious — read this before you debug a "why is my pixel one row off" issue.

For the *why* of cursor-anchored zoom and a single transform matrix, see [`arch/RENDERING.md`](../arch/RENDERING.md) decision 13.

---

## TL;DR — the four spaces

| Space | Origin | Y direction | Units | Used by |
|---|---|---|---|---|
| **Canvas pixels** | bottom-left of canvas | up | pixels | Layer state, brush dispatch, selection bytes, file format |
| **Tile-local pixels** | bottom-left of one 256×256 tile | up | pixels | Stamp shader internals (Metal NDC convention) |
| **Tile data bytes** | top of tile region | down | bytes | `BitmapLayer.readTileBytes`, `tiles.bin` |
| **Window points** | view top-left (or bottom-left, depending on flippedness) | depends | points | Mouse / stylus events from AppKit |
| **Drawable pixels** | view bottom-left | up | physical pixels | MTKView render target, Metal NDC-space input |
| **Metal NDC** | view center | up | normalized [−1, 1] | Vertex shader output |

This is more spaces than most apps because we composite to a Metal drawable while consuming AppKit events and CoreGraphics-style image bytes.

---

## Conversion paths

```
NSEvent.locationInWindow (window points, AppKit)
  ↓ NSView.convert(_:from:nil)        (still window points, view-local)
  ↓ ViewTransform.windowToCanvas(_:)  (canvas pixels)
  ↓ ... brush / selection / hit-test logic runs in canvas pixels ...
  ↓ vertex shader uses canvasPos directly via clipTransform matrix
  ↓ Metal NDC for the GPU
```

Once you cross into "canvas pixels" via `ViewTransform.windowToCanvas`, **everything downstream stays there** until the vertex shader builds NDC for the final blit. Brush sizes are canvas pixels. Tile coords are canvas-pixel-aligned. Stroke samples carry canvas-pixel positions. The selection bytes are a `width × height` grid in canvas pixels.

---

## `ViewTransform`

[ViewTransform.swift](../../Sources/Inkwell/ViewTransform.swift)

```swift
struct ViewTransform {
    var scale: CGFloat = 1.0       // window points per canvas pixel
    var rotation: CGFloat = 0.0    // CCW radians
    var offset: CGPoint = .zero    // canvas (0,0) position in window points
}
```

The forward map: `window_pt = R(canvas_pt) · scale + offset`, where `R` rotates by `rotation`.

Three families of method:
- **`windowToCanvas` / `canvasToWindow`** — point conversions.
- **`zoom(by:at:)` / `setScale(_:anchor:)` / `rotate(by:at:)` / `setRotation(_:anchor:)`** — mutate the transform while keeping a window point pinned to the same canvas point. This is how cursor-anchored zoom and rotate work.
- **`clipTransform(viewBoundsPt:viewDrawablePx:)`** — build a `simd_float4x4` that maps canvas-pixel coords directly to Metal clip space (NDC), accounting for the view's points-to-pixels scale (Retina handling).

The clip transform is built **once per frame** in `CanvasView.draw(in:)` and passed to every pipeline. Vertex shaders just multiply by it; they never see scale / rotation / offset separately.

---

## Y-axis conventions: where they conflict

This is where bugs live. Three different Y conventions show up in the same codebase, all correct in their own context.

### 1. Canvas pixels: Y goes **up**

The canvas pixel `(0, 0)` is the bottom-left of the canvas. A brush stamp at `canvasPoint = (x, y)` with `y` increasing means up. This matches Metal NDC.

But — when the cursor is reported as "X: 100, Y: 50" in the status bar, that's still the canvas Y, increasing **upward** from the bottom of the canvas. (If you'd prefer Y to feel "downward" like screen coords, that's a UI choice — not what we do today.)

### 2. Tile data bytes: row 0 is the **top**

Tile bytes (the `Data` from `BitmapLayer.readTileBytes`) are laid out top-down: byte offset 0 is the highest-canvas-Y row of the tile region.

So for a tile at `coord = (3, 4)` covering canvas y ∈ [1024, 1280):
- Tile row 0 corresponds to canvas-y = 1279.
- Tile row 255 corresponds to canvas-y = 1024.

Inverted from the canvas-pixel convention. `BitmapLayer.applyClearWithinSelection` ([BitmapLayer.swift:190](../../Sources/Inkwell/BitmapLayer.swift#L190)) walks `for py in 0..<tileH` and computes `canvasY = originY + (Canvas.tileSize - 1 - py)`. Pay attention to the `tileSize - 1 - py` flip whenever you read or write tile bytes.

### 3. Selection bytes: row 0 is the **top**, indexed by canvas-y

`Selection.bytes` is `width × height` of `UInt8`. Row 0 corresponds to canvas-y = `height - 1`, row `height - 1` corresponds to canvas-y = 0. Same convention as tile bytes (top-down), but with the canvas as a whole rather than a tile.

In the stamp shader, the selection texture is sampled with `selUV = (canvasPos.x / canvasW, 1.0 - canvasPos.y / canvasH)` to compensate. See `stamp_vertex` in [StampRenderer.swift](../../Sources/Inkwell/StampRenderer.swift).

### 4. Tile shader internals: tile-local Y goes **up**

Inside the stamp / ribbon shader, `stampCenterTilePixels = canvasCenter - tileOrigin` puts the stamp at a tile-local position with Y increasing up (Metal NDC convention). The shader then does `(tilePos / tileSize) * 2 - 1` to map to NDC.

Because the tile's render target is the underlying `MTLTexture` (whose row 0 is the top of the texture in Metal-pixel space), and Metal NDC has Y pointing up, the texture row at NDC y = +1 is the texture's row 0.

Net result for downstream code: when you ask `BitmapLayer.tile(at: coord)` and inspect the texture in a Metal debugger, the top of the texture is the **top** of the canvas-pixel region the tile covers — i.e., the highest canvas Y. That matches the tile-bytes convention.

---

## Flipped vs non-flipped `NSView`

`NSView.isFlipped`:
- `false` (default) — y axis goes up; origin at bottom-left.
- `true` — y axis goes down; origin at top-left.

This affects:
- **Mouse coords inside the view.** `event.locationInWindow` is window-coords (origin bottom-left always). After `convert(_:from:nil)` the result respects the view's `isFlipped`.
- **Drawing.** The view's draw rect is in flipped coords if `isFlipped == true`.
- **Subview layout via autolayout.** Frame y values flip.

In Inkwell:
- **`CanvasView`** is **non-flipped** (default). Mouse y increases upward; we feed straight into `windowToCanvas`. `isFlipped` returns false.
- **`LeftPaneView`, `LayerPanelView`, `BrushInspectorView`** override `isFlipped` to return **true**. Subviews stack top-down naturally — matches scrollable-list intuition.
- **`FlippedView`** ([DocumentWindowController.swift](../../Sources/Inkwell/DocumentWindowController.swift)) is a tiny private NSView subclass with `isFlipped = true`, used as the document view inside the side-pane scroll views so short content anchors at the top instead of the bottom.
- **`ColorWheelView`** is **non-flipped** so trig works naturally (atan2, etc.).
- **`ToolsGridView`** is **flipped** so the flow grid lays out top-to-bottom-left-to-right.

If you find yourself confused about which way Y goes in a given view, check `isFlipped`. The view's draw rect, mouse y, and subview layout all change together.

---

## `clipTransform` step by step

This is the matrix every vertex shader uses to convert canvas pixels into NDC. From `ViewTransform.clipTransform`:

```
// Step 1: canvas → window points
window_pt.x = (cx·cosθ − cy·sinθ) · s + ox
window_pt.y = (cx·sinθ + cy·cosθ) · s + oy

// Step 2: window points → drawable pixels (Retina handling)
drawable_px = pxPerPt · window_pt
   where pxPerPt = drawableSize / boundsSize  (typically 2 on Retina)

// Step 3: drawable pixels → NDC ([0..drawable] → [−1..+1])
clip = 2·drawable_px / drawableSize − 1
```

Combining all three:
```
let kx = 2 · pxPerPt / drawableW
let ky = 2 · pxPerPt / drawableH

clip.x = kx·s·cosθ · cx + (−kx·s·sinθ) · cy + (kx·ox − 1)
clip.y = ky·s·sinθ · cx + (ky·s·cosθ) · cy + (ky·oy − 1)
```

That's the 4×4 matrix returned. It bakes in: zoom, rotation, pan offset, points-vs-pixels scale, and the NDC remap. Vertex shaders multiply `transform · float4(canvasPos, 0, 1)` and that's it.

Note: Metal NDC has y-up. AppKit window coords for a non-flipped view are also y-up. So we're not flipping y in the matrix. (If `CanvasView` were flipped, we'd need to negate `ky` to compensate. Don't change `isFlipped` on `CanvasView` without re-deriving this matrix.)

---

## Cursor-anchored zoom: why `windowToCanvas` runs before mutating scale

`zoom(by:at:)`, `setScale(_:anchor:)`, `rotate(by:at:)`, `setRotation(_:anchor:)` all do the same dance:

```swift
let canvasPoint = windowToCanvas(windowPoint)   // capture canvas point under cursor *before* mutating
scale = ...                                      // (or rotation = ...)
anchorCanvasPoint(canvasPoint, at: windowPoint)  // adjust offset so canvasPoint maps to windowPoint again
```

The canvas point under the cursor is invariant across the operation. `anchorCanvasPoint` solves for the new offset that keeps it pinned. This is what makes pinch-zoom feel right: the spot under your fingers stays under your fingers.

---

## Mid-stroke navigation

When the user pans / zooms / rotates while a stroke is in flight, the in-flight stylus sample buffer is in canvas pixels — independent of view transform. So mid-stroke navigation just works: the next sample's `windowToCanvas` will use the new transform and produce the correct canvas-pixel position, and the stroke continues without distortion.

This is documented in architecture decision 13 ([`arch/RENDERING.md`](../arch/RENDERING.md)) as "mid-stroke pause-and-resume" but the actual code today is even simpler than the decision describes — there's no explicit pause; the stroke buffer is canvas-space throughout, and the transform-mutating gestures (pinch, scroll-zoom, rotate-drag) are handled in their own event paths that don't disturb the brush emitter.

---

## Common pitfalls

- **Storing window-space coords in a stroke sample.** Every stroke sample is canvas pixels. If you find a `CGPoint` in stroke code that came from `event.locationInWindow` without going through `sampleFor(event:)`, that's a bug.
- **Mixing tile-row and canvas-y.** Always go through `BitmapLayer.canvasRect(for: coord)` to get the canvas-space bounds of a tile. Don't assume "tile row 0 is the top of the canvas-y range" without reading the tile-bytes-vs-canvas-y note above.
- **Forgetting Retina.** `event.locationInWindow` is in **points**. `MTKView.drawableSize` is in **physical pixels**. They're not the same on Retina displays. `clipTransform` handles this; if you're doing your own pixel math somewhere, account for the points-to-pixels scale.
- **Clip-space y direction in shaders.** Metal NDC y is up. If a shader looks like it draws upside-down, double-check whether your input is screen-coords (y-down) or canvas-coords (y-up). The fix usually goes in the texture-UV calculation, not the vertex position.
- **Hit-testing inside flipped views.** A child view's bounds in a flipped parent has its own y-axis depending on its own `isFlipped`. If you're computing hit-test rects, derive them in the child's coordinate space, not the parent's.
- **Cursor stays stale on zoom.** The brush cursor is regenerated only when the system asks for it — typically on mouse-moved tracking events. After programmatic zoom the cursor lags. `CanvasView.invalidateBrushCursor()` is called from every zoom mutation site for this reason. If you add a new zoom path, call it.
