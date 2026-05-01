# Performance

Latency / frame-time / memory targets and the profiling workflow. Honest framing: **none of these targets are enforced by automation today.** They're the contract the architecture commits to and the levels we measure against by hand. CI-enforced budgets are tracked in [`TESTING.md`](TESTING.md).

## Targets

### Stroke latency

| Path | Target | Why |
|---|---|---|
| Stylus event → first stamp visible | **< 16 ms (one frame at 60 Hz)** | "Cursor lag" floor; below this most users don't perceive lag. |
| Stylus event → first stamp on-screen at 120 Hz display | **< 8 ms** | The headroom Apple Silicon gives us is real; aim for it. |
| Stylus event delivery rate, Wacom | **~300 Hz native** (not coalesced) | Architecture decision 10 — see [`design/STROKES.md`](design/STROKES.md). |

### Frame time

| Path | Target |
|---|---|
| Compositor frame, 1080×1920 canvas, 5 layers, full viewport visible | **< 4 ms** GPU |
| Compositor frame during a stroke | Same |
| Compositor frame with vector layer (~100 strokes, ~50 samples each) | **< 6 ms** GPU |
| Compositor frame with vector debug overlay enabled | **+ ~2 ms** for the line/point draws |

The window is 1/60 ≈ 16.7 ms; we want substantial headroom so a future feature doesn't push us over.

### Memory

| | Target |
|---|---|
| Per bitmap-layer tile (`.rgba8Unorm` 256×256) | **256 KB** (current) — 512 KB with 16-bit promotion |
| Per mask tile (`.r8Unorm` 256×256) | **64 KB** |
| Vector stroke (typical, ~100 raw samples + brush snapshot) | **~10 KB** |
| Total tile memory, 1080×1920 fully-painted single layer | **8 × 8 = 64 tiles × 256 KB = 16 MB** |
| Document RAM ceiling (informal) | **< 1 GB** for typical illustration documents (~20 layers, mid-size) |
| Undo entry per stroke (uncompressed tile bytes) | **256 KB × dirty-tile-count** |

Nothing prunes long-session undo memory yet. See [`UNDO_GUARANTEES.md`](UNDO_GUARANTEES.md) for what should change.

## How to profile

### Stroke latency

The Debug toolbar (**Debug → Show Debug Toolbar**) shows the moving-average tablet-event Hz. If you see ~60 instead of ~300 with a Wacom plugged in, mouse coalescing didn't disable.

To measure end-to-end stylus → on-screen latency directly, use a high-speed camera or a stylus that reports timestamps to the OS in a way Console can correlate against the drawable's `MTKView.draw(in:)` boundary. There's no built-in latency probe in the app today.

The two big known contributors:

1. **Mouse coalescing.** Disabled at app launch ([AppDelegate.swift](../Sources/Inkwell/AppDelegate.swift)). If the disable fails, console logs `Inkwell: setMouseCoalescingEnabled: unavailable; …`.
2. **Per-event command buffer batching.** All stamps from one input event collapse into one `MTLCommandBuffer`. See [`design/STROKES.md`](design/STROKES.md).

### Frame time

Use Xcode's Metal frame capture (camera icon in the debug bar, or **Debug → Capture GPU Frame**) while running from Xcode:

- Hover over each draw call in the captured frame's command-buffer view to see GPU time.
- The "Performance" tab gives total frame stats.
- Threshold: a single tile-quad draw should cost microseconds, not milliseconds. If it doesn't, look at the fragment shader — framebuffer-fetch blend math is the heavy fragment.

### Memory

`Memory Profiler` in Xcode's debug navigator shows resident memory while running. The per-tile cost dominates; tile count = `(non-empty layers) × (painted-tiles-per-layer)`.

For more detailed allocation breakdown:
```
xcrun xctrace record --template "Allocations" --launch -- ./build/Inkwell.app/Contents/MacOS/Inkwell
```
(or in Instruments → Allocations).

`Metal System Trace` is the right template for understanding GPU command-buffer queue depth — useful when investigating stroke stalls. Look for command-buffer queue saturation; that's what the per-event batching prevents.

## Known performance characteristics

### Where we spend time today

- **Compositor**: dominated by tile fragment shader's framebuffer-fetch blend math. ~5–20 µs per tile draw on Apple Silicon, so a viewport with 16 visible tiles is ~80–320 µs. Negligible.
- **Stamp dispatch**: one render pass per affected tile per stamp. Per-event batching keeps the command-buffer commit rate bounded; without it, 300 Hz × tight Catmull-Rom densification (~10 substamps) × multiple-tile-per-stamp would saturate the command queue (this is the bug we fixed; see commit history for `c579bae`).
- **Vector ribbon dispatch**: same per-event batching pattern, applied symmetrically.
- **Undo capture**: per-tile snapshot is `MTLTexture.getBytes` × dirty-tile-count, executed on the main thread at stroke commit. Bytes are uncompressed `Data` today. Each `getBytes` call **stalls the main thread** until any in-flight GPU writes to those tiles complete. The stall is bounded by the GPU's command-buffer drain time — typically sub-millisecond for the tile count a single stroke touches — but adds measurable latency at gesture commit for wide-area strokes that dirty many tiles.

### Where we don't spend time

- **Tile allocation**. Sparse `[TileCoord: MTLTexture]` lookup is `O(1)` and cheap; allocation only happens on first write to a tile.
- **Compositor walk**. `Canvas.walkVisibleRenderables` is a flat tree walk, irrelevant unless layer count is in the thousands.
- **Selection mask sampling**. Stamp shader reads one extra texture sample per fragment; bounded.

### Where we'll spend more time once architecture commitments land

- **16-bit tiles** (decision 6, currently 8-bit) → tile memory doubles, fragment-shader bandwidth doubles.
- **Display P3** → minor extra ColorSync work at present time; mostly a no-op cost.
- **`history.bin` persistence** (decision 9) → zstd-compressed deltas paged to disk. CPU cost at stroke commit, disk cost continuous.
- **Disk-spill tile cache** → eviction & re-page IO, depending on policy.

## Stroke-latency profiling procedure

Repeatable steps when investigating "why does this feel laggy":

1. **Plug in a Wacom tablet.** Mouse / trackpad events go through different paths and don't reproduce the latency budget.
2. Build & run debug. **Debug → Show Debug Toolbar.**
3. Draw a long sustained stroke. Confirm the Hz reading hits ~250–300. If not, mouse coalescing didn't disable — the rate is your floor.
4. **Xcode → Capture GPU Frame** during the stroke. Check:
   - Each tile-quad draw has GPU time in microseconds.
   - The total frame time stays under the budget.
   - The number of command buffers in flight isn't growing unboundedly. This is the symptom of the stroke-stall bug class.
5. **Instruments → Metal System Trace** if you suspect command-queue saturation. The trace shows the GPU's command-buffer queue depth over time; healthy is ≤ 2; pathological is > 5 sustained.

If the issue is "strokes burst on release" (the bug we fixed), the trace will show the queue depth growing linearly during the stroke, then a spike on release as everything finally drains.

## Tile-memory growth expectations

Linear in painted area, not canvas dimensions. For a typical workflow:

- Start a fresh document → 0 tiles allocated.
- Draw a few strokes covering ~5% of the canvas → ~5% of the tile grid allocated.
- Fill the canvas with a single big brush stroke → all tiles allocated, ~16 MB at 1080×1920.
- Add a layer mask → equal coverage at 1/4 the per-tile cost (`.r8Unorm`).

Memory does **not** drop when you erase pixels — the tile stays allocated until layer-clear or layer-delete. This is intentional (avoids re-allocation cost when the user paints back) and matches how most paint engines work. If memory is a concern, **Edit → Clear** on an empty area drops the tiles.

## Undo / history memory pressure

Per architecture decision 9: a 200-step soft cap, 256 MB working set, with disk-backed full history. **Today none of that is implemented**; we ship raw uncompressed `Data` per snapshot in the in-memory `NSUndoManager` queue.

A long session can therefore consume undo memory proportional to:
```
Σ (per-stroke dirty-tile-count) × 256 KB × 2     (before + after snapshots)
```

A user painting for an hour with ~1000 strokes touching 4 tiles each: ~2 GB of undo memory. Unrealistic in practice (sessions don't sustain that rate), but the upper bound is open.

When zstd compression and disk paging land, this number becomes bounded by a configurable cap. Until then: **Edit → Clear** the document or close & reopen as a workaround for a session that's eaten all available RAM.

## Frame-rate budget guardrails

If a new feature pushes a per-frame cost > 1 ms, it deserves a discussion in the PR:

- **Render regression**: golden-image diffs catch visual changes but not perf. Add a captured-frame note ("composite frame goes from 3.2 ms to 3.6 ms with the new pass") to the PR.
- **Per-stroke cost**: if a stroke produces > 1 GB of allocations or dirties > 100 tiles in a typical use case, reconsider.
- **Memory growth per layer**: if adding a new layer kind costs much more than the bitmap baseline (256 KB / tile), document why.

## Performance-related architectural decisions

- [`arch/RENDERING.md`](arch/RENDERING.md) decision 4 — tile-based GPU-resident lazy compositing. The reason memory scales with painted area, not canvas dimensions.
- [`arch/INPUT.md`](arch/INPUT.md) decision 10 — full-fidelity NSEvent capture, no prediction. The rationale for accepting raw 300 Hz input rather than predicting.
- [`arch/CONCURRENCY.md`](arch/CONCURRENCY.md) decision 8 — main / stroke / GPU / autosave thread split. Today most of this is aspirational; see [`THREADING_MODEL.md`](THREADING_MODEL.md) for shipping reality.

## Known performance gaps

- **No automated perf tests.** Targets above are aspirational without enforcement.
- **No frame-time HUD.** The debug toolbar shows tablet rate but not GPU frame time. Would be useful; tracked in [`FUTURES.md`](FUTURES.md) implicitly.
- **No memory budget warning.** The app will happily eat all available RAM on a sufficiently large session; macOS's memory pressure system handles this at the OS level (via paging).
- **No async tile flushing**. Stamp commits happen synchronously on the calling thread (today, the main thread). Decision 8's stroke thread isn't built out.
- **No render regression**. Visual perf changes in shaders are caught only by manual frame capture.
