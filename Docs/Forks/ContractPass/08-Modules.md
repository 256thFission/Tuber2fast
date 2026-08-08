# Proposed: the module rule, as `Contract.md` should read it

Stage 2 item 8 of [`CanvasCompleteTodo.md`](../CanvasCompleteTodo.md). The
code has landed; this file holds only the part that is **Phillip's to
decide** — what `Docs/Contract.md` says now that the import rule has a
different enforcer. Nothing here is in force, and nothing here was written
into `Contract.md`.

---

## The sentence that is now false in one direction

*Owners* currently ends with:

> Durable value types import Foundation only. UIKit and PencilKit may be
> imported only by the canvas runtime — the owners of frame-frequency canvas
> state, and the immutable values that carry a drawing out of them — and by
> the owner of the background-execution lease.

Two things about it changed under the split.

1. **"Durable value types import Foundation only" is no longer what the
   code does, and had not been for a while.** `DrawingSnapshot` imports
   PencilKit — it *is* the `PKDrawing` box — and it lives with the durable
   value types in `TuberModel`, which links PencilKit by your decision of
   2026-08-07. The sentence's parenthetical already carved it out ("and the
   immutable values that carry a drawing out of them"); the module makes the
   carve-out a link edge rather than a clause.
2. **The rule's subject is a module now, not a file.** "The canvas runtime"
   used to be a set of files a test allowlisted by path. It is a target.

## Proposed wording

Replacing the paragraph above, in *Owners*:

> The application is a graph of modules, and a module's place in it is the
> statement of what it may reach for: **TuberCore** (logging; Foundation and
> os), **TuberModel** (the durable value types and the immutable box that
> carries a drawing out of the canvas runtime; Foundation, CoreGraphics, and
> PencilKit), **TuberStore** (the sole writer of durable state, and the only
> module that touches the file system), **TuberRender** (off-main decode and
> composite), **TuberCanvas** (the canvas runtime — every owner of
> frame-frequency state), and the application target (the SwiftUI shell, the
> session, and the background-execution lease). Each depends only on modules
> below it. **No module below the application target may import SwiftUI**,
> which is golden rule 2's import half and is a build failure rather than a
> convention. TuberCanvas does not depend on TuberStore: the canvas runtime
> never sees the store.

Adding the module list to the contract is the part worth arguing about. The
case for: *Owners* already names concrete owners and draws their one
direction of flow, and the module graph is that same picture with the
compiler holding it. The case against: the contract "carries rules, not
structure", and a six-line list of target names is the most likely thing in
the file to be stale in three months. A middle option is to keep only the
two sentences that are *rules* — no SwiftUI below the app target, and the
canvas runtime does not depend on the store — and let `project.yml` carry
the graph, which it does with its reasons attached.

## What the link graph actually bought, and what it did not

Item 8 promised "a target that does not link SwiftUI cannot import it."
**That sentence is false as written, and finding out is the load-bearing
result of this item.** Swift autolinks an imported system framework and the
linker finds it in the SDK, so a framework target that lists SwiftUI nowhere
still builds when a file imports it. Absence of a link edge forbids nothing.

The ban is therefore explicit: every framework target compiles with
`-module-alias SwiftUI=TuberSwiftUIIsNotBelowTheAppTarget`, so `import
SwiftUI` resolves to a module that does not exist. Planted in
`Modules/TuberCanvas/InkCanvasView.swift`:

```text
Modules/TuberCanvas/InkCanvasView.swift:1:8: error: unable to resolve
module dependency: 'TuberSwiftUIIsNotBelowTheAppTarget'
** BUILD FAILED **
```

Only SwiftUI can be banned this way. Aliasing `UIKit` breaks PencilKit's
transitive load ("missing required modules: 'UIKit'"), and aliasing
`CoreGraphics` breaks Foundation's ("missing required module
'CoreGraphics'"). So UIKit, PencilKit, and CoreGraphics remain a
`ContractStructureTests` rule — but per module rather than per file, which
is the improvement that survives regardless: there is no longer any path in
an allowlist to go stale, and a file's permissions are a property of where
it lives.

Said honestly, as item 8 asked: the split buys the *import* half of golden
rule 2 for SwiftUI only, and turns the other three frameworks from a
23-entry path allowlist into a 6-entry module table. A SwiftUI view in the
app target mirroring state it shouldn't (`RootCanvasView.@State shapeKind`,
stage 1 item 4) is still review territory.

## A smaller thing, decided in code and recorded here

`DocumentStore.PageSaveRefusal` moved out of the store to sit beside
`DocumentStoring`, with `PageRefusal`. 07-StoreSeam.md flagged the choice:
either the refusal moves down with the vocabulary or the app imports the
store to name it. It moved, because the protocol's own doc comment promises
the refusal and a substitute store has to be able to throw it — naming the
one implementation to name a value the protocol speaks is exactly the
coupling the seam exists to remove. The reason is at the type.

`LoadedPage`, `AssetRef`, and the envelope were already top-level in what is
now TuberModel and did not move. `PageWrite` is in TuberStore with the page
form it describes.

## Open, and deliberately not decided here

- Whether a thin store-protocol module (07's "sixth target") is worth it, so
  that TuberRender depends on a surface rather than on TuberStore's build.
  It is not needed for anything today and would be five targets of graph for
  one protocol; left alone under "smallest change that proves the item".
- The `#if TN_SPIKE_MIRROR` hooks are still in `PageCanvasController`, and
  `SpikeMirrorFidelity.swift` moved into TuberCanvas with them. That is item
  12's problem, unchanged by this one.
