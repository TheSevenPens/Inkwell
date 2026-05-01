# Selections

The hybrid raster + optional vector selection system, the standard pro selection toolset, and how selections constrain every pixel-writing operation in the compositor.

This file is part of the Inkwell architecture corpus. Decision numbers are global across the corpus; the index lives in [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

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

> **Implementation status (as of Phase 11).** The v1 shipped toolset is a **subset** of the full decision above.
>
> **Shipped:** rectangle, ellipse, and freehand lasso tools; selection arithmetic (Shift / Option / Shift+Option modifiers); anti-aliased edges; marching-ants animated Metal overlay; constraint application in all three stamp pipelines (normal / erase / mask); selection persistence in the bundle (`selection.bin`); Select All (Cmd+A), Deselect (Cmd+D), Invert Selection (Cmd+Shift+I); all selection-mutating ops on the undo stack via `Document.registerSelectionUndo`.
>
> **Not yet shipped:** polygonal lasso; magic wand; color range; Quick Mask mode; floating-selection transforms; per-selection feather slider; vector path retention for shape selections. Gaps are tracked in [`FUTURES.md`](../FUTURES.md) under "Phase 7 Pass 2."

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
