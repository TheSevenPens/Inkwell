# Inkwell User Manual

This document is the user-facing reference for Inkwell. The current draft is a **feature list only**. Sections covering installation, first-run setup, a quick-start tutorial, keyboard shortcut reference, and detailed feature walkthroughs will be authored as the implementation matures.

The features below describe the v1 scope. Items deliberately deferred to later versions are tracked in `FUTURES.md`.

---

## Platform requirements

- macOS Tahoe or later
- Apple Silicon Mac

---

## Documents and files

- Native `.inkwell` document format (macOS bundle) preserves the full state of a document — layers, masks, selections, undo history.
- New documents with configurable pixel dimensions, color profile, and DPI metadata.
- Atomic save and autosave; crash-safe.
- Recent documents.
- Document scaling (resample up or down at high quality).
- Whole-image rotation (90°, 180°, 270°, arbitrary).
- Whole-image flipping (horizontal, vertical).
- Crop and resize canvas (separate from resample).

## File interop

- **Export** to PSD (8-bit, 16-bit, or 32-bit float; default 16-bit).
- **Export** to PNG (transparency preserved, profile-tagged).
- **Export** to JPG (configurable background flatten, profile-tagged).
- **Import** from PSD (layer tree, blend modes, masks, with documented fidelity).
- **Import** from PNG and JPG as single-layer documents.
- A published PSD fidelity table documents what travels exactly, what is approximated, and what is lost on round-trip.

## Layers

- Multiple bitmap layers in a single document.
- Layer groups (folders) with their own opacity and blend mode applied to the contained stack.
- Per-layer visibility, opacity, and blend mode.
- Layer thumbnails in the layer panel.
- Reorder, rename, duplicate, delete layers and groups.
- Per-layer non-destructive masks: paint to hide or reveal parts of a layer without losing pixels.
- Standard Photoshop-style blend mode set; final list and exact PSD round-trip mapping documented in the fidelity table.

## Brushes

- **Marker** — soft-edged, pressure modulates opacity, accumulates layered translucency.
- **G-Pen** — hard-edged, pressure modulates size and opacity, tight spacing for inking.
- **Airbrush** — soft circular tip, pressure modulates flow, paint emits continuously while held in place.
- **Eraser** — same engine as Marker, removes pixels rather than adding.

Brush settings:

- Name, size, spacing.
- Tip texture (built-in or imported PNG).
- Optional grain texture for paper / canvas surface simulation.
- Pressure-to-size mapping with editable pressure curve.
- Pressure-to-opacity mapping with editable pressure curve.
- Tilt influence on size and angle.
- Per-stamp jitter (size, opacity, angle, color).
- Stroke-internal blend mode.
- Save and load custom brushes.

## Stylus support

- Wacom (Bamboo, Intuos, Cintiq), Huion, XP-Pen, and other macOS-driven tablets.
- Apple Pencil via Sidecar.
- Pressure, tilt, rotation, and stylus button input.
- Eraser end of the stylus temporarily switches to the Eraser tool.
- Hot-plug detection.

## Selections

- Tools: **rectangle**, **ellipse**, **lasso**, **polygonal lasso**, **magic wand** (color similarity with tolerance), **color range**.
- **Quick Mask mode**: paint the selection with any brush.
- **Selection arithmetic**: add (Shift), subtract (Option), intersect (Shift+Option).
- Anti-aliased edges; explicit feather amount per selection.
- **Floating selection transforms**: move, scale, rotate selected pixels.
- Select All, Deselect, Inverse Selection.
- Selections persist with the document across save and reload.

## Color

- Working color space: Display P3.
- Internal precision: 16-bit per channel.
- Color picker (HSB and RGB sliders, color wheel, hex input).
- Eyedropper (hold Cmd while a brush is active).
- Basic color swatch palette (built-in and user-defined).

## View and navigation

- **Pan**: two-finger trackpad scroll, **Space + drag**, or the persistent Hand tool.
- **Zoom**: pinch on trackpad (cursor-anchored), Cmd + scroll (cursor-anchored), Cmd + plus / minus (center-anchored), Cmd + 0 to fit, Cmd + 1 to 100%.
- **Rotate**: two-finger trackpad rotate (cursor-anchored), R + drag, Shift snaps to 15°, Shift + R resets.
- **Mid-stroke navigation**: pan, zoom, or rotate during a stroke without ending it.
- **Tab** toggles all panels for a full-screen canvas view.
- Zoom range: 1% (or fit-to-window) up to 6400%.

## Editing

- Undo and redo at gesture granularity (Cmd + Z, Shift + Cmd + Z).
- Per-stroke and per-structural-operation undo steps; continuous gestures (slider drags, transforms) coalesced into one step.
- Full document-lifetime history persisted alongside the document.

## Held-modifier tool switches

- **Cmd** (with a brush tool) → temporary eyedropper.
- **Option** (with a brush tool) → temporary eraser.
- **Tab** → toggle all panels.

---

## Sections to be written

The following sections are planned but not yet authored:

- Installation and first launch.
- Quick-start tutorial.
- Detailed feature walkthroughs (brush settings, layer masks, selections, export).
- Full keyboard shortcut reference.
- Troubleshooting and FAQ.
- PSD fidelity table (also referenced from `ARCHITECTURE.md` decision 14).
