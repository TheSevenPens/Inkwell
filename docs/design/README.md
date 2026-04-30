# Subsystem design

If you've just landed on the Inkwell codebase, start here.

These docs answer *how the code actually works today*: data flow, conventions, where things live, and the gaps between the architectural commitment and what's shipping. They're a complement to the architecture corpus in [`../ARCHITECTURE.md`](../ARCHITECTURE.md), which answers *why we made the choices we did*.

## Reading order for a new contributor

1. [`TILES.md`](TILES.md) — Tiles and layer storage. The foundation everything else sits on.
2. [`COMPOSITOR.md`](COMPOSITOR.md) — How the canvas redraws. Five Metal pipelines, framebuffer-fetch blend math, samplers.
3. [`STROKES.md`](STROKES.md) — Event capture → emitter → stamp / ribbon. The most-touched code path during development.
4. [`COORDINATES.md`](COORDINATES.md) — Canvas / tile / window / NDC spaces. Read this before debugging any "Y is upside down" issue.
5. [`UNDO.md`](UNDO.md) — `NSUndoManager` integration and the inverse-snapshot pattern. Read before adding a new mutation.
6. [`COLOR.md`](COLOR.md) — Premultiplied alpha invariant, gamma-space blending, what's sRGB today vs. the P3 commitment.

## When to update these docs

- When you change a subsystem's data flow, conventions, or invariants — update the relevant subsystem doc.
- When a "Known gaps" item gets shipped — move it out of the gaps section and into the body.
- When you find a new convention you had to learn the hard way — add it under "Conventions you must not violate" so the next person doesn't repeat your debugging.

The decision docs in [`../arch/`](../arch/) record *why* we chose something. These docs record *how it works now*. The two should disagree only when the architecture has committed to something we haven't shipped yet — and in that case the subsystem doc should call out the gap explicitly (look for "Known gaps" sections).
