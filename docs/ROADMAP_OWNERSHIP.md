# Roadmap ownership

A reverse index from the items in [`FUTURES.md`](FUTURES.md) to **the code subsystem that would change** when each one ships, plus the prereqs and a "definition of done" checklist. Use this when you're about to pick up a deferred item and want to know *where the work actually lives*.

This is a navigation aid, not a project plan. For phase-by-phase planning, see [`PLAN.md`](PLAN.md).

---

## Reading the entries

Each item has:

- **Subsystem** — the design / architecture doc that frames it.
- **Likely files** — primary code-touchpoints. Not exhaustive.
- **Prereqs** — what must land before this can.
- **DoD** — definition-of-done checklist.

If you're adding a new deferred item to `FUTURES.md`, add an entry here too.

---

## Phase pass-2 deferrals

### Undo / timelapse history persistence (`history.bin`)

- **Subsystem**: [`UNDO_GUARANTEES.md`](UNDO_GUARANTEES.md), [`design/UNDO.md`](design/UNDO.md), [`arch/CONCURRENCY.md`](arch/CONCURRENCY.md) decision 9.
- **Likely files**: [Document.swift](../Sources/Inkwell/Document.swift), [FileFormat.swift](../Sources/Inkwell/FileFormat.swift), new `HistoryFile.swift`, new `DeltaCompression.swift`.
- **Prereqs**: zstd library decision (Swift wrapper around system `libcompression` is the default; SPM-imported zstd is a fallback). Bundle-format change requires a `currentVersion` bump and a migrator.
- **DoD**:
  - `history.bin` chunk written on every save with length-prefixed records.
  - Reader opens older bundles without `history.bin` cleanly.
  - Per-tile deltas zstd-compressed at capture.
  - Configurable RAM cap (default 200 steps / 256 MB).
  - Disk-backed paging on undo past RAM window.
  - Linear redo: drop redo stack on new edit.
  - Fail-soft on corrupted history.
  - Tests in a new `Tests/HistoryTests/` covering compression round-trip, cross-version load, partial-write recovery.

### Polygonal lasso, magic wand, color range

- **Subsystem**: [`arch/SELECTIONS.md`](arch/SELECTIONS.md) decision 12.
- **Likely files**: [Selection.swift](../Sources/Inkwell/Selection.swift), [CanvasView.swift](../Sources/Inkwell/CanvasView.swift) (new selection-gesture cases), [LeftPaneView.swift](../Sources/Inkwell/LeftPaneView.swift) (new tool icons).
- **Prereqs**: none structural.
- **DoD**: each tool wired to `ToolState.Tool`, mouse handlers in `CanvasView`, raster-mask output that uses the same constraint pipeline as existing selections, undo coverage via existing `registerSelectionUndo`.

### Quick Mask mode

- **Subsystem**: [`arch/SELECTIONS.md`](arch/SELECTIONS.md), [`design/STROKES.md`](design/STROKES.md).
- **Likely files**: new `QuickMaskController.swift`, [CanvasView.swift](../Sources/Inkwell/CanvasView.swift) (route brush input), [CanvasRenderer.swift](../Sources/Inkwell/CanvasRenderer.swift) (overlay).
- **Prereqs**: none.
- **DoD**: toggleable mode flag, brush input writes to selection mask via existing `applyMaskStamp`, translucent red overlay over unselected region, exit transitions back to a normal selection.

### Floating-selection transforms

- **Subsystem**: [`arch/SELECTIONS.md`](arch/SELECTIONS.md).
- **Likely files**: new `FloatingSelection.swift`, [Canvas.swift](../Sources/Inkwell/Canvas.swift) (transient pseudo-layer), [CanvasView.swift](../Sources/Inkwell/CanvasView.swift) (transform handles).
- **Prereqs**: think through how this interacts with `walkVisibleRenderables` — likely a new `RenderLayer` case for the floating layer.
- **DoD**: move / scale / rotate / free-transform with handles, commit applies to underlying layer, cancel reverts, undo wraps the whole gesture.

### Per-selection feather

- **Subsystem**: [`arch/SELECTIONS.md`](arch/SELECTIONS.md).
- **Likely files**: [Selection.swift](../Sources/Inkwell/Selection.swift) (Gaussian blur on the mask), UI in selection-tool options.
- **Prereqs**: none.
- **DoD**: feather slider per selection, persisted in `selection.bin` (add a feather field to the chunk), GPU-side blur applied at mask sample time.

### Vector path retention for shape selections

- **Subsystem**: [`arch/SELECTIONS.md`](arch/SELECTIONS.md).
- **Likely files**: [Selection.swift](../Sources/Inkwell/Selection.swift) (additional optional path), [CanvasRenderer.swift](../Sources/Inkwell/CanvasRenderer.swift) (path-aware ants shader).
- **Prereqs**: think through arithmetic ops that drop the path.
- **DoD**: shape selections (rectangle / ellipse / polygonal lasso) retain a `CGPath`, ants shader renders from it for crispness, transforms are lossless until commit.

### Layer-aware PSD round-trip

- **Subsystem**: [`EXPORT_IMPORT_GUIDE.md`](EXPORT_IMPORT_GUIDE.md), [`PSD_FIDELITY.md`](PSD_FIDELITY.md), [`arch/DOCUMENT.md`](arch/DOCUMENT.md) decision 14.
- **Likely files**: [PSDFormat.swift](../Sources/Inkwell/PSDFormat.swift) (substantial extension), [Canvas.swift](../Sources/Inkwell/Canvas.swift), [Document.swift](../Sources/Inkwell/Document.swift).
- **Prereqs**: pick whether to write our own codec or adopt a third-party. Architecture decision 2's hot-path note flags PSD codec as a likely C++ migration candidate.
- **DoD**: write the layer-and-mask-info section per Inkwell layer; map blend modes through a published table; embed ICC profile (image resource 1039); optional 16-bit channels; import path reads layer tree, masks, profile; rasterize-on-import for unsupported PSD features (text, smart objects, adjustment).

### Display P3 working space + gamut mapping

- **Subsystem**: [`design/COLOR.md`](design/COLOR.md), [`arch/RENDERING.md`](arch/RENDERING.md) decision 6.
- **Likely files**: every layer / tile init (pixel format change), every shader (16-bit / P3-aware reads), [Canvas.swift](../Sources/Inkwell/Canvas.swift) (export sheet adds gamut-map option), [Brush.swift](../Sources/Inkwell/Brush.swift) and [ColorWheelView.swift](../Sources/Inkwell/ColorWheelView.swift) (color picker projects into P3).
- **Prereqs**: format-version bump and migrator (8-bit sRGB tiles → 16-bit P3 tiles on first save under the new format).
- **DoD**: tile pixel format `.rgba16Float` (or 16-bit unorm); P3 working space throughout; gamut-mapped sRGB export with perceptual / relative-colorimetric option; embedded P3 profile in PNG / JPEG / PSD output; profile-aware import.

### Document scaling, resize, new-document dialog with custom DPI

- **Subsystem**: [`arch/DOCUMENT.md`](arch/DOCUMENT.md) decision 7.
- **Likely files**: [CanvasTransforms.swift](../Sources/Inkwell/CanvasTransforms.swift) (resample + crop), [NewDocumentDialog.swift](../Sources/Inkwell/NewDocumentDialog.swift) (DPI presets), [BitmapLayer.swift](../Sources/Inkwell/BitmapLayer.swift) (`replaceWithImage` with new dims).
- **Prereqs**: a story for image-transform undo (today's image transforms clear the undo stack — see [`UNDO_GUARANTEES.md`](UNDO_GUARANTEES.md)).
- **DoD**: Image → Resample (high-quality scaling), Image → Resize Canvas (no resample, anchored), Image → Rotate Arbitrary (any angle), New-document dialog with profile / DPI presets, document-level undo for transforms.

### Color picker, swatches, preferences, cursor preview

- **Subsystem**: [`design/COLOR.md`](design/COLOR.md), [`UI_COMPONENTS.md`](UI_COMPONENTS.md).
- **Likely files**: new `SwatchStorage.swift`, new `PreferencesPanel.swift`, [BrushInspectorView.swift](../Sources/Inkwell/BrushInspectorView.swift), [CanvasView.swift](../Sources/Inkwell/CanvasView.swift) (richer cursor).
- **Prereqs**: none.
- **DoD**: persistent user-saved swatches with "Add Current Color" button; preferences panel covering autosave / history budget / gamut policy / default new-doc dimensions; cursor preview reflects tip silhouette and tilt.

---

## Major deferred features

### Soft-edged vector brushes (Marker, Airbrush as vector)

- **Subsystem**: [`design/STROKES.md`](design/STROKES.md), [VectorLayer.swift](../Sources/Inkwell/VectorLayer.swift).
- **Likely files**: [StrokeRibbonRenderer.swift](../Sources/Inkwell/StrokeRibbonRenderer.swift) (new pipeline with two-pass scratch-buffer max-blend), [VectorStroke.swift](../Sources/Inkwell/VectorStroke.swift) (new `Kind` cases), [LeftPaneView.swift](../Sources/Inkwell/LeftPaneView.swift) (allow non-G-Pen brushes on vector layers).
- **Prereqs**: think through opacity + blend modes for soft-edged vector strokes; the V1 G-Pen ribbon's "constant per-stroke alpha" assumption breaks for soft strokes.
- **DoD**: Marker and Airbrush produce vector strokes when the active layer is vector; tile cache rebuilt correctly; round-trips through `.inkwell`.

### Per-stroke selection / move / restyle on vector layers

- **Subsystem**: [VectorLayer.swift](../Sources/Inkwell/VectorLayer.swift).
- **Likely files**: new selection mode for "stroke pick" (likely a new tool), [CanvasView.swift](../Sources/Inkwell/CanvasView.swift) (hit-test + handles), [VectorStroke.swift](../Sources/Inkwell/VectorStroke.swift) (allow color / opacity / radius edits).
- **Prereqs**: a stroke-selection state model (which strokes are selected, persistence).
- **DoD**: click a vector stroke to select; drag to translate; edit color / radius / opacity in inspector; undo coverage.

### True zoom-aware vector re-rasterization

- **Subsystem**: [`design/COMPOSITOR.md`](design/COMPOSITOR.md), [VectorLayer.swift](../Sources/Inkwell/VectorLayer.swift).
- **Likely files**: [StrokeRibbonRenderer.swift](../Sources/Inkwell/StrokeRibbonRenderer.swift) (re-rasterize at view scale on demand), [VectorLayer.swift](../Sources/Inkwell/VectorLayer.swift) (zoom-aware tile cache).
- **Prereqs**: cache-invalidation policy for transient zoom-level tiles.
- **DoD**: vector strokes look crisp at any zoom (currently nearest-neighbour magnifies the cached 1:1 rasterization).

### Distortion brushes (blur, liquify, smudge)

- **Subsystem**: [`arch/INPUT.md`](arch/INPUT.md) decision 11 (notes a parallel rasterization path for non-stamp brushes).
- **Likely files**: new `DistortionBrushRenderer.swift`, [Brush.swift](../Sources/Inkwell/Brush.swift) (new brush kind discriminator), [BrushPalette.swift](../Sources/Inkwell/BrushPalette.swift).
- **Prereqs**: tile read-then-write semantics (the GPU reads existing tile content during the distortion pass).
- **DoD**: at least one distortion brush ships (typically blur first); brush settings UI extends to its tunables.

### ABR brush import

- **Subsystem**: [Brush.swift](../Sources/Inkwell/Brush.swift), [BrushPalette.swift](../Sources/Inkwell/BrushPalette.swift).
- **Likely files**: new `ABRImporter.swift`, UI affordance in the brush picker.
- **Prereqs**: ABR format parser (likely third-party or hand-rolled). The brush settings format should already accommodate most ABR fields; gaps documented when the importer lands.
- **DoD**: imported ABR brushes appear in the brush picker; tip texture and most settings carry through; documented losses for ABR features we can't represent.

### Timelapse playback UI

- **Subsystem**: [`arch/CONCURRENCY.md`](arch/CONCURRENCY.md) decision 9.
- **Likely files**: new `TimelapseController.swift`, new playback UI window, [Document.swift](../Sources/Inkwell/Document.swift) (apply deltas in order).
- **Prereqs**: `history.bin` persistence (above).
- **DoD**: a timeline scrubber driven by stored timestamps; play / pause; export to video (likely via AVFoundation).

---

## Smaller deferred features

### Disk-spill for the tile cache

- **Subsystem**: [`design/TILES.md`](design/TILES.md).
- **Likely files**: [BitmapLayer.swift](../Sources/Inkwell/BitmapLayer.swift) (LRU eviction hook), new `TileSwapStore.swift`.
- **Prereqs**: an explicit cache-budget config.
- **DoD**: cold tiles paged to disk; lazy re-page on access; no visible stalls under normal use.

### Linear-light blending option

- **Subsystem**: [`design/COLOR.md`](design/COLOR.md).
- **Likely files**: [CanvasRenderer.swift](../Sources/Inkwell/CanvasRenderer.swift) (shader branch), per-document setting.
- **Prereqs**: none.
- **DoD**: per-document toggle in Document settings; tile / solid fragment shaders linearize on read and re-encode on write when active; documented difference.

### Active DPI

- **Subsystem**: [`arch/DOCUMENT.md`](arch/DOCUMENT.md) decision 7.
- **Likely files**: [Brush.swift](../Sources/Inkwell/Brush.swift) (size in mm/in or px), [BrushInspectorView.swift](../Sources/Inkwell/BrushInspectorView.swift), [Document.swift](../Sources/Inkwell/Document.swift) (DPI metadata becomes "active").
- **Prereqs**: per-document DPI in the manifest (already there; just unused).
- **DoD**: per-document toggle "use physical units"; brush sizes in mm / in; document dimensions in physical units; engine still works in pixels internally.

### Group masks

- **Subsystem**: [`arch/DOCUMENT.md`](arch/DOCUMENT.md) decision 7.
- **Likely files**: [GroupLayer.swift](../Sources/Inkwell/GroupLayer.swift) (add `mask: LayerMask?`), [CanvasRenderer.swift](../Sources/Inkwell/CanvasRenderer.swift) (apply group mask), [LayerPanelView.swift](../Sources/Inkwell/LayerPanelView.swift) (Add Mask on group).
- **Prereqs**: think through interaction with isolated group blending.
- **DoD**: a group can have a mask; mask applies to the composited group output; round-trips through `.inkwell` and PSD.

### Isolated group blending

- **Subsystem**: [`design/COMPOSITOR.md`](design/COMPOSITOR.md), [`arch/DOCUMENT.md`](arch/DOCUMENT.md).
- **Likely files**: [CanvasRenderer.swift](../Sources/Inkwell/CanvasRenderer.swift) (multi-pass: composite group's children into a transient texture, then blend into parent).
- **Prereqs**: a transient render-target allocation strategy. Group's effective render target is canvas-sized.
- **DoD**: group `blendMode` actually applies (not just multiplied opacity); matches Photoshop's default group behavior.

### Branching undo history

- **Subsystem**: [`arch/CONCURRENCY.md`](arch/CONCURRENCY.md) decision 9 (deliberately rejected for v1).
- **Likely files**: replacement for `NSUndoManager`, new `BranchingHistory.swift`, UI for branch navigation.
- **Prereqs**: clarity on what timelapse playback should do across branches.
- **DoD**: only revisit if there's clear user demand.

---

## UX gaps

### Eraser-tip cursor preview

- **Subsystem**: [`UI_STATE_MODEL.md`](UI_STATE_MODEL.md).
- **Likely files**: [CanvasView.swift](../Sources/Inkwell/CanvasView.swift) (`brushCursor()`).
- **Prereqs**: none.
- **DoD**: when the stylus eraser tip is engaged, the brush cursor swaps to a visually distinct shape (or shows an eraser badge).

### Discoverability of held-modifier behaviors

- **Subsystem**: [`UI_STATE_MODEL.md`](UI_STATE_MODEL.md), [`USERMANUAL.md`](USERMANUAL.md).
- **Likely files**: new help / shortcuts panel.
- **Prereqs**: Phase 12 onboarding and tutorial work.
- **DoD**: a Help → Keyboard Shortcuts panel; tooltips on tool icons mention modifier behaviors where applicable.

### R-drag rotation pivot

- **Subsystem**: [`arch/RENDERING.md`](arch/RENDERING.md) decision 13.
- **Likely files**: [CanvasView.swift](../Sources/Inkwell/CanvasView.swift), [ViewTransform.swift](../Sources/Inkwell/ViewTransform.swift).
- **Prereqs**: real-tablet feedback on the current view-center pivot.
- **DoD**: revisit only if user feedback says the current behavior feels wrong.

### Mouse-coalescing scope

- **Subsystem**: [`design/STROKES.md`](design/STROKES.md), [AppDelegate.swift](../Sources/Inkwell/AppDelegate.swift).
- **Likely files**: [AppDelegate.swift](../Sources/Inkwell/AppDelegate.swift), [CanvasView.swift](../Sources/Inkwell/CanvasView.swift).
- **Prereqs**: a way to toggle coalescing within stroke begin/end without leaks.
- **DoD**: coalescing disabled only during in-flight strokes.

### Per-sample command-buffer overhead at high stylus rates

- **Subsystem**: [`design/STROKES.md`](design/STROKES.md).
- **Status**: **already addressed** for both the stamp and ribbon paths via `beginBatch()` / `commitBatch()`. Listed for completeness; nothing to do here.

---

## Larger v2+ features

These are speculative. Each would warrant a new architectural decision before implementation.

| Feature | Subsystem entry point |
|---|---|
| Text layers | new `TextLayer.swift` next to `BitmapLayer` / `VectorLayer` |
| Adjustment layers | new `AdjustmentLayer.swift`; compositor needs to know how to apply non-pixel layers |
| Animation / multi-frame documents | document model gains a frame dimension; UI for timeline |
| Plugin system | new boundary in [Brush.swift](../Sources/Inkwell/Brush.swift) and possibly the renderer; sandboxing decisions |
| Procedural brushes | parallel path in [StampRenderer.swift](../Sources/Inkwell/StampRenderer.swift) (no tip texture; shader-computed) |
| Reference / pose-mannequin tools | a new top-level workspace surface |
| Stroke stabilization tuning | [StrokeEmitter.swift](../Sources/Inkwell/StrokeEmitter.swift), [VectorStrokeBuilder.swift](../Sources/Inkwell/VectorStrokeBuilder.swift) |

---

## How to use this doc when picking up an item

1. Find the item in `FUTURES.md` or in the [open issues](https://github.com/TheSevenPens/Inkwell/issues).
2. Look it up here.
3. Read the linked subsystem doc(s) to ground yourself.
4. Read the listed source files to see the current shape.
5. Check prereqs — landing on a deferred item that depends on another deferred item is the most common scope blowup.
6. Open a PR that ticks every DoD checkbox; if you skip one, document why.
