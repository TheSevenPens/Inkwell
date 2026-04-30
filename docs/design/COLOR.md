# Color

What ships today vs. what the architecture committed to. The honest version: we ship **sRGB throughout** while [`arch/RENDERING.md`](../arch/RENDERING.md) decision 6 commits to **Display P3 + 16-bit + premultiplied + gamma-space blends**. Premultiplied and gamma-space are real; P3 and 16-bit are deferred.

If you're wondering why the brush wheel looks fine but a deep stack of translucent strokes shows banding, this file explains it.

---

## TL;DR

| What we ship | What the architecture commits to |
|---|---|
| `.rgba8Unorm` tiles (8 bits per channel) | 16 bits per channel |
| sRGB working space throughout | Display P3 working space |
| Premultiplied alpha ✅ | Premultiplied alpha |
| Gamma-space blend math ✅ | Gamma-space blend math |
| Drawable: `bgra8Unorm` | (whatever the platform asks; with a profile tag) |
| Export: PNG / JPEG / PSD untagged or sRGB-tagged | P3-tagged with sRGB gamut-mapping option |
| Color profile import: assumed sRGB, not converted | Read embedded profile; convert to working space |

The deferred items are tracked in [`FUTURES.md`](../FUTURES.md) under "Phase 9 Pass 2 — Display P3 working color space + gamut mapping."

---

## `ColorRGBA`: the canonical color type

[Brush.swift](../../Sources/Inkwell/Brush.swift), top of file:

```swift
struct ColorRGBA: Codable, Equatable {
    var r: CGFloat   // sRGB-encoded, 0..1
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat
}
```

The class doc explicitly says *"Treats components as already-sRGB-encoded for Phase 3."* Every place that uses `ColorRGBA` (brushes, swatches, hex input, eyedropper, vector strokes, background layers) treats the components as sRGB.

When converting to / from `NSColor` we always use `NSColor(srgbRed:green:blue:alpha:)`, never the calibrated-RGB constructor. When constructing `CGColor` for Core Graphics use we tag with `CGColorSpace(name: CGColorSpace.sRGB)`.

**`a` is straight, not premultiplied.** Premultiplication happens *just before* writing pixels — the brush stamp shader emits premultiplied output, but `ColorRGBA` itself is straight RGBA so the inspector / hex input / color wheel can manipulate the components without divide-by-alpha headaches.

---

## Premultiplied alpha: the invariant

Inside the engine, **every pixel is premultiplied** the moment it lives in a tile or render target.

- `BitmapLayer` tile bytes are `.rgba8Unorm` premultiplied (alpha-premultiplied as `CGImageAlphaInfo.premultipliedLast` on the `CGContext` we use to flatten).
- The stamp fragment shader emits `(color.rgb * a, a)` where `a = tipAlpha * stampAlpha * selectionMask`.
- The tile composite shader's blend math operates on premultiplied source and dst, un-premultiplying internally only to compute non-Normal blend modes (Multiply / Screen / Overlay) and re-premultiplying on output.
- The vector ribbon shader output is premultiplied: `(color.rgb * a, a)` where `a = coverage * opacity`.
- The flatten path (`Canvas.flattenToCGImage`) builds a premultiplied-last `CGContext` and the result is sRGB-tagged.

**Where straight color leaks into the codebase**: `ColorRGBA` storage, `NSColor` round-trips through the system color picker, and the eyedropper output. The eyedropper is the one place we have to manually un-premultiply on read:

```swift
// CanvasView.sampleColorAtCanvasPoint
let a = CGFloat(pixel[3]) / 255.0
let r = min(1.0, CGFloat(pixel[0]) / 255.0 / a)  // un-premultiply
let g = min(1.0, CGFloat(pixel[1]) / 255.0 / a)
let b = min(1.0, CGFloat(pixel[2]) / 255.0 / a)
return ColorRGBA(r: r, g: g, b: b, a: 1.0)
```

If you find code that writes `RGB` without multiplying by `A`, or reads `RGB` from a tile without dividing by `A`, that's a bug.

---

## Gamma-space blending

Architecture decision 6 chose gamma-space (i.e. operate on sRGB-encoded values directly, without linearizing) for v1, matching Photoshop's behavior. This is mathematically not "physically correct," but it's what users trained on Photoshop expect — and it's what we do.

The blend shader does NOT linearize before blending. From `tile_fragment` ([CanvasRenderer.swift](../../Sources/Inkwell/CanvasRenderer.swift)):

```metal
float4 src = tile.sample(smp, in.uv);   // already gamma-encoded
float4 dst [[color(0)]];                 // already gamma-encoded
// ... un-premultiply, blend in gamma space, re-premultiply ...
```

Linear-light blending is the "linear blending option" the architecture mentions for a future per-document toggle.

**Beware:** Metal's `.rgba8Unorm_srgb` pixel format would automatically linearize on read and gamma-encode on write. We deliberately use plain `.rgba8Unorm` so the texels are the raw sRGB bytes; the shader sees them as the user intends, not as their linearized form.

---

## The color flow through a brush stroke

```
User picks color in inspector / wheel / swatch / hex
   ↓
ColorRGBA stored on BrushPalette.activeBrush.color  (sRGB, straight)
   ↓
mouseDragged → StylusSample → StrokeEmitter → dispatchSample
   ↓
StampDispatch.color = brush.color.simd  (Float4, sRGB, straight)
   ↓
StampRenderer.applyStamp uniforms include the color
   ↓
stamp_fragment computes alpha = tip * stamp * selection,
                  outputs (color.rgb * alpha, alpha)  (premultiplied, sRGB)
   ↓
Written into tile texture (.rgba8Unorm, premultiplied, sRGB)
   ↓
Next frame, tile_fragment reads the tile texture,
            blends with destination via framebuffer fetch,
            outputs final premultiplied color to the drawable
   ↓
MTKView presents (drawable format .bgra8Unorm)
   ↓
macOS color-management presents to the display
```

No conversions anywhere along that path. The "color" stays sRGB-encoded the whole way.

---

## The color wheel

[ColorWheelView.swift](../../Sources/Inkwell/ColorWheelView.swift) does explicit sRGB math. It conducts:

- **Hue ring** — Core Graphics conic gradient with sRGB stops at 6 hues + closing red. Drawn via `CGContextDrawConicGradient` (the C function; the Swift overlay doesn't expose it on this SDK).
- **SV square** — fill the square with the pure hue at full saturation/brightness, then composite a horizontal gradient (white → clear) and a vertical gradient (clear → black). The arithmetic happens in sRGB; the result on screen looks right because sRGB is the working space.
- **HSV → RGB** is computed manually (`ColorWheelView.hsvToRGB`) and treated as sRGB. We deliberately avoid `NSColor(calibratedHue:saturation:brightness:alpha:)` because it returns calibrated-RGB which converts later.
- **Setting the wheel from an external color** uses `NSColor(srgbRed:green:blue:alpha:).getHue(...)` so the wheel parses the same sRGB the brush stores.

The wheel binds bidirectionally to `BrushPalette.shared.activeBrush.color` via `LeftPaneView`. Changes from any other source (swatches, hex, eyedropper) push back into the wheel via `refreshColorWheel`.

---

## The "paper color" — a built-in canvas tint

`Canvas.paperColor: SIMD4<Float>` ([Canvas.swift:17](../../Sources/Inkwell/Canvas.swift#L17)):
```swift
static let paperColor: SIMD4<Float> = SIMD4(0.96, 0.95, 0.92, 1.0)
```

A warm cream. It's drawn by the paper pipeline as a canvas-sized quad before any layer composites. So an empty canvas is **never** white — it's a paper-stock tone.

This interacts with `BackgroundLayer` (see [`TILES.md`](TILES.md)): a Background Layer renders *on top of* paper. With Background opacity = 1 and Normal blend (the default), it covers paper completely. With opacity < 1 or non-Normal, paper bleeds through. The user manual carries an explicit caveat about this; the cleaner end-state (drop the implicit paper) is in [`FUTURES.md`](../FUTURES.md).

---

## Selection masks, layer masks: also `.r8Unorm`

Single-channel coverage textures, treated as 0..1 alpha. Not "color" exactly, but they participate in the per-pixel blend math: every brush stamp's output alpha is multiplied by the selection sample, and every layer composite is multiplied by the mask sample.

These are linear single-channel values — there's no gamma curve on a coverage texture. See [`TILES.md`](TILES.md) for the "absent mask tile = white" convention.

---

## Export and import: where sRGB lives in files

### Export

- **PNG** ([Canvas.encodePNGData](../../Sources/Inkwell/Canvas.swift)): premultipliedLast, sRGB color space. Tagged sRGB by ImageIO.
- **JPEG** ([Canvas.encodeJPEGData](../../Sources/Inkwell/Canvas.swift)): noneSkipLast, sRGB color space. Flattened against an opaque background.
- **PSD** ([PSDFormat.swift](../../Sources/Inkwell/PSDFormat.swift), `Canvas.encodePSDData`): premultipliedLast, sRGB color space, 8 bits per channel.

So output files leave Inkwell tagged sRGB and consumers (browsers, other apps) display them correctly on any color-managed surface. **No P3 export** today; that's a Phase 9 Pass 2 item.

### Import

- **PNG / JPEG** ([Canvas.loadPNG](../../Sources/Inkwell/Canvas.swift)): drawn into a `CGContext` with sRGB color space. ColorSync handles any source profile → sRGB conversion automatically.
- **PSD** ([PSDFormat.swift](../../Sources/Inkwell/PSDFormat.swift)): same, sRGB output `CGContext`.

Imports lose source-profile precision, but the conversion is sRGB-correct.

---

## NSColor round-trips: a footgun

`NSColor` has multiple constructors (`init(calibratedRed:...)`, `init(deviceRed:...)`, `init(srgbRed:...)`) and getters that return components in the color's *current* space.

Inkwell convention: **always use `srgbRed:` constructors and check `usingColorSpace(.sRGB)` on round-trip**. The system color picker (NSColorPanel) returns whatever space the user's last picker mode used — could be calibrated, P3, or sRGB. Always explicitly project to sRGB:

```swift
let ns = sender.color.usingColorSpace(.sRGB) ?? sender.color
let rgba = ColorRGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: 1)
```

(Pattern from `BrushInspectorView.colorChanged`, `LayerPanelView.bgColorChanged`.) Skipping the `usingColorSpace` projection causes "the color drifted slightly between picking and painting" bugs.

---

## Hex input

The brush inspector's hex field accepts `#RRGGBB` and `#RGB`. Implementation ([BrushInspectorView.swift](../../Sources/Inkwell/BrushInspectorView.swift), search `parseHex`): parse the bytes, scale to 0..1, build a `ColorRGBA`. Components go directly into the sRGB-encoded slots — no gamma conversion. So `#FF0000` is "sRGB pure red."

On bad input, the field reverts to the previous valid hex.

---

## Where conversions would happen if we promoted to P3

Today: nowhere. If we wired up architecture decision 6:

- Tile pixel format: `.rgba16Float` or `.rgba16Unorm` (P3-encoded or linear-light) instead of `.rgba8Unorm`.
- Stamp / ribbon / tile shaders update to read/write 16-bit; un-premul / re-premul math the same.
- Drawable presentation: tag it P3; macOS color-manages to whatever display.
- Color picker / hex input: still in sRGB notation for user familiarity, but project into P3 on the way to `ColorRGBA`. Or keep `ColorRGBA` as P3-encoded internally and document the change.
- Import path: read the embedded profile, convert to P3 via ColorSync.
- Export path: tag the output P3 by default, offer sRGB with gamut mapping.

The single hard-coded line that pins us to sRGB is `let cs = CGColorSpace(name: CGColorSpace.sRGB)!` repeated throughout — track that down across the codebase and you'll find every conversion site.

---

## Known gaps

- **8-bit precision visible in deep stacks.** The architecture commits to 16-bit; we ship 8-bit. Translucent overpainting on the same tile shows posterization beyond ~50 layers. Real but rare in normal use.
- **No Display P3 internally.** Brush color picks are sRGB; rendering is sRGB; export is sRGB. P3 displays still show the sRGB content correctly; they just can't reach the wider gamut. Tracked.
- **No gamut mapping anywhere.** Because we stay in sRGB, we never produce out-of-sRGB values to map. Becomes relevant only when (if) we adopt P3 internally.
- **`Canvas.paperColor` is hardcoded.** Not user-configurable; not exported as document metadata. The cleaner end-state is to drop the implicit paper and have Background Layers handle the whole concept — see [`FUTURES.md`](../FUTURES.md).
- **No 16-bit / 32-bit float PSD export.** Architecture decision 14 says "user chooses 8 / 16 / 32-bit on export, default 16-bit"; today we only write 8-bit.
- **No linear-light blending option.** Architecture decision 6 leaves this open as a future per-document toggle. Today: gamma-space only.
