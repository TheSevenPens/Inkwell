# Threading model

Concurrency contract for contributors: what runs on which thread *today*, what the architecture commits to, and which patterns are safe vs. dangerous.

## Honest framing

[`arch/CONCURRENCY.md`](arch/CONCURRENCY.md) decision 8 commits to a four-actor model: **main + stroke + GPU + autosave**. **Today the implementation is much simpler** — almost everything happens on the main thread, the GPU runs asynchronously as Metal manages, and autosave goes through `NSDocument`'s standard background save path.

The dedicated **stroke thread doesn't exist yet**. Stroke processing, stamp rasterization, and undo capture all run on main. The architecture invariant ("only one thread mutates the document") is preserved trivially because there's only one mutating thread.

When the stroke thread lands, this doc gets the contract; for now it captures the shipping reality plus the rules new code must follow so the future split is easy.

## Today: who runs where

| Work | Thread | Notes |
|---|---|---|
| `NSEvent` reception (mouse / stylus / tablet / proximity) | **Main** | AppKit delivers events on main. |
| `CanvasView.mouseDown/Dragged/Up/tabletPoint` | **Main** | Drives the brush emitters synchronously. |
| `StrokeEmitter` / `VectorStrokeBuilder` densification | **Main** | Catmull-Rom math runs in-line. |
| `StampRenderer.applyStamp` (encoder + draw + commit) | **Main** | Per-event command-buffer batch from the input handler. |
| `StrokeRibbonRenderer.drawCapsule` | **Main** | Same pattern. |
| Tile texture allocation (`ensureTile`) | **Main** | Lazy on first write. |
| Undo capture (`registerLayerStrokeUndo`, etc.) | **Main** | At gesture commit. |
| Compositor `CanvasRenderer.render` | **Main** (CPU side) → **GPU** | `MTKView.draw(in:)` callback runs on main; the encoded work runs asynchronously on the GPU. |
| Autosave / save | **Background** | `NSDocument` schedules autosave on a background queue; we participate via standard `fileWrapper(ofType:)`. |
| `Document.read(from:ofType:)` (file open) | **Main** | NSDocument calls this on the main queue. |
| Timer ticks (airbrush, marching-ants) | **Main** | `Timer.scheduledTimer` posts to the main runloop. |

So effectively two threads matter to most contributors:
- **Main** — everything you'll touch.
- **GPU** — `MTLCommandBuffer.commit()` returns immediately; the GPU consumes the buffer when it's ready.

## Snapshot boundaries and ownership

### Mutation ownership

The document tree, layer list, and tile cache all have **a single writer (main)**. Don't introduce concurrent writers without a discussion that updates the architecture decision.

This includes:
- `Canvas.rootLayers`
- `Canvas.activeLayerId`, `Canvas.editingMask`, `Canvas.selection`
- `BitmapLayer.tiles` / `VectorLayer.tiles` / `LayerMask.tiles`
- `VectorLayer.strokes`
- `BackgroundLayer.color`

### GPU read boundaries

The GPU reads tile textures via samplers and via framebuffer fetch. The reads happen "later" (whenever the GPU consumes the command buffer). On Apple Silicon's unified memory, the same allocation is CPU- and GPU-addressable, so there's no upload step.

Synchronization is implicit and per-command-buffer:
1. Stroke event arrives on main.
2. Main encodes a render pass that writes into tile texture T → commits the buffer.
3. Main next frame encodes a compositor pass that reads tile texture T → commits.
4. Metal serializes the dependency: the read can't begin before the write completes.

This works **only if the writes and reads are encoded in the same `MTLCommandQueue`**. Inkwell uses `Canvas.commandQueue` everywhere; respect that.

If you need finer-grained synchronization (e.g. partial writes you want to read mid-frame), use `MTLEvent` or `MTLFence`. We don't use either today; if you reach for them, document the reason in the touched file.

## Concurrency primitives in use

- **`NSDocument.undoManager`** (an `NSUndoManager`). Coalesces registered undos within an event-loop turn into one step. Already correct from main; not safe from background.
- **`Timer`** for airbrush emission and marching-ants animation. Scheduled on the main runloop.
- **`DispatchQueue.main.async`** in a few places where we need to deferred a callback by one runloop turn. Sparse.

What we **don't** use:
- **Actors.** No `actor` types in the codebase. Architecture decision 8 says actors are reserved for high-level coordination once the stroke thread exists; latency-critical inner loops use serial dispatch and unfair locks.
- **`@MainActor` annotations.** None. Adding them now would force every call site to become `await`-aware without a clear benefit.
- **Reader-writer locks.** Snapshot-based reads are the planned model; today there's only one thread reading and writing, so locks aren't needed.
- **`Task` / `async let` / structured concurrency.** Not yet. Adding it is fine for new I/O-heavy work (e.g. PSD codec), but stroke and compositor paths stay synchronous.

## Safe patterns

✅ **Synchronous mutation from a `mouseDragged` handler**:
```swift
override func mouseDragged(with event: NSEvent) {
    let sample = sampleFor(event: event)
    stampRenderer?.beginBatch()
    emitter?.continueTo(sample)
    stampRenderer?.commitBatch()
}
```
Single thread, single writer. No thread-safety concerns.

✅ **Reading model state from a redraw callback**:
```swift
func draw(in view: MTKView) {
    canvas.walkVisibleRenderables { kind, _, _ in … }
}
```
Same thread as mutators; nothing changes underneath you.

✅ **Posting work to main from a background completion**:
```swift
DispatchQueue.main.async { [weak self] in
    self?.canvas.notifyChanged()
}
```
This is fine; just don't reach into the model from the background side.

✅ **GPU work submitted from main**:
```swift
let cb = commandQueue.makeCommandBuffer()
// encode
cb.commit()
// returns immediately; don't wait
```
Standard Metal pattern. `cb.waitUntilCompleted()` is a foot-gun — don't use it on main except in narrowly scoped tooling code.

## Unsafe patterns

❌ **Mutating the document from a background queue**:
```swift
DispatchQueue.global().async {
    self.canvas.activeBitmapLayer?.removeAllTiles()  // race vs. the next compositor frame
}
```
Don't. Even though there's only one writer today, code in this shape becomes a race the moment the stroke thread lands. Always post mutations to main.

❌ **Reading tile bytes during an encode**:
```swift
let bytes = layer.readTileBytes(tex)  // CPU read
encoder.setFragmentTexture(tex, …)    // GPU access pending
```
On unified memory this isn't a *correctness* issue — `MTLTexture.getBytes` waits for outstanding GPU writes — but `getBytes` will stall main if the GPU is still writing. Avoid in latency-sensitive paths. The undo snapshot path (which reads bytes at gesture commit) is intentional and accepts the stall.

❌ **Calling `commandBuffer.waitUntilCompleted()` on main during a stroke**:
```swift
cb.commit()
cb.waitUntilCompleted()  // blocks the main thread, kills stroke latency
```
The stroke pipeline relies on commits returning immediately. If you find yourself wanting to wait, you probably want to encode the next dependent work into the *same* buffer or use an `MTLEvent`.

❌ **Adding `@MainActor` to a model type**:
```swift
@MainActor final class Canvas { … }   // Don't.
```
This forces every call site to become `await`-aware and bleeds into types that don't need it. Architecture decision 8 deliberately keeps the inner loops queue-based, not actor-based.

❌ **Reaching into `BrushPalette.shared` from inside a closure that escapes to a background queue**:
```swift
DispatchQueue.global().async {
    let r = BrushPalette.shared.activeBrush.radius   // race vs. main mutation
}
```
Singletons holding mutable state are main-only. Snapshot the value on main and capture the snapshot in the closure.

## When the stroke thread lands

The plan from [`arch/CONCURRENCY.md`](arch/CONCURRENCY.md):

- A single serial `DispatchQueue` (not an actor) that owns mutation of the tile cache and document tree.
- Main thread receives input, dispatches each sample to the stroke thread.
- Compositor reads document state via a copy-on-write **snapshot** taken at frame boundary.
- Autosave reads the same snapshot mechanism on its own queue.

Code preparation that helps:

- **Keep model state value-typed where possible.** Easier to snapshot.
- **Avoid main-only assumptions in `Canvas` / layer code.** Don't call `NSColor` methods or post `Notification`s from inside model mutators; do it from the calling layer.
- **Don't introduce shared mutable singletons.** `BrushPalette.shared` and `ToolState.shared` are exceptions inherited from earlier phases; new ones get pushback.

## Autosave specifics

`NSDocument.autosavesInPlace` is `true`. Autosave is triggered by AppKit on a background queue. We participate via:

```swift
override func fileWrapper(ofType:) throws -> FileWrapper {
    return try canvas.serializeToBundle()
}
```

`Canvas.serializeToBundle` reads from the document tree synchronously. Today this is **safe by accident**: the reading thread is background, but the only mutating thread is main, and AppKit serializes autosave saves with main-thread runloop turns.

When the stroke thread lands, this becomes a real concern: an autosave that grabs a snapshot mid-stroke could see torn state. The fix is the architecture's snapshot-based read path. Until then, contributors adding mutation to model types should keep them simple enough to read atomically.

## Where to look

- [`arch/CONCURRENCY.md`](arch/CONCURRENCY.md) — full architecture decision.
- [`design/STROKES.md`](design/STROKES.md) — the stroke pipeline as it actually runs today.
- [`design/COMPOSITOR.md`](design/COMPOSITOR.md) — how the compositor reads model state per frame.
- [`AppDelegate.swift`](../Sources/Inkwell/AppDelegate.swift) — process startup, including the mouse-coalescing disable that's important to event timing.
