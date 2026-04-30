# Concurrency

How Inkwell distributes work across threads, and how the document evolves over time. Threading and undo are bundled because both are about controlling *when* state mutates and who can read it safely.

This file is part of the Inkwell architecture corpus. Decision numbers are global across the corpus; the index lives in [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

---

## 8. Threading model: main + stroke + GPU + autosave, with snapshot reads

### Decision

Inkwell uses a **four-actor threading model** with clear ownership boundaries:

- **Main thread.** Receives `NSEvent` input (including stylus samples), runs all AppKit UI, dispatches compositor frames, and presents to the screen. Latency-critical for input reception. Never blocks on disk I/O, never waits on the stroke thread.
- **Stroke thread (single serial `DispatchQueue`).** Owns mutation of the tile cache and the document tree. Performs smoothing, pressure-curve evaluation, stamp placement, stamp rasterization into tile textures, and undo delta capture at stroke commit. Single serial queue, not an actor — predictable latency without `await`-induced reentrancy.
- **GPU.** Executes all compositing, blend-mode math, and shader work. Dispatched from the main thread but performs its work asynchronously. The GPU reads tile textures directly; on Apple Silicon's unified memory there is no upload step.
- **Autosave queue (background).** Periodically writes the `.inkwell` bundle to disk. Reads document state through a copy-on-write snapshot rather than holding a lock against the stroke thread. Atomic-rename pattern at the bundle-file level.

**Cross-thread access rules:**

- The document tree, layer list, and tile cache are **mutated only from the stroke thread**.
- The main thread and the autosave queue read the document model through **immutable snapshots** taken at well-defined points (frame boundary for the compositor, save trigger for autosave). Snapshots use copy-on-write semantics: cheap to create, cheap to hold, freed when the reader is done.
- The compositor reads **GPU-resident tile textures directly** rather than via snapshot. Tile textures are mostly-immutable between stamp commits; synchronization happens at tile-flush boundaries (a small set of `MTLEvent` or `MTLFence` signals from the stroke thread to the GPU encoder), not per-pixel.
- The stroke thread does not call back into the main thread synchronously. State the UI needs (current tool, current brush, modifier state) is read from atomically-updated value types or `OSAllocatedUnfairLock`-protected state.

**Concurrency primitives.** Actors are used for high-level coordination (e.g. document lifecycle, autosave scheduling) where `async/await` ergonomics help. Latency-critical inner loops (the stroke thread's per-sample work, the compositor's per-frame setup) use serial `DispatchQueue` and `OSAllocatedUnfairLock`-protected state — actor reentrancy across `await` points is undesirable in those paths.

### Context

By this point in the architecture, several earlier decisions have set hard constraints on the threading model:

- **Tile-based, GPU-resident rendering** (decision 4) means the GPU is the natural composition target and the CPU is mostly orchestrating.
- **Bitmap-layer rasterize-and-discard** (decision 5) means the stroke pipeline is short and fits comfortably on a single thread without pipelining.
- **Native bundle save format** (decision 7) means autosave writes potentially many small files atomically; this is real I/O work that must not block input.
- **Pure Swift for the engine** (decision 2) means we have access to Swift's concurrency primitives (actors, `async/await`) and dispatch queues, but we should pick deliberately rather than reflexively reach for actors.

The threading model has to satisfy all of these and stay simple enough that the next contributor can reason about a concurrency bug without consulting an architecture diagram.

### Alternatives considered

1. **Single thread for everything except autosave.** Input, stroke processing, rasterization, compositor dispatch, and undo capture all on the main thread; autosave on a background queue. Simplest possible model. Rejected because any main-thread stall (a slow stamp, a UI repaint, a system call) causes the input pipeline to drop or delay samples — directly visible to the user as cursor lag or jagged strokes.

2. **Main thread for UI/input, dedicated stroke thread for processing/raster, GPU for compositing, autosave on background.** Chosen. Decouples the latency-critical paths (input arrival on main, stamp work on stroke) and keeps the UI responsive even when stroke work is heavy.

3. **Multi-stage pipeline with parallel work between stages.** A pipeline of queues where smoothing, stamp placement, and rasterization run in parallel. Rejected because the stages are tightly coupled (each stamp depends on the previous one's tile state), pipeline hops add latency and variance, and we are not throughput-bound — a single serial stroke thread keeps up with 120 Hz input comfortably on Apple Silicon. The complexity is not justified by a measured need.

4. **Actors throughout, including for the inner stroke loop.** Modern, idiomatic Swift. Rejected for the inner loop because actor reentrancy across `await` points makes latency hard to bound, and because we do not need actor isolation for code that is already serialized on a single queue. Actors are still used at the high-level coordination layer where their ergonomics help.

### Pros

- **Predictable input latency.** The main thread is responsible for receiving stylus events and almost nothing else that competes for time on the latency-critical path. Stroke processing is offloaded the moment a sample arrives.
- **UI remains responsive under load.** Even when the stroke thread is busy with heavy stamp work, the main thread keeps redrawing menus, panels, and inspectors at 60 Hz.
- **Autosave is invisible to the user.** Writing a multi-megabyte bundle to disk does not stall input or compositing because it operates on a snapshot from its own thread.
- **One owner of mutable state.** The document tree, layer list, and tile cache have a single writer (the stroke thread). Most concurrency bugs in pro paint engines come from multiple writers competing; we eliminate that class of bug by construction.
- **Snapshots are cheap.** Copy-on-write of the document tree means a snapshot is essentially a reference bump; readers can hold them without blocking the writer.
- **Compositor reads tile textures directly.** Avoids snapshotting GPU-resident data and avoids the tax of per-frame copies. Synchronization is at coarse boundaries (tile-flush events) not per-pixel.
- **Clean actor / queue split.** High-level coordination uses actors and `async/await` where they help; latency-critical inner loops use serial dispatch and unfair locks where reentrancy would hurt.

### Cons

- **Snapshots add a small per-frame cost.** Building a copy-on-write snapshot of the document tree at frame boundary is cheap but not free. The compositor pays this cost every frame even when the document hasn't changed.
- **Cross-thread state for UI (current tool, brush, modifier state) needs an explicit channel.** We can't just call back into the main thread; we maintain a small set of atomically-updated values that both threads can read.
- **Debugging multi-thread bugs is harder than single-thread.** Even with one writer, race conditions in the snapshot mechanism or the tile-flush events are subtler than equivalent bugs in single-threaded code.
- **The model is more to learn for new contributors.** A flat single-thread model would be easier to onboard. The trade-off is paid up front in documentation and review attention rather than at runtime in dropped samples.
- **Mixing actors and dispatch queues invites confusion.** Future contributors will need to understand which primitive belongs where and why. We mitigate by keeping the rule simple ("inner loops use queues, coordination uses actors") and by writing it down here.

### Rationale

The model is shaped by where latency matters and where it does not. Input arrival and UI responsiveness must be sub-frame on the main thread; stamp work must be fast but does not have to be on the main thread; compositing is GPU work no matter what; autosave is slow I/O that must not be felt. Once those four are sorted, the partition follows.

We chose not to actor-ify the inner stroke loop because actors solve a problem we don't have (mutable state shared across many callers) and introduce a problem we don't want (reentrancy at `await` points in a latency-sensitive path). A single serial dispatch queue gives the same exclusive-access guarantee with predictable cost.

We chose snapshot-based reads over reader-writer locks because snapshots scale better to multiple readers (compositor, autosave, panels), simplify the writer's contract (the stroke thread never blocks waiting for readers), and play well with the copy-on-write document tree we already need for undo. The cost — a small per-frame snapshot build — is well below the budget and well-bounded.

### Forward implications

- **Tile flush boundaries need explicit GPU events.** When the stroke thread finishes writing a stamp into a tile, the next compositor frame that reads that tile must see the result. We use `MTLEvent` or `MTLFence` to express this dependency without a CPU-side wait.
- **The document tree and layer list use copy-on-write internally.** This is implied by the snapshot model and should be a foundational property of the data structures.
- **Undo capture happens on the stroke thread.** Per-tile deltas are recorded as part of the stroke commit step, before the snapshot used by the next compositor frame is published.
- **Autosave triggers from a timer or from a debounced "document dirty" signal.** It does not interrupt stroke work; it observes the document via snapshots between strokes.
- **UI-driven document edits (e.g. layer reorder, layer rename, blend mode change) are dispatched onto the stroke thread.** The UI sends a command; the stroke thread applies it under the same single-writer rule that pixel edits follow.

---

## 9. Undo/redo: per-stroke deltas, gesture-coalesced, RAM-windowed with full history persisted

### Decision

Undo and redo in Inkwell are built on a single ordered stream of **operation deltas** captured at user-gesture granularity. The same stream serves undo, redo, and (eventually) timelapse playback.

- **Step granularity.** One step per completed user gesture. Pixel edits: one step per committed stroke. Structural edits: one step per layer create/delete/reorder/rename/regroup, mask add/remove, visibility toggle, blend-mode change, opacity change. Continuous gestures (a slider drag changing opacity, a multi-step transform) are **coalesced** into a single step bounded by the gesture's start and end events.
- **Pixel delta format.** For each step that modifies pixels, the delta records the set of dirty tile IDs and the **before-pixels** of each dirty tile (after-pixels are the layer's current state). Tile deltas are **compressed** at capture time with zstd at a low compression level; the CPU cost is small and the storage savings are substantial on typical content.
- **Structural delta format.** A typed record describing the operation in enough detail to reverse it — e.g. "delete group at path /Layers/Folder1, group definition follows" or "set layer 17 blend mode from Normal to Multiply." Lives in the same ordered stream as pixel deltas, distinguished by record type.
- **Capture point.** All deltas are captured on the **stroke thread** at gesture commit, before the snapshot used by the next compositor frame is published. Single-writer rule from decision 8 is preserved.
- **In-memory window.** A configurable **soft cap** on recent history kept in RAM: "up to N steps OR M megabytes of compressed deltas, whichever is smaller." Default targets: 200 steps and 256 MB (subject to tuning). This is a working-set cap, not an availability cap.
- **Disk-backed full history.** Older history pages out to a `history` chunk inside the `.inkwell` bundle. The full step index lives in RAM at all times (so any step can be located quickly); only the delta payloads page out. When the user undoes far enough back that we cross the RAM window, we read deltas from disk on demand.
- **Linear redo semantics.** When the user undoes some steps and then performs a new edit, the redo stack is dropped. The history reflects the document's actual final state; this is what timelapse playback requires.
- **Failure mode: fail soft.** If a history entry cannot be read or decompressed (corrupted bundle, partial save), we log the failure, drop the unreachable history, leave the document state as-is, and surface a quiet notification. We never attempt destructive recovery that could corrupt the live document.

### Context

Almost every aspect of undo in Inkwell is already constrained by earlier decisions:

- Tile-based rendering (decision 4) makes per-tile deltas the natural unit and rules out whole-layer snapshots as the primary mechanism.
- Bitmap-layer rasterize-and-discard (decision 5) ties timelapse to the undo delta stream, requiring full document-lifetime history rather than a recent window.
- The document model with groups and masks (decision 7) requires the undo system to cover structural operations at the same fidelity as pixel edits.
- The threading model (decision 8) requires capture on the stroke thread, with snapshot-based reads from elsewhere.

What remained open were the storage format details, the in-memory cap, the coalescing rule, and the failure semantics — all settled in this decision.

### Alternatives considered

1. **Whole-layer snapshots per step.** Snapshot an entire layer's pixels before any edit. Rejected: at tile scale this is wasteful (most of the layer was untouched), and it scales poorly with document size and layer count. The tile-grain delta is dramatically smaller for typical edits.

2. **Per-stamp or per-sub-stroke granularity.** Each stamp placed during a brush stroke is its own undo step. Rejected: users would press `Cmd-Z` dozens of times to undo a single stroke, which no shipping paint app does. The user mental model is "undo the last thing I did," and "the last thing I did" is the stroke.

3. **RAM-only history with a hard cap.** Cap undo history at, say, 100 steps; older history is discarded. Rejected because it would prevent timelapse playback over the full document lifetime, which is the primary justification for the per-tile delta model in the first place.

4. **Branching history (Git-style) instead of linear redo.** Preserve undone branches so users can return to alternative explorations. Rejected: dramatically more complex UI and storage, ambiguous semantics for timelapse, and not a standard feature in this category. Could be revisited as a future addition behind a flag.

5. **Per-stroke deltas, coalesced gestures, RAM window with disk-backed full history, linear redo, fail-soft.** Chosen.

### Pros

- **Reuses what we already have.** The tile cache, the dirty-tile tracking, and the stroke commit step all exist for rendering reasons; capturing deltas at commit is an additional pass over the same data, not a new system.
- **Memory cost is bounded.** The RAM window keeps the working set predictable regardless of session length. A user can paint for hours without the in-memory undo state ballooning unboundedly.
- **Full document lifetime history is available.** Disk-backed older history means undo never silently runs out, and timelapse has the data it needs to replay the whole document's creation.
- **One stream covers everything.** Pixel edits and structural edits live in the same ordered stream, distinguished by record type. The undo system has one log to maintain, not two.
- **Compression is cheap and effective.** zstd at a low level is fast enough to run on the stroke thread at commit without affecting input latency, and tile deltas (often containing large constant-color regions) compress well.
- **Gesture coalescing matches user expectation.** Adjusting a slider produces one undo step, not hundreds. Users do not have to think about the granularity; they get the right behavior by default.
- **Linear redo is predictable.** Standard semantics; no branching state for users to lose track of.
- **Fail-soft preserves the live document.** A corrupted history sidecar is a recoverable problem, not a data loss event. The document the user can see is the document they keep.

### Cons

- **Big strokes produce big deltas.** A full-canvas brushstroke that touches every tile produces a delta proportional to the canvas size. The RAM cap protects against accumulated memory but does not protect against any single step being large.
- **History sidecar adds bundle complexity.** Reading and writing the `history` chunk, indexing it, and handling partial writes is real work that would not exist in a RAM-only undo system.
- **Disk I/O when undoing into older history.** Undoing far enough back to cross the RAM window pays a small disk-read cost. We should ensure this read happens off the main thread to avoid stuttering the UI during long undo runs.
- **Compression adds CPU at commit.** zstd is fast but not free. Profiling will tell us whether the stroke thread can absorb it without affecting input feel.
- **Linear redo cannot represent branching exploration.** Users who undo, try something else, and want to return to the original branch cannot. We accept this as the standard for the category.
- **Coalescing rules can surprise users.** What counts as one gesture for a complex interaction (drag a slider, then click elsewhere, then drag again) needs documenting. We will need to settle and test the boundaries case by case.

### Rationale

The structure of this decision is driven by a single insight from the stroke-model decision: the data we record for undo is the data we record for timelapse. That symmetry collapses two separate systems into one ordered stream and makes most of the design choices fall out automatically.

Per-stroke granularity is settled by user expectation. Compression and disk-backing are the natural consequences of needing full-lifetime history without unbounded RAM. Gesture coalescing is the standard rule for sliders and continuous adjustments. Linear redo is what every paint app in this category does; departing from it would be a unique design statement we have no reason to make.

Fail-soft on corruption is the choice every long-lived document app should make. The cost of being conservative (occasionally lost history) is small; the cost of being aggressive (corrupting the live document while trying to recover) is catastrophic.

### Forward implications

- **Bundle format must define a `history` chunk.** Layout, indexing, append-only semantics, and atomic-write rules belong in the file format spec.
- **Compression library choice.** zstd is the recommendation; the decision belongs in the implementation phase but should be picked early to size the CPU budget.
- **Undo coalescing rule must be documented per gesture type.** Sliders, drag transforms, multi-tap operations — each needs an explicit start/end boundary.
- **A "history budget" preference may need to be exposed.** Users on smaller machines might want a smaller RAM window; users with very long documents might want a larger one.
- **Per-document history pruning may be needed long-term.** A document edited daily for a year could accumulate gigabytes of history. We will need a "trim history older than X" affordance, with a clear note that it disables timelapse for the trimmed period.
- **Undo UI shows undo and redo state.** Menu items reflect the next undoable/redoable step's name (e.g. "Undo Brush Stroke", "Undo Delete Layer").
