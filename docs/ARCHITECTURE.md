# Inkwell Architecture

This document records the major architectural decisions for Inkwell, the reasoning behind them, and the trade-offs we accepted. New decisions are appended as we make them, so the document doubles as a chronological record of how the architecture took shape.

Each decision section follows the same structure: **Decision**, **Context**, **Alternatives considered**, **Pros**, **Cons**, and **Rationale**. Future readers should be able to understand not just *what* we chose, but *why* — and what we gave up to get there.

> **Implementation status.** All 14 decisions below are reflected in the shipping code as of Phase 11. A handful of decision-level commitments are still partially realized (notably decision 6's Display P3 working space — the engine currently runs in sRGB; and decision 9's full undo / timelapse history persistence — the in-memory undo system runs but `history.bin` is not yet written). These gaps are tracked in [`FUTURES.md`](FUTURES.md) under "Phase pass-2 deferrals." Decisions themselves are stable; deferrals are about delivery order, not redesign.

---

## 1. UI framework and language: AppKit + Swift, with Metal for rendering

### Decision

Inkwell is built as a **100% AppKit application written in Swift**, with the drawing canvas implemented as a **Metal-backed `NSView`**. SwiftUI is not used anywhere in the app.

### Context

Inkwell is a native macOS drawing application centered on a high-performance, pressure-sensitive canvas. The app must:

- Sustain stylus input at the device's full sample rate (typically 120 Hz or higher) without dropped samples or visible latency.
- Render and composite many bitmap layers, with blend modes and per-layer opacity, on documents that may be larger than the screen.
- Surround that canvas with the kind of dense, panel-heavy chrome that pro creative tools require: tool palettes, layer lists, brush settings, color pickers, inspectors, and floating HUDs.

The choice of UI framework affects all three concerns, but in different ways. The canvas and input handling have hard performance and API requirements; the surrounding chrome is a productivity question.

### Alternatives considered

1. **SwiftUI-only.** Rejected. SwiftUI's `Canvas` view cannot sustain stroke rendering at the required rate on large documents, and SwiftUI's gesture system does not expose the tablet event data we need (pressure, tilt, azimuth, barrel rotation). The core surface of the app would have to be wrapped AppKit anyway, so a "SwiftUI-only" app is not actually achievable for this domain.

2. **Hybrid: SwiftUI shell with AppKit/Metal canvas.** Plausible and common. SwiftUI is faster to build forms-heavy UI like brush settings and layer inspectors. The cost is a permanent interop seam between the two frameworks, plus exposure to SwiftUI-on-macOS rough edges that still ship in each release.

3. **AppKit-only in Swift, Metal canvas.** Chosen. One UI framework, one mental model, predictable performance, and abundant prior art from other pro Mac creative apps.

### Pros

- **No framework seam.** The canvas, input handling, and chrome all live in the same framework. There is no `NSViewRepresentable` boundary to manage, no SwiftUI/AppKit lifecycle mismatches, and no need to reason about two different layout systems at the same time.
- **Predictable performance.** AppKit's view model is direct and imperative. HUDs that update mid-stroke (brush size readouts, cursor previews, status bars) do not pay SwiftUI's diffing cost and do not stutter under load.
- **Full platform access.** Every `NSView`, `NSWindow`, `NSPanel`, `NSDocument`, and event API is available directly, without representable wrappers or workarounds for features SwiftUI has not yet caught up to.
- **`NSDocument` integration.** macOS document features — autosave, version browser, file coordination, atomic save — plug in naturally without bridging.
- **Strong prior art.** Most shipping pro Mac creative apps (Pixelmator Pro, Acorn, Affinity, classic Photoshop) are AppKit-based. When we hit an edge case, there is documented precedent.
- **Stable API surface.** AppKit changes slowly and predictably. We are unlikely to discover that a macOS point release has broken our toolbar or panel behavior.

### Cons

- **More boilerplate for forms-heavy UI.** Brush settings, layer panels, color pickers, and inspectors are faster to build in SwiftUI's declarative style. In AppKit we will write Auto Layout constraints in code (or XIBs) and bind values manually.
- **Older documentation and examples.** AppKit's reference material skews toward Objective-C examples from the 2010s. New Swift developers typically learn SwiftUI first, so onboarding contributors may take longer.
- **Not "modern" by framework choice.** We are not using the framework Apple is currently investing in for new platform features. If a future macOS feature ships SwiftUI-only, we will have to wait for it, work around it, or accept a small SwiftUI island.
- **Manual binding plumbing.** Two-way binding between UI controls and model state — trivial in SwiftUI — has to be wired by hand (KVO, target/action, Combine, or a custom binding layer).

### Rationale

The decisive factor is that **the highest-stakes parts of the app — the canvas and stylus input — must be AppKit + Metal regardless of any other choice**. SwiftUI cannot host them directly. Given that, a hybrid app trades the productivity win on panels for a permanent framework boundary running through the middle of the codebase. For a long-lived pro creative tool, the hybrid seam is a recurring tax: every feature that touches both the canvas and the surrounding UI pays it.

The "modern" feel of a Mac app comes from Swift idioms, Metal rendering, smooth gestures, good typography, and HIG compliance — not from which UI framework drew the inspector panel. AppKit + modern Swift (structured concurrency, `async/await`, value types, Combine where it helps) produces an app that is indistinguishable from a SwiftUI one to the user, while keeping a single coherent implementation for the team.

We accept the cost of more boilerplate on the chrome side as the price for one framework, one mental model, and predictable behavior under load.

---

## 2. Engine language: pure Swift, with hot paths isolated for possible C++ migration

### Decision

The Inkwell engine — everything below the UI layer, including stroke processing, stamp rasterization, tile management, and CPU-side image work — is written in **pure Swift**. We do not introduce C, C++, or Objective-C as engine languages at this time.

To keep a future migration option open, the CPU-bound hot paths are **isolated behind narrow internal protocols** so that any one of them can be reimplemented in C++ later without disturbing the rest of the codebase.

### Context

Most heavy compositing in Inkwell runs on the GPU through Metal, so the CPU's main jobs are: feeding Metal, processing stylus input, and handling work that does not belong on the GPU. The CPU paths that need to stay fast are well-understood and small in surface area, which means we can afford to evaluate language choices empirically rather than commit up front.

### Alternatives considered

1. **Pure Swift, isolated hot paths.** Chosen. One language, one build, one debugger. Defer cross-language complexity until profiling proves it is needed.

2. **Swift app with a C++ engine from day one.** Plausible. Zero ARC overhead, no bounds-check surprises, and a clean path to a future Linux/Windows/iPad port. Cost: a permanent bridging layer (Obj-C++ shim or Swift's still-maturing C++ interop), two debuggers, more complex builds, and a higher barrier to contribution. We do not have evidence today that this cost is justified.

3. **Swift app with Objective-C / Objective-C++ hot paths.** Rejected. Obj-C was the historical bridge to AppKit before Swift matured; it offers no performance or expressiveness advantage over modern Swift today, and would add a third language without buying anything in return.

### Pros

- **Single language across the project.** Contributors only need to know Swift. One toolchain, one debugger, one set of conventions.
- **Modern Swift is fast.** With whole-module optimization, `UnsafeMutableBufferPointer` and contiguous storage where it matters, and `@inlinable` on inner loops, Swift sits within a few percent of C for the kind of work Inkwell does on the CPU.
- **Safety by default.** ARC, bounds checks, and value semantics catch a class of bugs (use-after-free, buffer overruns, aliasing) that drawing engines have historically suffered from. We can opt out locally where the cost is real.
- **Faster iteration.** No bridging headers, no `.mm` files, no manual marshalling. The engine and the app evolve together at one pace.
- **Migration is preserved.** Because each hot path is isolated behind a protocol, swapping one to a C++ implementation later is a localized change, not a rewrite.

### Cons

- **Latent risk on inner loops.** ARC traffic and bounds checks are not free. If a hot path turns out to need every cycle, we may have to either lean hard on `unsafe` Swift idioms or accept a later port to C++.
- **Cross-platform port is harder later.** If we eventually want an iPad, Linux, or Windows version, the engine will not port directly. A C++ engine would have made that trivial.
- **Some libraries are C++-shaped.** If we adopt a third-party engine component (e.g. a PSD codec, a pixel-format converter, a filter library) it will likely be C/C++ and require a bridging layer at that boundary.
- **Swift's C++ interop is still maturing.** If we later decide to migrate a hot path, the bridging story today is workable but rough; we will pay some friction at that point.

### Hot paths to watch (candidates for future C++ migration)

These are the modules where we expect CPU performance to matter most. Each will be implemented behind a narrow Swift protocol so it can be replaced without touching its callers. If profiling on real documents shows Swift overhead is the bottleneck, these are the places we look first.

1. **Stroke input processor.** Receives stylus samples at 120+ Hz, applies smoothing, resampling, and pressure-curve evaluation, and emits a stream of stamp placements. Latency-sensitive: every microsecond on this path is felt by the user as cursor lag.
2. **Stamp rasterizer / placement engine.** Decides where stamps land between samples (spacing, jitter, scattering) and prepares the per-stamp parameters Metal will consume. Runs in tight loops with predictable shapes — a classic case where C++'s lack of ARC and bounds checks could matter.
3. **Tile cache and dirty-region tracker.** Manages the document's tile grid, tracks which tiles are dirty, and orchestrates upload/download between CPU and GPU memory. High call frequency, lots of small allocations and lookups.
4. **CPU-side filters and distortion brushes (future).** Blur, liquify, and similar effects that sample the canvas mid-stroke. These can run on the GPU in many cases, but the CPU paths that prepare or fall back for them are a likely future hot spot.
5. **PSD codec.** Reading and writing PSDs involves bit-banging, RLE decompression, and color-space conversion. Existing high-quality implementations are in C/C++; if we adopt one rather than write our own, the boundary lives here.

### Rationale

The decisive factor is that **we do not yet know which, if any, of these paths will be CPU-bound in practice**. Most compositing is GPU work, and Swift's CPU performance for the remaining tasks is generally adequate when written carefully. Committing to a C++ engine before we have profiling data would impose a permanent bridging tax — on every contributor, every build, and every debugging session — to solve a problem we have not confirmed exists.

By staying in pure Swift now and isolating the hot paths behind protocols, we keep the project simple and approachable today, and we keep the door open to migrate any individual module to C++ tomorrow if measurements demand it. The cost of being wrong in this direction is bounded (port one module later); the cost of being wrong in the other direction is paid every day forever.

---

## 3. Platform target: macOS Tahoe and later, Apple Silicon only

### Decision

Inkwell requires **macOS Tahoe or later** (the current macOS release at the time of this decision, April 2026) and runs on **Apple Silicon only**. We do not support older macOS versions, and we do not support Intel-based Macs.

### Context

Inkwell's expected audience skews strongly toward users who keep their Macs on the latest OS — pro and prosumer creative users who treat their machine as a working tool and tend to upgrade promptly. Apple has not shipped a new Intel-based Mac since late 2020, so a 2026 launch can reasonably treat Apple Silicon as the only relevant CPU/GPU architecture. The combination lets us collapse two large variables — OS version and CPU architecture — into a single, predictable target.

### Alternatives considered

1. **macOS Tahoe only, Apple Silicon only.** Chosen. Smallest test surface, newest API surface, simplest engine.
2. **macOS Sequoia (one back) and later, Apple Silicon only.** The conservative version of the same posture. Gains roughly the slice of the audience that has not yet upgraded to Tahoe, at the cost of guarding new APIs behind availability checks. We rejected it because we believe that audience slice is small for our target user, and the maintenance cost is permanent.
3. **macOS Sonoma (two back) and later, with Intel support.** Maximizes the addressable market. Rejected: doubles the GPU testing surface, constrains Metal feature use, and forces us to maintain Intel-specific performance paths for an audience that is shrinking every quarter.

### Pros

- **Single OS version to support.** One set of behaviors, one set of bugs, one set of API quirks. Every `#available` check we would otherwise have to write is replaced with the assumption that the latest API is present.
- **Single GPU architecture.** All supported machines have an Apple GPU with the same tile-based deferred rendering (TBDR) characteristics. We can tune the Metal pipeline for one architecture rather than cross-tuning for Apple GPUs and several generations of Intel/AMD discrete GPUs.
- **Unified memory architecture.** Apple Silicon's shared memory between CPU and GPU lets us pass tile data, stamp parameters, and brush textures to the GPU without explicit upload/download cycles. This simplifies the renderer and removes a class of performance pitfalls Intel Macs would have introduced.
- **Latest Metal feature set unconditionally.** Mesh shaders, the latest compute capabilities, the newest pixel format support, and current debugging tools are all available without fallbacks.
- **Latest Swift and Foundation.** New language features, current concurrency improvements, and the most recent framework APIs can be used directly without backport shims.
- **Smallest possible test matrix.** One OS version × one CPU architecture × one GPU family. This is roughly an order of magnitude less testing surface than a "macOS 14+, universal" target.

### Cons

- **Smaller addressable market at launch.** Users on macOS Sequoia or earlier, and users on remaining Intel Macs, cannot run Inkwell. For a paid creative tool, each excluded user is a potential lost sale.
- **No safety net if Tahoe ships a regression.** Because we depend on Tahoe-only behavior, a point-release bug in macOS itself becomes our problem to work around rather than something we could side-step by recommending an older OS.
- **Re-evaluation cost when the next macOS ships.** When the macOS release after Tahoe arrives, we will have to choose again: stay pinned to Tahoe-or-later, or move the floor up. Each move forward repeats the trade-off in this section.
- **No path to Intel users with old but capable Macs.** Some users on 2018–2020 Intel iMac Pros and Mac Pros have hardware that could in principle run a drawing app well. We are explicitly choosing not to serve them.

### Rationale

The deciding factor is the audience. We expect Inkwell's users to be on the latest macOS, which means the addressable-market cost of requiring Tahoe is smaller for us than it would be for a general-purpose app. In exchange, we get the simplest possible engineering target: one OS, one CPU architecture, one GPU family, one set of APIs. Every layer of the system — from `NSEvent` tablet handling up through Metal rendering — gets simpler when there is no compatibility branching.

Apple Silicon-only is the natural companion to that decision. Apple has shipped no new Intel Macs since late 2020, the unified memory architecture meaningfully simplifies the renderer, and the alternative — maintaining Intel performance parity — is a recurring tax for a shrinking audience.

We accept that this stance will need to be revisited each time a new macOS ships. The default re-evaluation question will be: "Has Tahoe's share of our audience dropped enough that staying pinned to it costs us more than moving the floor forward would?"

---

## 4. Rendering pipeline: tile-based, GPU-resident layers with lazy viewport compositing

### Decision

Inkwell stores each layer as a **sparse grid of fixed-size tiles**, with each tile resident as a **Metal texture in unified memory**. Compositing happens on the GPU, **lazily and only for the tiles that intersect the current viewport**.

Concretely:

- **Tile size:** 256 × 256 pixels. A standard size used by most pro paint engines; granular enough for tight dirty-region tracking and small enough that individual tile uploads/downloads (when needed) are fast, but large enough that per-tile bookkeeping overhead stays modest.
- **Sparse allocation:** A tile is only allocated when at least one pixel inside it has been painted. Empty regions of a layer cost essentially nothing.
- **GPU residency:** Tiles live as `MTLTexture` objects. Because the platform is Apple Silicon only (see decision 3), unified memory means the same allocation is addressable by both CPU and GPU without explicit upload/download. Stamps, compositing, and most filters operate on tiles in place.
- **Lazy compositing:** Each frame, the renderer composites only the tiles that intersect the visible viewport, in layer order, applying blend modes and per-layer opacity on the GPU. Tiles outside the viewport are not composited until they become visible.
- **Disk spill:** Out of scope for v1. If we later need to support documents larger than available memory, the tile cache is the natural place to add an LRU eviction-to-disk policy. We design the tile cache interface to make this addition non-disruptive, but we do not implement it now.

### Context

The rendering pipeline shapes nearly every other engine decision: how memory scales with document size, how undo/redo records changes, how dirty regions are tracked, how the brush engine writes pixels, how PSD export flattens layers, and how multi-threaded work is partitioned. Choosing well here is high-leverage; choosing poorly is hard to undo without a near-rewrite of the engine.

Inkwell's feature set — Photoshop-style blend modes, per-layer opacity, PSD export, pressure-sensitive painting on documents at sizes pro users expect — pushes us toward the rendering model that pro paint engines have converged on, rather than the simpler model that suffices for sketch apps.

### Alternatives considered

1. **Full-bitmap layers.** Each layer is one contiguous bitmap the size of the document. Simple to implement and to reason about: compositing is "blend layer over layer," undo can snapshot whole layers, no tile-boundary code anywhere. Rejected because memory scales with `document_pixels × layer_count × bytes_per_pixel`. A 4K document at 16-bit RGBA with twenty layers is roughly 10 GB before any working buffers — viable on a high-end Mac, painful on a base-model machine, and hostile to the larger documents pro users routinely create. More importantly, retrofitting tiles later is effectively an engine rewrite.

2. **Tile-based, CPU-resident.** Tiles live in CPU memory; the GPU receives uploads of dirty tiles each frame. This is the historical model from before unified memory, used by paint engines that must run on machines with discrete GPUs. Rejected because we have already committed to Apple Silicon only, and unified memory makes the upload-download cycle pure overhead with no portability benefit in return.

3. **Tile-based, GPU-resident, lazy viewport compositing.** Chosen. Memory scales with painted area, the GPU does compositing without redundant data movement, and only visible work is performed each frame.

4. **Eager composited result.** Maintain a single fully-composited image of the document and update it as layers change. Rejected because it wastes work for tiles outside the viewport, complicates blend-mode changes (an opacity slider drag would re-composite the entire document each frame), and offers no real benefit on top of lazy compositing once the tile cache is in place.

### Pros

- **Memory scales with what is drawn, not the document's dimensions.** A 16K canvas with mostly-empty layers costs almost nothing; a small canvas painted edge-to-edge costs the same per painted area as a large one. This unlocks document sizes that would be infeasible under full-bitmap.
- **Tiles are the natural unit for almost everything else.** Dirty-region tracking, undo/redo deltas, GPU work partitioning, parallel filter application, save-file structure, and progressive PSD export all map cleanly onto a tile grid. Decisions in those areas become simpler because they share a vocabulary.
- **Unified memory removes the usual tile-engine pain point.** On platforms with discrete GPUs, the tile-engine designer spends real effort minimizing CPU↔GPU traffic. On Apple Silicon there is no traffic to minimize: the GPU reads the same memory the CPU just wrote. This is a meaningful simplification of the renderer.
- **Lazy compositing keeps frame time bounded by viewport, not document size.** Zoomed in to a small region of a giant document, we composite a handful of tiles per frame regardless of how large the canvas is. Pan and zoom remain smooth at any document size.
- **Strong precedent.** Procreate, Photoshop, Krita, Clip Studio, and most other pro paint engines use tile-based representations. The trade-offs are well-mapped; we are not breaking new ground.

### Cons

- **Largest single piece of upfront engineering.** Tile allocation, lifecycle, and lookup; stroke handling that crosses tile boundaries without visible seams; per-tile dirty marking; tile-aware brush rasterization; tile-to-layer flattening for export — none of this is hard in isolation, but together it is the largest module in the engine.
- **Stroke-time tile allocation must be carefully designed.** A brush stroke crossing into a previously empty region needs to allocate new tiles mid-stroke without stalling the input pipeline or producing seams at tile boundaries. This requires the stroke processor and the tile cache to cooperate at low latency.
- **PSD and PNG export must flatten tiled layers.** The output formats expect contiguous pixel data per layer (PSD) or per image (PNG). The export path needs an efficient tile-to-strip conversion that does not duplicate the entire document in memory while writing.
- **Debugging is harder.** A "wrong pixel" bug can originate in stroke math, in tile allocation, in dirty tracking, in compositing, or in the shader. Tile boundaries are the most common location for visible bugs (seams, double-applied alpha, off-by-one cropping). We will need diagnostic tooling — at minimum, a debug overlay that visualizes tile boundaries and dirty state — early.
- **Disk spill is non-trivial when we eventually need it.** Although we have deferred this to a future version, when the time comes it will require careful work on eviction policy, tile-locking during access, and minimizing visible stalls when an evicted tile is paged back in.

### Rationale

Two factors make tile-based, GPU-resident, lazy compositing the right choice rather than the ambitious choice. First, the platform decisions we have already made (Apple Silicon only, Metal rendering) eliminate the historical pain of tile engines: there is no upload/download cycle to optimize. The renderer becomes considerably simpler than equivalent designs on cross-platform engines. Second, our feature set — multiple layers, blend modes, opacity, PSD interop — already implies the kind of documents that full-bitmap cannot serve well. Choosing full-bitmap to ship faster would buy a few months of velocity in exchange for a near-rewrite later.

Tile size is set at 256 × 256 because the trade-off is well-understood at this size. Larger tiles (512+) reduce per-tile overhead but make dirty-region tracking coarser and increase the cost of small edits; smaller tiles (128 or below) make tracking precise but multiply the bookkeeping cost. 256 × 256 is the size most pro engines have converged on for the same reasons.

Lazy viewport compositing is chosen over eager composited results because it bounds per-frame work by what the user actually sees, and because it interacts well with the rest of the engine: a layer-property change (opacity, blend mode) does not force re-compositing of off-screen tiles, and panning brings new tiles into composition without disturbing existing ones.

### Cross-cutting implications

This decision constrains several later decisions, all of which should refer back here:

- **Undo/redo (future decision).** Per-tile deltas are the natural representation; whole-layer snapshots are wasteful at this scale.
- **Dirty-region tracking.** A bitmap of dirty tiles, not a rectangle list, is the right data structure.
- **Stroke processing and stamp rasterization.** The stamp rasterizer writes into tile textures, allocating new tiles on demand at the stroke front.
- **PSD/PNG export.** Need a streaming tile-to-strip flattener that does not materialize a full-document bitmap in memory.
- **Save format.** Inkwell's native file format should store the tile grid sparsely, mirroring the in-memory representation.

---

## 5. Stroke model: rasterize-and-discard for bitmap layers, with engine commitments to keep future layer types open

### Decision

For **bitmap layers**, Inkwell rasterizes each stroke into the tile grid as it is drawn and **discards the input samples once the stroke commits**. There is no per-stroke sample log on bitmap layers. Live smoothing, resampling, and pressure-curve evaluation operate on an in-flight sample buffer that is released at stroke end.

To ensure that future layer types (in particular vector layers, but also potential text and adjustment layers) can be added later without an engine rewrite, the following **four architectural commitments** are made now and apply to every system that touches layers:

1. **`Layer` is a sum type or protocol from day one.** No code may assume a layer is a `BitmapLayer`. New layer kinds slot in by conforming to the layer abstraction.
2. **The stroke processing pipeline is layer-aware.** The processor produces a stream of samples and computed stamps; the *layer* decides how to consume that stream. Bitmap layers rasterize into tiles and forget. A future vector layer would store the samples (or a fitted representation) and re-rasterize on demand. The processor itself does not bake "rasterize and discard" into its contract.
3. **The save format is extensible per-layer.** Every layer record in the native file format carries a type tag and a version. Older builds skip layer types they do not understand cleanly; newer builds add layer types as a pure addition without breaking the format.
4. **The compositor accepts heterogeneous layers.** Each frame, the compositor asks each layer for tile-shaped pixel data at the current view. Bitmap layers serve their tiles directly. Future vector layers rasterize to a transient tile at the current view scale on demand.

Timelapse, when it ships, will be built on the **undo delta stream** described in the next section's preview — not on stored stroke samples. The implications for the stroke model are explicit: we do not need to retain samples to support timelapse.

### Context

Pressure-sensitive painting produces stylus samples at 120 Hz or more. The engine has to decide what becomes of those samples after the stamp rasterizer has consumed them. Two future features named in the overview — vector layers and timelapse recording — could in principle motivate retaining samples beyond the active stroke. We considered each and concluded that neither requires it.

Vector layers are best served by being a *separate layer type* with their own representation, rather than by retroactively interpreting bitmap-layer strokes as vector data. Bitmap layers in every pro tool work exactly as we are choosing here; users do not expect a bitmap stroke to be retroactively re-shapeable. Vector behavior belongs to a vector layer.

Timelapse can be implemented from the per-stroke tile deltas the undo system already records. Playback applies committed deltas forward, paced by stored timestamps. The trade-off is visual: each stroke "snaps" into existence rather than animating along the stylus path. We accept this; it is the same model many shipping apps use for their default timelapse mode.

### Alternatives considered

1. **Rasterize and discard for bitmap layers (the chosen model).** The simplest pipeline and the one that matches user expectations for bitmap painting.

2. **Store every sample, rasterize lazily.** Bitmap layers would themselves be derived from a sample log, and re-rasterization on document scale-up would be lossless. Rejected because the memory and storage cost is real (a long session can produce hundreds of MB of samples), the stroke pipeline becomes considerably more complex, and the user-facing benefit (vector-like behavior on a *bitmap* layer) is not what bitmap layers are for. If users want vector behavior, they should use a vector layer.

3. **Hybrid: rasterize for display, archive samples to a per-document log.** Pays roughly half the cost of #2 in exchange for keeping the door open to features we have decided not to build. Rejected because the features that would benefit (input-replay timelapse, retroactive brush-setting changes) are either replaceable (timelapse via undo deltas) or out of scope for bitmap layers (retroactive editing belongs to vector layers).

### Pros

- **Simplest stroke pipeline.** Samples flow through a small in-memory buffer, get consumed by the stamp rasterizer, and are released. There is no log to design, persist, version, or migrate.
- **Zero residual memory cost per stroke.** After commit, the only artifact of a stroke is the painted pixels in the tile grid. A long session does not accumulate hundreds of MB of sample data.
- **Matches user expectations.** Bitmap layers in every pro paint tool behave this way. Users will not be surprised that a committed stroke cannot be retroactively re-shaped.
- **Keeps the engine small.** The stroke processor's contract is "consume samples, produce stamp placements"; it does not also have to be an archival system.
- **Does not foreclose vector layers.** The four architectural commitments above keep that door fully open. A vector layer is a future addition, not a future rewrite.

### Cons

- **A committed bitmap stroke cannot be retroactively edited.** Changing the brush, size, or pressure curve and re-applying to existing strokes is not possible on bitmap layers. (This matches user expectation.)
- **Bitmap-layer strokes do not re-rasterize losslessly when the document is scaled up.** Pixel content scales like a pixel image. (Vector layers, when they ship, will scale losslessly.)
- **No live-replay timelapse on bitmap layers.** Per-stroke playback off the undo stream is supported; stroke-along-the-path animation is not. If we ever want input-replay timelapse, it would have to be added as a separate feature and would naturally apply only to vector layers.

### Rationale

The deciding insight is that **the future features that seemed to motivate retaining samples are better served by other means**. Vector layers want a different layer type, not a different bitmap-layer model. Timelapse can be built on the undo delta stream that we have to maintain anyway. Once we recognized those, retaining samples on bitmap layers became cost without benefit.

The four architectural commitments are the actual safeguard. They ensure that "we did not retain samples on bitmap layers" never becomes "we cannot add vector layers." Bitmap layers and vector layers are siblings, not the same thing in different modes; the engine just has to admit that from day one.

### Forward link: timelapse and undo

The decision to build timelapse on the undo delta stream is recorded here as a constraint on the *forthcoming* undo decision. When we make that decision, the requirements that flow from this section are:

- Undo deltas are recorded at tile granularity (already implied by the rendering pipeline decision).
- Each delta records a timestamp at commit, sufficient for timelapse pacing.
- The delta stream can be persisted to the document (or a sidecar) for the full lifetime of the document, not capped to a recent-history window.
- Undone-then-overwritten history is handled by standard linear-redo semantics so that timelapse playback shows only the strokes that survived to the final state.

---

## 6. Color and blending: Display P3, 16-bit, premultiplied, gamma-space blends

### Decision

The Inkwell engine adopts the following color and blending model for all internal work:

- **Working color space:** Display P3.
- **Internal precision:** 16-bit per channel (64 bpp RGBA) for tile storage, with 32-bit float intermediates on the GPU during compositing and blend-mode math.
- **Alpha handling:** Premultiplied alpha throughout the pipeline — in tiles, in stamp output, in compositing, and at every internal boundary.
- **Blend math:** Performed in gamma-encoded space (sRGB-style transfer curve) by default, matching Photoshop's blend-mode behavior. A "linear blending" option may be added later as a per-document opt-in but is not part of v1.
- **Color profile handling:** Imported PNG, JPG, and PSD content is converted from its embedded profile (or assumed sRGB if none) into the working Display P3 space. Exported files are tagged with the appropriate ICC profile (P3 by default, sRGB on user request, with gamut mapping where needed).

### Context

Color and blending choices touch every pixel the engine produces. They determine what the user's brush looks like on screen, how stacked translucent strokes accumulate, how blend modes behave, what is preserved on round-trip through PSD, and what happens when the document leaves Inkwell for a destination with a different color expectation. Reversing these choices later forces pipeline-wide changes to stamp output, tile format, compositing shaders, and import/export — so it is worth making them deliberately.

### Alternatives considered

1. **sRGB working space, 8-bit, gamma-space blending, premultiplied alpha.** The classic mid-2000s default. Simplest to implement, smallest tiles, no gamut mapping anywhere. Rejected because it caps the in-app gamut at sRGB's 1996 limits, which looks dated and dull on the wide-gamut displays Apple Silicon Macs ship with.

2. **Display P3 working space, 8-bit, gamma blending.** Halves tile memory compared to the chosen model. Rejected because 8-bit per channel produces visible posterization in subtle gradients and in deep stacks of translucent layers — exactly the cases serious users care about.

3. **Linear-light blending throughout.** Physically correct: a 50% gray stroke fades through a perceptually linear midpoint. Rejected because it does not match what users trained on Photoshop expect, and produces results that look "wrong" in normal painting workflows. The cost is a one-line option to revisit later.

4. **Display P3, 16-bit, premultiplied, gamma-space blending.** Chosen. Wide gamut for the platform, precision headroom for stacking, blend math users expect, and standard pro-tool compositing semantics.

### Pros

- **Wide gamut on the platform that has it.** Apple Silicon Macs ship wide-gamut displays. Working in Display P3 means the brush colors a user picks are the colors they see, not a sRGB approximation.
- **No precision loss in deep stacks.** 16-bit channels carry enough precision that translucent overpainting, layer opacity, and blend modes do not produce visible banding even after dozens of operations on the same tile.
- **GPU headroom.** 32-bit float intermediates on the GPU keep blend-mode math (especially modes that involve division or contrast) numerically stable even when input tiles are at the 16-bit edges.
- **Premultiplied alpha cleanly handles edges.** No darkening at translucent edges, no "halo" artifacts when a stroke meets a different background, and blend-mode formulas simplify.
- **Gamma-space blending matches user expectation.** Users trained on Photoshop will see familiar fades and blend results. The visible behavior of blend modes round-trips through PSD without surprise.
- **sRGB content imports losslessly.** sRGB is a subset of Display P3. Bringing in sRGB references, scans, or photos is a pure lift into the working space; no detail is lost.
- **Profile-aware export prevents color shift.** Tagging output files with the correct ICC profile means downstream consumers (browsers, print, other apps) display the colors the user chose.

### Cons

- **Tiles are twice the size of an 8-bit pipeline.** A 256 × 256 tile at 16-bit RGBA is 256 KB versus 128 KB at 8-bit. The tile cache, working memory, and any disk-spill backing all pay this cost.
- **Export to sRGB destinations requires gamut mapping.** Colors that fall outside the sRGB gamut have to be either clipped or perceptually compressed when exporting to sRGB-only formats. This is a real (if well-understood) engineering task and a small surprise for users who pick a vivid P3 color and then export to sRGB.
- **Gamma-space blending is not physically correct.** Some specialized workflows (compositing photographic content, simulating light interaction) genuinely want linear blending. We accept this gap and may ship a per-document "linear" option later.
- **Color management bugs are hard to see.** A wrong profile assumption or a missed conversion looks like "colors are slightly off" rather than a crash. We will need test images, reference comparisons, and ideally automated round-trip tests to catch regressions.

### Rationale

The four sub-decisions are mutually reinforcing on the platform we have chosen. Apple Silicon's unified memory makes 16-bit tiles affordable. The wide-gamut displays Apple ships make Display P3 the right working space. The pro-tool ecosystem we interoperate with (PSD round-trip, user expectations) makes gamma-space blending and premultiplied alpha the right blend semantics. Together they describe the color model a serious paint app written for Apple Silicon in 2026 should have.

The most defensible alternative was 8-bit precision, in exchange for halving tile memory. We rejected it because the visible failure mode of 8-bit (posterization in subtle work) is exactly the kind of issue our target users would notice and report, while the failure mode of 16-bit (more memory consumed) is hidden inside the engine and well-managed by the tile cache.

### Forward implications

- **Tile cache sizing.** Memory budgets in the tile cache should be calculated against 64 bpp tiles, not 32 bpp.
- **Stamp output.** The brush engine writes 16-bit-per-channel premultiplied stamps; sub-pixel and sub-precision stamp blending happens in 32-bit float on the GPU before being stored back to 16-bit tiles.
- **Compositor.** Reads 16-bit tile textures, composites in 32-bit float, presents to the screen at the display's bit depth via Metal's standard color-managed presentation path.
- **PSD interop.** PSD's 16-bit mode round-trips natively. PSD's 8-bit mode imports lossily-but-faithfully and exports with the user's chosen bit depth.
- **PNG/JPG export.** Profile-tagged with either Display P3 or sRGB at user choice; gamut mapping path required for sRGB.

---

## 7. Document model: grouped layer tree, per-layer masks, native `.inkwell` bundle, PSD as export-only

### Decision

An Inkwell document is a tree of layers organized into optional groups, plus document-level metadata, plus the undo/timelapse delta stream. The model is:

- **Layer hierarchy** is a tree, not a flat list. Layers can be contained in **layer groups** ("folders"). Groups have their own opacity and blend mode, applied to the composited result of their contents.
- **Per-layer masks** are single-channel bitmaps attached to a layer that gate its visibility. Painting on the mask non-destructively reveals or hides parts of the underlying layer. Masks are tile-stored, sparse, and follow the same tile rules as the layer they attach to.
- **Document metadata** is: pixel width and height, DPI, color profile (Display P3 by default), creation and modification timestamps, and optional title/author. **DPI is metadata-only in v1** — it is recorded for export and information, but does not influence rendering, brush sizing, or any in-app dimension. Brush sizes are specified in pixels.
- **Native file format** is `.inkwell`, a **macOS document bundle** (a directory that Finder presents as a single file). The bundle contains: the document metadata, a sparse tile-store, the layer tree definition, optional layer masks, embedded color profile, and the undo/timelapse delta stream. The bundle layout includes a **document format version field** from day one so future format changes are non-breaking.
- **PSD is export-only.** Inkwell can write PSDs with the best-fidelity mapping it can produce, but PSD is never used as a primary save format. Users who want a `.psd` get one through Export, not through Save.

### Context

The shape of a document constrains the renderer, the file format, the layer-panel UI, the undo system, the export pipeline, and what kinds of features can be added later without disturbing existing files. Earlier decisions (tile-based rendering, `Layer` as a sum type, bitmap-layers-rasterize-and-discard) defined how a single layer behaves; this decision defines how layers fit together into a document and how documents are persisted.

### Alternatives considered

1. **Flat layer list, no groups.** Simpler compositor (a list, not a tree), simpler layer UI. Rejected because pro users organize complex documents with groups (line art, flats, shadows, references), and retrofitting groups later is invasive — it touches the compositor, the file format, undo, selection, and masking simultaneously. Building groups in from v1 costs less than adding them in v2.

2. **No layer masks; users duplicate layers and erase.** The "destructive" workflow. Rejected because it does not match how serious users work and produces files that are hard to revise. The cost of supporting masks is small (one extra sparse tile grid per masked layer) and the workflow benefit is large.

3. **DPI as an active dimension (brush sizes in mm, etc.).** Some print-oriented apps work this way. Rejected for v1 because it adds UI complexity, requires DPI-aware brush math throughout the engine, and serves a small audience for a tool whose primary domain is screen-resolution painting. We can revisit if users ask.

4. **PSD as the native save format.** Every save would be a PSD; no proprietary format to design. Rejected because PSD cannot represent everything the Inkwell engine needs to persist: our undo/timelapse delta stream, our exact tile layout, our future layer types (vector, etc.), and certain blend-mode and color-management nuances. Every save would be a lossy re-encode.

5. **Single-file format (custom container or SQLite-backed).** More familiar to users who copy a single file between machines. Rejected because a bundle is materially easier to evolve (new chunks land as new files inside the bundle), interacts well with tile streaming and incremental save, and is the standard pro-Mac-app convention (Sketch, Procreate, Affinity). macOS Finder presents bundles as single files anyway, so the user-visible difference is negligible.

6. **Native bundle format with groups, masks, DPI metadata-only, version field, PSD export-only.** Chosen.

### Pros

- **Groups match how pro users actually work.** Organizing twenty-layer illustrations without folders is painful; with folders it is normal. Building this in from v1 lets us design the rest of the engine (compositor, undo, selection) around the tree from the start.
- **Masks enable non-destructive editing.** Users can hide parts of a layer without losing the underlying pixels. This is table-stakes for pro workflow.
- **Native format preserves engine state losslessly.** Tile layout, layer types we may add in the future, the undo/timelapse stream, and color profile all round-trip through `.inkwell` exactly. Reopening a saved file is identity, not lossy reconstruction.
- **Bundle is evolvable.** Adding a new feature that needs persistent state (e.g. brush presets per document, recorded comments, references) is a matter of dropping a new file into the bundle. The format version field gates the change.
- **PSD remains a first-class export target.** Interoperability is preserved without making PSD the bottleneck for the engine.
- **Version field is cheap insurance.** It costs nothing now; it is the difference between a smooth format upgrade and a forced migration when v2 changes the layout.
- **Bundle is friendly to incremental and atomic save.** New tile data writes to a temporary file inside the bundle and is moved into place; partial writes do not corrupt the document.

### Cons

- **Compositor walks a tree, not a list.** Group opacity and blend mode require compositing the group's contents into a transient buffer first, then blending that buffer into the parent. More code than a flat list, and more memory at peak.
- **Layer panel UI is more complex.** Hierarchy, expand/collapse, drag-into-group, drag-out-of-group, group selection vs single-layer selection. All standard but all real work.
- **PSD export is a translation step with edge cases.** Mapping our layer tree, masks, and blend modes to PSD's nominally-similar structures is a non-trivial fidelity exercise. Some features (anything we add that PSD lacks) will export with a documented loss.
- **Bundle format is occasionally surprising to users.** A user who right-clicks a `.inkwell` and chooses "Show Package Contents" will see the internal structure. This is rarely a problem and is the standard macOS convention, but we should not assume zero confusion.
- **Mask painting is its own UI surface.** Mask edit mode, mask preview overlay, "paint on layer vs paint on mask" toggle. Standard pro features, but a non-trivial UX area.
- **Tree-shaped data structures are harder to reason about under concurrency.** When we get to threading, the compositor and undo system will both need clear rules about who is allowed to mutate the tree and when.

### Rationale

The deciding factor is that **everything in this bundle is what pro users expect from a serious Mac creative app, and every alternative defers cost rather than saves it**. Groups, masks, and a native format with versioning are not advanced features we could add later; they are foundational structures that other features (compositor design, undo system, file format, export) depend on. Building them in now is cheaper than retrofitting them.

The choice of a bundle over a single-file container is a question of evolvability versus packaging. Bundles win on evolvability and match macOS conventions; the only real cost is occasional user surprise when they peek inside, which is shared by every other pro Mac app and well-handled by Finder.

PSD as export-only is the standard pro-app posture and is the only one that lets the engine evolve freely. Tying our save format to PSD would mean every internal change has to be expressible in PSD or lost on save — a constant tax for a small interop benefit we already get through export.

DPI as metadata-only is a deliberate scope cut for v1. Active DPI (brush sizes in mm, document dimensions in inches) is a feature for print-first workflows and adds non-trivial complexity throughout the engine. Recording DPI in metadata means we can add active DPI later without breaking existing files.

### Forward implications

- **File format specification will need its own document.** The `.inkwell` bundle layout, chunk types, version negotiation, and atomicity rules deserve their own spec.
- **PSD export must publish a fidelity table.** A documented mapping from Inkwell's layer types, blend modes, and masks to PSD's, including known lossy cases.
- **Layer panel UI is hierarchical.** Drag-and-drop into and out of groups, expand/collapse, selection semantics for groups, and group-aware context menus.
- **Compositor is recursive over groups.** Each group composites its contents into an intermediate buffer at group resolution, then blends that buffer into the parent according to the group's opacity and blend mode.
- **Undo system covers structural operations.** Creating, deleting, reordering, regrouping, and renaming layers and groups; adding and removing masks; toggling visibility. All recorded at the same fidelity as pixel edits.
- **Mask editing is a UI mode.** Selecting a layer's mask routes brush input to the mask tile grid instead of the layer tile grid.

---

## 8. Threading model: main + stroke + GPU + autosave, with snapshot reads

### Decision

Inkwell uses a **four-actor threading model** with clear ownership boundaries:

- **Main thread.** Receives `NSEvent` input (including stylus samples), runs all AppKit UI, dispatches compositor frames, and presents to the screen. Latency-critical for input reception. Never blocks on disk I/O, never waits on the stroke thread.
- **Stroke thread (single serial `DispatchQueue`).** Owns mutation of the tile cache and the document tree. Performs smoothing, pressure-curve evaluation, stamp placement, stamp rasterization into tile textures, and undo delta capture at stroke commit. Single serial queue, not an actor — predictable latency without `await`-induced reentrancy.
- **GPU.** Executes all compositing, blend-mode math, and shader work. Dispatched from the main thread but performs its work asynchronously. The GPU reads tile textures directly; on Apple Silicon's unified memory there is no upload step.
- **Autosave queue (background).** Periodically writes the `.inkwell` bundle to disk. Reads document state through a copy-on-write snapshot rather than holding a lock against the stroke thread. Atomic-rename pattern at the bundle-file level.

**Cross-thread access rules:**

- The document tree, layer list, and tile cache are **mutated only from the stroke thread**.
- The main thread and the autosave queue read the document model through **immutable snapshots** taken at well-defined points (frame boundary for the compositor, save trigger for autosave). Snapshots use copy-on-write semantics: cheap to create, cheap to hold, freed when the reader is done.
- The compositor reads **GPU-resident tile textures directly** rather than via snapshot. Tile textures are mostly-immutable between stamp commits; synchronization happens at tile-flush boundaries (a small set of `MTLEvent` or `MTLFence` signals from the stroke thread to the GPU encoder), not per-pixel.
- The stroke thread does not call back into the main thread synchronously. State the UI needs (current tool, current brush, modifier state) is read from atomically-updated value types or `OSAllocatedUnfairLock`-protected state.

**Concurrency primitives.** Actors are used for high-level coordination (e.g. document lifecycle, autosave scheduling) where `async/await` ergonomics help. Latency-critical inner loops (the stroke thread's per-sample work, the compositor's per-frame setup) use serial `DispatchQueue` and `OSAllocatedUnfairLock`-protected state — actor reentrancy across `await` points is undesirable in those paths.

### Context

By this point in the architecture, several earlier decisions have set hard constraints on the threading model:

- **Tile-based, GPU-resident rendering** (decision 4) means the GPU is the natural composition target and the CPU is mostly orchestrating.
- **Bitmap-layer rasterize-and-discard** (decision 5) means the stroke pipeline is short and fits comfortably on a single thread without pipelining.
- **Native bundle save format** (decision 7) means autosave writes potentially many small files atomically; this is real I/O work that must not block input.
- **Pure Swift for the engine** (decision 2) means we have access to Swift's concurrency primitives (actors, `async/await`) and dispatch queues, but we should pick deliberately rather than reflexively reach for actors.

The threading model has to satisfy all of these and stay simple enough that the next contributor can reason about a concurrency bug without consulting an architecture diagram.

### Alternatives considered

1. **Single thread for everything except autosave.** Input, stroke processing, rasterization, compositor dispatch, and undo capture all on the main thread; autosave on a background queue. Simplest possible model. Rejected because any main-thread stall (a slow stamp, a UI repaint, a system call) causes the input pipeline to drop or delay samples — directly visible to the user as cursor lag or jagged strokes.

2. **Main thread for UI/input, dedicated stroke thread for processing/raster, GPU for compositing, autosave on background.** Chosen. Decouples the latency-critical paths (input arrival on main, stamp work on stroke) and keeps the UI responsive even when stroke work is heavy.

3. **Multi-stage pipeline with parallel work between stages.** A pipeline of queues where smoothing, stamp placement, and rasterization run in parallel. Rejected because the stages are tightly coupled (each stamp depends on the previous one's tile state), pipeline hops add latency and variance, and we are not throughput-bound — a single serial stroke thread keeps up with 120 Hz input comfortably on Apple Silicon. The complexity is not justified by a measured need.

4. **Actors throughout, including for the inner stroke loop.** Modern, idiomatic Swift. Rejected for the inner loop because actor reentrancy across `await` points makes latency hard to bound, and because we do not need actor isolation for code that is already serialized on a single queue. Actors are still used at the high-level coordination layer where their ergonomics help.

### Pros

- **Predictable input latency.** The main thread is responsible for receiving stylus events and almost nothing else that competes for time on the latency-critical path. Stroke processing is offloaded the moment a sample arrives.
- **UI remains responsive under load.** Even when the stroke thread is busy with heavy stamp work, the main thread keeps redrawing menus, panels, and inspectors at 60 Hz.
- **Autosave is invisible to the user.** Writing a multi-megabyte bundle to disk does not stall input or compositing because it operates on a snapshot from its own thread.
- **One owner of mutable state.** The document tree, layer list, and tile cache have a single writer (the stroke thread). Most concurrency bugs in pro paint engines come from multiple writers competing; we eliminate that class of bug by construction.
- **Snapshots are cheap.** Copy-on-write of the document tree means a snapshot is essentially a reference bump; readers can hold them without blocking the writer.
- **Compositor reads tile textures directly.** Avoids snapshotting GPU-resident data and avoids the tax of per-frame copies. Synchronization is at coarse boundaries (tile-flush events) not per-pixel.
- **Clean actor / queue split.** High-level coordination uses actors and `async/await` where they help; latency-critical inner loops use serial dispatch and unfair locks where reentrancy would hurt.

### Cons

- **Snapshots add a small per-frame cost.** Building a copy-on-write snapshot of the document tree at frame boundary is cheap but not free. The compositor pays this cost every frame even when the document hasn't changed.
- **Cross-thread state for UI (current tool, brush, modifier state) needs an explicit channel.** We can't just call back into the main thread; we maintain a small set of atomically-updated values that both threads can read.
- **Debugging multi-thread bugs is harder than single-thread.** Even with one writer, race conditions in the snapshot mechanism or the tile-flush events are subtler than equivalent bugs in single-threaded code.
- **The model is more to learn for new contributors.** A flat single-thread model would be easier to onboard. The trade-off is paid up front in documentation and review attention rather than at runtime in dropped samples.
- **Mixing actors and dispatch queues invites confusion.** Future contributors will need to understand which primitive belongs where and why. We mitigate by keeping the rule simple ("inner loops use queues, coordination uses actors") and by writing it down here.

### Rationale

The model is shaped by where latency matters and where it does not. Input arrival and UI responsiveness must be sub-frame on the main thread; stamp work must be fast but does not have to be on the main thread; compositing is GPU work no matter what; autosave is slow I/O that must not be felt. Once those four are sorted, the partition follows.

We chose not to actor-ify the inner stroke loop because actors solve a problem we don't have (mutable state shared across many callers) and introduce a problem we don't want (reentrancy at `await` points in a latency-sensitive path). A single serial dispatch queue gives the same exclusive-access guarantee with predictable cost.

We chose snapshot-based reads over reader-writer locks because snapshots scale better to multiple readers (compositor, autosave, panels), simplify the writer's contract (the stroke thread never blocks waiting for readers), and play well with the copy-on-write document tree we already need for undo. The cost — a small per-frame snapshot build — is well below the budget and well-bounded.

### Forward implications

- **Tile flush boundaries need explicit GPU events.** When the stroke thread finishes writing a stamp into a tile, the next compositor frame that reads that tile must see the result. We use `MTLEvent` or `MTLFence` to express this dependency without a CPU-side wait.
- **The document tree and layer list use copy-on-write internally.** This is implied by the snapshot model and should be a foundational property of the data structures.
- **Undo capture happens on the stroke thread.** Per-tile deltas are recorded as part of the stroke commit step, before the snapshot used by the next compositor frame is published.
- **Autosave triggers from a timer or from a debounced "document dirty" signal.** It does not interrupt stroke work; it observes the document via snapshots between strokes.
- **UI-driven document edits (e.g. layer reorder, layer rename, blend mode change) are dispatched onto the stroke thread.** The UI sends a command; the stroke thread applies it under the same single-writer rule that pixel edits follow.

---

## 9. Undo/redo: per-stroke deltas, gesture-coalesced, RAM-windowed with full history persisted

### Decision

Undo and redo in Inkwell are built on a single ordered stream of **operation deltas** captured at user-gesture granularity. The same stream serves undo, redo, and (eventually) timelapse playback.

- **Step granularity.** One step per completed user gesture. Pixel edits: one step per committed stroke. Structural edits: one step per layer create/delete/reorder/rename/regroup, mask add/remove, visibility toggle, blend-mode change, opacity change. Continuous gestures (a slider drag changing opacity, a multi-step transform) are **coalesced** into a single step bounded by the gesture's start and end events.
- **Pixel delta format.** For each step that modifies pixels, the delta records the set of dirty tile IDs and the **before-pixels** of each dirty tile (after-pixels are the layer's current state). Tile deltas are **compressed** at capture time with zstd at a low compression level; the CPU cost is small and the storage savings are substantial on typical content.
- **Structural delta format.** A typed record describing the operation in enough detail to reverse it — e.g. "delete group at path /Layers/Folder1, group definition follows" or "set layer 17 blend mode from Normal to Multiply." Lives in the same ordered stream as pixel deltas, distinguished by record type.
- **Capture point.** All deltas are captured on the **stroke thread** at gesture commit, before the snapshot used by the next compositor frame is published. Single-writer rule from decision 8 is preserved.
- **In-memory window.** A configurable **soft cap** on recent history kept in RAM: "up to N steps OR M megabytes of compressed deltas, whichever is smaller." Default targets: 200 steps and 256 MB (subject to tuning). This is a working-set cap, not an availability cap.
- **Disk-backed full history.** Older history pages out to a `history` chunk inside the `.inkwell` bundle. The full step index lives in RAM at all times (so any step can be located quickly); only the delta payloads page out. When the user undoes far enough back that we cross the RAM window, we read deltas from disk on demand.
- **Linear redo semantics.** When the user undoes some steps and then performs a new edit, the redo stack is dropped. The history reflects the document's actual final state; this is what timelapse playback requires.
- **Failure mode: fail soft.** If a history entry cannot be read or decompressed (corrupted bundle, partial save), we log the failure, drop the unreachable history, leave the document state as-is, and surface a quiet notification. We never attempt destructive recovery that could corrupt the live document.

### Context

Almost every aspect of undo in Inkwell is already constrained by earlier decisions:

- Tile-based rendering (decision 4) makes per-tile deltas the natural unit and rules out whole-layer snapshots as the primary mechanism.
- Bitmap-layer rasterize-and-discard (decision 5) ties timelapse to the undo delta stream, requiring full document-lifetime history rather than a recent window.
- The document model with groups and masks (decision 7) requires the undo system to cover structural operations at the same fidelity as pixel edits.
- The threading model (decision 8) requires capture on the stroke thread, with snapshot-based reads from elsewhere.

What remained open were the storage format details, the in-memory cap, the coalescing rule, and the failure semantics — all settled in this decision.

### Alternatives considered

1. **Whole-layer snapshots per step.** Snapshot an entire layer's pixels before any edit. Rejected: at tile scale this is wasteful (most of the layer was untouched), and it scales poorly with document size and layer count. The tile-grain delta is dramatically smaller for typical edits.

2. **Per-stamp or per-sub-stroke granularity.** Each stamp placed during a brush stroke is its own undo step. Rejected: users would press `Cmd-Z` dozens of times to undo a single stroke, which no shipping paint app does. The user mental model is "undo the last thing I did," and "the last thing I did" is the stroke.

3. **RAM-only history with a hard cap.** Cap undo history at, say, 100 steps; older history is discarded. Rejected because it would prevent timelapse playback over the full document lifetime, which is the primary justification for the per-tile delta model in the first place.

4. **Branching history (Git-style) instead of linear redo.** Preserve undone branches so users can return to alternative explorations. Rejected: dramatically more complex UI and storage, ambiguous semantics for timelapse, and not a standard feature in this category. Could be revisited as a future addition behind a flag.

5. **Per-stroke deltas, coalesced gestures, RAM window with disk-backed full history, linear redo, fail-soft.** Chosen.

### Pros

- **Reuses what we already have.** The tile cache, the dirty-tile tracking, and the stroke commit step all exist for rendering reasons; capturing deltas at commit is an additional pass over the same data, not a new system.
- **Memory cost is bounded.** The RAM window keeps the working set predictable regardless of session length. A user can paint for hours without the in-memory undo state ballooning unboundedly.
- **Full document lifetime history is available.** Disk-backed older history means undo never silently runs out, and timelapse has the data it needs to replay the whole document's creation.
- **One stream covers everything.** Pixel edits and structural edits live in the same ordered stream, distinguished by record type. The undo system has one log to maintain, not two.
- **Compression is cheap and effective.** zstd at a low level is fast enough to run on the stroke thread at commit without affecting input latency, and tile deltas (often containing large constant-color regions) compress well.
- **Gesture coalescing matches user expectation.** Adjusting a slider produces one undo step, not hundreds. Users do not have to think about the granularity; they get the right behavior by default.
- **Linear redo is predictable.** Standard semantics; no branching state for users to lose track of.
- **Fail-soft preserves the live document.** A corrupted history sidecar is a recoverable problem, not a data loss event. The document the user can see is the document they keep.

### Cons

- **Big strokes produce big deltas.** A full-canvas brushstroke that touches every tile produces a delta proportional to the canvas size. The RAM cap protects against accumulated memory but does not protect against any single step being large.
- **History sidecar adds bundle complexity.** Reading and writing the `history` chunk, indexing it, and handling partial writes is real work that would not exist in a RAM-only undo system.
- **Disk I/O when undoing into older history.** Undoing far enough back to cross the RAM window pays a small disk-read cost. We should ensure this read happens off the main thread to avoid stuttering the UI during long undo runs.
- **Compression adds CPU at commit.** zstd is fast but not free. Profiling will tell us whether the stroke thread can absorb it without affecting input feel.
- **Linear redo cannot represent branching exploration.** Users who undo, try something else, and want to return to the original branch cannot. We accept this as the standard for the category.
- **Coalescing rules can surprise users.** What counts as one gesture for a complex interaction (drag a slider, then click elsewhere, then drag again) needs documenting. We will need to settle and test the boundaries case by case.

### Rationale

The structure of this decision is driven by a single insight from the stroke-model decision: the data we record for undo is the data we record for timelapse. That symmetry collapses two separate systems into one ordered stream and makes most of the design choices fall out automatically.

Per-stroke granularity is settled by user expectation. Compression and disk-backing are the natural consequences of needing full-lifetime history without unbounded RAM. Gesture coalescing is the standard rule for sliders and continuous adjustments. Linear redo is what every paint app in this category does; departing from it would be a unique design statement we have no reason to make.

Fail-soft on corruption is the choice every long-lived document app should make. The cost of being conservative (occasionally lost history) is small; the cost of being aggressive (corrupting the live document while trying to recover) is catastrophic.

### Forward implications

- **Bundle format must define a `history` chunk.** Layout, indexing, append-only semantics, and atomic-write rules belong in the file format spec.
- **Compression library choice.** zstd is the recommendation; the decision belongs in the implementation phase but should be picked early to size the CPU budget.
- **Undo coalescing rule must be documented per gesture type.** Sliders, drag transforms, multi-tap operations — each needs an explicit start/end boundary.
- **A "history budget" preference may need to be exposed.** Users on smaller machines might want a smaller RAM window; users with very long documents might want a larger one.
- **Per-document history pruning may be needed long-term.** A document edited daily for a year could accumulate gigabytes of history. We will need a "trim history older than X" affordance, with a clear note that it disables timelapse for the trimmed period.
- **Undo UI shows undo and redo state.** Menu items reflect the next undoable/redoable step's name (e.g. "Undo Brush Stroke", "Undo Delete Layer").

---

## 10. Tablet input: full-fidelity NSEvent capture, no prediction, eraser-end switches tool

### Decision

The Inkwell canvas is a custom **`NSView` subclass** that handles raw `NSEvent` input directly. The canvas captures every available stylus parameter from every available event type, leaves the brush engine to decide what to use, and relies on macOS Tahoe's existing tablet driver ecosystem rather than implementing device-specific drivers.

- **Event types handled.**
  - `mouseDown`, `mouseDragged`, `mouseUp` are the primary sample channel. When the input device is a stylus, these events carry tablet data via `subtype == .tabletPoint` and expose pressure, tilt, rotation, and related accessors.
  - `tabletPoint` events are handled as a supplementary stream wherever they arrive.
  - `tabletProximity` events are handled to detect stylus presence, which end of the stylus is engaged (tip vs eraser), the device's unique ID, and the device's reported capability flags.
- **Stylus parameters captured per sample.** Position (window coordinates, transformed to canvas pixels by the current view transform), pressure (0…1), tilt-X and tilt-Y (with altitude/azimuth derived where useful), barrel rotation, stylus button state, eraser flag (from proximity), and an event timestamp. Parameters not reported by a particular device are recorded as "unsupported" rather than zero, so the brush engine can fall back rather than misinterpret missing data as data.
- **Event coalescing.** Disabled on the canvas window. macOS by default coalesces mouse-style events to one per refresh; for 120+ Hz stylus input this drops samples and produces visibly polygonal strokes. We turn off coalescing for the canvas and read every sub-sample carried by each event.
- **Motion prediction.** Not used in v1. macOS does not have a direct equivalent of iOS's `predictedTouches` for `NSEvent` tablet input. We render from raw samples and rely on Metal's low-latency presentation path. We will revisit if profiling on real users shows perceived input lag.
- **Device support.** Whatever the user's macOS Tahoe install can drive: Wacom (Bamboo, Intuos, Cintiq, etc.), Huion, XP-Pen, third-party Wacom-compatible tablets, and Apple Pencil exposed through Sidecar. We do not ship device-specific drivers and we do not contain device-specific quirk code at the input layer.
- **Hot-plug.** A new device ID appearing in a `tabletProximity` event is treated as a new stylus. No reconnect ceremony required; capability detection happens at first proximity.
- **Eraser-end behavior.** When `tabletProximity` reports the eraser end engaged, the input pipeline temporarily switches to the **Eraser tool** with the user's current eraser settings. When the tip end re-engages, the previous tool is restored. This matches the industry-standard behavior pro users expect from physical eraser-tipped styluses.
- **Coordinate space.** Events arrive in window coordinates. The canvas applies its current pan / zoom / rotate transform to produce canvas pixel coordinates. Pressure and other normalized values are coordinate-independent.

### Context

Decision 1 (AppKit + Swift, with Metal for rendering) already required a custom `NSView` subclass for the canvas — SwiftUI does not surface stylus parameters through its gesture system. What was left open was *what the canvas actually captures from the event stream*, *how the stream is treated* (coalescing, prediction, sample rate), and *which devices we explicitly support*. Those choices flow downstream to the brush engine, the stroke processor (which earlier decisions located on the stroke thread), and the user-visible behavior of physical stylus features (eraser end, barrel buttons).

### Alternatives considered

1. **Use PencilKit instead of raw `NSEvent`.** PencilKit is the iPadOS / Catalyst stylus framework; on macOS it is only relevant when running an iPad app via Catalyst or accepting input from an iPad over Sidecar in a Catalyst context. Rejected: Inkwell is a native Mac app supporting all macOS-driven tablets, not just Apple Pencil through Sidecar. PencilKit does not see Wacom or Huion tablets connected to a Mac.

2. **Handle only `mouseDragged` events; ignore `tabletPoint` and `tabletProximity`.** Every supported tablet delivers stylus data through `mouseDragged` with a tablet subtype, so this would not lose pressure or tilt. Rejected because it misses proximity transitions (no eraser-end detection, no "stylus is hovering" awareness for cursor preview, no device-ID tracking) and discards the supplementary `tabletPoint` stream where it arrives. Cheap to handle all three; expensive to retrofit later.

3. **Capture only position and pressure; ignore tilt and rotation.** Simpler stylus sample structure, smaller stroke-thread payload. Rejected because it permanently caps brush engine ambition at "the brush knows where and how hard, but not how the stylus is held." Several intended brushes (calligraphy, airbrush at angle) genuinely use tilt; rotation matters for the future Wacom Art Pen audience. Cheap to capture; impossible to invent later.

4. **Implement motion prediction in v1.** Synthesize one or two predicted samples ahead of the latest real sample to mask GPU latency. Rejected for v1 because macOS does not provide predicted samples and our own prediction is error-prone (a wrong prediction at stroke direction-change time produces a visible "wobble"). Apple Silicon's GPU latency is low enough that raw-sample rendering feels good without it.

5. **Implement device-specific quirk paths (e.g. for known-bad Huion or XP-Pen drivers).** Rejected for v1: we trust the OS's driver layer. If specific tablets misbehave at the OS level, the right fix is a vendor driver update or a documented known-issue, not a quirk path in our input code. We can revisit if widespread issues appear.

6. **Full event handling, full parameter capture, coalescing disabled, no prediction, OS-driven device support, eraser-end tool switch.** Chosen.

### Pros

- **Maximum data fidelity to the brush engine.** Every parameter the device reports reaches the brush engine. Brushes that want to use tilt or rotation can; brushes that only want pressure ignore the rest.
- **Full sample rate.** Disabling coalescing lets the canvas receive every stylus sample the OS exposes. Strokes look smooth at 120+ Hz instead of polygonal at refresh rate.
- **Eraser-end behavior is correct out of the box.** Pro users do not have to configure anything to make the eraser end of their stylus erase. It just does.
- **Hot-plug works without ceremony.** Users can plug in a tablet mid-session and continue drawing; the next proximity event registers the device.
- **No vendor driver code to maintain.** The OS handles per-device quirks. If a new tablet ships, it works as soon as macOS supports it.
- **Coordinate transformation is centralized.** The canvas applies one transform from window coords to canvas pixels; everything downstream sees canvas pixels. No transform-related bugs in the stroke processor or the brush engine.
- **Capability detection rides on existing events.** No separate device-enumeration code; `tabletProximity` tells us what each connected stylus reports.

### Cons

- **More events to process per sample.** Disabling coalescing increases event volume on the main thread. We are dispatching to the stroke thread immediately, so the main-thread cost is small, but it is real.
- **Tilt and rotation are unevenly supported across devices.** Brushes that lean on tilt will feel different on tablets that do not report it. The fallback (treat unsupported parameters as neutral) is correct but does mean some brush behavior is device-dependent.
- **No motion prediction means GPU latency is felt directly.** On a system with unusual latency (perhaps a misbehaving driver, perhaps an external display chain), users may perceive lag. We do not have a built-in mitigation in v1.
- **Implicit hot-plug detection is best-effort.** A tablet that is plugged in but never enters proximity is invisible to us. This is not a real failure — proximity is the trigger for any actual use — but it means a Settings panel listing "connected tablets" would need its own device enumeration.
- **Eraser-end tool switch is a hidden behavior.** If a user does not realize their stylus has an eraser end, the temporary tool switch may surprise them. Mitigation: surface the behavior in the user manual and make sure the cursor or status bar reflects the current tool clearly.

### Rationale

The deciding stance is **capture everything, decide later**. The cost of capturing more parameters from each event is negligible — a slightly larger sample struct on the stroke thread — while the cost of *not* capturing is permanent. Brushes that one day want tilt cannot retrofit it onto strokes drawn before tilt was being recorded. Capturing the full set today preserves every future option.

Coalescing disabled and prediction off form a coherent stance: prefer the highest-fidelity raw signal we can get and put the smoothing budget into the stroke processor (which can apply curve fits and resampling with full visibility into the data) rather than into prediction (which guesses about samples that haven't happened yet). If profiling later proves perceived latency is a real problem, prediction can be added as a layered improvement; smoothing the raw sample stream cannot.

Trusting the OS for device support — rather than shipping device-specific code paths — keeps the input layer small and shrinks the maintenance surface. macOS's tablet driver ecosystem, while imperfect, is the right level of abstraction for an app of our size; chasing per-device quirks is a treadmill we do not need to be on.

### Forward implications

- **The stylus sample struct is the canonical input to the stroke processor.** Its definition (position, pressure, tilt-X, tilt-Y, rotation, buttons, eraser flag, timestamp, device ID) is fixed early and rarely changed.
- **Unsupported parameters are encoded explicitly, not as zero.** A `Pressure?` (or sentinel value) lets the brush engine distinguish "device reports 0 pressure" from "device does not support pressure" — these have different correct behaviors.
- **The brush engine is parameter-aware.** Each brush declares which stylus parameters it consumes; the brush settings UI exposes pressure curves, tilt mappings, and rotation mappings only for parameters the active device supports.
- **The cursor preview reflects current device state.** When a stylus is in proximity, the cursor previews the brush at the appropriate tilt/rotation; when the eraser is engaged, the cursor reflects the eraser tool.
- **A "current input device" status surface is needed somewhere in the UI.** At minimum, the user should be able to tell which stylus the app last saw and what parameters that device reports.
- **Window-level event tuning is required at canvas creation.** Setting `acceptsTouchEvents`, disabling mouse coalescing, and enabling tablet event delivery are setup steps the canvas view must perform; they are not defaults.

---

## 11. Brush engine: data-driven stamp engine, GPU composition, four v1 brushes from one core

### Decision

Inkwell ships a **single stamp-based brush engine**. All v1 brushes — Marker, G-Pen, Airbrush, Eraser — are different settings over the same core. New brushes are added by editing a brush definition file, not by writing code. The core engine consumes stylus samples (with the full parameter set from decision 10), produces a stream of stamps, and composites those stamps into the active layer's tile grid on the GPU.

- **Brush definition is data, not code.** Each brush is a serializable struct (Swift `Codable`, persisted as JSON or property list) containing identity, stamp tip reference, spacing rule, parameter mappings, jitter, and accumulation rule. Built-in brushes live in the app bundle; user-edited brushes live in user data; future imported brushes (see ABR in the futures doc) land in the same format.
- **Stamp tip and grain.** Each brush has a required grayscale **tip texture** (the stamp shape — round, oval, calligraphy nib, etc.) and an optional **grain texture** that modulates the stamp to simulate paper or canvas texture.
- **Spacing.** Stamps are placed at a configurable percentage of brush size along the stroke path. Path between samples is interpolated linearly for short distances and with a Catmull-Rom curve for smoother sections.
- **Per-stamp parameter mappings.** Pressure → size, pressure → opacity, tilt → angle, rotation → stamp rotation, with optional jitter on each. Each mapping has a curve (see "Pressure curves" below) that maps the raw 0…1 device value to an effective 0…1 brush value.
- **Color jitter.** Optional per-stamp variation in hue, saturation, and value, useful for natural-media brushes.
- **Stroke-internal blend mode.** Each brush specifies how its stamps accumulate within a single stroke (e.g. "Normal" for a flat marker, "Lighten" for additive effects). The layer's own blend mode then determines how the committed stroke composites with layers below.
- **GPU-side stamp composition.** Stamp rasterization is a Metal **compute shader** that reads the tip and grain textures, applies the per-stamp parameters, and blends directly into the layer's tile texture. We do not allocate a CPU-side stamp buffer. On Apple Silicon's unified memory there is no upload step. The stroke thread builds a small batch of stamps per stylus sample and dispatches one compute pass per batch.
- **Pressure curves (provisional).** v1 uses a **cubic Bézier with two interior control points** as the placeholder representation. **The math and the user experience for pressure curves are explicitly subject to revision** per the project owner's pending design input. This decision documents the current implementation choice but does not lock it; later work may replace the representation, the editing UI, or both.

### The four v1 brushes (sketched)

- **G-Pen.** Hard-edged round tip. Pressure → size and pressure → opacity. Tight spacing. For comic inking and confident line work.
- **Marker.** Soft-edged round tip. Pressure → opacity, with size largely fixed. Translucent layered painting.
- **Airbrush.** Soft circular tip. Pressure → flow rate (paint emits continuously while held in place); low per-stamp opacity that accumulates over time.
- **Eraser.** Same engine as Marker, with the destination-out blend mode (or operating directly on alpha) so painted strokes remove pixels rather than add them.

The point is that all four are *the same engine with different settings*. Adding a fifth brush is a settings file, not a code change.

### Context

The brush engine is the component users will judge the app on. It is also the most central CPU/GPU collaboration: the stroke thread feeds it samples and parameters, the GPU rasterizes its output into tiles, and the tile cache (decision 4) holds the result. Earlier decisions have already constrained the design — Apple Silicon GPU compute, unified memory, 16-bit premultiplied tiles, single-stroke-thread mutation — so the remaining choices were the engine's shape and the format of brush definitions.

### Alternatives considered

1. **Stamp-based engine, brushes as data.** Chosen. Industry standard. One engine to optimize, brushes that can be edited and shared without recompiling.
2. **Per-brush hand-coded engines.** Each brush has its own implementation tuned to its needs. Rejected: code multiplies, cross-brush refinements (e.g. fixing an artifact at low pressure) have to be repeated, and adding a new brush is engineering work.
3. **Procedural brushes (no tip texture; shape computed in shader).** Powerful for some effects but limited for natural-media brushes that depend on a specific tip silhouette. Rejected as the v1 default; we may add procedural brush nodes as a layered feature later.
4. **CPU stamp composition with per-stamp GPU upload.** Predictable, simple to debug. Rejected because we already have unified memory and can compose directly on the GPU; CPU composition adds work without a benefit.
5. **Hybrid: simple brushes on GPU, complex brushes (future distortion brushes) on CPU.** A reasonable forward stance. Distortion brushes (in futures.md) sample the canvas and may use a different rasterization path; that does not change the v1 engine, which is uniformly GPU-composed.

### Pros

- **One engine to optimize.** Performance work on stamp composition, smoothing, parameter mapping, and tile updates pays off across every brush.
- **Brushes are user-editable.** A brush is a small JSON-shaped file. Power users can tweak; future ABR import can target the same format. This unlocks community brush libraries without engine work.
- **GPU composition matches the platform.** Apple Silicon's compute capability and unified memory make per-sample compute dispatches the natural pattern. No upload overhead, no per-stamp CPU rasterization.
- **Clean parameter pipeline.** The stylus sample (with all parameters) flows through smoothing, through per-mapping curves, and into the stamp dispatch. Each step is testable in isolation.
- **Brush identity is decoupled from brush behavior.** Renaming a brush, changing its icon, reorganizing categories — all data edits, never code.
- **Future brushes (texture-heavy, multi-tip, calligraphic) require no engine change** if they fit the stamp model. The model accommodates a wide range of natural-media behaviors.

### Cons

- **Some effects do not fit the stamp model cleanly.** Wet-edge brushes that interact with previously laid paint, distortion brushes that sample the canvas, and "smudge" tools that move existing pixels are not pure stamp engines. We will need a parallel path for these (deferred to future versions per the futures doc).
- **GPU compute dispatch overhead matters at high stamp rates.** A naive "one dispatch per stamp" would be slow; we batch stamps per stylus sample. The batching logic is a place where bugs would manifest as visible stamp-spacing artifacts.
- **Brush definitions need versioning.** As the engine evolves, brush settings will gain fields. Old brush files must continue to load. This is the standard "extensible Codable struct with version fields" problem; it costs forethought.
- **Tip texture quality is a real workload.** A few well-made tip textures define how the v1 brushes feel. Producing them is a design task with no shortcut.
- **Pressure curve representation is provisional.** The chosen cubic-Bézier-with-two-control-points may not survive contact with the project owner's planned redesign of pressure-curve math and UX. We have minimized blast radius by isolating curves behind a clear interface, but a representation change still touches the brush settings format and the brush settings UI.

### Rationale

The stamp-based, data-driven engine is what the rest of the industry uses because it is the right factoring of the problem. Stylus input naturally produces a path; brushes naturally consist of a stamp shape applied along that path with parameter modulation. Other factorings either repeat work (per-brush engines) or give up flexibility (procedural-only). Our v1 brush set is small enough that the question "is one engine enough?" is easy to answer yes; our future brush ambition (ABR, more natural-media brushes, possibly procedural nodes later) is well-served by the same engine plus future additions.

GPU-side composition is the right call on this platform. We are not trying to support a discrete-GPU upload-download model that does not apply here.

The pressure curve representation is the one part of this decision we are explicitly *not* locking in. The project owner has signaled that they have specific design input on pressure curves — both the math and the UX — that has not been fully articulated yet. Cubic Bézier with two control points is the placeholder we ship, isolated behind a curve-evaluation interface so it can be replaced without rippling through the engine.

### Forward implications

- **Pressure curve representation and editing UI are open design questions.** A future decision (or revision of this one) will document the chosen math and UX. Implementation should keep curve evaluation behind a small interface so the representation can change.
- **Brush definition format gets a version field.** Standard practice for any user-editable, long-lived format.
- **Brush settings UI is built early.** Even if the v1 brush set is fixed, the editor that lets us iterate on tip textures, spacing, jitter, and curves is what makes the engine tunable.
- **Tip and grain texture pipeline is needed.** Importing PNG/SVG textures, normalizing them, and packing them into a brush bundle is its own small system.
- **Stamp batching at the dispatch layer.** One Metal compute dispatch per stylus sample, with N stamps per dispatch (where N depends on spacing and per-sample motion). Batching shape and limits will need profiling.
- **The stamp rasterizer remains on the C++-migration candidate list** from decision 2. Profiling will tell us whether Swift's GPU-dispatch overhead is a real problem.

---

## 12. Selections: hybrid raster + optional vector, with the standard pro toolset

### Decision

Selections in Inkwell are represented as a **raster alpha mask** stored in the same sparse tile structure as layers and layer masks. When a selection is created from a shape tool whose intent is naturally a path, the engine **additionally** retains a **vector path** describing that shape. The raster mask is always present and is the source of truth for how selections constrain other operations. The vector path, when present, is used for crisp marching-ants display and for lossless transforms.

- **Tools.**
  - **Shape selections** (vector + raster): rectangle, ellipse, polygonal lasso.
  - **Freehand and color-based selections** (raster only): lasso, magic wand (color-similarity from a clicked pixel with a tolerance setting), color range (all pixels matching a target color across the layer).
  - **Quick Mask mode** (paint-the-selection): a toggleable mode that routes brush input to the selection mask instead of the active layer. The canvas shows a translucent overlay indicating the unselected region. Reuses the brush engine; no new rasterization path.
  - **Menu items**: Select All, Deselect, Inverse Selection, Select Similar (extends color-range across the document).
- **Anti-aliasing and feathering.** Selection masks are anti-aliased by default (alpha 0…1, not 0/1). Each selection has an explicit **feather amount** (Gaussian blur applied to the mask, in pixels) configurable per selection.
- **Selection arithmetic (modifier-driven).**
  - **Shift** + new selection → add to existing.
  - **Option** + new selection → subtract from existing.
  - **Shift + Option** + new selection → intersect with existing.
  - When both representations exist, arithmetic happens at the raster level; the vector path is dropped on any operation that cannot be expressed as a clean path operation.
- **Marching ants display.** A small Metal overlay shader animates a dashed outline at the selection edge. When a vector path is present, the shader renders directly from the path for crispness. When only a raster mask exists, the shader traces the 50% alpha threshold.
- **Floating selection transforms.** Move, scale, rotate, and free-transform of the selected pixels happen as a transient floating pseudo-layer that follows the transform handles. Commit applies the transform to the underlying layer; cancel reverts. Vector-path selections transform losslessly until commit; raster selections resample at commit.
- **Constraint application.** A selection is enforced in the GPU compositor by **multiplying the operation's alpha by the selection mask alpha** at each pixel. This applies uniformly to every operation that writes pixels: brush stamps, fills, transforms, filters, paint-bucket. The constraint is a single extra texture read in the relevant shader, not a per-operation code path.
- **Persistence.** The active selection (raster mask, optional vector path, feather amount) is saved with the document. Closing and reopening preserves the in-progress selection.

### Context

Selections touch nearly every other operation in a paint app — brush, fill, transform, filter, layer ops, copy/paste. Their representation has to be cheap to apply per-pixel (the brush engine consults it on every stamp) and rich enough to support the full pro toolset (shape, freehand, color-based). The right answer here is well-established by prior art; the decision is mostly about making sure our specific implementation respects the constraints set by earlier decisions (tile-based rendering, GPU composition, single-stroke-thread mutation).

### Alternatives considered

1. **Raster only.** Simplest representation. Rejected because shape selections (rectangle, ellipse, polygonal lasso) lose their inherent crispness — marching ants would be drawn from rasterized edges, and transforms would resample pixels at every step rather than transforming the path. The cost of those losses is visible in normal use.

2. **Vector only.** Compact and lossless under transform. Rejected because it cannot represent freehand lasso or color-based selections (there is no meaningful path), and because rasterizing the path on every brush stamp to apply the constraint would be wasteful — the brush engine wants a tile-aligned mask, which is exactly what a raster is.

3. **Raster primary, vector additional when meaningful.** Chosen. Pays for both representations only when both add value; degrades gracefully to raster-only when no path applies.

4. **Path-on-demand (raster primary, vector reconstructed by tracing the mask edge when needed).** A clever middle option. Rejected because edge-tracing produces a path that looks different from the user's intent (a "rectangle" selection becomes a polygon with hundreds of vertices), and the reconstruction is not cheap.

### Pros

- **Cheap per-pixel constraint application.** Brush stamps, fills, and transforms multiply by one extra texture lookup in the GPU shader. Selections do not have to be threaded through every operation's code path; the compositor handles them uniformly.
- **Crisp shape-based selections.** Marching ants on a rectangle look like a rectangle, not a stair-stepped raster outline.
- **Lossless transforms when intent is geometric.** A user scaling a rectangular selection moves a path; the rasterization happens once at commit, not on every drag frame.
- **Standard pro toolset.** Every selection idiom users expect from Photoshop and similar apps is supported. No surprises.
- **Quick Mask reuses the brush engine.** Painting a selection is the brush engine writing into a tile-stored mask. No second rasterization path; no new optimization surface.
- **Selections survive save/load.** Users do not lose a complex selection by saving and reopening, which is a real (and common) frustration in tools that do not persist them.
- **Selection mask uses the existing tile cache.** No new memory model. The tile cache, dirty tracking, and undo system all treat the selection mask the same way they treat layer masks.

### Cons

- **Two representations to keep consistent.** When both raster and vector exist, edits that affect one have to either propagate to or invalidate the other. Standard practice is to drop the vector when an operation cannot be expressed cleanly as a path edit; this is correct but is a real maintenance discipline.
- **Vector-to-raster rasterization at selection creation.** A shape selection has to rasterize its path into the mask once at creation. Cheap on the GPU but not free, and the rasterization quality (anti-aliasing, exact edge alignment) has to be tuned.
- **Marching-ants shader is its own surface.** A small but real piece of Metal code, animated and tied to the active selection's representation.
- **Floating selection transforms add UI surface.** Transform handles, commit/cancel affordances, hover state, modifier-aware behavior. Standard and expected, but each detail has to be designed and built.
- **Quick Mask is a modal feature with a hidden hotkey.** Users have to know about it; first-time users will not discover it without onboarding hints.
- **Persisted selections add to the document state.** The save format must record selection mask tiles and the optional path. Atomic save complexity grows accordingly.

### Rationale

Hybrid representation is the only choice that gets both cases right. Raster-only loses the geometric crispness of shape selections; vector-only cannot describe the selections users actually make most of the time (freehand, wand, color-range). The cost of carrying both — a small consistency discipline at edit time — is the smallest cost on the table.

GPU-side constraint application is what makes selections affordable to enforce uniformly. Implementing the constraint in the compositor as a one-extra-texture-read multiplication means that every operation that ever writes pixels respects the selection automatically; no operation can forget to consult it.

Persisting the selection with the document is a small file-format addition with a large UX payoff. Users routinely make selections that take real effort (carefully isolating a character against a complex background) and losing those on save is exactly the kind of small papercut that makes a tool feel unprofessional.

### Forward implications

- **Selection mask uses the same tile cache layout as layer masks.** A "mask tile" is a generic structure; whether it is attached to a layer or to the document's selection state is a metadata distinction.
- **Compositor reads the selection mask each frame.** When no selection is active, the compositor short-circuits this read. When a selection exists, the constraint is enforced in every pixel-writing operation.
- **The save format includes a `selection` chunk.** Stores the raster mask tiles, the optional path, and the feather amount.
- **The undo system records selection changes as structural ops.** Per decision 9, gestures that change the selection (creating, modifying, deselecting) are undo-coalesced steps in the same stream as pixel and layer edits.
- **The marching-ants shader has its own small Metal pipeline.** Rendered as a screen-space overlay over the canvas, animated by a low-frequency timer (~10 Hz).
- **Floating selection is a transient pseudo-layer in the compositor.** It composites in-place at the layer's position, displaced by the in-progress transform; on commit, it merges into the underlying layer and the selection mask updates to the new region.
- **Quick Mask mode is a UI mode flag.** When active, brush input writes to the selection mask tile grid instead of the active layer's tile grid. The brush engine is unchanged.

---

## 13. View control: cursor-anchored zoom and rotate, single transform matrix

### Decision

The canvas view applies a **single composed transform** (scale, rotation, translation) that maps canvas pixels to window points for display. The inverse transform maps incoming stylus and mouse events back to canvas pixels. This transform is the only source of truth for view state, and one matrix inversion per event covers all input mapping.

- **Pan.** Two-finger trackpad scroll, **Space + drag** (universal modifier, works with stylus or mouse), and a selectable persistent **Hand tool** for users who prefer a sticky pan mode.
- **Zoom.** Pinch on trackpad (cursor-anchored), **Cmd + scroll** (cursor-anchored), **Cmd + plus / minus** (center-anchored), **Cmd + 0** to fit to window, **Cmd + 1** to zoom to 100%.
- **Rotate.** Two-finger trackpad rotate gesture (cursor-anchored), **R + drag** as the stylus-friendly alternative (anchored at the cursor at drag start), **Shift** held during rotation snaps to 15° increments, **Shift + R** resets rotation to 0°.
- **Pivots.**
  - Pan has no pivot; it is pure translation.
  - Zoom anchors at the cursor for pinch and Cmd+scroll; at the canvas center for keyboard zoom.
  - Rotate anchors at the cursor at the moment the gesture begins.
- **Mid-stroke navigation.** When a navigation gesture (pan, zoom, rotate) starts during an in-flight stroke, stylus sample emission **pauses** for the duration of the gesture and **resumes** when the gesture releases. If the stylus is still down at resume, the stroke continues with a synthetic continuation sample so the user does not have to lift and re-engage.
- **Held-modifier temporary tool switches** (separate from the eraser-end behavior in decision 10).
  - **Cmd** held with a brush tool → temporary **eyedropper** (pick color from canvas).
  - **Option** held with a brush tool → temporary **eraser**, applying the user's current eraser settings.
  - **Tab** toggles all panels for a full-screen canvas view.
- **Zoom range.** Minimum is 1% or "fit to window" (whichever is smaller for the current document and window size). Maximum is 6400% (64×). Below or above is rarely useful and is clamped.

### Context

View control is a small surface in lines of code but a large surface in user feel. The decision space is well-explored — every pro paint app converges on roughly the same set of gestures and modifiers — but the *anchoring* of zoom and rotate is where apps either feel right or feel wrong. Anchoring at the cursor lets a user zoom into the part of the canvas they are working on without re-panning; anchoring at the center forces a re-pan after every zoom and is the single biggest navigation papercut in apps that get this wrong.

This decision also has to coexist with earlier ones: the canvas is a custom `NSView` (decision 1, decision 10), input flows through the stroke thread (decision 8), and stylus events arrive with full parameter fidelity (decision 10). The view transform sits between window-space input and canvas-space stroke processing.

### Alternatives considered

1. **Separate scale, rotation, and translation values, composed at draw time.** Equivalent in effect to a single composed transform but more intuitive to reason about for some operations. Rejected because the matrix form is the more direct representation for the GPU (it goes straight into the vertex shader), and because reading "the scale" or "the rotation" out of separate fields can drift from the rendered state when partial updates happen.

2. **Center-anchored zoom and rotate (system default).** Simpler to implement (the pivot is constant), but it forces the user to re-pan after every zoom. Rejected: this is the navigation papercut that pro paint apps universally avoid. Cursor-anchored is the right default; anything else is fighting user expectation.

3. **Hand tool only, no Space + drag modifier.** Simpler keyboard model. Rejected because Space + drag is the cross-app standard for pan, expected by anyone coming from Photoshop, Figma, Procreate, or similar tools, and works mid-stroke without committing the active stroke.

4. **Mid-stroke navigation cancels the stroke.** Simpler implementation; the user has to start the stroke over after navigating. Rejected because users routinely zoom in mid-stroke to refine a detail; cancelling the stroke breaks that workflow. Pause-and-resume is more code, much better UX.

5. **Cursor-anchored zoom and rotate, Space + drag, Hand tool, mid-stroke pause-and-resume, standard held-modifier tool switches.** Chosen.

### Pros

- **Cursor-anchored navigation feels right.** Users zoom into the part of the canvas they are working on; rotation pivots around the part of the canvas they are working on. No re-pan after every zoom.
- **Single transform matrix is computationally clean.** One matrix multiplication for display, one inverse for input mapping. The rest of the engine deals in canvas coordinates only.
- **Mid-stroke navigation preserves work.** Users do not lose a stroke because they wanted to zoom in. The pause-and-resume model matches what the user means by "I want to look at this more closely."
- **Shift snapping for rotate is the standard "I want a precise angle" affordance.** 15° steps cover the common useful angles (0, 15, 30, 45, 90, etc.).
- **Held-modifier tool switches are fast and tactile.** Users can sample a color or erase a stray pixel without committing to a tool change.
- **Hand tool gives non-modifier-fans a persistent mode.** Some users prefer a sticky pan tool, especially when working on an iPad-via-Sidecar setup with limited keyboard access.
- **Zoom range is bounded sanely.** Excludes useless extremes (zoom to 0.01% accomplishes nothing) without limiting realistic workflows.

### Cons

- **Cursor-anchored math is more involved than center-anchored.** Each zoom or rotate operation has to convert the current cursor position into canvas coordinates, apply the new transform, and re-translate so that the same canvas point lands under the cursor. This is well-understood math but a place where bugs (cursor drift after repeated operations) can hide.
- **Mid-stroke pause-and-resume needs careful definition.** What counts as "still in the same stroke" when the gesture finishes? We pause sampling, but if the user lifts the stylus during the navigation, the next contact is a new stroke. The state machine for this is small but real.
- **The R-key rotate hotkey conflicts with no current tool but is a future risk.** Future tools that want to live on R (e.g. some apps use R for "rectangle") will conflict with the rotate gesture. We accept R for rotate as the established convention.
- **Held modifiers can be a discoverability problem.** First-time users do not know that Cmd-during-brush samples color. We mitigate via the user manual and tooltips, but this is a known UX gap for any tool that relies on modifier conventions.
- **Trackpad gesture detection competes with click-and-drag.** Distinguishing a two-finger pan from a click-and-drag from a pinch is the OS's job, but tuning gesture thresholds (especially the start of a pinch when fingers are nearly parallel) can be finicky.
- **Tab to toggle all panels is a hidden feature.** Users will not discover it without onboarding. Standard pro-app behavior, but worth surfacing in the UI somewhere.

### Rationale

The cursor-anchored pivot is the deciding factor and it is essentially non-negotiable for a paint app. The rest of the design follows from a desire to match cross-app standards (Space+drag, pinch zoom, trackpad rotate gesture, Cmd+0/Cmd+1 for fit/100%) so that users coming from any other pro tool can navigate Inkwell without learning new muscle memory.

Mid-stroke pause-and-resume is more implementation work than cancelling the stroke would be, but it is the behavior every serious paint app uses, and the alternative is a workflow papercut users hit dozens of times an hour. Worth the cost.

The held-modifier tool switches (Cmd → eyedropper, Opt → eraser, Tab → panels) are conventions inherited from Photoshop and shared by every tool in this category. We do not invent new conventions here; using familiar ones reduces friction for the audience we want.

### Forward implications

- **The canvas view holds the view transform and is the input authority.** All input events get transformed at the canvas layer; nothing downstream sees window coordinates.
- **The stroke processor receives canvas-pixel coordinates only.** It is unaware of the view transform, which means brush sizes and spacing are always in canvas pixels (matching decision 7's "DPI is metadata-only, brush sizes are pixels").
- **The stylus sample buffer for an in-flight stroke survives navigation gestures.** Pause and resume operate on the buffer, not on a freshly-started stroke.
- **The R-key rotate hotkey reserves R from the tool keymap.** Future tools that might want R need a different binding.
- **The cursor preview reflects view rotation.** When the canvas is rotated, the brush preview and tilt indicators rotate with it, so the user sees the brush in canvas-relative orientation.
- **The compositor receives the view transform per frame.** Used for the final blit from canvas-space tiles to window-space pixels, including any rotation and zoom.

---

## 14. Native file format and export/import pipeline

### Decision

Inkwell uses a **macOS document bundle** named `.inkwell` (a directory presented as a single file by Finder) for its native save format, and supports **PSD as export-only** plus PNG and JPG for export and flattened import. The detailed byte-level layout of the bundle is intentionally deferred to a separate document — **`FILEFORMAT.md`** — to be authored when implementation starts. This decision sets the high-level shape; `FILEFORMAT.md` will be the authoritative reference for chunk types, headers, byte orders, and version negotiation.

#### Bundle contents

A `.inkwell` bundle contains the following at its top level:

- **`manifest.json`** — document metadata, format version, layer tree definition, references to tile/history/asset locations, embedded color profile reference. Human-readable for diagnosability; small enough to load eagerly.
- **`tiles.bin`** — a single packed store containing all layer and mask tile pixel data, with a header index mapping `(layer_id, mask?, tile_x, tile_y)` to byte ranges. Append-only writes for new and edited tiles; periodic compaction reclaims space from overwritten tiles.
- **`history.bin`** — append-only stream of undo/timelapse deltas (per decision 9), with a length-prefixed record format so partial appends after a crash are detectable and recoverable.
- **`assets/`** — embedded brush tip textures, custom brushes saved to the document, and any embedded ICC profiles. Each file in this directory is a normal PNG / JSON / ICC asset, identified by a stable name.
- **`thumbnail.png`** — a small flattened preview at a known size, for Finder QuickLook and the macOS recent-documents UI. Refreshed at save time.

#### Save and load semantics

- **Atomicity at the bundle level.** Saves write to a sibling temporary directory, `fsync` the contents, then atomically rename into place. A crash mid-save leaves either the previous good bundle or the temporary directory; never a half-written final bundle.
- **Atomicity within the bundle.** `history.bin` and `tiles.bin` are append-only; their length-prefixed records let us truncate the trailing partial record after a crash. The manifest is rewritten in full each save and is small enough that this is cheap.
- **Versioning.** The manifest carries a `format_version` integer. The reader checks compatibility on open: a newer-than-supported version is refused with a clear error; an older version triggers an in-memory migration step, after which the next save produces the current format. Migration code is preserved in the codebase indefinitely; we do not remove old-format readers.
- **Packed tile store over many-small-files.** Filesystems, Time Machine, and iCloud Drive all behave better with a few large files than with thousands of small ones. The packed store costs us slightly more careful index management in exchange for materially better behavior under sync and backup.

#### PSD export — fidelity policy

- **Layer types:** bitmap layers and groups round-trip cleanly. Future vector layers (when they ship) export as rasterized bitmap layers.
- **Blend modes:** a published mapping table (lives in `FILEFORMAT.md` or its own short doc). Modes PSD does not have map to the closest available equivalent, with a documented loss.
- **Masks:** Inkwell layer masks map directly to PSD layer masks.
- **Selections:** the active selection (raster + optional vector) maps to a PSD saved selection (alpha channel).
- **Color profile:** the document's embedded profile is written into the PSD, defaulting to Display P3.
- **Bit depth:** the user chooses 8-bit, 16-bit, or 32-bit float on export; default 16-bit (matching our internal precision per decision 6). 8-bit incurs a quantization step; 32-bit float is lossless and large.
- **A user-facing fidelity table** documents what is preserved exactly, what is approximated, and what is lost. Lives outside ARCHITECTURE.md; referenced from the user manual.

#### PNG and JPG export

- **Always flattened** to a single composited image at the document's pixel dimensions.
- **Profile-tagged** with the document's working profile (Display P3) or sRGB at user choice.
- **Gamut mapping for sRGB output**, applied when the document contains colors outside the sRGB gamut. Default mapping policy: perceptual; relative-colorimetric available as an option for users who prefer it.
- **Transparency preserved for PNG.** JPG flattens against a user-configurable background color, defaulting to white.

#### Import behavior

- **PNG / JPG.** Drag-drop, File → Open, or paste creates a new document with the imported image as a single bitmap layer. Embedded color profile is read and converted into the working space (Display P3); images with no profile are assumed sRGB.
- **PSD.** File → Open imports the layer tree with best-effort fidelity, mapping blend modes through the same table used for export, reading layer masks, and converting embedded color profile to working space. Unsupported PSD features (text layers, smart objects, adjustment layers) import as rasterized bitmap layers with a flag noting the conversion. The import path is documented in the same fidelity table.

### Context

Earlier decisions named the native format (`.inkwell` bundle in decision 7), constrained tile storage to be sparse (decision 4), required full-lifetime undo persistence (decision 9), and committed Display P3 working space (decision 6). What was open was the bundle's internal organization, the tile-storage strategy (many small files vs packed store), the export fidelity policy across formats, and the import behavior. This decision settles those at the architectural level and defers implementation-grade detail (chunk byte layouts, magic numbers, header CRCs, exact compaction policy) to `FILEFORMAT.md`.

### Alternatives considered

1. **Many-small-files tile storage** (one file per tile under `tiles/<layer>/<x>_<y>.tile`). Trivially atomic per-tile, simplest possible append/replace model. Rejected because filesystems, Time Machine, and iCloud Drive handle thousands of small files poorly. A documented packed store is a better long-term choice for sync, backup, and Finder responsiveness.

2. **SQLite or another embedded database for the bundle.** Mature transactional semantics for free. Rejected because an opaque database file is hard to inspect or recover from corruption, and we do not need transactional semantics across the whole bundle — append-only streams plus a small re-written manifest is sufficient.

3. **PSD as the native save format.** Already rejected in decision 7; reaffirmed here. PSD cannot represent our undo/timelapse stream, our exact tile layout, our future layer types, or every blend mode we want.

4. **Single-file format with a custom container** (instead of a directory bundle). Friendlier to users who copy a single file between machines without bundle awareness. Rejected because Finder presents bundles as single files anyway, every other pro Mac creative app uses bundles, and bundles are dramatically easier to evolve.

5. **No format version field; rely on schema autodetection.** Tempting for "we will figure it out later." Rejected: the cost of including the field is one integer; the cost of not having it is forever painful when v2 changes layout.

6. **Bundle with a packed tile store, append-only history, JSON manifest, versioned, with PSD/PNG/JPG export and PSD/PNG/JPG import as described.** Chosen.

### Pros

- **One internal organization for everything.** Tiles, history, masks, assets, and metadata all live under one bundle root with predictable names. New chunks (future features) drop in without disturbing existing ones.
- **Sync- and backup-friendly.** A few large files behave well under iCloud Drive, Time Machine, Dropbox, and Git LFS. Many small files do not.
- **Atomic save by construction.** Temp-directory + atomic rename means there is no window in which the bundle is half-written. Recovery from a crashed save is automatic on next launch.
- **Versioning is cheap insurance.** A single integer in the manifest, plus a migration discipline, lets the format evolve without breaking existing files.
- **Human-readable manifest.** A user with a corrupted bundle can open the manifest in a text editor and at least see what the document was. Diagnostic-friendly.
- **PSD export is comprehensive but bounded.** A documented fidelity table tells users exactly what does and does not survive the round trip; no surprises.
- **Import paths normalize everything to working space.** Imported content arrives in Display P3 with predictable color behavior, regardless of source format.
- **`FILEFORMAT.md` deferred is honest.** The detailed byte layout will be authored when implementation starts and the trade-offs are concrete; locking in those details now would be guessing.

### Cons

- **Packed store needs careful index management.** Append-only with periodic compaction is a real mechanism with edge cases (compaction during save, recovery from a crash mid-compact). Manageable but non-trivial.
- **Migration discipline is forever.** Every format change, however small, has to come with a tested migration path. Old-format readers must remain in the codebase.
- **PSD fidelity table is a real maintenance surface.** Every change to our blend modes, layer types, or color handling has to update the table. An inaccurate table is worse than no table.
- **Bundle structure occasionally surprises users.** A user who right-clicks → "Show Package Contents" sees the internals. This is the standard macOS convention and users will not lose data, but it is a small confusion vector.
- **Gamut mapping for sRGB export has subjective choices.** Perceptual versus relative-colorimetric produces visibly different results for some images. We default and offer an option, but the choice is not invisible.
- **PSD round-trip is not perfect.** Documents that exercise features PSD does not represent (or that PSD represents differently) lose information. Disclosed in the fidelity table; still a real cost.
- **`FILEFORMAT.md` does not yet exist.** Implementers will need to author it before writing the codec; this is an explicit forward task.

### Rationale

The deciding factors are evolvability, sync-friendliness, and atomicity. A bundle with a packed tile store and an append-only history stream gives us all three: new features add new chunks, the filesystem is happy with a small number of large files, and atomic rename plus length-prefixed records make crash recovery a non-event. The architecture decision documents the shape; the byte-level details belong in their own spec because they will need to be precise and exhaustive in a way that does not belong in a design document.

PSD as export-only (rather than a primary format) was settled in decision 7 and the fidelity policy here flows from it: we treat PSD as a respectful interop target with documented losses, not as a contract we have to fulfill on every save. Users who need full fidelity save `.inkwell`; users who need to hand off to Photoshop export PSD with eyes open about what travels.

Deferring `FILEFORMAT.md` is the right call. Decisions about CRC choice, chunk magic numbers, byte order conventions, and exact compaction triggers are implementation work that benefits from being authored against actual code, not against speculation. We commit here to writing it; we do not pretend to write it now.

### Forward implications

- **`FILEFORMAT.md` is a required deliverable** before format-touching code is written. It will document: every chunk type, byte layout, byte order, header CRCs, format version negotiation, append/compact rules, error handling, and the exact PSD fidelity table.
- **A migration framework lives in the codebase from v1.** Even if v1 has no migrations, the structure for "read manifest version, dispatch to migrator if older, save in current format on next save" is set up early so v2 does not have to retrofit it.
- **The packed tile store has its own lifecycle.** Compaction strategy, when triggered, how it interacts with active strokes, and how it survives crashes are subjects for `FILEFORMAT.md` and for the implementation phase.
- **A PSD codec is a non-trivial dependency.** Whether we write our own (educational, full control), use an existing library (faster start, possible C++ bridge per decision 2's "PSD codec" hot-path note), or fund a contractor is an open question for the implementation phase.
- **PNG and JPG codecs come from system frameworks** (`ImageIO`). No third-party codec needed.
- **Color management on import and export uses ColorSync / Core Graphics** for ICC profile handling. The gamut mapping policy choice (perceptual vs relative-colorimetric on sRGB export) is exposed in the export sheet UI.
- **The thumbnail is generated on save.** A small composited preview rendered into a known-size PNG lives at the bundle root for Finder.
- **A recovery path for partial saves is required at startup.** If the app finds a `.inkwell.tmp` next to a `.inkwell` on launch (suggesting a crashed save), the user is offered the older bundle and the temp is cleaned up after diagnostic logging.

---
