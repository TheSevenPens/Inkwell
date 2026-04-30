# Inkwell User Manual

This document is the user-facing reference for Inkwell. **Phases 0–11 have shipped**; the manual below describes what's actually in the app today, with documented deferrals at the end of each section pointing to [`FUTURES.md`](FUTURES.md).

Sections covering installation, first-run setup, a quick-start tutorial, keyboard shortcut reference, and detailed feature walkthroughs are part of Phase 12 (pre-launch hardening) and will be authored at that time.

---

## Platform requirements

- macOS Tahoe (26) or later
- Apple Silicon Mac

---

## Documents and files

- Native `.inkwell` document format (macOS bundle) preserves layers, layer masks, blend modes, opacity, the active selection, and the layer tree across save and reload.
- Atomic save via `NSFileWrapper` (temp + rename).
- Format version field with a migration scaffold; older format readers are kept indefinitely.
- Recent documents in **File → Open Recent**.
- Image transforms: **Image → Rotate 180°**, **Rotate 90° CW**, **Rotate 90° CCW**, **Flip Horizontal**, **Flip Vertical**.

**Deferred (see `FUTURES.md`):** undo / timelapse history persistence (`history.bin`), document scaling (resample), resize canvas without resample, crop, new-document dialog with custom dimensions / profile / DPI presets, arbitrary-angle rotation.

## File interop

- **Export** to PNG (transparency preserved, sRGB-tagged).
- **Export** to JPEG (white background flatten, sRGB-tagged).
- **Export** to PSD (flat 8-bit composite).
- **Import** from PSD, PNG, and JPEG as a single-layer document.
- The published [PSD fidelity table](PSD_FIDELITY.md) documents exactly what travels through PSD round-trip today and what's coming in Pass 2.

**Deferred:** layer-aware PSD export (groups, masks, blend modes preserved as PSD layers); layer-aware PSD import; embedded ICC color profile in PSD output; 16/32-bit PSD; Display P3 export with gamut mapping for sRGB targets.

## Layers

- Multiple bitmap layers in a single document.
- Layer groups (folders) with their own opacity (multiplied through children — pass-through groups in Phase 4; isolated group blending is a future addition).
- Per-layer visibility, opacity, blend mode.
- Layer panel: outline view with eye toggle and editable name; drag-to-reorder within and into groups; "M" badge when a layer has a mask.
- Reorder, rename, duplicate, delete layers; new layer / new group / duplicate / delete buttons in the panel toolbar.
- Per-layer non-destructive masks: Add Mask / Remove Mask buttons; **Edit: [Layer | Mask]** toggle routes brush input.
- Blend modes: Normal, Multiply, Screen, Overlay (the full Photoshop set is a Phase 9 follow-up).

**Deferred:** group masks, vector layers, layer thumbnails in the panel, isolated group blending.

## Brushes

Four built-in brushes share one data-driven engine. Click any in the **Brushes** picker on the left.

- **G-Pen** — hard-edged round tip; pressure → size and pressure → opacity; tight spacing for inking.
- **Marker** — soft-edged; pressure → opacity primarily; layers translucently.
- **Airbrush** — very soft tip with low base opacity; emits continuously while held in place at 60 Hz.
- **Eraser** — same engine as Marker with destination-out blend so painted strokes remove pixels.

Brush settings (live-edited in the right inspector):

- Size, hardness, spacing, opacity.
- Pressure → size and pressure → opacity strengths (curve representation is provisional per ARCHITECTURE.md decision 11).
- Tilt → size influence (tilt-aware sizing).
- Per-stamp jitter for size and opacity.

**Deferred:** grain textures; color jitter; stroke-internal blend mode; user-saved custom brushes; ABR import.

## Stylus support

- Wacom (Bamboo, Intuos, Cintiq), Huion, XP-Pen, and other macOS-driven tablets.
- Apple Pencil via Sidecar.
- Pressure, tilt, and stylus-tip-vs-eraser detection captured per sample.
- Hot-plug detection (via `tabletProximity` events).
- Eraser end of the stylus temporarily switches to the Eraser tool.

## Selections

Pick **Rectangle**, **Ellipse**, or **Lasso** under the **Selection** section in the left sidebar. Drag on the canvas to select.

- **Selection arithmetic** via modifier keys at drag start: Shift = add, Option = subtract, Shift+Option = intersect, no modifier = replace.
- **Live preview**: the marching-ants overlay updates as you drag.
- **Marching ants** animate on committed selections (active or live preview).
- **Constraint application**: every pixel-writing operation (brush stamp on a layer, brush stamp on a mask, eraser) multiplies by the selection mask at the canvas pixel.
- Menu items: **Edit → Select All** (Cmd+A), **Deselect** (Cmd+D), **Invert Selection** (Cmd+Shift+I).
- Selections persist with the document across save and reload.

**Deferred:** polygonal lasso, magic wand, color range tools; Quick Mask mode (paint the selection with a brush); floating-selection transforms (move / scale / rotate); per-selection feather slider; selection-state undo (selection edits aren't yet on the undo stack).

## Color

- 12 built-in swatches in the brush inspector — click to set the active brush's color.
- **Hex input** (`#RRGGBB` or `#RGB`) next to the color well; bad input restores the previous valid hex.
- **Color well** opens the system color picker (HSB / RGB / wheel / palettes).
- **Cmd-click on canvas** while a brush is active samples the active layer's pixel and applies it to the brush.

**Deferred:** persistent user-saved swatches with "Add Current Color"; custom in-app color picker UI (the system picker is the current path); Display P3 working color space (sRGB throughout today, despite ARCHITECTURE.md decision 6's commitment to P3).

## View and navigation

- **Pan**: two-finger trackpad scroll, **Space + drag**, or the persistent **Hand** tool (left sidebar, "Navigate" section).
- **Zoom**: pinch on trackpad (cursor-anchored), Cmd + scroll (cursor-anchored), Cmd + plus / minus.
- **View → Fit Window** (Cmd+0), **View → Actual Size** (Cmd+1).
- **Rotate**: two-finger trackpad rotate gesture (cursor-anchored), **R + drag** (anchored at view center), **Shift** during R+drag snaps to 15°, **Shift+R** resets rotation.
- **Mid-stroke navigation**: zoom / pan / rotate during a brush stroke without ending it.
- **Tab** toggles the left sidebar (Brushes / Selection / Navigate) and the right sidebar (Brush Inspector + Layers).
- Zoom range: ~5% to 6400%.

## Status bar

At the bottom of the canvas:

- **Zoom**: current zoom percentage. View rotation in degrees appears alongside when non-zero.
- **Cursor position**: canvas-pixel X/Y under the cursor (`—` when off-canvas).
- **Document size**: pixel dimensions on the right.

## Editing

- Undo and redo at gesture granularity (Cmd+Z, Shift+Cmd+Z).
- Per-stroke and per-mask-stroke undo steps. Image transforms clear the undo stack (per-tile snapshots from before a transform may reference coords that no longer exist).
- Continuous gestures (the brush stroke as a whole) are coalesced into one step.

**Deferred:** full document-lifetime history persistence (the undo stream isn't yet written to the bundle); document-level undo for image transforms; selection-state undo.

## Held-modifier tool switches

While a brush tool is active:

- **Cmd-click** → eyedropper. Samples the active layer's pixel under the cursor and updates the brush color.
- **Option** held during a stroke → that stroke uses erase blend (overrides the brush's blend mode for the duration of the stroke).

App-wide:

- **Tab** → toggle sidebar panels.

---

## Sections to be written (Phase 12)

The following sections will be authored as part of Phase 12 (pre-launch hardening):

- Installation and first launch.
- Quick-start tutorial.
- Detailed feature walkthroughs (brush settings, layer masks, selections, export).
- Full keyboard shortcut reference.
- Troubleshooting and FAQ.
