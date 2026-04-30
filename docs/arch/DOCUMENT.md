# Document model

What an Inkwell document *is*: the in-memory layer tree, what each layer kind stores, and how it all serializes to disk and round-trips through interop formats.

This file is part of the Inkwell architecture corpus. Decision numbers are global across the corpus; the index lives in [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

---

## 5. Stroke model: rasterize-and-discard for bitmap layers, with engine commitments to keep future layer types open

### Decision

For **bitmap layers**, Inkwell rasterizes each stroke into the tile grid as it is drawn and **discards the input samples once the stroke commits**. There is no per-stroke sample log on bitmap layers. Live smoothing, resampling, and pressure-curve evaluation operate on an in-flight sample buffer that is released at stroke end.

To ensure that future layer types (in particular vector layers, but also potential text and adjustment layers) can be added later without an engine rewrite, the following **four architectural commitments** are made now and apply to every system that touches layers:

1. **`Layer` is a sum type or protocol from day one.** No code may assume a layer is a `BitmapLayer`. New layer kinds slot in by conforming to the layer abstraction.
2. **The stroke processing pipeline is layer-aware.** The processor produces a stream of samples and computed stamps; the *layer* decides how to consume that stream. Bitmap layers rasterize into tiles and forget. A future vector layer would store the samples (or a fitted representation) and re-rasterize on demand. The processor itself does not bake "rasterize and discard" into its contract.
3. **The save format is extensible per-layer.** Every layer record in the native file format carries a type tag and a version. Older builds skip layer types they do not understand cleanly; newer builds add layer types as a pure addition without breaking the format.
4. **The compositor accepts heterogeneous layers.** Each frame, the compositor asks each layer for tile-shaped pixel data at the current view. Bitmap layers serve their tiles directly. Future vector layers rasterize to a transient tile at the current view scale on demand.

Timelapse, when it ships, will be built on the **undo delta stream** described in the next section's preview — not on stored stroke samples. The implications for the stroke model are explicit: we do not need to retain samples to support timelapse.

### Context

Pressure-sensitive painting produces stylus samples at 120 Hz or more. The engine has to decide what becomes of those samples after the stamp rasterizer has consumed them. Two future features named in the overview — vector layers and timelapse recording — could in principle motivate retaining samples beyond the active stroke. We considered each and concluded that neither requires it.

Vector layers are best served by being a *separate layer type* with their own representation, rather than by retroactively interpreting bitmap-layer strokes as vector data. Bitmap layers in every pro tool work exactly as we are choosing here; users do not expect a bitmap stroke to be retroactively re-shapeable. Vector behavior belongs to a vector layer.

Timelapse can be implemented from the per-stroke tile deltas the undo system already records. Playback applies committed deltas forward, paced by stored timestamps. The trade-off is visual: each stroke "snaps" into existence rather than animating along the stylus path. We accept this; it is the same model many shipping apps use for their default timelapse mode.

### Alternatives considered

1. **Rasterize and discard for bitmap layers (the chosen model).** The simplest pipeline and the one that matches user expectations for bitmap painting.

2. **Store every sample, rasterize lazily.** Bitmap layers would themselves be derived from a sample log, and re-rasterization on document scale-up would be lossless. Rejected because the memory and storage cost is real (a long session can produce hundreds of MB of samples), the stroke pipeline becomes considerably more complex, and the user-facing benefit (vector-like behavior on a *bitmap* layer) is not what bitmap layers are for. If users want vector behavior, they should use a vector layer.

3. **Hybrid: rasterize for display, archive samples to a per-document log.** Pays roughly half the cost of #2 in exchange for keeping the door open to features we have decided not to build. Rejected because the features that would benefit (input-replay timelapse, retroactive brush-setting changes) are either replaceable (timelapse via undo deltas) or out of scope for bitmap layers (retroactive editing belongs to vector layers).

### Pros

- **Simplest stroke pipeline.** Samples flow through a small in-memory buffer, get consumed by the stamp rasterizer, and are released. There is no log to design, persist, version, or migrate.
- **Zero residual memory cost per stroke.** After commit, the only artifact of a stroke is the painted pixels in the tile grid. A long session does not accumulate hundreds of MB of sample data.
- **Matches user expectations.** Bitmap layers in every pro paint tool behave this way. Users will not be surprised that a committed stroke cannot be retroactively re-shaped.
- **Keeps the engine small.** The stroke processor's contract is "consume samples, produce stamp placements"; it does not also have to be an archival system.
- **Does not foreclose vector layers.** The four architectural commitments above keep that door fully open. A vector layer is a future addition, not a future rewrite.

### Cons

- **A committed bitmap stroke cannot be retroactively edited.** Changing the brush, size, or pressure curve and re-applying to existing strokes is not possible on bitmap layers. (This matches user expectation.)
- **Bitmap-layer strokes do not re-rasterize losslessly when the document is scaled up.** Pixel content scales like a pixel image. (Vector layers, when they ship, will scale losslessly.)
- **No live-replay timelapse on bitmap layers.** Per-stroke playback off the undo stream is supported; stroke-along-the-path animation is not. If we ever want input-replay timelapse, it would have to be added as a separate feature and would naturally apply only to vector layers.

### Rationale

The deciding insight is that **the future features that seemed to motivate retaining samples are better served by other means**. Vector layers want a different layer type, not a different bitmap-layer model. Timelapse can be built on the undo delta stream that we have to maintain anyway. Once we recognized those, retaining samples on bitmap layers became cost without benefit.

The four architectural commitments are the actual safeguard. They ensure that "we did not retain samples on bitmap layers" never becomes "we cannot add vector layers." Bitmap layers and vector layers are siblings, not the same thing in different modes; the engine just has to admit that from day one.

### Forward link: timelapse and undo

The decision to build timelapse on the undo delta stream is recorded here as a constraint on the *forthcoming* undo decision. When we make that decision, the requirements that flow from this section are:

- Undo deltas are recorded at tile granularity (already implied by the rendering pipeline decision).
- Each delta records a timestamp at commit, sufficient for timelapse pacing.
- The delta stream can be persisted to the document (or a sidecar) for the full lifetime of the document, not capped to a recent-history window.
- Undone-then-overwritten history is handled by standard linear-redo semantics so that timelapse playback shows only the strokes that survived to the final state.

---

## 7. Document model: grouped layer tree, per-layer masks, native `.inkwell` bundle, PSD as export-only

### Decision

An Inkwell document is a tree of layers organized into optional groups, plus document-level metadata, plus the undo/timelapse delta stream. The model is:

- **Layer hierarchy** is a tree, not a flat list. Layers can be contained in **layer groups** ("folders"). Groups have their own opacity and blend mode, applied to the composited result of their contents.
- **Per-layer masks** are single-channel bitmaps attached to a layer that gate its visibility. Painting on the mask non-destructively reveals or hides parts of the underlying layer. Masks are tile-stored, sparse, and follow the same tile rules as the layer they attach to.
- **Document metadata** is: pixel width and height, DPI, color profile (Display P3 by default), creation and modification timestamps, and optional title/author. **DPI is metadata-only in v1** — it is recorded for export and information, but does not influence rendering, brush sizing, or any in-app dimension. Brush sizes are specified in pixels.
- **Native file format** is `.inkwell`, a **macOS document bundle** (a directory that Finder presents as a single file). The bundle contains: the document metadata, a sparse tile-store, the layer tree definition, optional layer masks, embedded color profile, and the undo/timelapse delta stream. The bundle layout includes a **document format version field** from day one so future format changes are non-breaking.
- **PSD is export-only.** Inkwell can write PSDs with the best-fidelity mapping it can produce, but PSD is never used as a primary save format. Users who want a `.psd` get one through Export, not through Save.

### Context

The shape of a document constrains the renderer, the file format, the layer-panel UI, the undo system, the export pipeline, and what kinds of features can be added later without disturbing existing files. Earlier decisions (tile-based rendering, `Layer` as a sum type, bitmap-layers-rasterize-and-discard) defined how a single layer behaves; this decision defines how layers fit together into a document and how documents are persisted.

### Alternatives considered

1. **Flat layer list, no groups.** Simpler compositor (a list, not a tree), simpler layer UI. Rejected because pro users organize complex documents with groups (line art, flats, shadows, references), and retrofitting groups later is invasive — it touches the compositor, the file format, undo, selection, and masking simultaneously. Building groups in from v1 costs less than adding them in v2.

2. **No layer masks; users duplicate layers and erase.** The "destructive" workflow. Rejected because it does not match how serious users work and produces files that are hard to revise. The cost of supporting masks is small (one extra sparse tile grid per masked layer) and the workflow benefit is large.

3. **DPI as an active dimension (brush sizes in mm, etc.).** Some print-oriented apps work this way. Rejected for v1 because it adds UI complexity, requires DPI-aware brush math throughout the engine, and serves a small audience for a tool whose primary domain is screen-resolution painting. We can revisit if users ask.

4. **PSD as the native save format.** Every save would be a PSD; no proprietary format to design. Rejected because PSD cannot represent everything the Inkwell engine needs to persist: our undo/timelapse delta stream, our exact tile layout, our future layer types (vector, etc.), and certain blend-mode and color-management nuances. Every save would be a lossy re-encode.

5. **Single-file format (custom container or SQLite-backed).** More familiar to users who copy a single file between machines. Rejected because a bundle is materially easier to evolve (new chunks land as new files inside the bundle), interacts well with tile streaming and incremental save, and is the standard pro-Mac-app convention (Sketch, Procreate, Affinity). macOS Finder presents bundles as single files anyway, so the user-visible difference is negligible.

6. **Native bundle format with groups, masks, DPI metadata-only, version field, PSD export-only.** Chosen.

### Pros

- **Groups match how pro users actually work.** Organizing twenty-layer illustrations without folders is painful; with folders it is normal. Building this in from v1 lets us design the rest of the engine (compositor, undo, selection) around the tree from the start.
- **Masks enable non-destructive editing.** Users can hide parts of a layer without losing the underlying pixels. This is table-stakes for pro workflow.
- **Native format preserves engine state losslessly.** Tile layout, layer types we may add in the future, the undo/timelapse stream, and color profile all round-trip through `.inkwell` exactly. Reopening a saved file is identity, not lossy reconstruction.
- **Bundle is evolvable.** Adding a new feature that needs persistent state (e.g. brush presets per document, recorded comments, references) is a matter of dropping a new file into the bundle. The format version field gates the change.
- **PSD remains a first-class export target.** Interoperability is preserved without making PSD the bottleneck for the engine.
- **Version field is cheap insurance.** It costs nothing now; it is the difference between a smooth format upgrade and a forced migration when v2 changes the layout.
- **Bundle is friendly to incremental and atomic save.** New tile data writes to a temporary file inside the bundle and is moved into place; partial writes do not corrupt the document.

### Cons

- **Compositor walks a tree, not a list.** Group opacity and blend mode require compositing the group's contents into a transient buffer first, then blending that buffer into the parent. More code than a flat list, and more memory at peak.
- **Layer panel UI is more complex.** Hierarchy, expand/collapse, drag-into-group, drag-out-of-group, group selection vs single-layer selection. All standard but all real work.
- **PSD export is a translation step with edge cases.** Mapping our layer tree, masks, and blend modes to PSD's nominally-similar structures is a non-trivial fidelity exercise. Some features (anything we add that PSD lacks) will export with a documented loss.
- **Bundle format is occasionally surprising to users.** A user who right-clicks a `.inkwell` and chooses "Show Package Contents" will see the internal structure. This is rarely a problem and is the standard macOS convention, but we should not assume zero confusion.
- **Mask painting is its own UI surface.** Mask edit mode, mask preview overlay, "paint on layer vs paint on mask" toggle. Standard pro features, but a non-trivial UX area.
- **Tree-shaped data structures are harder to reason about under concurrency.** When we get to threading, the compositor and undo system will both need clear rules about who is allowed to mutate the tree and when.

### Rationale

The deciding factor is that **everything in this bundle is what pro users expect from a serious Mac creative app, and every alternative defers cost rather than saves it**. Groups, masks, and a native format with versioning are not advanced features we could add later; they are foundational structures that other features (compositor design, undo system, file format, export) depend on. Building them in now is cheaper than retrofitting them.

The choice of a bundle over a single-file container is a question of evolvability versus packaging. Bundles win on evolvability and match macOS conventions; the only real cost is occasional user surprise when they peek inside, which is shared by every other pro Mac app and well-handled by Finder.

PSD as export-only is the standard pro-app posture and is the only one that lets the engine evolve freely. Tying our save format to PSD would mean every internal change has to be expressible in PSD or lost on save — a constant tax for a small interop benefit we already get through export.

DPI as metadata-only is a deliberate scope cut for v1. Active DPI (brush sizes in mm, document dimensions in inches) is a feature for print-first workflows and adds non-trivial complexity throughout the engine. Recording DPI in metadata means we can add active DPI later without breaking existing files.

### Forward implications

- **File format specification will need its own document.** The `.inkwell` bundle layout, chunk types, version negotiation, and atomicity rules deserve their own spec.
- **PSD export must publish a fidelity table.** A documented mapping from Inkwell's layer types, blend modes, and masks to PSD's, including known lossy cases.
- **Layer panel UI is hierarchical.** Drag-and-drop into and out of groups, expand/collapse, selection semantics for groups, and group-aware context menus.
- **Compositor is recursive over groups.** Each group composites its contents into an intermediate buffer at group resolution, then blends that buffer into the parent according to the group's opacity and blend mode.
- **Undo system covers structural operations.** Creating, deleting, reordering, regrouping, and renaming layers and groups; adding and removing masks; toggling visibility. All recorded at the same fidelity as pixel edits.
- **Mask editing is a UI mode.** Selecting a layer's mask routes brush input to the mask tile grid instead of the layer tile grid.

---

## 14. Native file format and export/import pipeline

### Decision

Inkwell uses a **macOS document bundle** named `.inkwell` (a directory presented as a single file by Finder) for its native save format, and supports **PSD as export-only** plus PNG and JPG for export and flattened import. The detailed byte-level layout of the bundle is intentionally deferred to a separate document — **`FILEFORMAT.md`** — to be authored when implementation starts. This decision sets the high-level shape; `FILEFORMAT.md` will be the authoritative reference for chunk types, headers, byte orders, and version negotiation.

#### Bundle contents

A `.inkwell` bundle contains the following at its top level:

- **`manifest.json`** — document metadata, format version, layer tree definition, references to tile/history/asset locations, embedded color profile reference. Human-readable for diagnosability; small enough to load eagerly.
- **`tiles.bin`** — a single packed store containing all layer and mask tile pixel data, with a header index mapping `(layer_id, mask?, tile_x, tile_y)` to byte ranges. Append-only writes for new and edited tiles; periodic compaction reclaims space from overwritten tiles.
- **`history.bin`** — append-only stream of undo/timelapse deltas (per decision 9), with a length-prefixed record format so partial appends after a crash are detectable and recoverable.
- **`assets/`** — embedded brush tip textures, custom brushes saved to the document, and any embedded ICC profiles. Each file in this directory is a normal PNG / JSON / ICC asset, identified by a stable name.
- **`thumbnail.png`** — a small flattened preview at a known size, for Finder QuickLook and the macOS recent-documents UI. Refreshed at save time.

#### Save and load semantics

- **Atomicity at the bundle level.** Saves write to a sibling temporary directory, `fsync` the contents, then atomically rename into place. A crash mid-save leaves either the previous good bundle or the temporary directory; never a half-written final bundle.
- **Atomicity within the bundle.** `history.bin` and `tiles.bin` are append-only; their length-prefixed records let us truncate the trailing partial record after a crash. The manifest is rewritten in full each save and is small enough that this is cheap.
- **Versioning.** The manifest carries a `format_version` integer. The reader checks compatibility on open: a newer-than-supported version is refused with a clear error; an older version triggers an in-memory migration step, after which the next save produces the current format. Migration code is preserved in the codebase indefinitely; we do not remove old-format readers.
- **Packed tile store over many-small-files.** Filesystems, Time Machine, and iCloud Drive all behave better with a few large files than with thousands of small ones. The packed store costs us slightly more careful index management in exchange for materially better behavior under sync and backup.

#### PSD export — fidelity policy

- **Layer types:** bitmap layers and groups round-trip cleanly. Future vector layers (when they ship) export as rasterized bitmap layers.
- **Blend modes:** a published mapping table (lives in `FILEFORMAT.md` or its own short doc). Modes PSD does not have map to the closest available equivalent, with a documented loss.
- **Masks:** Inkwell layer masks map directly to PSD layer masks.
- **Selections:** the active selection (raster + optional vector) maps to a PSD saved selection (alpha channel).
- **Color profile:** the document's embedded profile is written into the PSD, defaulting to Display P3.
- **Bit depth:** the user chooses 8-bit, 16-bit, or 32-bit float on export; default 16-bit (matching our internal precision per decision 6). 8-bit incurs a quantization step; 32-bit float is lossless and large.
- **A user-facing fidelity table** documents what is preserved exactly, what is approximated, and what is lost. Lives outside ARCHITECTURE.md; referenced from the user manual.

#### PNG and JPG export

- **Always flattened** to a single composited image at the document's pixel dimensions.
- **Profile-tagged** with the document's working profile (Display P3) or sRGB at user choice.
- **Gamut mapping for sRGB output**, applied when the document contains colors outside the sRGB gamut. Default mapping policy: perceptual; relative-colorimetric available as an option for users who prefer it.
- **Transparency preserved for PNG.** JPG flattens against a user-configurable background color, defaulting to white.

#### Import behavior

- **PNG / JPG.** Drag-drop, File → Open, or paste creates a new document with the imported image as a single bitmap layer. Embedded color profile is read and converted into the working space (Display P3); images with no profile are assumed sRGB.
- **PSD.** File → Open imports the layer tree with best-effort fidelity, mapping blend modes through the same table used for export, reading layer masks, and converting embedded color profile to working space. Unsupported PSD features (text layers, smart objects, adjustment layers) import as rasterized bitmap layers with a flag noting the conversion. The import path is documented in the same fidelity table.

### Context

Earlier decisions named the native format (`.inkwell` bundle in decision 7), constrained tile storage to be sparse (decision 4), required full-lifetime undo persistence (decision 9), and committed Display P3 working space (decision 6). What was open was the bundle's internal organization, the tile-storage strategy (many small files vs packed store), the export fidelity policy across formats, and the import behavior. This decision settles those at the architectural level and defers implementation-grade detail (chunk byte layouts, magic numbers, header CRCs, exact compaction policy) to `FILEFORMAT.md`.

### Alternatives considered

1. **Many-small-files tile storage** (one file per tile under `tiles/<layer>/<x>_<y>.tile`). Trivially atomic per-tile, simplest possible append/replace model. Rejected because filesystems, Time Machine, and iCloud Drive handle thousands of small files poorly. A documented packed store is a better long-term choice for sync, backup, and Finder responsiveness.

2. **SQLite or another embedded database for the bundle.** Mature transactional semantics for free. Rejected because an opaque database file is hard to inspect or recover from corruption, and we do not need transactional semantics across the whole bundle — append-only streams plus a small re-written manifest is sufficient.

3. **PSD as the native save format.** Already rejected in decision 7; reaffirmed here. PSD cannot represent our undo/timelapse stream, our exact tile layout, our future layer types, or every blend mode we want.

4. **Single-file format with a custom container** (instead of a directory bundle). Friendlier to users who copy a single file between machines without bundle awareness. Rejected because Finder presents bundles as single files anyway, every other pro Mac creative app uses bundles, and bundles are dramatically easier to evolve.

5. **No format version field; rely on schema autodetection.** Tempting for "we will figure it out later." Rejected: the cost of including the field is one integer; the cost of not having it is forever painful when v2 changes layout.

6. **Bundle with a packed tile store, append-only history, JSON manifest, versioned, with PSD/PNG/JPG export and PSD/PNG/JPG import as described.** Chosen.

### Pros

- **One internal organization for everything.** Tiles, history, masks, assets, and metadata all live under one bundle root with predictable names. New chunks (future features) drop in without disturbing existing ones.
- **Sync- and backup-friendly.** A few large files behave well under iCloud Drive, Time Machine, Dropbox, and Git LFS. Many small files do not.
- **Atomic save by construction.** Temp-directory + atomic rename means there is no window in which the bundle is half-written. Recovery from a crashed save is automatic on next launch.
- **Versioning is cheap insurance.** A single integer in the manifest, plus a migration discipline, lets the format evolve without breaking existing files.
- **Human-readable manifest.** A user with a corrupted bundle can open the manifest in a text editor and at least see what the document was. Diagnostic-friendly.
- **PSD export is comprehensive but bounded.** A documented fidelity table tells users exactly what does and does not survive the round trip; no surprises.
- **Import paths normalize everything to working space.** Imported content arrives in Display P3 with predictable color behavior, regardless of source format.
- **`FILEFORMAT.md` deferred is honest.** The detailed byte layout will be authored when implementation starts and the trade-offs are concrete; locking in those details now would be guessing.

### Cons

- **Packed store needs careful index management.** Append-only with periodic compaction is a real mechanism with edge cases (compaction during save, recovery from a crash mid-compact). Manageable but non-trivial.
- **Migration discipline is forever.** Every format change, however small, has to come with a tested migration path. Old-format readers must remain in the codebase.
- **PSD fidelity table is a real maintenance surface.** Every change to our blend modes, layer types, or color handling has to update the table. An inaccurate table is worse than no table.
- **Bundle structure occasionally surprises users.** A user who right-clicks → "Show Package Contents" sees the internals. This is the standard macOS convention and users will not lose data, but it is a small confusion vector.
- **Gamut mapping for sRGB export has subjective choices.** Perceptual versus relative-colorimetric produces visibly different results for some images. We default and offer an option, but the choice is not invisible.
- **PSD round-trip is not perfect.** Documents that exercise features PSD does not represent (or that PSD represents differently) lose information. Disclosed in the fidelity table; still a real cost.
- **`FILEFORMAT.md` does not yet exist.** Implementers will need to author it before writing the codec; this is an explicit forward task.

### Rationale

The deciding factors are evolvability, sync-friendliness, and atomicity. A bundle with a packed tile store and an append-only history stream gives us all three: new features add new chunks, the filesystem is happy with a small number of large files, and atomic rename plus length-prefixed records make crash recovery a non-event. The architecture decision documents the shape; the byte-level details belong in their own spec because they will need to be precise and exhaustive in a way that does not belong in a design document.

PSD as export-only (rather than a primary format) was settled in decision 7 and the fidelity policy here flows from it: we treat PSD as a respectful interop target with documented losses, not as a contract we have to fulfill on every save. Users who need full fidelity save `.inkwell`; users who need to hand off to Photoshop export PSD with eyes open about what travels.

Deferring `FILEFORMAT.md` is the right call. Decisions about CRC choice, chunk magic numbers, byte order conventions, and exact compaction triggers are implementation work that benefits from being authored against actual code, not against speculation. We commit here to writing it; we do not pretend to write it now.

### Forward implications

- **`FILEFORMAT.md` is a required deliverable** before format-touching code is written. It will document: every chunk type, byte layout, byte order, header CRCs, format version negotiation, append/compact rules, error handling, and the exact PSD fidelity table.
- **A migration framework lives in the codebase from v1.** Even if v1 has no migrations, the structure for "read manifest version, dispatch to migrator if older, save in current format on next save" is set up early so v2 does not have to retrofit it.
- **The packed tile store has its own lifecycle.** Compaction strategy, when triggered, how it interacts with active strokes, and how it survives crashes are subjects for `FILEFORMAT.md` and for the implementation phase.
- **A PSD codec is a non-trivial dependency.** Whether we write our own (educational, full control), use an existing library (faster start, possible C++ bridge per decision 2's "PSD codec" hot-path note), or fund a contractor is an open question for the implementation phase.
- **PNG and JPG codecs come from system frameworks** (`ImageIO`). No third-party codec needed.
- **Color management on import and export uses ColorSync / Core Graphics** for ICC profile handling. The gamut mapping policy choice (perceptual vs relative-colorimetric on sRGB export) is exposed in the export sheet UI.
- **The thumbnail is generated on save.** A small composited preview rendered into a known-size PNG lives at the bundle root for Finder.
- **A recovery path for partial saves is required at startup.** If the app finds a `.inkwell.tmp` next to a `.inkwell` on launch (suggesting a crashed save), the user is offered the older bundle and the temp is cleaned up after diagnostic logging.
