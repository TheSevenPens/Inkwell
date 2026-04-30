# Undo / redo

How Inkwell records reversible operations today. Built on `NSDocument`'s `undoManager` (an `NSUndoManager`), with a self-registering inverse-snapshot pattern: each undo action captures the *current* state, applies the *target* state, then registers another undo with the captured state as its target. Cmd-Z and Cmd-Shift-Z drive it.

For the *why* of per-stroke deltas and gesture coalescing, see [`arch/CONCURRENCY.md`](../arch/CONCURRENCY.md) decision 9. That decision describes the eventual end-state (zstd-compressed deltas, RAM window, disk-backed full history); today we ship the in-memory `NSUndoManager` part. `history.bin` is reserved in the bundle but not yet written.

---

## TL;DR

- One file owns the registration: [Document.swift](../../Sources/Inkwell/Document.swift).
- Four kinds of registrable mutation:
  - **Bitmap layer pixel edit** → `registerLayerStrokeUndo(layerId:before:after:)`
  - **Mask pixel edit** → `registerMaskStrokeUndo(layerId:before:after:)`
  - **Vector layer strokes-list edit** → `registerVectorStrokeUndo(layerId:before:after:)`
  - **Selection edit** → `registerSelectionUndo(before:after:actionName:)`
- All use the **inverse-snapshot pattern**: each registered undo captures `previous` at apply time and registers another undo with `previous` as its target.
- **Gesture coalescing** comes from `NSUndoManager` itself — within one event-loop turn (one mouse stroke, one slider drag), all `registerUndo` calls consolidate into a single Cmd-Z step.

---

## The inverse-snapshot pattern

Most undo systems separate "register" (pre-mutation) from "store inverse" (post-mutation). We do something simpler: we capture **before** and **after** snapshots and register an undo that, when applied, *also* registers its own inverse. NSUndoManager handles the redo direction automatically by virtue of being inside an undo group.

The shape, abstracted:

```swift
func registerXxxUndo(layerId: UUID, before: State, after: State) {
    guard let undoManager, before != after else { return }
    undoManager.setActionName("…")
    undoManager.registerUndo(withTarget: self) { [weak self] _ in
        self?.applyXxxAndRegisterInverse(layerId: layerId, snapshot: before)
    }
}

private func applyXxxAndRegisterInverse(layerId: UUID, snapshot: State) {
    let previous = currentState(layerId)        // capture pre-apply state
    apply(snapshot, to: layerId)                // mutate
    onCanvasChanged?()
    undoManager?.setActionName("…")
    undoManager?.registerUndo(withTarget: self) { [weak self] _ in
        self?.applyXxxAndRegisterInverse(layerId: layerId, snapshot: previous)
    }
}
```

Read it as: *"to undo, restore the snapshot — and queue an inverse undo so redo will work too."* `NSUndoManager` knows whether we're undoing or redoing based on its own state machine; the same `applyXxxAndRegisterInverse` runs in both directions.

---

## The four kinds in detail

### 1. Bitmap layer pixel edit

[Document.swift](../../Sources/Inkwell/Document.swift), `registerLayerStrokeUndo` and `applyLayerSnapshotAndRegisterInverse`.

State is a [`BitmapLayer.TileSnapshot`](../../Sources/Inkwell/BitmapLayer.swift):
```swift
struct TileSnapshot {
    var presentTiles: [TileCoord: Data]   // bytes for tiles that should exist
    var absentTiles: Set<TileCoord>       // coords that should *not* exist
    static let empty = TileSnapshot(presentTiles: [:], absentTiles: [])
}
```

The two-halves design is what lets us reverse "stroke crossed into a tile that was previously empty":
- **Before** snapshot has the (then-empty) coord in `absentTiles`.
- **After** snapshot has the coord in `presentTiles` with the painted bytes.
- Undo applies `before`: the painted tile is removed (back to absent).
- Redo applies `after`: the tile is re-allocated and painted bytes restored.

Capturing the snapshots:
- Brush stroke (`CanvasView.beginStroke` and `dispatchSample`): tracks `strokeAffectedCoords: Set<TileCoord>` and the union of pre-edit `BitmapLayer.snapshotTiles(...)` calls. On `mouseUp`, `commitUndoIfNeeded()` builds the after-snapshot from the same coord set and calls `registerLayerStrokeUndo`.
- Edit → Clear (`Document.clearLayerContents`): snapshots all tile coords on the layer, clears, re-snapshots, registers.
- Move Layer tool (`CanvasView.endMoveLayer`): snapshots all pre-move tiles, calls `BitmapLayer.translatePixels`, snapshots the union of pre + post tile coords for after.

### 2. Mask pixel edit

[Document.swift](../../Sources/Inkwell/Document.swift), `registerMaskStrokeUndo` and `applyMaskSnapshotAndRegisterInverse`.

Identical structure to bitmap, but operates on a `LayerMask.TileSnapshot`. Used when the user paints with **Edit: Mask** on a masked bitmap layer. The brush dispatch sees `strokeTarget == .mask(layerId)` and snapshots / mutates `layer.mask`'s tiles instead.

### 3. Vector layer strokes-list edit

[Document.swift](../../Sources/Inkwell/Document.swift), `registerVectorStrokeUndo` and `applyVectorStrokesAndRegisterInverse`.

State is the **whole strokes array** (`[VectorStroke]`) — cheap because strokes are value types and the array is typically small (dozens to hundreds).

Apply path: `VectorLayer.setStrokes(_:ribbonRenderer:)` clears the tile cache and re-rasterizes from the snapshotted array. So undoing a vector edit always rebuilds tiles deterministically from the (smaller) authoritative strokes data.

Used by:
- Vector stroke commit (`CanvasView.endVectorStroke`).
- Vector eraser (`CanvasView.endVectorEraser` — captures before at `beginVectorEraser`, after at end).
- Edit → Clear on vector layer (`Document.clearVectorContents` — before = current strokes, after = empty).
- Move Layer on a vector layer (`CanvasView.endMoveLayer` — before = strokes pre-translate, after = translated strokes).

### 4. Selection edit

[Document.swift](../../Sources/Inkwell/Document.swift), `registerSelectionUndo` and `applySelectionBytesAndRegisterInverse`.

State is `[UInt8]?` — `nil` means "no selection active," non-nil means "selection bytes." Apply path:
- If `bytes` is nil, call `canvas.deselect()`.
- Else, call `canvas.replaceSelectionBytes(bytes)`.

Used by:
- Rectangle / ellipse / lasso commits (`CanvasView.commitSelectionGesture` — captures `preGestureSelectionForUndo` at `beginSelectionGesture`).
- Cmd-A Select All, Cmd-D Deselect, Cmd-Shift-I Invert (each in `CanvasView`'s menu actions, capturing `before`/`after` at the call site).

The `preGestureSelectionForUndo` is **separate** from `preGestureSelectionBytes`. The latter substitutes a zero-array when no selection was active so the live-preview math has something to combine against; the undo snapshot stays nil so "no selection" round-trips correctly.

---

## What's *not* on the undo stack today

These are tracked in [`FUTURES.md`](../FUTURES.md):

- **Image transforms** (rotate / flip). Per the user manual, image transforms **clear the undo stack** (`undoManager?.removeAllActions()` in [Document.swift:79](../../Sources/Inkwell/Document.swift#L79)). The reason: the per-tile snapshots from before a transform reference tile coords that no longer exist after the transform (rotation 90° permutes coords). Document-level undo for transforms is a Phase 10 Pass 2 follow-up.
- **Layer-tree structural ops** (create / delete / reorder / rename / regroup, mask add/remove, opacity slider, blend popup). These mutate `Canvas.rootLayers` and per-layer attributes but do not register undo. A full structural-op undo is on the roadmap; today users can't undo a layer creation or rename.
- **Brush settings changes**. Adjusting the brush's size, hardness, opacity — these are model edits to `BrushPalette.activeBrush` and don't go through `NSUndoManager`.
- **Background layer color picks**. Mutating `BackgroundLayer.color` via the inspector color well does `canvas.notifyChanged()` but doesn't register undo.

If you're adding a new mutation path, ask yourself first: should this be undoable? If yes, snapshot the affected state before, register an undo via the patterns above. If no, document why.

---

## Gesture coalescing

`NSUndoManager` automatically groups all `registerUndo` calls that happen within a single run-loop turn into one undo step (its `groupsByEvent` is true by default for document undo managers). So:

- A brush stroke that calls `registerLayerStrokeUndo` once at `mouseUp` is one step. ✅
- A selection drag that calls `registerSelectionUndo` once at `commitSelectionGesture` is one step. ✅
- A vector eraser drag that may rewrite the strokes array many times during the drag, but registers once at `endVectorEraser`, is one step. ✅

We never need to manually call `beginUndoGrouping` / `endUndoGrouping`; the per-event grouping is what we want.

---

## Why we register from `Document`, not from `Canvas` or `CanvasView`

`NSUndoManager` is provided by `NSDocument.undoManager`. It's a property of the document, not of the model or the view. So registration has to happen where we have access to the `Document`.

`CanvasView` holds a `weak var document: Document?` and calls `document?.registerXxxUndo(...)` from event handlers. The `Document` then calls back into the model (the `Canvas`'s layer dictionary) by id lookup.

This isolates undo registration to one file ([Document.swift](../../Sources/Inkwell/Document.swift)) and lets the model stay undo-agnostic.

---

## Action names

Each `registerUndo` call sets an `actionName` so the menu reads "Undo Brush Stroke" / "Redo Selection" / etc. Keep this in sync when adding new ops — the menu is silent about ops without action names.

Examples:
- `"Brush Stroke"` — bitmap and vector strokes, mask strokes.
- `"Mask Stroke"` — explicit mask edits.
- `"Clear Layer"`, `"Clear Selection"`, `"Clear Mask"` — Edit → Clear in different contexts.
- `"Selection"` — generic selection-gesture commit.
- `"Select All"`, `"Deselect"`, `"Invert Selection"` — menu-driven selection ops.

---

## Adding a new undoable mutation: checklist

1. **Define what state to snapshot.** A small `[UInt8]?`? A `Set<TileCoord>`-keyed dict? Something custom? Smaller is better — we'll potentially keep N copies in memory.
2. **Capture `before` at the start of the gesture** and `after` at the end. If the work happens within one event handler, capture both there. If across multiple handlers (e.g. begin/continue/end), store `before` on a `CanvasView` field at begin, build `after` at end.
3. **Add a `registerXxxUndo(...)` method** to [Document.swift](../../Sources/Inkwell/Document.swift) modeled on the existing four. It should:
   - Bail early if `before == after`.
   - Set an action name.
   - Register an undo block that calls `applyXxxAndRegisterInverse(...)` with `before` as the target.
4. **Add the `applyXxxAndRegisterInverse(snapshot:)` method**:
   - Capture `previous = currentState`.
   - Apply `snapshot`.
   - Call `onCanvasChanged?()` so the UI redraws.
   - Register an undo block with `previous` as the target — same pattern, recursing.
5. **Wire the call site** to invoke `document?.registerXxxUndo(before:after:)` at gesture commit, plus `document?.updateChangeCount(.changeDone)`.

That's it. NSUndoManager handles grouping, the menu names, the redo direction.

---

## File-load and document-open: clearing the stack

When a document opens or a save lands, we call `undoManager?.removeAllActions()` ([Document.swift](../../Sources/Inkwell/Document.swift), search `removeAllActions`). The user can't undo *into* a different document state. This is also why image transforms currently clear: we don't yet have a way to express "undo a transform" cleanly given the per-tile snapshot design, so we conservatively wipe.

---

## What we're storing in memory

`NSUndoManager` holds the closure objects for both directions of every registered step. Each closure captures (via the inverse-snapshot pattern) a `before` snapshot. So memory is roughly:

- For bitmap stroke undo: bytes of every tile the stroke touched (tile bytes are 256 KB each). A canvas-wide stroke that hits 16 tiles ⇒ ~4 MB of tile bytes per before-snapshot, times the in-memory undo window.
- For vector stroke undo: the full pre-edit strokes array. A 1000-stroke layer with ~100 samples each at ~32 bytes ⇒ ~3 MB per snapshot. Vectors are cheap.
- For selection undo: full canvas-pixel byte array (`width × height` bytes). 4 MB at 2K canvas. Repeated for every selection edit.

Architecture decision 9 commits to compressing tile deltas with zstd at capture time and disk-backing older history. Today we don't compress and we don't page out. For typical sessions this is fine; long sessions on big canvases will eventually push memory.

---

## Known gaps

- **No `history.bin`.** The bundle reserves the chunk; `FileFormat.historyFilename` is declared but not written. Tracked in [`FUTURES.md`](../FUTURES.md) as Phase 5 deferred.
- **No zstd compression.** Per-tile deltas are kept as raw `Data`.
- **No structural-op undo.** Layer create/delete/reorder/rename, opacity slider, blend popup, mask add/remove — none registered.
- **Image transforms clear the stack.** Workaround pending Phase 10 Pass 2.
- **Brush settings and background-color edits don't undo.** Quietly mutating model state without `registerUndo`.
- **Single linear history.** No branching; redo stack is dropped on new edit. Standard for the category — see decision 9.
