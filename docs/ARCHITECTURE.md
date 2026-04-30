# Inkwell Architecture

This corpus records the major architectural decisions for Inkwell, the reasoning behind them, and the trade-offs we accepted. New decisions are appended chronologically, so the corpus doubles as a record of how the architecture took shape.

Each decision section follows the same structure: **Decision**, **Context**, **Alternatives considered**, **Pros**, **Cons**, and **Rationale**. Future readers should be able to understand not just *what* we chose, but *why* — and what we gave up to get there.

> **Implementation status.** All 14 decisions below are reflected in the shipping code as of Phase 11. A handful of decision-level commitments are still partially realized (notably decision 6's Display P3 working space — the engine currently runs in sRGB; and decision 9's full undo / timelapse history persistence — the in-memory undo system runs but `history.bin` is not yet written). These gaps are tracked in [`FUTURES.md`](FUTURES.md) under "Phase pass-2 deferrals." Decisions themselves are stable; deferrals are about delivery order, not redesign.

---

## How this corpus is organized

The corpus is split into six topical files under [`arch/`](arch/). **Decision numbers are global across the corpus** — the index below maps each numbered decision to the file it lives in. References sprinkled through the codebase and other docs ("per ARCHITECTURE.md decision 11") still resolve via this index; readers click through to find the file. New decisions get appended numbers; their file is recorded in the index.

| # | Topic | File |
|---|---|---|
| 1 | UI framework and language: AppKit + Swift, with Metal for rendering | [`arch/FOUNDATION.md`](arch/FOUNDATION.md) |
| 2 | Engine language: pure Swift, with hot paths isolated for possible C++ migration | [`arch/FOUNDATION.md`](arch/FOUNDATION.md) |
| 3 | Platform target: macOS Tahoe and later, Apple Silicon only | [`arch/FOUNDATION.md`](arch/FOUNDATION.md) |
| 4 | Rendering pipeline: tile-based, GPU-resident layers with lazy viewport compositing | [`arch/RENDERING.md`](arch/RENDERING.md) |
| 5 | Stroke model: rasterize-and-discard for bitmap layers, with engine commitments to keep future layer types open | [`arch/DOCUMENT.md`](arch/DOCUMENT.md) |
| 6 | Color and blending: Display P3, 16-bit, premultiplied, gamma-space blends | [`arch/RENDERING.md`](arch/RENDERING.md) |
| 7 | Document model: grouped layer tree, per-layer masks, native `.inkwell` bundle, PSD as export-only | [`arch/DOCUMENT.md`](arch/DOCUMENT.md) |
| 8 | Threading model: main + stroke + GPU + autosave, with snapshot reads | [`arch/CONCURRENCY.md`](arch/CONCURRENCY.md) |
| 9 | Undo/redo: per-stroke deltas, gesture-coalesced, RAM-windowed with full history persisted | [`arch/CONCURRENCY.md`](arch/CONCURRENCY.md) |
| 10 | Tablet input: full-fidelity NSEvent capture, no prediction, eraser-end switches tool | [`arch/INPUT.md`](arch/INPUT.md) |
| 11 | Brush engine: data-driven stamp engine, GPU composition, four v1 brushes from one core | [`arch/INPUT.md`](arch/INPUT.md) |
| 12 | Selections: hybrid raster + optional vector, with the standard pro toolset | [`arch/SELECTIONS.md`](arch/SELECTIONS.md) |
| 13 | View control: cursor-anchored zoom and rotate, single transform matrix | [`arch/RENDERING.md`](arch/RENDERING.md) |
| 14 | Native file format and export/import pipeline | [`arch/DOCUMENT.md`](arch/DOCUMENT.md) |

## File overview

- **[`arch/FOUNDATION.md`](arch/FOUNDATION.md)** — UI framework, engine language, platform target. Read first when evaluating "could we do X?"
- **[`arch/RENDERING.md`](arch/RENDERING.md)** — Tile pipeline, color & blending, view control. Everything about turning canvas state into pixels.
- **[`arch/DOCUMENT.md`](arch/DOCUMENT.md)** — Stroke model, layer tree, file format. What an Inkwell document *is*.
- **[`arch/CONCURRENCY.md`](arch/CONCURRENCY.md)** — Threading and undo. Both are about controlling *when* state mutates and who can read it safely.
- **[`arch/INPUT.md`](arch/INPUT.md)** — Tablet input and the brush engine. From hardware event to deposited stamp.
- **[`arch/SELECTIONS.md`](arch/SELECTIONS.md)** — Hybrid raster + optional vector selection system.

## Conventions

- **Decision numbers are stable identifiers.** Once a decision is numbered, that number does not change. New decisions append.
- **Cross-references use the bare number.** "Per decision 4" or "(decision 11)" is unambiguous; readers find the file via the index above. Avoid file-path-qualified references in prose so reorganizations stay cheap.
- **One file per subsystem, not per decision.** Decisions cluster naturally — splitting them further fragments the prose.
- **The structure inside each decision is uniform**: Decision · Context · Alternatives considered · Pros · Cons · Rationale · (optional) Forward implications.

---

## Subsystem design docs

The architecture corpus answers *why* the code is the way it is. The subsystem docs under [`design/`](design/) answer *how it actually works today* — code references, data flow, conventions, gotchas. Read these when you're about to work on a subsystem.

- [`design/TILES.md`](design/TILES.md) — Tiles and layer storage. Foundational; read first.
- [`design/COMPOSITOR.md`](design/COMPOSITOR.md) — Render pass, the five Metal pipelines, blend math.
- [`design/STROKES.md`](design/STROKES.md) — Event capture, emitters, stamp + ribbon renderers, command-buffer batching.
- [`design/COORDINATES.md`](design/COORDINATES.md) — Canvas / tile / window / NDC spaces, Y-axis conventions, view transform.
- [`design/UNDO.md`](design/UNDO.md) — `NSUndoManager` integration, the inverse-snapshot pattern, what is and isn't undoable.
- [`design/COLOR.md`](design/COLOR.md) — Premultiplied alpha invariant, gamma-space blending, sRGB-everywhere reality vs. P3 architectural intent.

## Companion docs

- [`OVERVIEW.md`](OVERVIEW.md) — product-level summary; the "what we're building" doc.
- [`USERMANUAL.md`](USERMANUAL.md) — user-facing feature reference for what's shipping today.
- [`PLAN.md`](PLAN.md) — phased implementation plan with per-phase status.
- [`FUTURES.md`](FUTURES.md) — deferred work with architectural-readiness notes.
- [`FILEFORMAT.md`](FILEFORMAT.md) — `.inkwell` bundle byte-level specification.
- [`PSD_FIDELITY.md`](PSD_FIDELITY.md) — PSD round-trip table.
- [`UI_COMPONENTS.md`](UI_COMPONENTS.md) — catalog of reusable UI building blocks.
