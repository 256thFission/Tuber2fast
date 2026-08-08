# Proposed: the store seam, and what the contract should say about it

Stage 2 item 7 of [`CanvasCompleteTodo.md`](../CanvasCompleteTodo.md). The
code has landed; this file holds only the part that is **Phillip's to
decide** — whether `Docs/Contract.md` mentions any of it. Nothing here is in
force, and nothing here was written into `Contract.md`.

---

## What landed

`DocumentStoring` (`TuberNotesApp/DocumentStoring.swift`) — the store's
surface as `EditorSession` and `StaticLayerRenderer` actually consume it:

```text
load() -> DocumentIndex?
loadPage(_ pageID: UUID) -> LoadedPage
save(index: DocumentIndex, pages: [PageWrite])
writeAsset(_ bytes: Data, assetID: UUID, format: AssetFormat)
loadAsset(assetID: UUID, format: AssetFormat) -> Data
deleteLayerFileIfUnreferenced(layerID: UUID) -> Bool
deleteAssetIfUnreferenced(assetID: UUID, format: AssetFormat) -> Bool
```

All `async throws`; `save(index:changedPages:)` is a protocol extension over
the one `save`, not a second capability. `DocumentStore` is the only
conformance, constructed where it always was, in `EditorLifecycle`.

## The question for the contract

*Owners* says durable state has one writer and names `DocumentStore` as it.
The protocol does not change that — one conformance, one construction site —
but it does make "the store" nameable as a role rather than as a class, and
the module split (item 8) will make the distinction load-bearing.

Three options, in the order this agent would rank them:

1. **Say nothing.** The rule is about who *writes*, and a protocol with one
   conformance writes nothing. `Contract.md` gains no sentence, and the code
   comment at the protocol carries the why. This is the smallest honest
   answer and the one that matches "the contract carries rules, not
   structure."
2. **One clause in *Owners*.** After "`DocumentStore` receives immutable
   values and never reaches into a canvas", add that consumers *declare* the
   store by its consumed surface and that substituting it is a test
   affordance, never a second writer. Worth it only if a reviewer would
   otherwise read the protocol as permission for a second store.
3. **A rule that the surface is closed** — new capability, new
   `CONTRACT:` amendment, mirroring *Durable form*'s closed set of layer
   kinds. This is the strongest and the most likely to be wrong now: the
   surface is still moving (item 10's runtime seam, item 8's modules).

A related decision the split will force, recorded here so it is not
discovered inside item 8: `LoadedPage`, `PageWrite`, `AssetRef`, and
`DocumentStore.PageSaveRefusal` are the vocabulary the protocol speaks.
The first three are already top-level durable-form types; the refusal is
nested in `DocumentStore` and is caught by type in `EditorSession`. If the
store becomes its own module, either the refusal moves down with the
vocabulary or the app target keeps importing the store to name it.

## What the seam has already paid for

Recorded because it is the argument for the shape, not to claim a rule:

- `EditorSession.serializationDelayForTesting` — a **suspension point on the
  production save path**, shipped in every configuration — is gone. The three
  tests that needed a save held open now hold it with a store that does not
  return (`TuberNotesTests/HeldSaveStore.swift`), which is both stronger (the
  hold is indefinite rather than a 200 ms race against the assertions) and
  outside the session entirely.
- The other production-path suspension, `StaticLayerRenderer`'s render gate,
  is **not** retired, and the seam is why: the gate keys on the *request*,
  which is the renderer's vocabulary and invisible at the store.
  `inFlightDedupIsTransformAware` releases two renders of the same layer —
  and so of the same asset — in a chosen order, which a store-level gate
  cannot express. It is `#if DEBUG` instead, so no Release path can be
  suspended by it.

## For item 8

- The renderer holds the store, so `TuberRender` depends on `TuberStore`;
  the protocol makes that a dependency on a *surface*, and a thin
  store-protocol module would let the renderer stop depending on the
  implementation. Whether that is worth a sixth target is the open question.
- `PagedCanvasController` is named in item 7's text as a third store
  consumer. It is not one — it holds a `StaticLayerRenderer`. The canvas
  runtime never sees the store, which is a cleaner cut than the plan
  assumed.
- The suite still has seven near-copies of a `waitUntil` poll helper. Same
  species as the twelve `Scratch` copies, not fixed here; a shared one
  belongs wherever the test-support files end up when the targets move.
