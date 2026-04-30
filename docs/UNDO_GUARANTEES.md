# Undo guarantees

The contributor-facing **policy** for which edits must be undoable, how to register them, and where today's coverage diverges from the policy. Implementation specifics — the inverse-snapshot pattern, the `Document.register*Undo` helpers — live in [`design/UNDO.md`](design/UNDO.md).

## Policy

Every edit a user can perform that **changes a persistent property of the document** must be undoable. "Persistent" means: it survives save / reopen, OR is observable to the user as a meaningful state in the running app.

By that rule:

- **Required undoable**: pixel painting, mask painting, vector strokes, vector eraser, layer create / delete / reorder / rename / regroup, mask add / remove, layer visibility, layer opacity, layer blend mode, background-layer color, selection edits, image transforms.
- **Not required undoable**: tool selection, brush selection, brush-setting adjustments, view transform changes (zoom / rotate / pan), panel collapse, eyedropper sampling, debug toggles.

The cut is roughly: **"if I close the document and reopen it, would my edit still be there?"** If yes, undoable. If no, ephemeral UI state.

## What we ship today

Implemented:
- ✅ Brush stroke (bitmap layer, "Brush Stroke")
- ✅ Brush stroke on a mask ("Mask Stroke")
- ✅ Vector stroke commit ("Brush Stroke" — same name; could differentiate)
- ✅ Vector eraser drag (all three modes)
- ✅ Edit → Clear (layer / mask / vector layer; one undo step)
- ✅ Selection rect / ellipse / lasso commit ("Selection")
- ✅ Select All ("Select All")
- ✅ Deselect ("Deselect")
- ✅ Invert Selection ("Invert Selection")
- ✅ Move Layer drag (one step per drag, both bitmap and vector layers)

Not yet implemented (gaps):

- ❌ Layer create / delete (`+`-button additions, Del button).
- ❌ Layer reorder (drag-reorder in the panel).
- ❌ Layer rename.
- ❌ Layer regroup (drag into / out of group).
- ❌ Mask add / remove.
- ❌ Layer visibility toggle (eye button).
- ❌ Layer opacity slider.
- ❌ Layer blend mode popup.
- ❌ Background layer color picker.
- ❌ Image rotate / flip (currently *clears* the stack — undo is destroyed).

These are tracked in [`FUTURES.md`](FUTURES.md) and [`ROADMAP_OWNERSHIP.md`](ROADMAP_OWNERSHIP.md).

## Action naming convention

Every `registerUndo` should set an `actionName` so the menu reads "Undo X" / "Redo X" with the user's mental label.

| Edit | Action name |
|---|---|
| Brush stroke (bitmap, mask, vector) | `"Brush Stroke"` |
| Mask stroke specifically | `"Mask Stroke"` |
| Vector eraser | `"Brush Stroke"` (because the user's mental model is "I'm doing a stroke") — debatable; could differentiate |
| Edit → Clear (layer, mask, vector) | `"Clear Layer"`, `"Clear Mask"`, or `"Clear Selection"` based on context |
| Selection gesture | `"Selection"` |
| Select All / Deselect / Invert | `"Select All"` / `"Deselect"` / `"Invert Selection"` |

When adding a new undoable interaction:

- Use **plain English** that matches the menu — Title Case.
- Avoid technical jargon ("apply tile snapshot to layer 17" is wrong; "Brush Stroke" is right).
- If two interactions produce the same kind of edit (vector stroke vs. vector eraser), it's OK to share an action name unless users would benefit from differentiating in the menu.

## Grouping convention

`NSUndoManager` groups all `registerUndo` calls that happen during one event-loop turn into one step. So the rule of thumb is:

- **Register at gesture commit, not during.** A brush stroke that calls `registerUndo` at every stamp would fragment into hundreds of undo steps. Aggregate at `mouseUp` (the gesture's natural boundary).
- **Register once per discrete user action.** A click on "+ Layer" → one undo step. A blend-mode popup change → one undo step.
- **Drag interactions** use `mouseDown` to snapshot `before`, `mouseUp` to snapshot `after`, and register once at end.

Today the grouping rule is enforced by structure: `commitUndoIfNeeded()`, `endVectorStroke`, `endVectorEraser`, `endMoveLayer`, `commitSelectionGesture`, `Document.clearXxxContents` each call `registerXxxUndo` exactly once.

When adding a new interaction:

- If it's a single-event mutation (click / menu pick) → register at the action handler.
- If it's a continuous gesture (drag) → snapshot at begin, build after-snapshot at end, register at end.

## How to add a new undoable mutation

Step-by-step. The pattern is repeatable.

### 1. Decide what state to snapshot

Smaller is better — we hold N copies in memory. Examples:

- Color picker on background layer → snapshot just the `ColorRGBA` (16 bytes).
- Rename a layer → snapshot just the old / new name (a few bytes each).
- Toggle visibility → snapshot a `Bool`.
- Reorder layers → snapshot an array of layer IDs in old order vs. new order.

### 2. Capture `before` and `after`

For single-event mutations (handler-driven):
```swift
@objc private func somethingChanged(_ sender: NSControl) {
    guard let canvas, let layer = canvas.activeLayer else { return }
    let before = layer.someProperty
    layer.someProperty = newValue
    let after = layer.someProperty
    document?.registerSomethingUndo(layerId: layer.id, before: before, after: after)
    document?.updateChangeCount(.changeDone)
}
```

For drag-style gestures (begin/continue/end):
```swift
private func beginGesture() {
    self.beforeState = currentState()
}

private func continueGesture() {
    // mutate live state; no undo registration yet
}

private func endGesture() {
    let after = currentState()
    document?.registerXxxUndo(before: beforeState, after: after)
    document?.updateChangeCount(.changeDone)
}
```

### 3. Add the registration helper to `Document`

[Document.swift](../Sources/Inkwell/Document.swift). Modeled on the existing four:

```swift
func registerSomethingUndo(layerId: UUID, before: T, after: T) {
    guard let undoManager, before != after else { return }
    undoManager.setActionName("Something")
    undoManager.registerUndo(withTarget: self) { [weak self] _ in
        self?.applySomethingAndRegisterInverse(layerId: layerId, value: before)
    }
}

private func applySomethingAndRegisterInverse(layerId: UUID, value: T) {
    guard let layer = canvas.findLayer(layerId) else { return }
    let previous = layer.someProperty
    layer.someProperty = value
    onCanvasChanged?()
    undoManager?.setActionName("Something")
    undoManager?.registerUndo(withTarget: self) { [weak self] _ in
        self?.applySomethingAndRegisterInverse(layerId: layerId, value: previous)
    }
}
```

Recursive registration. NSUndoManager handles the redo direction automatically.

### 4. Verify

- Perform the edit; run `Cmd+Z` → state restores.
- `Cmd+Shift+Z` → state re-applies.
- Multiple edits → each undoes individually.
- Edit, undo, edit again → redo stack is dropped. Re-edit produces a new linear history.

## Exceptions documented

These are not yet undoable today and their entries above call them out. The most surprising:

- **Image transforms clear the stack.** Rotate 90° or Flip Horizontal calls `undoManager?.removeAllActions()`. The reason: per-tile snapshots from before a transform reference tile coords that no longer exist after (rotation permutes coords). Document-level undo for image transforms is a Phase 10 Pass 2 follow-up.
- **Layer-tree structural ops don't register.** This is a real gap; users can't undo a layer creation or rename. Tracked.

If your change relies on these gaps existing (e.g. you have a workflow that *expects* Image Rotate to clear the stack), document why; otherwise plan to fix the gap rather than work around it.

## Memory cost

Each registered undo holds a closure capturing the `before` snapshot. The closure stays in memory until the user redoes past it or until the undo manager evicts it (`NSUndoManager` has a `levelsOfUndo` cap; default is unlimited).

Concrete sizes:

- **Bitmap stroke** — bytes of every dirty tile (256 KB each, uncompressed). A canvas-wide stroke touching 16 tiles → ~4 MB per `before` snapshot.
- **Vector stroke** — full strokes array (~32 bytes/sample × ~100 samples × stroke count). Cheap.
- **Selection edit** — full canvas-pixel byte array (`width × height` bytes). 4 MB at 2K canvas.
- **Layer property toggle** — bytes.

A long session with hundreds of bitmap strokes can accumulate hundreds of MB of undo memory. The architecture's solution (zstd compression + disk-backed full history) isn't implemented yet; for now, **Edit → Clear** the document or close & reopen to release.

## Related

- [`design/UNDO.md`](design/UNDO.md) — implementation pattern and code references.
- [`arch/CONCURRENCY.md`](arch/CONCURRENCY.md) decision 9 — the architectural commitment to per-stroke deltas, gesture coalescing, and full document-lifetime history.
- [`UI_STATE_MODEL.md`](UI_STATE_MODEL.md) — which user interactions exist and which are expected to undo.
- [`ROADMAP_OWNERSHIP.md`](ROADMAP_OWNERSHIP.md) — entry points for closing the listed gaps.
