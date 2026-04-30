# Contributing

Workflow, conventions, and review expectations for changes to Inkwell.

## Before you start

- Read [`OVERVIEW.md`](OVERVIEW.md) and [`ARCHITECTURE.md`](ARCHITECTURE.md). The architecture corpus in [`arch/`](arch/) records *why* the code is the way it is.
- Walk the subsystem docs under [`design/`](design/) for the area you're touching.
- Check [`FUTURES.md`](FUTURES.md) and [open issues](https://github.com/TheSevenPens/Inkwell/issues) to make sure your change isn't duplicating planned work.

## Branch and PR conventions

### Branches

- Always branch from `main`. No long-lived feature branches.
- Branch name is short and descriptive: `vector-eraser`, `fix-stroke-stall`, `dev-docs`. No personal prefixes.
- Delete the branch on merge.

### Commits

- One logical change per commit. If a single feature has independent pieces (e.g. shader change + Swift wiring + docs), it's fine to keep them in one commit *if* they only make sense together.
- Commit messages follow the existing style: imperative subject under ~70 chars, body wrapped at ~72, "why" before "what."
  ```
  Vector eraser (3 modes), vector path overlay, brush cursor zoom refresh

  Vector eraser lands with three modes selectable via Edit → Vector Eraser
  Mode (persisted across launches): …
  ```
- Co-authored AI commits are fine — keep the existing trailer pattern:
  ```
  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```

### PRs

- Title matches the lead commit's subject.
- Body lists the headline change first, then implementation notes, then any caveats / known gaps.
- Link to the issue (`Closes #42`) if there is one.
- For visible changes, drop a screenshot or short clip into the description.

There's no formal review hierarchy yet — PRs go in once they pass the **required checks** below.

## Required checks before merge

Until CI is wired up (tracked in [`TESTING.md`](TESTING.md)), the contributor runs these locally:

1. **`swift build`** with no warnings on the touched files. The codebase is currently warning-clean; keep it that way.
2. **`./scripts/build.sh`** completes and produces a launchable `build/Inkwell.app`.
3. **Smoke run** the app: open a document, draw a few strokes with each brush, save & reopen, undo & redo. Anything you broke shows up here.
4. **Documentation parity**: if your change makes any subsystem doc, architecture doc, user-facing doc, or design caveat obsolete, update it in the same PR. Stale docs are worse than missing ones.
5. **Targeted regression**: if the area has known fragility (stroke timing, tile boundaries, undo, file format), exercise it explicitly. See [`TESTING.md`](TESTING.md) for the manual scenario list.

If the change touches the **file format**, also:

- Bump `FileFormat.currentVersion` if the wire format changes.
- Add a migration in `FormatMigrator` (currently scaffolded only — see [SCHEMA_REFERENCE.md](SCHEMA_REFERENCE.md)).
- Round-trip an existing `.inkwell` document through your build and verify it still opens.

## Style conventions

### Swift

- **Swift 6 toolchain, language mode v5.** Set in `Package.swift`. Don't bump the language mode without a separate decision — Swift 6 strict concurrency would touch every file.
- **2-space indentation** (Apple-default). Match the surrounding file if it disagrees with itself; consistency over the rule.
- **`final class`** by default. Open inheritance only with a reason.
- **Value types** for plain data (`StylusSample`, `VectorStroke`, `TileCoord`, `ColorRGBA`).
- **Reference types** for view-tier objects (NSView subclasses, controllers) and model types with identity (layers).
- **`@MainActor`** is *not* used in this codebase. Most things run on main today; the architecture's eventual stroke / GPU / autosave threading is documented in [`THREADING_MODEL.md`](THREADING_MODEL.md). Don't add `@MainActor` annotations without reading that.
- **Documentation comments**: `///` on every public type and non-trivial method. Aim for "what / why / gotcha," not "what" alone.
- **Avoid emojis** in source comments and doc strings unless the project owner has explicitly asked for them in a specific surface (e.g. status-bar indicators).

### Metal shaders

- Shaders live as `static let metalSource = """ … """` strings inside their owning Swift file (e.g. [CanvasRenderer.swift](../Sources/Inkwell/CanvasRenderer.swift)). Don't split them out into `.metal` files — we compile at runtime via `device.makeLibrary(source:options:)`.
- Match the **CPU-side uniform struct's memory layout exactly**. Padding fields (`var _pad0: Float = 0`) exist to align with the shader struct. Mismatch silently corrupts uniforms.
- Output **premultiplied** RGBA from fragment shaders that write into tile textures or the drawable. See [`design/COLOR.md`](design/COLOR.md).
- Branch on `int blendMode` for blend-mode dispatch; framebuffer fetch (`float4 dst [[color(0)]]`) is how we read the destination.

### Docs

- Subsystem docs in [`design/`](design/) describe **what shipping today does**. Architecture docs in [`arch/`](arch/) describe **why we chose what we chose**. Don't blur them.
- Every doc starts with a TL;DR or 1-paragraph summary.
- "Known gaps" sections at the end of subsystem docs call out divergence between architectural intent and shipping reality. New contributors trust them; keep them honest.
- Code references use the form `[BitmapLayer.swift:190](../Sources/Inkwell/BitmapLayer.swift#L190)` so they survive a click and don't rot when files move.

## When to write an Architecture Decision vs. a design note vs. nothing

This is the most-asked question. Rule of thumb:

| Change | Where it goes |
|---|---|
| New behavior that's *implemented*, follows existing decisions, fits an existing subsystem | Subsystem doc in [`design/`](design/) gets a new section. No architecture decision. Code comments where helpful. |
| Change to a documented invariant (row order, premultiplied alpha, who owns mutation) | Update the subsystem doc *and* the relevant architecture decision. If the change reverses a decision, write a new decision saying so — don't silently edit the old one. |
| New cross-cutting choice (e.g. "we will adopt zstd for tile delta compression") | New numbered decision in the architecture corpus, in the appropriate `arch/<file>.md`. Append the decision number; update `ARCHITECTURE.md`'s index. |
| Tactical implementation detail (renamed a private method, refactored a helper) | Code comments only. No doc change. |
| Big new subsystem (e.g. timelapse, vector layers V2) | Both: a new architecture decision *and* a new design doc once it's implemented. |

When in doubt: write the smaller artifact first. If it grows past two pages, promote.

## What "done" looks like

A change is done when:

- Code compiles and passes the smoke run.
- Docs that describe the affected subsystem are correct as of this PR.
- "Known gaps" sections updated if you closed one.
- A user would not be surprised by the new behavior — manual entries updated for visible changes ([USERMANUAL.md](USERMANUAL.md)).
- Any feature that introduces a deferred caveat is recorded in [`FUTURES.md`](FUTURES.md).

## What we don't do

- **No commented-out code.** Delete it; git remembers.
- **No `print()` debugging in committed code.** Use `NSLog` for the one or two places we log warnings, or remove before merge.
- **No third-party UI kits.** Everything is hand-built on AppKit primitives. See [`UI_COMPONENTS.md`](UI_COMPONENTS.md) for the inventory of reusable components.
- **No SwiftUI.** Architecture decision 1 picked AppKit; reaffirm before introducing it.
- **No third-party Metal helper libraries.** Shaders and pipelines are inline.
- **No mid-merge force-pushes to `main`.** PRs land via merge or squash, not rebase-and-push to main.

## Getting help

- Start in [`design/`](design/) — most "how does this work" questions are answered there.
- For `why` questions, the architecture corpus in [`arch/`](arch/).
- For deferred work, [`FUTURES.md`](FUTURES.md) and [`ROADMAP_OWNERSHIP.md`](ROADMAP_OWNERSHIP.md).
- If a doc is wrong, fix it in the same PR as your code change.
