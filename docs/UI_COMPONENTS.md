# Inkwell UI Components

A catalog of the custom UI components in Inkwell — what's reusable, what's a top-level composite, and the conventions all of them follow. Every component below is hand-built on AppKit primitives (`NSView`, `NSButton`, `NSStackView`, etc.); there is no third-party UI kit and no SwiftUI in this codebase.

---

## Conventions

These are the unwritten rules the existing components already follow. Any new sidebar UI should match them.

### Typography

| Use | Font |
|---|---|
| Section title (under a disclosure triangle) | `.boldSystemFont(ofSize: 12)`, `.secondaryLabelColor` |
| Row label (e.g. "Opacity", "Hardness") | `.systemFont(ofSize: 12)` |
| Active brush name | `.systemFont(ofSize: 14, weight: .medium)` |
| Numeric value next to a slider | `.monospacedDigitSystemFont(ofSize: 11)` |
| Hex / debug field | `.monospacedSystemFont(ofSize: 11, weight: .regular)` |

### Icon buttons (sidebar)

- Frame: **36 × 32** pt, `bezelStyle = .regularSquare`.
- Image: SF Symbol at `pointSize: 16, weight: .regular`, `imagePosition = .imageOnly`.
- **Toggle** (active tool / active brush): `setButtonType(.pushOnPushOff)`.
- **Action** (one-shot, e.g. Deselect): `setButtonType(.momentaryPushIn)`, `target = nil` so the action dispatches up the responder chain.
- Always set `toolTip` — these are icon-only buttons, the tooltip is the user's only label.

### Layout

- Vertical sidebar stacks: `spacing = 6`, `edgeInsets = (16, 8, 16, 8)`, `alignment = .centerX` (icons) or `.leading` (forms).
- Mid-panel separators: 1pt `NSView` with `.separatorColor` background.
- The two scrollable sidebar panels (left / right) wrap their content view in a `FlippedView` documentView so short content anchors to the visual top.

### Colors

- Panel backgrounds: `NSColor.windowBackgroundColor` via `wantsLayer`.
- Section title color: `.secondaryLabelColor`.
- Debug bar: hardcoded yellow-orange `(1.0, 0.78, 0.20)` so it's visually unmistakable.

---

## Reusable building blocks

These are designed to be reused. Some are still `private` / `fileprivate` to their host file — when you want to use one outside, promote its visibility to `internal`.

### CollapsibleSection

[CollapsibleSection.swift](../Sources/Inkwell/CollapsibleSection.swift)

Disclosure-triangle header that toggles `isHidden` on a registered list of body views. Used by **Brush Settings** and **Layers**.

```swift
let section = CollapsibleSection(title: "My Section")
stack.addArrangedSubview(section.header)         // the disclosure-triangle row
section.add(myRow1, to: stack)                   // also adds to stack
section.add(myRow2, to: stack)
// Body views are toggled together when the user clicks the disclosure triangle.
```

NSStackView excludes hidden arranged subviews from layout, so the section collapses smoothly without further work.

**Visibility:** `internal` (file-level) — directly reusable.

---

### FlippedView

[DocumentWindowController.swift:6](../Sources/Inkwell/DocumentWindowController.swift)

Trivial NSView subclass with `isFlipped = true`. Used as the documentView of an NSScrollView so short content anchors to the visual top of the clip view rather than the bottom (NSClipView is non-flipped by default).

```swift
let content = FlippedView()
content.translatesAutoresizingMaskIntoConstraints = false
scroll.documentView = content
content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
```

**Visibility:** `private` to `DocumentWindowController.swift`. **Promote to `internal`** if you build another scrollable panel.

---

### ViewTransform

[ViewTransform.swift](../Sources/Inkwell/ViewTransform.swift)

Pan / zoom / rotate transform with `windowToCanvas` / `canvasToWindow` helpers. Pure Swift value type, no AppKit dependency.

```swift
var t = ViewTransform()
t.scale = 2.0
t.rotation = .pi / 4
let canvasPoint = t.windowToCanvas(viewLocalPoint)
```

Used by `CanvasView` for everything to do with view-space ↔ canvas-space mapping. Reusable for any zoomable/rotatable surface.

**Visibility:** `internal` — directly reusable.

---

### SliderRow

[BrushInspectorView.swift](../Sources/Inkwell/BrushInspectorView.swift) (`fileprivate final class`)

Labeled slider + monospaced numeric value field, with `min` / `max` / `fmt` and an `onChange` callback. Used 9× in the brush inspector.

```swift
let row = SliderRow(label: "Opacity", min: 0, max: 1, fmt: "%.2f")
row.onChange = { value in /* … */ }
row.value = 0.5
```

**Visibility:** `fileprivate` to `BrushInspectorView.swift`. **Promote to `internal`** (or move to its own file) when another panel needs a labeled slider.

---

### SwatchButton

[BrushInspectorView.swift:227](../Sources/Inkwell/BrushInspectorView.swift) (`fileprivate final class`)

NSButton subclass that fills its bounds with a `ColorRGBA`. Used 12× in the swatch row.

```swift
let button = SwatchButton(color: ColorRGBA(r: 1, g: 0, b: 0))
button.target = self
button.action = #selector(swatchClicked(_:))
```

**Visibility:** `fileprivate` to `BrushInspectorView.swift`. Promote when reused.

---

## Top-level composite views

One customer each — the document window. Listed here so you know they exist and roughly what shape they have. Each is a custom subclass of `NSView` (or `MTKView` for the canvas).

| Component | File | Purpose |
|---|---|---|
| `CanvasView` | [CanvasView.swift](../Sources/Inkwell/CanvasView.swift) | The MTKView. Handles all mouse / tablet input, brush dispatch (bitmap and vector paths), selection gestures, eyedropper, view transform gestures, debug telemetry. |
| `LeftPaneView` | [LeftPaneView.swift](../Sources/Inkwell/LeftPaneView.swift) | The left pane — a single "Tools" section today (brushes, selection shapes, deselect action, hand). Generic name so future palettes / sections land here without another rename. |
| `BrushInspectorView` | [BrushInspectorView.swift](../Sources/Inkwell/BrushInspectorView.swift) | Right sidebar (top half). Color well + hex field + 12 swatches + 9 sliders. Wrapped in a `CollapsibleSection`. |
| `LayerPanelView` | [LayerPanelView.swift](../Sources/Inkwell/LayerPanelView.swift) | Right sidebar (bottom half). Layer-action toolbar, Edit/Layer-Mask toggle, opacity slider, blend popup, NSOutlineView of the layer tree, mask toolbar. Wrapped in a `CollapsibleSection`. |
| `StatusBarView` | [StatusBarView.swift](../Sources/Inkwell/StatusBarView.swift) | Bottom status bar — zoom %, rotation°, cursor canvas-position, document size. |
| `DebugBarView` | [DebugBarView.swift](../Sources/Inkwell/DebugBarView.swift) | Yellow-orange diagnostic bar at the top of the canvas area. Source / position / pressure / tilt / azimuth / altitude / Hz. Toggled via Debug → Show Debug Toolbar. |
| `LayerRowCell` | [LayerPanelView.swift](../Sources/Inkwell/LayerPanelView.swift) (`private final class`) | Outline view cell. Eye toggle + editable name + "M" mask badge. |

---

## When to add a new component

- **Need a labeled slider somewhere new?** Promote `SliderRow` to internal and use it. Don't reinvent.
- **Need a toggle-able panel header?** Use `CollapsibleSection`.
- **Need a panel that scrolls when too tall for the window?** Wrap your content in a `FlippedView` inside an `NSScrollView`. See `DocumentWindowController.init` for the template.
- **Need an icon button?** Match the sidebar conventions above (36×32, SF Symbol 16pt, push-on-push-off for toggles, momentary-push-in for actions, always set tooltip).
- **Need a status / overlay bar?** Look at `StatusBarView` and `DebugBarView` as templates — they're tiny and self-contained.

---

## Honest gaps

These don't exist yet. Listed so future contributors don't reinvent them in inconsistent ways:

- **Custom color picker UI.** We use `NSColorWell` + the system color panel. A first-party picker is a Phase-12 task.
- **Toast / status notification.** No standard way to surface non-error feedback (e.g. "Marker doesn't paint on a vector layer"). Today these conditions silently no-op.
- **Saved swatch persistence.** Built-in swatches only; user-saved swatches are tracked in `FUTURES.md`.
- **Tooltip / shortcut hint badges** (the kind that show ⌘K next to a menu hint). Not implemented; we rely on tooltips and the menu.
- **Onboarding / first-run UI.** None. Phase 12.
