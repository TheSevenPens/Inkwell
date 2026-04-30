# Tiles & layer storage

How Inkwell stores layer pixel data on the GPU. This is the foundation everything else sits on — the brush engine writes into tiles, the compositor reads from tiles, undo snapshots tiles, save/load streams tiles. Read this first.

For the *why* of tile-based storage, see [`arch/RENDERING.md`](../arch/RENDERING.md) decision 4. This file documents the *how* as it actually exists today.

---

## TL;DR

- A **canvas** (e.g. 1080×1920 px) is divided into **256×256** tiles.
- Each layer holds a **sparse `[TileCoord: MTLTexture]`** dictionary: only tiles that have been written get allocated.
- Tiles are **GPU-resident** (`storageMode = .shared` on Apple Silicon → CPU and GPU read the same memory).
- Bitmap-layer tiles: **`.rgba8Unorm`, premultiplied**.
- Mask tiles: **`.r8Unorm`** (single-channel coverage). Absent ⇒ fully white (visible).
- Vector layers cache their rasterization in **the same tile structure** the bitmap path uses.
- Background layers have **no tiles** — rendered as one canvas-sized quad.

---

## Key types

| Type | File | Role |
|---|---|---|
| `TileCoord` | [Canvas.swift](../../Sources/Inkwell/Canvas.swift) | `(x: Int, y: Int)` value type. Hashable, used as dictionary key. |
| `Canvas.tileSize` | [Canvas.swift:16](../../Sources/Inkwell/Canvas.swift#L16) | Static constant: `256`. |
| `Canvas` | [Canvas.swift](../../Sources/Inkwell/Canvas.swift) | Owns the layer tree, `MTLDevice`, `MTLCommandQueue`, document dimensions. |
| `LayerNode` (protocol) | [LayerNode.swift](../../Sources/Inkwell/LayerNode.swift) | Common attributes: `id`, `name`, `isVisible`, `opacity`, `blendMode`. |
| `CompositableLayer` (protocol) | [LayerNode.swift](../../Sources/Inkwell/LayerNode.swift) | The "I have tiles" interface used by the compositor. Conformers: `BitmapLayer`, `VectorLayer`. |
| `BitmapLayer` | [BitmapLayer.swift](../../Sources/Inkwell/BitmapLayer.swift) | The painted-pixels layer kind. |
| `VectorLayer` | [VectorLayer.swift](../../Sources/Inkwell/VectorLayer.swift) | Authoritative `[VectorStroke]` + cached tile rasterization. |
| `BackgroundLayer` | [BackgroundLayer.swift](../../Sources/Inkwell/BackgroundLayer.swift) | Solid-color, no tiles. Conforms to `LayerNode` only. |
| `GroupLayer` | [GroupLayer.swift](../../Sources/Inkwell/GroupLayer.swift) | Container of child `LayerNode`s. No tiles itself. |
| `LayerMask` | [LayerMask.swift](../../Sources/Inkwell/LayerMask.swift) | Optional mask attached to a `BitmapLayer`. Same tile structure, single-channel. |

---

## Conventions you must not violate

### 1. Row order: tile data is **top-down**

`BitmapLayer.applyClearWithinSelection` ([BitmapLayer.swift:190](../../Sources/Inkwell/BitmapLayer.swift#L190)):
> *"Tile data row 0 = highest canvas-Y row of the tile region."*

So a tile at `coord = (3, 4)` covers canvas pixels `x ∈ [768, 1024)`, `y ∈ [1024, 1280)`. The tile's byte offset 0 is the row at canvas-y = 1279, not 1024. This is non-obvious and is the source of most "Y is upside down" bugs. Read/write paths handle it by walking `tileRow = Canvas.tileSize - 1 - py`.

### 2. Pixels are **premultiplied alpha**

Every tile texture and every byte buffer that flows through the engine treats RGB as already multiplied by alpha. The eyedropper has to *un-premultiply* on read ([CanvasView.swift](../../Sources/Inkwell/CanvasView.swift), search `sampleColorAtCanvasPoint`); the brush stamp shader emits already-premultiplied output. See [`COLOR.md`](COLOR.md) for the full color story.

### 3. Tiles are **GPU-resident**, no upload step

`storageMode = .shared` on Apple Silicon means the same allocation is both CPU- and GPU-addressable. The brush engine writes into a tile texture via a render pass; the compositor reads the same texture via a sampler in the next frame. There is no `replace`-then-upload cycle.

The only places that materialize CPU bytes are: undo snapshots ([`UNDO.md`](UNDO.md)), file save (`tiles.bin`), PSD export, and the eyedropper.

### 4. Absent tiles ≠ allocated-and-zeroed

The dictionary has *no entry* until something writes to that tile. `tile(at:) -> MTLTexture?` returns `nil`; `ensureTile(at:) -> MTLTexture` lazily allocates a zeroed tile and inserts it. The compositor skips coords with `nil` tiles entirely — no wasted draws over empty areas.

### 5. Mask tiles default to **white** (fully visible), not black

`LayerMask.ensureTile` at [LayerMask.swift:46](../../Sources/Inkwell/LayerMask.swift#L46) initializes a freshly-allocated mask tile to all-255 bytes. The convention from `LayerMask`'s top-of-file doc:
> *"An absent tile is fully white (1.0) — i.e., the layer is fully visible at that location."*

So the moment you add a mask to a layer, nothing changes visually; mask painting *removes* visibility. The compositor's default mask binding is a 1×1 white texture (`Canvas.defaultMaskTexture` at [Canvas.swift:44](../../Sources/Inkwell/Canvas.swift#L44)) so the shader doesn't have to branch on "no mask."

---

## The `CompositableLayer` interface

```swift
protocol CompositableLayer: LayerNode {
    var canvasWidth: Int { get }
    var canvasHeight: Int { get }
    var mask: LayerMask? { get }
    func tile(at coord: TileCoord) -> (any MTLTexture)?
    func tilesIntersecting(_ rect: CGRect) -> [TileCoord]
    func canvasRect(for coord: TileCoord) -> CGRect
    func allTiles() -> [(coord: TileCoord, texture: any MTLTexture)]
    func readTileBytes(_ texture: any MTLTexture) -> Data
}
```

This is the contract the compositor and the file format rely on. `BitmapLayer` and `VectorLayer` both implement it; their `mask` getters differ (`BitmapLayer.mask` is settable, `VectorLayer.mask` is hard-coded `nil` in V1).

`BackgroundLayer` does **not** conform — it has no tiles. The compositor handles backgrounds via a separate `RenderLayer.background(_)` case (see [`COMPOSITOR.md`](COMPOSITOR.md)).

---

## Tile coordinate math

```
canvasRect(for: TileCoord(x: cx, y: cy))
    = CGRect(x: cx*256, y: cy*256, width: 256, height: 256)

tilesAcross = ceil(canvasWidth  / 256)
tilesDown   = ceil(canvasHeight / 256)

tilesIntersecting(rect)
    = all (cx, cy) such that canvasRect(cx, cy) overlaps rect,
      clamped to [0..tilesAcross-1] × [0..tilesDown-1]
```

The right- and bottom-edge tiles **physically cover area outside the canvas** (e.g. a 1080-wide canvas has 5 tiles across covering up to x=1280). Bitmap content outside the canvas is alpha=0 because no brush stamp touches it. Background layers use a separate canvas-sized quad to avoid this overhang from showing as solid color.

---

## Lifecycle: who creates and destroys tiles?

```
ensureTile(at:) → allocates if absent, returns existing otherwise
              ↓ called from:
              ├─ StampRenderer.applyStamp    (brush stroke writes)
              ├─ StrokeRibbonRenderer.*      (vector stroke writes)
              ├─ BitmapLayer.applyTileSnapshot  (undo restoring an absent tile to present)
              ├─ LayerMask.ensureTile        (mask painting allocates white-default tile)
              └─ FileFormat (load path)      (rebuilding tiles from tiles.bin bytes)

Tiles are removed by:
              ├─ removeAllTiles()            (Edit → Clear without selection; layer rebuild)
              ├─ replaceWithImage()          (image-transform ops: rotate, flip, resample)
              ├─ applyTileSnapshot()         (undo restoring a present tile to absent)
              └─ Canvas.deleteLayer          (the whole layer goes; ARC frees its tiles)
```

There is no LRU eviction or disk spill yet. Tiles live in unified memory for the lifetime of the layer.

---

## Bitmap vs vector tile populations

**Bitmap layers**: tiles are populated *directly* by stamp dispatches. Each `StampRenderer.applyStamp` ([StampRenderer.swift](../../Sources/Inkwell/StampRenderer.swift)) opens an `MTLRenderCommandEncoder` against the tile, draws a quad with the stamp shader, and the tile texture now has the stamp blended into it. The tile's contents *are* the painted pixels.

**Vector layers**: tiles are a **derived cache** of the rasterized strokes. The authoritative state is `VectorLayer.strokes: [VectorStroke]`. Tiles get repopulated from strokes by `StrokeRibbonRenderer`:
- `appendStroke` — incremental, draws one stroke into the tiles it overlaps.
- `rebuildTiles(coords:)` — clears the given coords and re-renders every overlapping stroke.
- `setStrokes(...)` / `rebuildAllTilesFromStrokes(...)` — full rebuild.

This is why vector strokes can be undone cheaply (snapshot the strokes array; rebuild tiles from it) and why their tile cache is **not persisted in `tiles.bin`** — strokes are authoritative, the cache is regenerated on load.

---

## Mask tiles attach to a `BitmapLayer`

Each `BitmapLayer` has an optional `mask: LayerMask?`. When painting on a mask, brush input is routed to the mask's tile grid via `StampRenderer.applyMaskStamp` instead of `applyStamp`. The mask tile's pixel format is `.r8Unorm` (single channel = coverage 0..1), and the stamp shader's `mask_stamp_fragment` does the blending against the existing mask value with framebuffer fetch.

At composite time, the tile fragment shader multiplies its sampled tile color by the mask sample at the same UV. Layers without a mask bind `Canvas.defaultMaskTexture` (a shared 1×1 white) so the multiply is a no-op.

The "Edit: [Layer | Mask]" toggle in the right pane (`Canvas.editingMask`) selects which target the brush writes to.

---

## Snapshot / restore (the undo path)

```swift
struct TileSnapshot {
    var presentTiles: [TileCoord: Data]   // tile bytes to restore
    var absentTiles: Set<TileCoord>       // tiles that should be removed
}
```

This is on [BitmapLayer.swift](../../Sources/Inkwell/BitmapLayer.swift) and mirrored on `LayerMask`. Two halves:
- **`presentTiles`** captures the bytes of tiles that existed before a mutation.
- **`absentTiles`** captures coords that *did not* exist before a mutation but might exist after.

`snapshotTiles(_ coords:)` reads bytes for each coord that has a tile, and lists the rest as absent. `applyTileSnapshot(_:)` restores both directions: write bytes to present coords (allocating if needed), and remove absent coords from the dictionary.

The undo system stores `before`/`after` snapshots and can apply either. See [`UNDO.md`](UNDO.md) for the full pattern.

---

## Sparseness: where the savings come in

A 4096×4096 canvas with one bitmap layer painted in a 200-pixel scribble allocates **at most a handful of 256×256 tiles** — typically 1–4. The empty `(canvas - scribble)` area costs zero. Compare against a full-bitmap layer model where every layer always allocates `4096*4096*4 = 64 MB` even when blank.

Memory cost per tile:
- Bitmap layer (`.rgba8Unorm` 256×256): **256 KB**
- Mask (`.r8Unorm` 256×256): **64 KB**

For typical illustration documents the tile count stays in the hundreds; total tile memory is comfortably bounded.

---

## Background layers don't fit this model

A `BackgroundLayer` is a `LayerNode` but **not** a `CompositableLayer`. It stores just a `ColorRGBA` and has no tiles. The compositor handles it via a separate `RenderLayer.background(_)` case (see [`COMPOSITOR.md`](COMPOSITOR.md)) by drawing a single canvas-sized quad with a `solidPipeline`. This is intentionally not unified with the tile path — synthesizing N tiles of solid color would be wasteful and extends past the canvas at the right/bottom edge tiles.

---

## Where to look in the code

- **`BitmapLayer`** ([BitmapLayer.swift](../../Sources/Inkwell/BitmapLayer.swift)) — the canonical implementation. Read this first.
- **`VectorLayer`** ([VectorLayer.swift](../../Sources/Inkwell/VectorLayer.swift)) — same `CompositableLayer` interface, but with the "tiles are a derived cache" twist.
- **`LayerMask`** ([LayerMask.swift](../../Sources/Inkwell/LayerMask.swift)) — same shape as `BitmapLayer` but `.r8Unorm` and white-default.
- **`Canvas.walkVisibleRenderables`** ([Canvas.swift](../../Sources/Inkwell/Canvas.swift)) — the iteration order the compositor uses. Yields a `RenderLayer` enum case per visible leaf.

---

## Known gaps

- **No disk spill / LRU eviction.** The architecture's tile cache is designed to add this; today it doesn't. Long sessions with very large documents will eventually OOM. Tracked in [`FUTURES.md`](../FUTURES.md).
- **No 16-bit precision.** Architecture decision 6 commits to 16-bit per channel for the working space; today we ship `.rgba8Unorm` everywhere. Visible posterization in deep stacks.
- **No mid-stroke tile pre-allocation strategy.** A stroke that crosses into a previously-empty region calls `ensureTile` per stamp; first allocation is in-line. At 300Hz with sparse stamps this hasn't shown up as a stall, but it's not optimized.
- **Vector tile cache invalidation is coarse.** `rebuildTiles(coords:)` clears the given coords and re-rasterizes every overlapping stroke. Sufficient for the current undo and eraser paths; not optimized for "edit one stroke and rebuild only what changed."
