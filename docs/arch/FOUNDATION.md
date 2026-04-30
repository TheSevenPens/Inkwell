# Foundation

Decisions that establish what kind of app Inkwell is: the UI framework, engine language, and platform target. Read these first when evaluating "could we do X?" — most platform-level constraints flow from here.

This file is part of the Inkwell architecture corpus. Decision numbers are global across the corpus; the index lives in [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

---

## 1. UI framework and language: AppKit + Swift, with Metal for rendering

### Decision

Inkwell is built as a **100% AppKit application written in Swift**, with the drawing canvas implemented as a **Metal-backed `NSView`**. SwiftUI is not used anywhere in the app.

### Context

Inkwell is a native macOS drawing application centered on a high-performance, pressure-sensitive canvas. The app must:

- Sustain stylus input at the device's full sample rate (typically 120 Hz or higher) without dropped samples or visible latency.
- Render and composite many bitmap layers, with blend modes and per-layer opacity, on documents that may be larger than the screen.
- Surround that canvas with the kind of dense, panel-heavy chrome that pro creative tools require: tool palettes, layer lists, brush settings, color pickers, inspectors, and floating HUDs.

The choice of UI framework affects all three concerns, but in different ways. The canvas and input handling have hard performance and API requirements; the surrounding chrome is a productivity question.

### Alternatives considered

1. **SwiftUI-only.** Rejected. SwiftUI's `Canvas` view cannot sustain stroke rendering at the required rate on large documents, and SwiftUI's gesture system does not expose the tablet event data we need (pressure, tilt, azimuth, barrel rotation). The core surface of the app would have to be wrapped AppKit anyway, so a "SwiftUI-only" app is not actually achievable for this domain.

2. **Hybrid: SwiftUI shell with AppKit/Metal canvas.** Plausible and common. SwiftUI is faster to build forms-heavy UI like brush settings and layer inspectors. The cost is a permanent interop seam between the two frameworks, plus exposure to SwiftUI-on-macOS rough edges that still ship in each release.

3. **AppKit-only in Swift, Metal canvas.** Chosen. One UI framework, one mental model, predictable performance, and abundant prior art from other pro Mac creative apps.

### Pros

- **No framework seam.** The canvas, input handling, and chrome all live in the same framework. There is no `NSViewRepresentable` boundary to manage, no SwiftUI/AppKit lifecycle mismatches, and no need to reason about two different layout systems at the same time.
- **Predictable performance.** AppKit's view model is direct and imperative. HUDs that update mid-stroke (brush size readouts, cursor previews, status bars) do not pay SwiftUI's diffing cost and do not stutter under load.
- **Full platform access.** Every `NSView`, `NSWindow`, `NSPanel`, `NSDocument`, and event API is available directly, without representable wrappers or workarounds for features SwiftUI has not yet caught up to.
- **`NSDocument` integration.** macOS document features — autosave, version browser, file coordination, atomic save — plug in naturally without bridging.
- **Strong prior art.** Most shipping pro Mac creative apps (Pixelmator Pro, Acorn, Affinity, classic Photoshop) are AppKit-based. When we hit an edge case, there is documented precedent.
- **Stable API surface.** AppKit changes slowly and predictably. We are unlikely to discover that a macOS point release has broken our toolbar or panel behavior.

### Cons

- **More boilerplate for forms-heavy UI.** Brush settings, layer panels, color pickers, and inspectors are faster to build in SwiftUI's declarative style. In AppKit we will write Auto Layout constraints in code (or XIBs) and bind values manually.
- **Older documentation and examples.** AppKit's reference material skews toward Objective-C examples from the 2010s. New Swift developers typically learn SwiftUI first, so onboarding contributors may take longer.
- **Not "modern" by framework choice.** We are not using the framework Apple is currently investing in for new platform features. If a future macOS feature ships SwiftUI-only, we will have to wait for it, work around it, or accept a small SwiftUI island.
- **Manual binding plumbing.** Two-way binding between UI controls and model state — trivial in SwiftUI — has to be wired by hand (KVO, target/action, Combine, or a custom binding layer).

### Rationale

The decisive factor is that **the highest-stakes parts of the app — the canvas and stylus input — must be AppKit + Metal regardless of any other choice**. SwiftUI cannot host them directly. Given that, a hybrid app trades the productivity win on panels for a permanent framework boundary running through the middle of the codebase. For a long-lived pro creative tool, the hybrid seam is a recurring tax: every feature that touches both the canvas and the surrounding UI pays it.

The "modern" feel of a Mac app comes from Swift idioms, Metal rendering, smooth gestures, good typography, and HIG compliance — not from which UI framework drew the inspector panel. AppKit + modern Swift (structured concurrency, `async/await`, value types, Combine where it helps) produces an app that is indistinguishable from a SwiftUI one to the user, while keeping a single coherent implementation for the team.

We accept the cost of more boilerplate on the chrome side as the price for one framework, one mental model, and predictable behavior under load.

---

## 2. Engine language: pure Swift, with hot paths isolated for possible C++ migration

### Decision

The Inkwell engine — everything below the UI layer, including stroke processing, stamp rasterization, tile management, and CPU-side image work — is written in **pure Swift**. We do not introduce C, C++, or Objective-C as engine languages at this time.

To keep a future migration option open, the CPU-bound hot paths are **isolated behind narrow internal protocols** so that any one of them can be reimplemented in C++ later without disturbing the rest of the codebase.

### Context

Most heavy compositing in Inkwell runs on the GPU through Metal, so the CPU's main jobs are: feeding Metal, processing stylus input, and handling work that does not belong on the GPU. The CPU paths that need to stay fast are well-understood and small in surface area, which means we can afford to evaluate language choices empirically rather than commit up front.

### Alternatives considered

1. **Pure Swift, isolated hot paths.** Chosen. One language, one build, one debugger. Defer cross-language complexity until profiling proves it is needed.

2. **Swift app with a C++ engine from day one.** Plausible. Zero ARC overhead, no bounds-check surprises, and a clean path to a future Linux/Windows/iPad port. Cost: a permanent bridging layer (Obj-C++ shim or Swift's still-maturing C++ interop), two debuggers, more complex builds, and a higher barrier to contribution. We do not have evidence today that this cost is justified.

3. **Swift app with Objective-C / Objective-C++ hot paths.** Rejected. Obj-C was the historical bridge to AppKit before Swift matured; it offers no performance or expressiveness advantage over modern Swift today, and would add a third language without buying anything in return.

### Pros

- **Single language across the project.** Contributors only need to know Swift. One toolchain, one debugger, one set of conventions.
- **Modern Swift is fast.** With whole-module optimization, `UnsafeMutableBufferPointer` and contiguous storage where it matters, and `@inlinable` on inner loops, Swift sits within a few percent of C for the kind of work Inkwell does on the CPU.
- **Safety by default.** ARC, bounds checks, and value semantics catch a class of bugs (use-after-free, buffer overruns, aliasing) that drawing engines have historically suffered from. We can opt out locally where the cost is real.
- **Faster iteration.** No bridging headers, no `.mm` files, no manual marshalling. The engine and the app evolve together at one pace.
- **Migration is preserved.** Because each hot path is isolated behind a protocol, swapping one to a C++ implementation later is a localized change, not a rewrite.

### Cons

- **Latent risk on inner loops.** ARC traffic and bounds checks are not free. If a hot path turns out to need every cycle, we may have to either lean hard on `unsafe` Swift idioms or accept a later port to C++.
- **Cross-platform port is harder later.** If we eventually want an iPad, Linux, or Windows version, the engine will not port directly. A C++ engine would have made that trivial.
- **Some libraries are C++-shaped.** If we adopt a third-party engine component (e.g. a PSD codec, a pixel-format converter, a filter library) it will likely be C/C++ and require a bridging layer at that boundary.
- **Swift's C++ interop is still maturing.** If we later decide to migrate a hot path, the bridging story today is workable but rough; we will pay some friction at that point.

### Hot paths to watch (candidates for future C++ migration)

These are the modules where we expect CPU performance to matter most. Each will be implemented behind a narrow Swift protocol so it can be replaced without touching its callers. If profiling on real documents shows Swift overhead is the bottleneck, these are the places we look first.

1. **Stroke input processor.** Receives stylus samples at 120+ Hz, applies smoothing, resampling, and pressure-curve evaluation, and emits a stream of stamp placements. Latency-sensitive: every microsecond on this path is felt by the user as cursor lag.
2. **Stamp rasterizer / placement engine.** Decides where stamps land between samples (spacing, jitter, scattering) and prepares the per-stamp parameters Metal will consume. Runs in tight loops with predictable shapes — a classic case where C++'s lack of ARC and bounds checks could matter.
3. **Tile cache and dirty-region tracker.** Manages the document's tile grid, tracks which tiles are dirty, and orchestrates upload/download between CPU and GPU memory. High call frequency, lots of small allocations and lookups.
4. **CPU-side filters and distortion brushes (future).** Blur, liquify, and similar effects that sample the canvas mid-stroke. These can run on the GPU in many cases, but the CPU paths that prepare or fall back for them are a likely future hot spot.
5. **PSD codec.** Reading and writing PSDs involves bit-banging, RLE decompression, and color-space conversion. Existing high-quality implementations are in C/C++; if we adopt one rather than write our own, the boundary lives here.

### Rationale

The decisive factor is that **we do not yet know which, if any, of these paths will be CPU-bound in practice**. Most compositing is GPU work, and Swift's CPU performance for the remaining tasks is generally adequate when written carefully. Committing to a C++ engine before we have profiling data would impose a permanent bridging tax — on every contributor, every build, and every debugging session — to solve a problem we have not confirmed exists.

By staying in pure Swift now and isolating the hot paths behind protocols, we keep the project simple and approachable today, and we keep the door open to migrate any individual module to C++ tomorrow if measurements demand it. The cost of being wrong in this direction is bounded (port one module later); the cost of being wrong in the other direction is paid every day forever.

---

## 3. Platform target: macOS Tahoe and later, Apple Silicon only

### Decision

Inkwell requires **macOS Tahoe or later** (the current macOS release at the time of this decision, April 2026) and runs on **Apple Silicon only**. We do not support older macOS versions, and we do not support Intel-based Macs.

### Context

Inkwell's expected audience skews strongly toward users who keep their Macs on the latest OS — pro and prosumer creative users who treat their machine as a working tool and tend to upgrade promptly. Apple has not shipped a new Intel-based Mac since late 2020, so a 2026 launch can reasonably treat Apple Silicon as the only relevant CPU/GPU architecture. The combination lets us collapse two large variables — OS version and CPU architecture — into a single, predictable target.

### Alternatives considered

1. **macOS Tahoe only, Apple Silicon only.** Chosen. Smallest test surface, newest API surface, simplest engine.
2. **macOS Sequoia (one back) and later, Apple Silicon only.** The conservative version of the same posture. Gains roughly the slice of the audience that has not yet upgraded to Tahoe, at the cost of guarding new APIs behind availability checks. We rejected it because we believe that audience slice is small for our target user, and the maintenance cost is permanent.
3. **macOS Sonoma (two back) and later, with Intel support.** Maximizes the addressable market. Rejected: doubles the GPU testing surface, constrains Metal feature use, and forces us to maintain Intel-specific performance paths for an audience that is shrinking every quarter.

### Pros

- **Single OS version to support.** One set of behaviors, one set of bugs, one set of API quirks. Every `#available` check we would otherwise have to write is replaced with the assumption that the latest API is present.
- **Single GPU architecture.** All supported machines have an Apple GPU with the same tile-based deferred rendering (TBDR) characteristics. We can tune the Metal pipeline for one architecture rather than cross-tuning for Apple GPUs and several generations of Intel/AMD discrete GPUs.
- **Unified memory architecture.** Apple Silicon's shared memory between CPU and GPU lets us pass tile data, stamp parameters, and brush textures to the GPU without explicit upload/download cycles. This simplifies the renderer and removes a class of performance pitfalls Intel Macs would have introduced.
- **Latest Metal feature set unconditionally.** Mesh shaders, the latest compute capabilities, the newest pixel format support, and current debugging tools are all available without fallbacks.
- **Latest Swift and Foundation.** New language features, current concurrency improvements, and the most recent framework APIs can be used directly without backport shims.
- **Smallest possible test matrix.** One OS version × one CPU architecture × one GPU family. This is roughly an order of magnitude less testing surface than a "macOS 14+, universal" target.

### Cons

- **Smaller addressable market at launch.** Users on macOS Sequoia or earlier, and users on remaining Intel Macs, cannot run Inkwell. For a paid creative tool, each excluded user is a potential lost sale.
- **No safety net if Tahoe ships a regression.** Because we depend on Tahoe-only behavior, a point-release bug in macOS itself becomes our problem to work around rather than something we could side-step by recommending an older OS.
- **Re-evaluation cost when the next macOS ships.** When the macOS release after Tahoe arrives, we will have to choose again: stay pinned to Tahoe-or-later, or move the floor up. Each move forward repeats the trade-off in this section.
- **No path to Intel users with old but capable Macs.** Some users on 2018–2020 Intel iMac Pros and Mac Pros have hardware that could in principle run a drawing app well. We are explicitly choosing not to serve them.

### Rationale

The deciding factor is the audience. We expect Inkwell's users to be on the latest macOS, which means the addressable-market cost of requiring Tahoe is smaller for us than it would be for a general-purpose app. In exchange, we get the simplest possible engineering target: one OS, one CPU architecture, one GPU family, one set of APIs. Every layer of the system — from `NSEvent` tablet handling up through Metal rendering — gets simpler when there is no compatibility branching.

Apple Silicon-only is the natural companion to that decision. Apple has shipped no new Intel Macs since late 2020, the unified memory architecture meaningfully simplifies the renderer, and the alternative — maintaining Intel performance parity — is a recurring tax for a shrinking audience.

We accept that this stance will need to be revisited each time a new macOS ships. The default re-evaluation question will be: "Has Tahoe's share of our audience dropped enough that staying pinned to it costs us more than moving the floor forward would?"
