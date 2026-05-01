# Rendering

The graphics stack: how layer state turns into pixels on screen. Tile-based GPU storage, the color and blend math we composite with, and the view transform that maps canvas space to window space.

This file is part of the Inkwell architecture corpus. Decision numbers are global across the corpus; the index lives in [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

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

## 6. Color and blending: Display P3, 16-bit, premultiplied, gamma-space blends

### Decision

The Inkwell engine adopts the following color and blending model for all internal work:

- **Working color space:** Display P3.
- **Internal precision:** 16-bit per channel (64 bpp RGBA) for tile storage, with 32-bit float intermediates on the GPU during compositing and blend-mode math.
- **Alpha handling:** Premultiplied alpha throughout the pipeline — in tiles, in stamp output, in compositing, and at every internal boundary.
- **Blend math:** Performed in gamma-encoded space (sRGB-style transfer curve) by default, matching Photoshop's blend-mode behavior. A "linear blending" option may be added later as a per-document opt-in but is not part of v1.
- **Color profile handling:** Imported PNG, JPG, and PSD content is converted from its embedded profile (or assumed sRGB if none) into the working Display P3 space. Exported files are tagged with the appropriate ICC profile (P3 by default, sRGB on user request, with gamut mapping where needed).

> **Current implementation.** Premultiplied alpha and gamma-space blending are live. **Display P3 working space and 16-bit tile precision are deferred** — the engine currently operates in sRGB with `.rgba8Unorm` (8-bit per channel) tile storage throughout. See [`design/COLOR.md`](../../design/COLOR.md) for the full gap summary and [`FUTURES.md`](../../FUTURES.md) under "Phase 9 Pass 2 — Display P3 working color space + gamut mapping" for the roadmap entry.

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

  > **Implementation note.** The shipped code is simpler than "pause and resume" implies. Because `sampleFor(event:)` converts stylus positions to canvas-pixel coordinates immediately using the current view transform, in-flight navigation (which only mutates the view transform) does not disturb the stroke buffer at all. The next sample is converted with the updated transform and lands at the correct canvas position automatically. There is no explicit pause/resume state machine. See [`design/COORDINATES.md`](../../design/COORDINATES.md) for the coordinate-space explanation.
- **The R-key rotate hotkey reserves R from the tool keymap.** Future tools that might want R need a different binding.
- **The cursor preview reflects view rotation.** When the canvas is rotated, the brush preview and tilt indicators rotate with it, so the user sees the brush in canvas-relative orientation.
- **The compositor receives the view transform per frame.** Used for the final blit from canvas-space tiles to window-space pixels, including any rotation and zoom.
