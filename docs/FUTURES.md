# Inkwell Futures

This document tracks work that is **deliberately out of scope for v1** but worth doing eventually, plus known UX gaps and architectural revisit points. It exists so that the v1 scope cuts in `PLAN.md` are not forgotten, and so future contributors can see what we decided to defer and why.

Items here are grouped roughly in order of how likely we are to pick them up, but priority is not committed — the order is suggestive.

---

## Phase pass-2 deferrals (closest to picked up)

These are direct deferrals from Phases 5–11. The architecture and groundwork are already in place; the work is bounded.

### Phase 5 — undo / timelapse history persistence

The format reserves the `history.bin` chunk in the `.inkwell` bundle (per `ARCHITECTURE.md` decision 9). v1 readers ignore its absence; v1 writers don't yet emit it. Persisting the delta stream needs:

- A binary record format for tile-delta and structural-op records (length-prefixed, append-only).
- Replay code that rebuilds the in-memory undo manager state at document load.
- Integration with `Document.registerLayerStrokeUndo` and `registerMaskStrokeUndo` to write each step as it commits.

Once shipped, this also unlocks the timelapse playback UI (see "Timelapse playback UI" below).

### Phase 7 Pass 2 — selection completeness

- Polygonal lasso, magic wand (color similarity with tolerance), color range (color match across the canvas).
- Quick Mask mode: paint the selection with any brush (route brush input to the selection's tile grid; reuse the mask stamp pipeline).
- Floating-selection transforms (move / scale / rotate the selected pixels as a transient pseudo-layer with commit / cancel).
- Per-selection feather slider (Gaussian blur applied to the mask).
- Vector path retention for shape selections (rectangle / ellipse / polygonal lasso) — keeps marching ants crisp under transform and enables lossless transforms before commit.
- Selection-state undo: selection edits (rect / ellipse / lasso, Select All, Invert, Deselect) aren't yet on the undo stack.

### Phase 9 Pass 2 — layer-aware PSD round-trip

The flat-composite PSD export from Pass 1 covers basic interop but loses the layer hierarchy. Pass 2 is a proper PSD codec:

- Write the layer-and-mask-info section with one record per Inkwell bitmap layer: name, opacity, blend mode, channel data.
- Map our v1 blend modes (Normal / Multiply / Screen / Overlay) to PSD blend-mode keys; expand to a fuller Photoshop set in the same pass.
- Write the embedded ICC profile as image resource 1039.
- Optionally support 16-bit channels.
- Implement a PSD parser for import that reads the layer tree back as Inkwell bitmap layers and groups (deferring text / smart-object / adjustment layers).
- Optionally export Inkwell layer masks as PSD layer masks.

See [`PSD_FIDELITY.md`](PSD_FIDELITY.md) for the current fidelity table; Pass 2 fills in the gaps it documents.

### Phase 9 Pass 2 — Display P3 working color space + gamut mapping

`ARCHITECTURE.md` decision 6 commits Inkwell to Display P3 internally with 16-bit channels. The implementation today uses sRGB throughout (8-bit `.rgba8Unorm` tiles, sRGB-tagged exports). Promoting to P3 requires:

- Tile texture format change (`.rgba8Unorm_srgb` or 16-bit P3) and shader updates.
- Working-space conversion at import and export.
- Gamut mapping (perceptual or relative-colorimetric) at sRGB export.
- Embedded P3 profile in PNG / JPEG / PSD output.

### Phase 10 Pass 2 — document scaling, resize, new-document dialog

Pass 1 ships rotate / flip; Pass 2 fills in:

- Document scaling (resample, both up and down) at high quality. Same flatten-and-rebuild pipeline as the rotate / flip ops, with a different draw rect.
- Crop / resize canvas without resampling, with selectable anchor (center / TL / TR / BL / BR).
- Arbitrary-angle rotation (45°, etc.).
- New-document dialog with size, color profile, and DPI presets.
- Document-level undo for image transforms (Pass 1 clears the stack on transform).

### Phase 11 Pass 2 — color picker, swatches, preferences, cursor preview

- Persistent user-saved swatches with an "Add Current Color" affordance; saved with the document or globally.
- Custom in-app color picker UI (HSB / RGB sliders, color wheel, hex input integrated into a single panel). The system `NSColorPanel` reached via the color well is fine for now; a richer in-app picker is a polish win.
- Preferences panel (autosave interval, history budget, gamut mapping policy, default new-doc dimensions).
- Cursor preview improvements — brush silhouette beyond the current circle outline; tilt indicator; rotation indicator. Most useful when non-circular tip previews ship.

---

## Major deferred features (architecturally pre-cleared)

These are sizable additions designed in from the start: the architecture preserves the option to add them later without rework.

### Vector layers

A new layer type alongside bitmap layers. Strokes on a vector layer are stored as fitted paths (Bézier or input samples) and re-rasterized on demand at the current view scale. The big wins are lossless transforms and lossless document scaling.

**Why deferred from v1.** Significant engineering surface — a second layer type with its own rendering, editing, hit-testing, and PSD interop story. v1 is bitmap-first because that is what the brush engine and tile cache already serve.

**Architectural readiness.** The four commitments in `ARCHITECTURE.md` decision 5 are designed to keep this door open: `Layer` is a sum type from day one; the stroke pipeline is layer-aware; the save format carries a per-layer type tag and version; the compositor accepts heterogeneous layers. Adding `VectorLayer` as a new conformer should be a pure addition, not a rewrite.

**Open questions for when we pick this up.**
- Stroke representation: keep raw input samples (richer, larger), fitted Bézier paths (compact, smoother), or both?
- Editing model: do strokes remain editable after commit, or are they immutable like bitmap-layer strokes?
- PSD export: rasterize on export (simple, lossy) or attempt SVG-style preservation in a custom layer (complex, fragile)?
- Memory: how do we bound stroke retention on long sessions of vector painting?

---

### Distortion brushes (blur, liquify, smudge)

Brushes that read the canvas mid-stroke and produce a result that depends on what is already there: blur, smudge, liquify, push, pull.

**Why deferred from v1.** These do not fit the pure stamp-based engine cleanly — they need to sample existing tile content during stroke processing, which changes the GPU dispatch shape and adds a tile-read dependency we do not have today. They are also brush-design-heavy: each distortion brush has its own tunables and feel.

**Architectural readiness.** The brush engine in decision 11 is open to a parallel rasterization path for non-stamp brushes. Distortion brushes will sit alongside the stamp engine, not inside it. The tile cache, color model, and threading model already support read-then-write tile operations.

**Open questions.**
- GPU compute kernel design for blur, smudge, liquify (each is its own shader).
- How distortion brushes interact with selections (constrain reads as well as writes?).
- How they interact with masks.
- Brush settings UI for distortion-specific parameters (radius, strength, falloff).

---

### ABR brush import

Read Photoshop `.abr` brush files and import them into Inkwell's brush format.

**Why deferred from v1.** Useful but not foundational. Inkwell ships with a small curated brush set; users who want more variety can wait for ABR support, write their own brushes (the format is editable JSON), or import via a community pack.

**Architectural readiness.** Decision 11 makes brushes data, not code, with a versioned settings format. ABR import is a translator from `.abr`'s binary structure to our brush settings file.

**Open questions.**
- ABR format reverse-engineering and version coverage (Photoshop has shipped many versions; not all are documented).
- Mapping ABR's brush dynamics model (it is similar but not identical to ours) — what is preserved exactly, what is approximated, what is dropped.
- Tip texture extraction from ABR's embedded image data.
- A user-facing fidelity table for ABR import (matching the PSD one).

---

### Timelapse playback UI

The undo delta stream captures everything needed for per-stroke timelapse playback (decisions 5 and 9). What remains is the **playback UI** — controls for speed, scrubbing, export to video — plus the underlying `history.bin` write (a Phase 5 Pass 2 prerequisite — see above).

**Architectural readiness.** The `history.bin` chunk in the bundle (decision 14) holds the data with timestamps. Playback is straightforward: read deltas in order, apply each to the document, render frames. Video export uses `AVFoundation`.

**Open questions.**
- Default playback speed and pacing (real time, fixed-duration, per-stroke "snap" with configurable interval).
- Scrubber UI on the timeline.
- Export format and codec choices (H.264, ProRes).
- Whether to offer audio (background music, ambient).
- Per-stroke playback only, or per-stamp interpolation for smoother visual flow?

---

## Smaller deferred features

These are scoped tighter and could land in any post-v1 release.

### Disk-spill for the tile cache

Today's tile cache lives entirely in unified memory. For very large documents (16K canvases, hundreds of layers), we will need to evict cold tiles to disk and page them back in on demand.

**Architectural readiness.** Decision 4 anticipates this. The tile cache interface is designed so a disk-backed eviction policy can be added without disturbing callers.

**Open questions.** Eviction policy (LRU? LFU? hybrid?), tile-locking during access, and how to minimize visible stalls when an evicted tile is paged back in mid-stroke.

---

### Linear-light blending option

Decision 6 commits Inkwell to gamma-space blending by default to match Photoshop and user expectation. Some users (compositing photos, simulating physical light) genuinely want linear blending.

**Plan.** A per-document setting that switches the blend math in the compositor's shaders. Simple to implement; the cost is testing every blend mode in both modes and documenting the difference.

---

### Active DPI

DPI in v1 is metadata-only (and not yet exposed in the UI). Brush sizes are in pixels. For print-first workflows, users may want brush sizes in millimeters or inches and document dimensions in physical units.

**Plan.** A per-document "use physical units" toggle, with brush size editors and document dialogs that translate to the chosen unit. The engine still works in pixels internally; the UI translates at the boundary.

---

### Group masks

Decision 7 supports masks per layer. Group masks (one mask applied to an entire group) are the natural extension. Architecturally identical to layer masks — same tile structure, same rendering — but require UI affordances and a clear interaction model with per-layer masks within the group.

---

### Isolated group blending

Phase 4 ships pass-through groups: a group's opacity multiplies through children, but its blend mode is ignored at composite time. Isolated groups would composite their children into a transient buffer first and then blend that buffer onto the parent according to the group's own blend mode (Photoshop's default mode for groups other than "Pass Through").

**Architectural readiness.** Requires a multi-encoder / multi-pass renderer change to allocate viewport-sized transient textures per isolated group per frame. The compositor will need to walk the tree post-order rather than directly to the drawable.

---

### Branching undo history

Decision 9 chose linear redo for v1 (the standard for the category). A future "branching history" feature could let users return to alternative explorations after undoing.

**Why deferred.** Significantly more complex UI and storage; semantics for timelapse become ambiguous (which branch plays back?); not a standard feature in this category. Worth considering only if a clear user demand emerges.

---

## Operational and infrastructure futures

### C++ migration of hot paths

Decision 2 lists five hot paths as candidates for future C++ implementation: stroke input processor, stamp rasterizer, tile cache, CPU-side filters and distortion brushes, PSD codec. v1 ships pure Swift with each path isolated behind a protocol so a swap is localized.

**Trigger.** Profiling on real documents reveals Swift overhead is the bottleneck and tuning the Swift implementation has reached diminishing returns. We make the call per-module, not all-or-nothing.

**Cost.** Bridging layer (Swift's C++ interop or an Obj-C++ shim), two debuggers, more complex builds. We pay this only when measurements justify it.

---

### Cross-platform port (iPad, Linux, Windows)

Inkwell v1 is macOS only. A cross-platform port would require either rewriting the engine in C++ (so it builds outside the Apple toolchain) or adopting a portable Swift toolchain (still maturing for non-Apple platforms).

**Why deferred.** No clear need yet, and the tradeoffs depend heavily on platform and form factor. iPad is the most likely first port (closest to macOS, same Metal API, but a different input model and UI framework).

**Architectural readiness.** Decision 2's hot-path isolation makes the engine reusable in a different shell. The full app (UI chrome, AppKit-specific behavior) would not port.

---

### Mac App Store distribution

v1 plans for direct distribution via signed/notarized DMG (decision 14, Phase 12 of the plan). Mac App Store distribution is a separate decision involving sandboxing constraints, in-app purchase considerations, and review process trade-offs.

**Plan.** Decide closer to launch. Sandboxing affects file access patterns and tablet driver interaction; we should profile both options before committing.

---

### macOS version target re-evaluation

Decision 3 pins v1 to macOS Tahoe. Each subsequent macOS release prompts the question: stay pinned, or move the floor up?

**Cadence.** Re-evaluate when the next macOS ships. The default question is whether Tahoe's share of our audience has dropped enough that staying pinned costs more than moving the floor would.

---

## Known UX gaps to revisit

These are not features — they are weak spots in the v1 design that we know about today.

### Pressure curve math and UX (provisional)

Decision 11 explicitly flags pressure curves (cubic Bézier with two control points) as a placeholder pending the project owner's design input. The implementation isolates curve evaluation behind a small interface so the representation can change. This is a tracked revisit, not an open question — when the design lands, the brush engine's curve module is the implementation point.

---

### Discoverability of held-modifier behaviors

Several v1 behaviors rely on modifier keys that first-time users will not discover unaided:

- Cmd-click → eyedropper
- Option-during-stroke → eraser
- Tab → toggle panels
- Space + drag → pan
- R + drag → rotate
- Shift+R → reset rotation

**Plan.** These are addressed partly by Phase 12 onboarding and partly by the user manual walkthrough sections (when written). Worth a revisit after launch based on user-feedback patterns: which conventions land naturally and which need surfacing in the UI.

---

### Eraser-tip behavior surfacing

Decision 10's eraser-end-of-stylus behavior is industry standard but invisible until the user discovers their stylus has an eraser tip. The cursor or status bar should reflect the active tool clearly so the temporary tool switch is not a surprise.

---

### PSD round-trip fidelity gaps

Anything Inkwell can do that PSD cannot represent (or represents differently) loses information on round-trip. The fidelity table in [`PSD_FIDELITY.md`](PSD_FIDELITY.md) makes this explicit, but users who do not read the table may be surprised. Over time, the table should become a list of resolved or accepted gaps; the UI should warn at export when a feature in the document is about to be downgraded.

---

### R-drag rotation pivot

Decision 13 specifies "R + drag, cursor-anchored." The Phase 8 implementation anchors R-drag rotation at the **view center**, not the cursor at drag start. The view-center pivot gives a usable angular reference; cursor-pivot has zero-radius math at drag start that needs a different UX (e.g., requiring an initial drag direction before rotation begins). Worth revisiting if the current feel is wrong on a real tablet.

---

### Mouse coalescing disable is global to the process

Phase 11's stroke-quality fix disables `NSEvent` mouse coalescing via the legacy Obj-C class method (the Swift import doesn't expose it). On a Wacom this raises the input rate from the refresh-clamped ~60 Hz to the tablet's native ~300 Hz, which fixed the segmentation artifact. The toggle is process-global, so it also applies to ordinary mouse moves and trackpad gestures. Hasn't been a problem in test sessions, but if it ever is — re-enable on demand or only while a stroke tool is active (toggle in the tool's begin / end lifecycle).

---

### Per-sample command-buffer overhead at high stylus rates

Each `StampRenderer.applyStamp` dispatch commits its own command buffer with one render pass per affected tile. At 300 Hz with a tight-spacing brush like G-Pen, that's hundreds of command buffers per second during fast painting. Apple Silicon handles it today, but it's not optimal — batching multiple stamps into a single command buffer per stylus sample (one buffer with N render passes inside) would be the obvious next optimization if any latency, thermal, or scheduling issues surface.

---

## Larger v2+ features (speculative)

These are mentioned for completeness; none are committed.

- **Text layers.** Editable text as a layer type, with font / size / color / paragraph controls, exported as rasterized in PSD. Significant new surface (font handling, text rendering, layout) and a different layer type from bitmap or vector strokes.
- **Adjustment layers.** Non-destructive color/tone adjustments (curves, levels, hue/saturation, etc.) applied as layers. Architecturally similar to filters but in the layer stack rather than at the brush.
- **Animation / multi-frame documents.** A timeline of frames with onion-skinning. A different document model from single-frame v1 and a major UI surface.
- **Plugin system.** Third-party brushes, filters, and tools loaded at runtime. Requires a stable API contract, sandboxing decisions, and a distribution channel.
- **Procedural brushes.** Brushes whose stamp shape is computed in a shader rather than from a tip texture. Powerful for some natural-media and effect brushes; a layered addition to the existing brush engine.
- **Reference-image and pose-mannequin tools.** A reference panel with pinned images, optional 3D pose models — common in illustration workflows.
- **Stroke stabilization tuning.** Beyond the smoothing in the stroke processor, user-adjustable stabilization (correction strength, lag) for shaky-hand workflows.

---

## How to use this document

- When v1 ships and we plan v1.x or v2, this document is the starting point.
- When considering any change to the v1 architecture, check whether this document anticipates the change — many "new" ideas are already tracked here with the architectural readiness already in place.
- When closing out a deferred item, move it from this document into `ARCHITECTURE.md` (as a new decision if applicable), `USERMANUAL.md` (as a feature), and `PLAN.md` (as a phase or pass) — and remove the entry here.
