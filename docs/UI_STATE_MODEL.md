# UI state model

The active tool, the modifier keys held, the held-key shortcuts, the panel collapse state. Reads as a concise reference for *what the user can be in the middle of doing* and how state transitions behave.

Most of this lives in [CanvasView.swift](../Sources/Inkwell/CanvasView.swift), [ToolState.swift](../Sources/Inkwell/ToolState.swift), and the various `*Controller`s under [`Sources/Inkwell/`](../Sources/Inkwell/).

## Tool state

Single source of truth: `ToolState.shared.tool` ([ToolState.swift](../Sources/Inkwell/ToolState.swift)).

```swift
enum Tool: Equatable {
    case brush
    case hand
    case moveLayer
    case selectRectangle
    case selectEllipse
    case selectLasso
}
```

### Transitions

A tool change happens on:
- Click of an icon in the left pane Tools section ([LeftPaneView.swift](../Sources/Inkwell/LeftPaneView.swift), `toolButtonClicked(_:)`).
- The eraser-tip auto-swap from `tabletProximity` (`CanvasView.tabletProximity` swaps the active brush, not the tool — see "Brush vs. tool" below).

Held-key transitions are **temporary** and don't change `ToolState.shared.tool`; they overlay behavior on the current tool. See "Held modifiers."

### Brush vs. tool

A subtle but important split:

- **`ToolState.shared.tool`** — what tool the user picked from the icon strip. Brush is one tool.
- **`BrushPalette.shared.activeBrush`** — which brush (G-Pen, Marker, Airbrush, Eraser) is active *while the brush tool is selected*.

The stylus-eraser-tip swap (decision 10) modifies `BrushPalette.activeIndex` (forcing the active brush to Eraser), not `ToolState.shared.tool`. So a user who has the Hand tool active and brushes their stylus eraser past the tablet sees no change — the swap only matters when the brush tool is what they'd be drawing with.

The current brush is irrelevant when the tool is `.hand`, `.moveLayer`, or any selection tool.

## Held modifiers (precedence rules)

Modifiers held during input have precedence over the active tool. The order matters because some combinations are ambiguous.

### Mouse-down decision tree

When `mouseDown` fires while the brush tool is active ([CanvasView.swift](../Sources/Inkwell/CanvasView.swift), `mouseDown(with:)`):

```
1. If Space is held → begin Pan (overrides everything).
2. Else if R is held → begin Rotate-drag.
3. Else dispatch by tool:
   .brush:
     a. If Cmd is held → eyedropper. Sample, set brush color, return.
     b. Else:
        forceErase = (Option held) || (stylus eraser tip is engaged)
        sample = sampleFor(event: event)
        If active layer is a vector layer:
           if brush.id == "eraser" or forceErase:
              beginVectorEraser(at: sample)   // hit-test deletion
           else:
              beginVectorStroke(at: sample)   // ribbon paint
        Else (bitmap layer):
           beginStroke(at: sample, forceErase: forceErase)
   .moveLayer:    beginMoveLayer(with: event)
   .hand:         beginPan(with: event)
   .selectRectangle / .selectEllipse / .selectLasso:
                  beginSelectionGesture(with the appropriate selection-op
                                        derived from Shift/Option modifiers)
```

So the precedence stack is:

1. **Space (held)** → temporary Pan tool.
2. **R (held)** → temporary Rotate.
3. **Cmd (during brush click)** → eyedropper.
4. **Option (during brush stroke)** → force-erase blend.
5. **Stylus eraser tip** → swap to Eraser brush (and force-erase).

Ambiguity rules:

- **Space + Option** → Pan wins.
- **Space + Cmd** → Pan wins.
- **R + Cmd** → Rotate wins.
- **Cmd + Option** during brush click — Cmd wins (eyedropper, no stroke).
- **Shift / Option / Shift+Option** during a selection gesture → maps to Selection.Op via `selectionOp(_:)`:
  - Shift → `.add`
  - Option → `.subtract`
  - Shift+Option → `.intersect`
  - none → `.replace`

### Selection-op modifier evaluation

Selection modifiers are sampled at **drag start**, not continuously. Mid-gesture modifier changes don't switch the op. This matches Photoshop and avoids visual jumps.

### Held-key tracking

`CanvasView` tracks `spaceHeld` and `rHeld` Bools, mutated by `keyDown` / `keyUp`. The brush cursor's appearance is recomputed via `cursorUpdate(with:)` on every key transition.

`keyDown` swallows held-modifier keys (space, R, Tab, Backspace) regardless of `event.isARepeat` to suppress system beeps on auto-repeat.

## Cursor-update triggers

The brush cursor needs to refresh whenever the *displayed brush size* changes. Triggers ([CanvasView.swift](../Sources/Inkwell/CanvasView.swift)):

- Mouse-moved tracking-area events (standard).
- Brush palette change (any brush field).
- Tool state change.
- Vector overlay toggle (no cursor effect; just redraw).
- **Zoom-changing mutations** (every place that calls `viewTransform.zoom(...)` / `.scale = …` / `setScale`): explicitly call `invalidateBrushCursor()` because tracking-area events alone don't fire on zoom-only changes.

If you add a new way to mutate `viewTransform.scale`, you must call `invalidateBrushCursor()` after, or the cursor will lag at its previous size.

## Persisted UI state

State that survives launch is stored in `UserDefaults` under stable keys.

| Key | Purpose | Owner |
|---|---|---|
| `Inkwell.LeftPaneWidth` | Left-pane width in points (clamped to 56–320) | [DocumentWindowController.swift](../Sources/Inkwell/DocumentWindowController.swift) |
| `Inkwell.DebugBarVisible` | Whether the debug toolbar is visible | [DebugBarController.swift](../Sources/Inkwell/DebugBarController.swift) |
| `Inkwell.VectorOverlayVisible` | Whether the vector path overlay is enabled | [VectorOverlayController.swift](../Sources/Inkwell/VectorOverlayController.swift) |
| `Inkwell.VectorEraserMode` | "wholeStroke" / "region" / "toIntersection" | [VectorEraserMode.swift](../Sources/Inkwell/VectorEraserMode.swift) |
| `Inkwell.SectionCollapsed.<id>` | Whether each `Section` is collapsed | [Section.swift](../Sources/Inkwell/Section.swift) |

State that does **not** persist (intentionally):

- The active tool (`ToolState.shared.tool`).
- The active brush (`BrushPalette.shared.activeIndex`).
- The brush settings (radius / opacity / hardness / curves). These reset to the bundled defaults on each launch.
- The window position and size (handled by `NSWindow`'s frame autosave; we don't manage it explicitly).
- The active selection (saved with the document, not globally).

If you add a UI state that should survive launch, give it a stable `Inkwell.<Namespace>.<Key>` UserDefaults key. Don't reuse keys; don't bury them in deeply-namespaced strings.

## Section collapse / expand

Generic via [`CollapsibleSection.swift`](../Sources/Inkwell/CollapsibleSection.swift) and [`Section.swift`](../Sources/Inkwell/Section.swift). The latter is a thin wrapper that adds:
- A standardized header row.
- Persisted collapsed state under `Inkwell.SectionCollapsed.<id>`.
- A body container into which the caller adds rows.

Three sections use this:
- Tools (left pane)
- Brush Settings (right pane)
- Layers (right pane)
- Color Palette (left pane) — uses `Section`, not raw `CollapsibleSection`

The persistence pattern: id is whatever string the caller passed. Pick a stable id at section creation and never change it; renaming the id orphans the collapsed state.

**Lifetime gotcha**: `Section` (and `CollapsibleSection`) must be retained by the parent view as a stored property — its `NSButton.target` is weak, so allowing the wrapper to deallocate makes the chevron visually rotate but stop toggling. Both files document this; new callers must do the same.

## Undo grouping per interaction

Each user-visible gesture should produce **one** undo step. The `NSUndoManager` event-grouping rule does most of the work — register-undo calls during a single event-loop turn coalesce.

Today's per-interaction grouping:

| Interaction | Undo grouping |
|---|---|
| Brush stroke (begin → drag → end) | One step at `mouseUp` via `commitUndoIfNeeded()`. |
| Vector stroke (begin → drag → end) | One step at `mouseUp` via `endVectorStroke`. |
| Vector eraser drag (any mode) | One step at `mouseUp` via `endVectorEraser`. |
| Move Layer drag | One step at `mouseUp` via `endMoveLayer`. |
| Edit → Clear | One step. |
| Selection gesture (rect / ellipse / lasso) | One step at `commitSelectionGesture()`. |
| Cmd-A / Cmd-D / Cmd-Shift-I | One step each. |

Today's exclusions (no undo step registered):

- Tool change.
- Brush change.
- Brush settings (radius slider, opacity slider, etc.).
- Background layer color picker.
- Layer create / delete / reorder / rename / regroup.
- Mask add / remove.
- Layer visibility / opacity / blend mode changes.
- Image transforms (rotate / flip) — these *clear* the undo stack instead.

When adding a new interaction that should be undoable, follow the patterns documented in [`UNDO_GUARANTEES.md`](UNDO_GUARANTEES.md).

## What's not modeled as state today

- **Tool options** (any tool-specific configuration beyond brush settings). The Vector Eraser Mode is the closest thing; it lives in its own controller ([VectorEraserController](../Sources/Inkwell/VectorEraserMode.swift)) rather than as part of `ToolState`.
- **Modal modes** like Photoshop's Quick Mask. Architecture decision 12 plans for this; today there's no toggleable "edit selection as raster" mode.
- **A formal state machine**. Tool transitions are implemented as direct conditional dispatch in `CanvasView`, not as a state graph. If transition rules grow, a `ToolStateMachine` type would be the natural refactor.

## Hidden behaviors worth surfacing

These work but aren't visible from the UI alone:

- **Cmd-click during brush** → eyedropper.
- **Option-during-stroke** → force-erase regardless of brush.
- **Stylus eraser tip** → temporary brush swap to Eraser.
- **Tab** → toggle all panels.
- **Space + drag** → temporary Pan.
- **R + drag** → temporary Rotate.
- **Shift during R-drag** → snap to 15° increments.
- **Shift + R** → reset rotation to 0°.
- **Shift / Option / Shift+Option during selection drag** → add / subtract / intersect.

The **Help → Keyboard Shortcuts** menu doesn't exist yet. The full reference is in [`USERMANUAL.md`](USERMANUAL.md). Phase 12 hardening should surface a shortcut-reference panel.

## Related docs

- [`USERMANUAL.md`](USERMANUAL.md) — user-facing description of every interaction.
- [`UNDO_GUARANTEES.md`](UNDO_GUARANTEES.md) — what should be undoable and how.
- [`design/STROKES.md`](design/STROKES.md) — input → painting pipeline.
- [`design/COORDINATES.md`](design/COORDINATES.md) — how event coordinates become canvas pixels.
