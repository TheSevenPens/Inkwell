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
- **Vector layers** (V1 — G-Pen only): strokes are stored as polylines + per-sample pressure and rendered as a continuous swept-path SDF ribbon (no stamp seams). Compose into the layer tree alongside bitmap and group layers. Create with **+ Vector** in the layer panel toolbar.
- **Background layers**: solid-color full-canvas layers with no per-pixel data. Create with **+ BG** in the layer panel toolbar; it inserts at the bottom of the stack by default. With a Background Layer selected, a **Color** row appears in the Layer panel with a system color well. Standard layer attributes (visibility, opacity, blend mode, drag-to-reorder) all work. Caveat: the canvas itself has a built-in warm-cream **paper color** that renders before any layer. A Background Layer with `alpha < 1`, or a non-Normal blend mode, will show that paper color through. For a clean fill, leave the BG layer at full opacity / Normal blend (the default); this completely covers the paper. True transparent-canvas support is a separate, currently unsupported feature.
- Layer groups (folders) with their own opacity (multiplied through children — pass-through groups in Phase 4; isolated group blending is a future addition).
- Per-layer visibility, opacity, blend mode.
- Layer panel: outline view with eye toggle and editable name; drag-to-reorder within and into groups; "M" badge when a layer has a mask.
- Reorder, rename, duplicate, delete layers; new layer / **new vector** / new group / duplicate / delete buttons in the panel toolbar.
- Per-layer non-destructive masks (bitmap layers only — vector layers don't yet support masks): Add Mask / Remove Mask buttons; **Edit: [Layer | Mask]** toggle routes brush input.
- The Layers panel (and the Brush Settings panel above it) is **collapsible** — click the disclosure triangle next to the section title to hide / show its contents.
- Layer-action toolbar (**+ Layer**, **+ Vector**, **+ Group**, **Dup**, **Del**) sits directly under the Layers section title for fast access.
- Blend modes: Normal, Multiply, Screen, Overlay (the full Photoshop set is a Phase 9 follow-up).

**Deferred:** group masks, vector-layer masks, layer thumbnails in the panel, isolated group blending, per-stroke selection / move / restyle on vector layers, soft-edged vector brushes (Marker/Airbrush as vector).

## Brushes

Four built-in brushes share one data-driven engine. Click any in the **Tools** section of the left pane.

- **G-Pen** — hard-edged round tip; pressure → size and pressure → opacity; tight spacing for inking. On vector layers, G-Pen produces a true swept-path stroke (pressure modulates radius along a single continuous ribbon; opacity is constant per stroke).
- **Marker** — soft-edged; pressure → opacity primarily; layers translucently.
- **Airbrush** — very soft tip with low base opacity; emits continuously while held in place at 60 Hz.
- **Eraser** — on bitmap layers, same engine as Marker with destination-out blend so painted strokes remove pixels. On vector layers, hit-tests strokes; what gets removed is controlled by **Edit → Vector Eraser Mode**:
  - **Whole Stroke** (default): any stroke the eraser disc touches is deleted entirely. Caveat: barely grazing the tail of a stroke still deletes the whole thing — the eraser radius is the only knob, not "how much of the stroke was crossed."
  - **Touched Region**: each touched stroke is split at the raw stylus samples that fall inside the eraser disc; the runs of consecutive non-erased samples remain as new sub-strokes. Caveat: cuts snap to sample boundaries — dense polylines give clean cuts, sparse ones can leave a visible stub on either side of the gap. (Sub-pixel disc-edge clipping is a V2 follow-up; tracked in `FUTURES.md`.)
  - **To Intersection**: from the closest sample on the touched stroke to the eraser center, walks forward and backward until a segment of the stroke crosses either a non-adjacent segment of itself or any segment of any other stroke. Removes everything between those two stops. Useful for cleaning up linework where lines cross. Caveats:
    - "Crossing" is a strict transversal — exactly-collinear or exactly-touching segments don't count. In practice sample quantization makes that vanishingly rare.
    - "Self-intersection" only counts non-adjacent segments; two consecutive segments sharing a sample never trigger a stop.
    - When no crossing is found in a direction, the eraser walks all the way to the stroke's tip on that side (the stroke is trimmed).
  - The whole eraser drag is **one undo step** — Cmd+Z restores everything you erased in that drag.
  - The mode persists across launches.

Brush settings (live-edited in the right pane's Brush Settings section):

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
- **Eraser end of the stylus** temporarily switches the active brush to **Eraser** while the eraser tip is in proximity. The brush picker, brush inspector, and a `● Eraser (stylus tip)` indicator in the status bar all reflect the swap. Lifting the eraser end restores the previous brush (unless you manually picked a different one mid-swap, in which case your choice is honored).

## Selections

Pick **Rectangle**, **Ellipse**, or **Lasso** in the **Tools** section of the left pane. Drag on the canvas to select.

- **Selection arithmetic** via modifier keys at drag start: Shift = add, Option = subtract, Shift+Option = intersect, no modifier = replace.
- **Live preview**: the marching-ants overlay updates as you drag.
- **Marching ants** animate on committed selections (active or live preview).
- **Constraint application**: every pixel-writing operation (brush stamp on a layer, brush stamp on a mask, eraser) multiplies by the selection mask at the canvas pixel.
- Menu items: **Edit → Select All** (Cmd+A), **Deselect** (Cmd+D), **Invert Selection** (Cmd+Shift+I). The Tools section in the left pane also has a **Deselect** action button (xmark icon).
- Selections persist with the document across save and reload.
- **Selection edits are on the undo stack**: rectangle / ellipse / lasso commits, Select All, Deselect, and Invert Selection can each be undone with Cmd+Z.

**Deferred:** polygonal lasso, magic wand, color range tools; Quick Mask mode (paint the selection with a brush); floating-selection transforms (move / scale / rotate); per-selection feather slider.

## Color

- 12 built-in swatches in the brush inspector — click to set the active brush's color.
- **Hex input** (`#RRGGBB` or `#RGB`) next to the color well; bad input restores the previous valid hex.
- **Color well** opens the system color picker (HSB / RGB / wheel / palettes).
- **Cmd-click on canvas** while a brush is active samples the active layer's pixel and applies it to the brush.

**Deferred:** persistent user-saved swatches with "Add Current Color"; custom in-app color picker UI (the system picker is the current path); Display P3 working color space (sRGB throughout today, despite ARCHITECTURE.md decision 6's commitment to P3).

## View and navigation

- **Pan**: two-finger trackpad scroll, **Space + drag**, or the persistent **Hand** tool (Tools section in the left pane).
- **Zoom**: pinch on trackpad (cursor-anchored), **mouse wheel** (cursor-anchored, each notch ≈ 10%), Cmd + trackpad-scroll (cursor-anchored), Cmd + plus / minus.
- **View → Fit Window** (Cmd+0), **View → Actual Size** (Cmd+1).
- **Rotate**: two-finger trackpad rotate gesture (cursor-anchored), **R + drag** (anchored at view center), **Shift** during R+drag snaps to 15°, **Shift+R** resets rotation.
- **Mid-stroke navigation**: zoom / pan / rotate during a brush stroke without ending it.
- **Tab** toggles the left pane (Tools) and the right pane (Brush Inspector + Layers).
- Zoom range: ~5% to 6400%.
- **Sampling**: the compositor uses linear filtering when zooming out (smooth downscale, no shimmer) and nearest-neighbour when zooming in (crisp pixels, no edge blur). The transition is automatic around 100%.
- **View → Show Vector Path Overlay**: debug overlay that draws each visible vector layer's raw stylus samples as orange node markers connected by cyan polyline segments, on top of the normal composite. Useful for inspecting stroke geometry and seeing how the densifier interpolates between samples. State persists across launches.

## Window

- **Window → Fit to Screen** (`⌃⌘F`) — forcibly resizes and repositions the current window to fit inside the visible area of whichever screen contains it (above the dock, below the menu bar). Use this if the window opens off-screen or extends past the dock.
- **Window → Move to Next Display** (`⌃⌘N`) — cycles the window to the next attached monitor, preserving size (clamped to fit). Beeps if there's only one display.
- **Window → Minimize** / **Zoom** — standard.

## Status bar

At the bottom of the canvas:

- **Zoom**: current zoom percentage. View rotation in degrees appears alongside when non-zero.
- **Cursor position**: canvas-pixel X/Y under the cursor (`—` when off-canvas).
- **Stylus tool indicator** (orange, only visible when active): `● Eraser (stylus tip)` while the stylus's eraser end is in tablet proximity.
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
