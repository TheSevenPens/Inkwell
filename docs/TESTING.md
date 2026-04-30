# Testing

Quality strategy and the test matrix. Honest framing up front: **today there is no automated test suite in the repo.** No `Tests/` target, no CI. This doc records the strategy we'll grow into and the manual-test scenarios contributors run before merge.

## Why no tests yet

- Phases 0–11 prioritized shipping the engine and the user-visible feature surface. Tests for a Metal-heavy paint app require either render-regression infra (golden images) or careful seam isolation between the engine and the UI; both are real engineering investments.
- The engine *is* designed to be testable: most of the math (tile coords, view transform, Catmull-Rom densification, vector eraser ops, color HSV math) is in pure Swift functions or value types and can be unit-tested without spinning up an `MTKView` or `MTLDevice`.
- Promoting tests is a Phase 12 hardening task. This doc is the spec for that work; it's also the contract for contributors today (manual scenarios are mandatory).

## The test pyramid we're aiming at

```
   ┌─ End-to-end manual scenarios (today: required pre-merge)
   │   - Open / save round-trip, draw / undo / redo, export to PNG/JPEG/PSD,
   │     stylus-eraser swap, vector eraser modes, move-layer, etc.
   │
   ┌──── Render regression / golden image tests (planned)
   │      - Per-brush stroke fixture → PNG → diff against committed golden.
   │      - Per-blend-mode composite fixture.
   │      - Vector ribbon SDF fixture.
   │
   ┌────── Integration tests (planned)
   │        - Document save → reopen identity (in-memory).
   │        - PSD round-trip fidelity.
   │        - Undo / redo through structural ops.
   │
   ┌──────── Unit tests (planned, lowest cost)
              - Pure-math: ViewTransform, Catmull-Rom densification,
                segment-vs-disc hit-test, HSV ↔ RGB, Selection arithmetic,
                file-format encoders, vector eraser ops.
```

The **unit-test layer is the highest-leverage place to start** — most of those functions take values in and return values out, no mocking required.

## What to test (when adding a feature)

| Surface | Strategy |
|---|---|
| Pure math (no `MTLDevice`) | Unit tests in a planned `Tests/InkwellTests/` target. Free, fast, deterministic. |
| Tile-coord math, dirty-region tracking | Unit tests over `BitmapLayer` / `LayerMask` / `VectorLayer`. Constructing a layer requires a Metal device, but the math (`tilesIntersecting`, `canvasRect(for:)`) doesn't actually touch the GPU and runs under headless test bundles. |
| Brush rasterization | Render regression: render a fixed stroke into a fixed canvas at a fixed seed, dump tile bytes, diff against a committed golden PNG. **Seed any jitter** — `Brush.sizeJitter` and `opacityJitter` use `CGFloat.random` today; pipe a deterministic source for tests (planned). |
| Blend modes | Render fixture per mode; diff. Mode-by-mode known thresholds documented in [`PSD_FIDELITY.md`](PSD_FIDELITY.md). |
| Vector ribbon | Render fixture per ribbon shape. The Catmull-Rom densification is shared between in-flight builder and committed renderer; assert the dense polylines from each path match. |
| Selection ops | Unit tests on `Selection` arithmetic + raster mask byte arrays. |
| Undo | Integration: build a sequence of ops, undo back, assert tile bytes / strokes array / selection bytes match the original. |
| File format | Integration: write a manifest + tiles to a temp directory, read back, assert structural identity. |
| PSD round-trip | Integration: write our document via `PSDFormat.encodeFlat`, read it back via `Canvas.loadPNG` (which uses CGImageSource), compare flattened images within tolerance. |

## Manual scenarios — required before merging

Since CI doesn't gate this yet, contributors run these locally on every PR. The list is not exhaustive — pick the ones that exercise the area you touched, plus the universal smoke run.

### Universal smoke run (every PR)

1. **Cold launch.** App opens with a default Untitled document.
2. **File → New** prompts for size, creates a new document at the chosen size.
3. **Draw a stroke** with G-Pen, Marker, Airbrush, Eraser. Each looks distinct and reasonable.
4. **Undo / Redo** the stroke. State round-trips.
5. **Save** to `.inkwell` → close → reopen. Document state survives.
6. **Export to PNG, JPEG, PSD.** Re-open exports in Preview.
7. **Quit cleanly.** No crash, no hang.

### Stroke / brush changes

- Draw at high speed; verify no visible polygon-corners (Catmull-Rom densification).
- Draw with stylus (if available); verify pressure modulation and tilt.
- Flip the stylus to its eraser end; verify status bar shows `● Eraser (stylus tip)` and the brush picker switches to Eraser. Lift; verify the previous brush is restored.
- Draw a long continuous stroke (> 1 sec at high pressure); verify no stall (the stamp-batching fix).

### Vector layer changes

- Add a vector layer; draw G-Pen strokes; undo / redo / clear; verify exact pixel reproduction (live preview vs. committed render).
- Switch to Eraser; for each of the three Vector Eraser Modes (Whole Stroke, Touched Region, To Intersection), verify the documented behavior.
- Move Layer tool on a vector layer; baked offset places strokes correctly.
- Open a saved file with vector strokes; tile cache rebuilds correctly.

### Selection changes

- Rectangle / ellipse / lasso → modifier-based add/subtract/intersect.
- Quick selection ops: Select All, Deselect, Invert. All on the undo stack.
- Marching ants animate; selections persist on save / reopen.
- Brush stamp inside a selection clips to the selection.

### Layer / document structural changes

- Add bitmap, vector, background, group layers via the **+** pull-down.
- Drag-reorder layers (within and into groups).
- Per-layer visibility, opacity, blend mode, mask add/remove.
- Background layer color picker round-trips through save.

### View / window

- Pinch zoom (cursor-anchored), Cmd-scroll zoom, mouse-wheel zoom.
- Trackpad rotate; R-drag rotate.
- Window → Fit to Screen; Window → Move to Next Display.
- Tab toggles panels.
- Resize the left pane; tools section reflows columns.

### File format / interop

- Save → close → reopen → expect identity.
- Open a PSD; expect a flattened bitmap layer.
- Open a PNG with embedded sRGB profile; expect correct color.
- Export to PSD; reopen the exported PSD in Photoshop / Preview; expect the documented fidelity.

## Render regression: what we plan to add

Render regression for a paint app is fragile: a one-pixel color drift or an alpha-channel rounding difference can fail every test. Conventions to set when we wire this up:

- **Goldens are PNGs in `Tests/Goldens/`** with stable names tied to the test fixture.
- **Diff tolerance is per-test**, expressed as max-channel-difference in 0..255 + max-affected-pixel-count. Most tests should accept ≤ 1 channel diff over ≤ 10 px (rounding); blend-mode tests allow more.
- **Goldens are committed to the repo** (small images, ~20 KB each). LFS is overkill at expected sizes.
- **A `test-update-goldens` task** writes new goldens after a deliberate change. PRs touching renderer code will routinely include golden updates; reviewers should look at diffs.
- **Runs locally and in CI**; CI failure means the PR can't merge until golden differences are explicitly updated or the regression is fixed.

## Input device coverage

Manual; the test matrix is small but real:

- **Trackpad** (any modern Mac).
- **Magic Mouse** (limited — no scroll wheel notches; treats scrolling as continuous).
- **Wired mouse** with scroll wheel notches.
- **Wacom tablet** (Bamboo, Intuos, or Cintiq) for stylus + eraser end + pressure + tilt.
- **Apple Pencil via Sidecar** if available.

Tablet manufacturers ship driver updates that change `tabletProximity` semantics occasionally — if tablets misbehave, the right fix is usually a driver update on the user's side, per architecture decision 10.

## File-format compatibility tests

Required when changing anything in [`FileFormat.swift`](../Sources/Inkwell/FileFormat.swift), [`Canvas.swift`](../Sources/Inkwell/Canvas.swift) (serialization paths), or any layer's `Codable` shape.

Manual procedure:

1. Before the change: save a representative document on `main`. Stash it as `tests/fixtures/<name>.inkwell`.
2. Apply your change, rebuild.
3. Open the stashed file. It must open and produce visually identical output.
4. Save it from the new build. Open it again. Still identical.

If your change makes old files unreadable:
- Bump `FileFormat.currentVersion`.
- Add a migrator in `FormatMigrator`.
- Document the migration in [`SCHEMA_REFERENCE.md`](SCHEMA_REFERENCE.md).
- Add the old fixture to a planned `Tests/Migrations/` corpus.

## What's not tested today (and isn't immediately worth testing)

- **Window position autosave** (system-managed via `NSWindow`).
- **Color picker accuracy** (we trust `NSColorPanel`).
- **macOS scrollbar behavior**.
- **Cursor lookup** (bitmap rendering of SF Symbols into `NSCursor`).
- **System color management at the drawable** (Metal + ColorSync handle this).

Manual smoke test catches breakage in these; automated tests would mostly verify Apple's frameworks.

## Until CI exists

Each PR runs the smoke scenarios + the area-specific scenarios above. Reviewer should ask "what did you actually exercise?" and the PR description should answer.

When CI lands, this doc becomes a living spec for what CI gates on.
