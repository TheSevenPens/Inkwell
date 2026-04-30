# Input pipeline

From the hardware tablet event to the stamps deposited on a tile. Decision 10 captures stylus input at full fidelity; decision 11 turns those samples into pixels via a single shared brush engine.

This file is part of the Inkwell architecture corpus. Decision numbers are global across the corpus; the index lives in [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

---

## 10. Tablet input: full-fidelity NSEvent capture, no prediction, eraser-end switches tool

### Decision

The Inkwell canvas is a custom **`NSView` subclass** that handles raw `NSEvent` input directly. The canvas captures every available stylus parameter from every available event type, leaves the brush engine to decide what to use, and relies on macOS Tahoe's existing tablet driver ecosystem rather than implementing device-specific drivers.

- **Event types handled.**
  - `mouseDown`, `mouseDragged`, `mouseUp` are the primary sample channel. When the input device is a stylus, these events carry tablet data via `subtype == .tabletPoint` and expose pressure, tilt, rotation, and related accessors.
  - `tabletPoint` events are handled as a supplementary stream wherever they arrive.
  - `tabletProximity` events are handled to detect stylus presence, which end of the stylus is engaged (tip vs eraser), the device's unique ID, and the device's reported capability flags.
- **Stylus parameters captured per sample.** Position (window coordinates, transformed to canvas pixels by the current view transform), pressure (0…1), tilt-X and tilt-Y (with altitude/azimuth derived where useful), barrel rotation, stylus button state, eraser flag (from proximity), and an event timestamp. Parameters not reported by a particular device are recorded as "unsupported" rather than zero, so the brush engine can fall back rather than misinterpret missing data as data.
- **Event coalescing.** Disabled on the canvas window. macOS by default coalesces mouse-style events to one per refresh; for 120+ Hz stylus input this drops samples and produces visibly polygonal strokes. We turn off coalescing for the canvas and read every sub-sample carried by each event.
- **Motion prediction.** Not used in v1. macOS does not have a direct equivalent of iOS's `predictedTouches` for `NSEvent` tablet input. We render from raw samples and rely on Metal's low-latency presentation path. We will revisit if profiling on real users shows perceived input lag.
- **Device support.** Whatever the user's macOS Tahoe install can drive: Wacom (Bamboo, Intuos, Cintiq, etc.), Huion, XP-Pen, third-party Wacom-compatible tablets, and Apple Pencil exposed through Sidecar. We do not ship device-specific drivers and we do not contain device-specific quirk code at the input layer.
- **Hot-plug.** A new device ID appearing in a `tabletProximity` event is treated as a new stylus. No reconnect ceremony required; capability detection happens at first proximity.
- **Eraser-end behavior.** When `tabletProximity` reports the eraser end engaged, the input pipeline temporarily switches to the **Eraser tool** with the user's current eraser settings. When the tip end re-engages, the previous tool is restored. This matches the industry-standard behavior pro users expect from physical eraser-tipped styluses.
- **Coordinate space.** Events arrive in window coordinates. The canvas applies its current pan / zoom / rotate transform to produce canvas pixel coordinates. Pressure and other normalized values are coordinate-independent.

### Context

Decision 1 (AppKit + Swift, with Metal for rendering) already required a custom `NSView` subclass for the canvas — SwiftUI does not surface stylus parameters through its gesture system. What was left open was *what the canvas actually captures from the event stream*, *how the stream is treated* (coalescing, prediction, sample rate), and *which devices we explicitly support*. Those choices flow downstream to the brush engine, the stroke processor (which earlier decisions located on the stroke thread), and the user-visible behavior of physical stylus features (eraser end, barrel buttons).

### Alternatives considered

1. **Use PencilKit instead of raw `NSEvent`.** PencilKit is the iPadOS / Catalyst stylus framework; on macOS it is only relevant when running an iPad app via Catalyst or accepting input from an iPad over Sidecar in a Catalyst context. Rejected: Inkwell is a native Mac app supporting all macOS-driven tablets, not just Apple Pencil through Sidecar. PencilKit does not see Wacom or Huion tablets connected to a Mac.

2. **Handle only `mouseDragged` events; ignore `tabletPoint` and `tabletProximity`.** Every supported tablet delivers stylus data through `mouseDragged` with a tablet subtype, so this would not lose pressure or tilt. Rejected because it misses proximity transitions (no eraser-end detection, no "stylus is hovering" awareness for cursor preview, no device-ID tracking) and discards the supplementary `tabletPoint` stream where it arrives. Cheap to handle all three; expensive to retrofit later.

3. **Capture only position and pressure; ignore tilt and rotation.** Simpler stylus sample structure, smaller stroke-thread payload. Rejected because it permanently caps brush engine ambition at "the brush knows where and how hard, but not how the stylus is held." Several intended brushes (calligraphy, airbrush at angle) genuinely use tilt; rotation matters for the future Wacom Art Pen audience. Cheap to capture; impossible to invent later.

4. **Implement motion prediction in v1.** Synthesize one or two predicted samples ahead of the latest real sample to mask GPU latency. Rejected for v1 because macOS does not provide predicted samples and our own prediction is error-prone (a wrong prediction at stroke direction-change time produces a visible "wobble"). Apple Silicon's GPU latency is low enough that raw-sample rendering feels good without it.

5. **Implement device-specific quirk paths (e.g. for known-bad Huion or XP-Pen drivers).** Rejected for v1: we trust the OS's driver layer. If specific tablets misbehave at the OS level, the right fix is a vendor driver update or a documented known-issue, not a quirk path in our input code. We can revisit if widespread issues appear.

6. **Full event handling, full parameter capture, coalescing disabled, no prediction, OS-driven device support, eraser-end tool switch.** Chosen.

### Pros

- **Maximum data fidelity to the brush engine.** Every parameter the device reports reaches the brush engine. Brushes that want to use tilt or rotation can; brushes that only want pressure ignore the rest.
- **Full sample rate.** Disabling coalescing lets the canvas receive every stylus sample the OS exposes. Strokes look smooth at 120+ Hz instead of polygonal at refresh rate.
- **Eraser-end behavior is correct out of the box.** Pro users do not have to configure anything to make the eraser end of their stylus erase. It just does.
- **Hot-plug works without ceremony.** Users can plug in a tablet mid-session and continue drawing; the next proximity event registers the device.
- **No vendor driver code to maintain.** The OS handles per-device quirks. If a new tablet ships, it works as soon as macOS supports it.
- **Coordinate transformation is centralized.** The canvas applies one transform from window coords to canvas pixels; everything downstream sees canvas pixels. No transform-related bugs in the stroke processor or the brush engine.
- **Capability detection rides on existing events.** No separate device-enumeration code; `tabletProximity` tells us what each connected stylus reports.

### Cons

- **More events to process per sample.** Disabling coalescing increases event volume on the main thread. We are dispatching to the stroke thread immediately, so the main-thread cost is small, but it is real.
- **Tilt and rotation are unevenly supported across devices.** Brushes that lean on tilt will feel different on tablets that do not report it. The fallback (treat unsupported parameters as neutral) is correct but does mean some brush behavior is device-dependent.
- **No motion prediction means GPU latency is felt directly.** On a system with unusual latency (perhaps a misbehaving driver, perhaps an external display chain), users may perceive lag. We do not have a built-in mitigation in v1.
- **Implicit hot-plug detection is best-effort.** A tablet that is plugged in but never enters proximity is invisible to us. This is not a real failure — proximity is the trigger for any actual use — but it means a Settings panel listing "connected tablets" would need its own device enumeration.
- **Eraser-end tool switch is a hidden behavior.** If a user does not realize their stylus has an eraser end, the temporary tool switch may surprise them. Mitigation: surface the behavior in the user manual and make sure the cursor or status bar reflects the current tool clearly.

### Rationale

The deciding stance is **capture everything, decide later**. The cost of capturing more parameters from each event is negligible — a slightly larger sample struct on the stroke thread — while the cost of *not* capturing is permanent. Brushes that one day want tilt cannot retrofit it onto strokes drawn before tilt was being recorded. Capturing the full set today preserves every future option.

Coalescing disabled and prediction off form a coherent stance: prefer the highest-fidelity raw signal we can get and put the smoothing budget into the stroke processor (which can apply curve fits and resampling with full visibility into the data) rather than into prediction (which guesses about samples that haven't happened yet). If profiling later proves perceived latency is a real problem, prediction can be added as a layered improvement; smoothing the raw sample stream cannot.

Trusting the OS for device support — rather than shipping device-specific code paths — keeps the input layer small and shrinks the maintenance surface. macOS's tablet driver ecosystem, while imperfect, is the right level of abstraction for an app of our size; chasing per-device quirks is a treadmill we do not need to be on.

### Forward implications

- **The stylus sample struct is the canonical input to the stroke processor.** Its definition (position, pressure, tilt-X, tilt-Y, rotation, buttons, eraser flag, timestamp, device ID) is fixed early and rarely changed.
- **Unsupported parameters are encoded explicitly, not as zero.** A `Pressure?` (or sentinel value) lets the brush engine distinguish "device reports 0 pressure" from "device does not support pressure" — these have different correct behaviors.
- **The brush engine is parameter-aware.** Each brush declares which stylus parameters it consumes; the brush settings UI exposes pressure curves, tilt mappings, and rotation mappings only for parameters the active device supports.
- **The cursor preview reflects current device state.** When a stylus is in proximity, the cursor previews the brush at the appropriate tilt/rotation; when the eraser is engaged, the cursor reflects the eraser tool.
- **A "current input device" status surface is needed somewhere in the UI.** At minimum, the user should be able to tell which stylus the app last saw and what parameters that device reports.
- **Window-level event tuning is required at canvas creation.** Setting `acceptsTouchEvents`, disabling mouse coalescing, and enabling tablet event delivery are setup steps the canvas view must perform; they are not defaults.

---

## 11. Brush engine: data-driven stamp engine, GPU composition, four v1 brushes from one core

### Decision

Inkwell ships a **single stamp-based brush engine**. All v1 brushes — Marker, G-Pen, Airbrush, Eraser — are different settings over the same core. New brushes are added by editing a brush definition file, not by writing code. The core engine consumes stylus samples (with the full parameter set from decision 10), produces a stream of stamps, and composites those stamps into the active layer's tile grid on the GPU.

- **Brush definition is data, not code.** Each brush is a serializable struct (Swift `Codable`, persisted as JSON or property list) containing identity, stamp tip reference, spacing rule, parameter mappings, jitter, and accumulation rule. Built-in brushes live in the app bundle; user-edited brushes live in user data; future imported brushes (see ABR in the futures doc) land in the same format.
- **Stamp tip and grain.** Each brush has a required grayscale **tip texture** (the stamp shape — round, oval, calligraphy nib, etc.) and an optional **grain texture** that modulates the stamp to simulate paper or canvas texture.
- **Spacing.** Stamps are placed at a configurable percentage of brush size along the stroke path. Path between samples is interpolated linearly for short distances and with a Catmull-Rom curve for smoother sections.
- **Per-stamp parameter mappings.** Pressure → size, pressure → opacity, tilt → angle, rotation → stamp rotation, with optional jitter on each. Each mapping has a curve (see "Pressure curves" below) that maps the raw 0…1 device value to an effective 0…1 brush value.
- **Color jitter.** Optional per-stamp variation in hue, saturation, and value, useful for natural-media brushes.
- **Stroke-internal blend mode.** Each brush specifies how its stamps accumulate within a single stroke (e.g. "Normal" for a flat marker, "Lighten" for additive effects). The layer's own blend mode then determines how the committed stroke composites with layers below.
- **GPU-side stamp composition.** Stamp rasterization is a Metal **compute shader** that reads the tip and grain textures, applies the per-stamp parameters, and blends directly into the layer's tile texture. We do not allocate a CPU-side stamp buffer. On Apple Silicon's unified memory there is no upload step. The stroke thread builds a small batch of stamps per stylus sample and dispatches one compute pass per batch.
- **Pressure curves (provisional).** v1 uses a **cubic Bézier with two interior control points** as the placeholder representation. **The math and the user experience for pressure curves are explicitly subject to revision** per the project owner's pending design input. This decision documents the current implementation choice but does not lock it; later work may replace the representation, the editing UI, or both.

### The four v1 brushes (sketched)

- **G-Pen.** Hard-edged round tip. Pressure → size and pressure → opacity. Tight spacing. For comic inking and confident line work.
- **Marker.** Soft-edged round tip. Pressure → opacity, with size largely fixed. Translucent layered painting.
- **Airbrush.** Soft circular tip. Pressure → flow rate (paint emits continuously while held in place); low per-stamp opacity that accumulates over time.
- **Eraser.** Same engine as Marker, with the destination-out blend mode (or operating directly on alpha) so painted strokes remove pixels rather than add them.

The point is that all four are *the same engine with different settings*. Adding a fifth brush is a settings file, not a code change.

### Context

The brush engine is the component users will judge the app on. It is also the most central CPU/GPU collaboration: the stroke thread feeds it samples and parameters, the GPU rasterizes its output into tiles, and the tile cache (decision 4) holds the result. Earlier decisions have already constrained the design — Apple Silicon GPU compute, unified memory, 16-bit premultiplied tiles, single-stroke-thread mutation — so the remaining choices were the engine's shape and the format of brush definitions.

### Alternatives considered

1. **Stamp-based engine, brushes as data.** Chosen. Industry standard. One engine to optimize, brushes that can be edited and shared without recompiling.
2. **Per-brush hand-coded engines.** Each brush has its own implementation tuned to its needs. Rejected: code multiplies, cross-brush refinements (e.g. fixing an artifact at low pressure) have to be repeated, and adding a new brush is engineering work.
3. **Procedural brushes (no tip texture; shape computed in shader).** Powerful for some effects but limited for natural-media brushes that depend on a specific tip silhouette. Rejected as the v1 default; we may add procedural brush nodes as a layered feature later.
4. **CPU stamp composition with per-stamp GPU upload.** Predictable, simple to debug. Rejected because we already have unified memory and can compose directly on the GPU; CPU composition adds work without a benefit.
5. **Hybrid: simple brushes on GPU, complex brushes (future distortion brushes) on CPU.** A reasonable forward stance. Distortion brushes (in futures.md) sample the canvas and may use a different rasterization path; that does not change the v1 engine, which is uniformly GPU-composed.

### Pros

- **One engine to optimize.** Performance work on stamp composition, smoothing, parameter mapping, and tile updates pays off across every brush.
- **Brushes are user-editable.** A brush is a small JSON-shaped file. Power users can tweak; future ABR import can target the same format. This unlocks community brush libraries without engine work.
- **GPU composition matches the platform.** Apple Silicon's compute capability and unified memory make per-sample compute dispatches the natural pattern. No upload overhead, no per-stamp CPU rasterization.
- **Clean parameter pipeline.** The stylus sample (with all parameters) flows through smoothing, through per-mapping curves, and into the stamp dispatch. Each step is testable in isolation.
- **Brush identity is decoupled from brush behavior.** Renaming a brush, changing its icon, reorganizing categories — all data edits, never code.
- **Future brushes (texture-heavy, multi-tip, calligraphic) require no engine change** if they fit the stamp model. The model accommodates a wide range of natural-media behaviors.

### Cons

- **Some effects do not fit the stamp model cleanly.** Wet-edge brushes that interact with previously laid paint, distortion brushes that sample the canvas, and "smudge" tools that move existing pixels are not pure stamp engines. We will need a parallel path for these (deferred to future versions per the futures doc).
- **GPU compute dispatch overhead matters at high stamp rates.** A naive "one dispatch per stamp" would be slow; we batch stamps per stylus sample. The batching logic is a place where bugs would manifest as visible stamp-spacing artifacts.
- **Brush definitions need versioning.** As the engine evolves, brush settings will gain fields. Old brush files must continue to load. This is the standard "extensible Codable struct with version fields" problem; it costs forethought.
- **Tip texture quality is a real workload.** A few well-made tip textures define how the v1 brushes feel. Producing them is a design task with no shortcut.
- **Pressure curve representation is provisional.** The chosen cubic-Bézier-with-two-control-points may not survive contact with the project owner's planned redesign of pressure-curve math and UX. We have minimized blast radius by isolating curves behind a clear interface, but a representation change still touches the brush settings format and the brush settings UI.

### Rationale

The stamp-based, data-driven engine is what the rest of the industry uses because it is the right factoring of the problem. Stylus input naturally produces a path; brushes naturally consist of a stamp shape applied along that path with parameter modulation. Other factorings either repeat work (per-brush engines) or give up flexibility (procedural-only). Our v1 brush set is small enough that the question "is one engine enough?" is easy to answer yes; our future brush ambition (ABR, more natural-media brushes, possibly procedural nodes later) is well-served by the same engine plus future additions.

GPU-side composition is the right call on this platform. We are not trying to support a discrete-GPU upload-download model that does not apply here.

The pressure curve representation is the one part of this decision we are explicitly *not* locking in. The project owner has signaled that they have specific design input on pressure curves — both the math and the UX — that has not been fully articulated yet. Cubic Bézier with two control points is the placeholder we ship, isolated behind a curve-evaluation interface so it can be replaced without rippling through the engine.

### Forward implications

- **Pressure curve representation and editing UI are open design questions.** A future decision (or revision of this one) will document the chosen math and UX. Implementation should keep curve evaluation behind a small interface so the representation can change.
- **Brush definition format gets a version field.** Standard practice for any user-editable, long-lived format.
- **Brush settings UI is built early.** Even if the v1 brush set is fixed, the editor that lets us iterate on tip textures, spacing, jitter, and curves is what makes the engine tunable.
- **Tip and grain texture pipeline is needed.** Importing PNG/SVG textures, normalizing them, and packing them into a brush bundle is its own small system.
- **Stamp batching at the dispatch layer.** One Metal compute dispatch per stylus sample, with N stamps per dispatch (where N depends on spacing and per-sample motion). Batching shape and limits will need profiling.
- **The stamp rasterizer remains on the C++-migration candidate list** from decision 2. Profiling will tell us whether Swift's GPU-dispatch overhead is a real problem.
