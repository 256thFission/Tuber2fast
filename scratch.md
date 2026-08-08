# Review: `canvas-feature-complete`

Critical code review, focused on actual defects. Build verified green:
`xcodegen generate` + `xcodebuild build-for-testing` on the pinned
`iPad Pro 11-inch (M5)` simulator, exit 0. ~26.6k insertions vs `main`;
24 app files (~10.2k LOC), 20 test files (~10.5k LOC).

Scope: this report covers **code defects and forward-risk**, not the
contract-adoption workflow, which is the maintainer's process and working
as designed.

---

## Real defects

### 1. Crash on a hit-test path — `preconditionFailure` on a touch

`LayerEnvelope.swift:127-135`

```swift
func containsUnitSquarePoint(x: Double, y: Double) -> Bool {
    guard let inverse = inverted else {
        preconditionFailure(
            "a singular transform reached a hit test; a layer with one is refused at load"
        )
    }
```

A hit test is an interaction path. The comment argues this is unreachable
because singular transforms are refused at load — but `transformLayer`
(`EditorSession.swift:1503-1506`) itself frames a singular transform
arriving at the session as "a defect in a caller," i.e. it is a possible
bug, not an impossibility. The `precondition` there guards the *commit*,
not the frame-by-frame *preview*. If the gesture handler ever produces a
singular transform during a drag, the app crashes on finger-down. "Fail
loud" on an interaction path means a crash on a touch. Return `false` and
log; the loud failure belongs at the site that produced the singular
transform, not at the hit test.

### 2. Crash on a layout path — `precondition` in `viewDidLayoutSubviews`

`PageCanvasController.swift:440-445`

```swift
precondition(
    CGFloat(ceiling) >= fitWidth,
    "page \(geometry.width)x\(geometry.height) is smaller than the "
        + "document's zoom cap allows: its fit-width scale "
        + "\(fitWidth) is past the ceiling \(ceiling)"
)
```

This runs inside `establishZoomIfNeeded()`, called from
`viewDidLayoutSubviews`. A page whose geometry does not fit the zoom
ceiling crashes the app during layout — not at page creation, not at
import, but on the first layout pass. A document loaded from disk with
bad geometry (corrupted or hand-edited index) would crash on every
launch. Geometry validation belongs at the `DocumentIndex.validated()`
seam, not at layout time. (A second `precondition` at lines 458-464 has
the same shape.)

### 3. `MainActor.assumeIsolated` in an undo callback — unverified thread assumption

`PageCanvasController.swift:1072-1083`

```swift
undoManager.registerUndo(withTarget: self) { controller in
    MainActor.assumeIsolated {
        controller.commitLayerTransform(layerID, from: committed, to: previous)
    }
}
```

The comment asserts undo is invoked from the main thread by the responder
chain. `Unproven.md` states layer-edit undo has never been checked on a
device and `undoManager` is `nil` for an unhosted controller, so this has
never been exercised. `assumeIsolated` is a runtime trap if the assumption
is wrong — an assertion, not a hop. If PencilKit's responder chain ever
invokes undo off-main, this is undefined behavior rather than a graceful
failure.

### 4. `trimToByteBound` sorts the entire cache on every insert

`StaticLayerRenderer.swift:557-575`

```swift
private func trimToByteBound(protecting key: CompositeKey) {
    guard cachedBytes > byteBound else { return }
    for candidate in cache.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
```

`cache.sorted(by:)` is O(n log n) and allocates a full array copy of every
entry, on every `remember` call that exceeds the bound. `remember` runs on
every composite completion — the render actor's hot path. Today the cache
holds ~4 composites (96 MB bound, ~22 MB each) so the absolute cost is
small, but the sort runs on every insert once the bound is reached even
when only one entry needs evicting. A tracked LRU list or a min-heap makes
eviction O(log n) instead of O(n log n) per insert.

### 5. `changedStaticLayers` is O(n²) per page, per save pass

`EditorSession.swift:102-104`

```swift
var changedStaticLayers: [LayerEnvelope] {
    staticLayers.filter { !savedStaticLayers.contains($0) }
}
```

`Array.contains` on `LayerEnvelope` is a linear scan (value equality). This
is quadratic in the page's layer count and is called in `beginSave` for
every page on every save pass (line 1040). A page with 50 image layers does
~2,500 comparisons per save. A `Set<LayerEnvelope>` (or a `Set<UUID>` of
saved layer IDs) makes this O(n).

### 6. `appendPage` makes trailing pages durable immediately

`EditorSession.swift:825-830` (already a KNOWN DEFECT)

An appended page is saved with empty bytes immediately, so an accidental
swipe past the last page permanently grows the document. The contract says
the trailing page's durability is decided by *Empty trailing pages*; the
code makes it durable on append, before any ink. The comment calls it a
"knowing divergence" and says the contract side is right. It is still a
defect a user will hit.

### 7. Synchronous `PKDrawing(data:)` decode on the main thread at settle

`PagedCanvasController.swift:457-472` (already a KNOWN DEFECT)

The settle path (`scrollViewDidEndDecelerating` → `settle()` →
`refreshWindow()` → `makeSlot()`) does `try PKDrawing(data: data)`
synchronously on the main actor. A fast multi-page flick is an interaction
path; the settle moved the decode off the drag itself, but at rest it is
still synchronous main-thread decode. For a page with heavy ink this is a
visible hitch on the landing page. This is the one genuine bend of the
"nothing synchronous on interaction paths" rule.

### 8. `lastSerializeDuration` measurement defects

`EditorSession.swift:942-953` (already two KNOWN DEFECTs)

The duration sums across every dirty page, so the debounce grows with how
many pages changed rather than with what writing one page costs; and it
starts at zero so the first save of a session gets no backoff. Measured at
126 ms cold vs 48 ms warm — the first save after launch, the one most
likely to be interrupted by backgrounding, is systematically
under-estimated.

### 9. Spike instrumentation threaded through the production controller

`PageCanvasController.swift` — 8 `#if TN_SPIKE_MIRROR` blocks at lines
184, 271, 339, 1164, 1179, 1188, 1198, 1206; plus `#if TN_SPIKE_LENS` in
`TuberNotesApp.swift:12`.

The spike hooks are not isolated to the `Spike*.swift` files — they are
woven through `PageCanvasController` at eight sites, including near the
layout and PencilKit delegate paths. They compile out by default (verified:
the flag-off build is green), but every edit to those methods must thread
around the `#if` blocks, and the Release configuration carries the
`$(TN_SPIKE_CONDITIONS)` hook. The spike results belong in `Docs/Forks/`
or a commit message; the `#if` blocks should come out of the production
controller.

### 10. Zoom dies with the controller — inconsistent zoom across a turn

`PageCanvasController.swift:384-391` (already a KNOWN DEFECT)

A page retired from the live window is released with no zoom saved, so
turning back rebuilds it at fit-width, while pages still inside the window
keep their scale. Zoom behavior differs by how far the user scrolled. Not a
data bug, but a real feel bug.

---

## Forward-risk hotspots (not bugs today, will hurt as it grows)

These are the places where continuing to add features without a split will
accelerate into unmaintainability.

- **`EditorSession.swift` (1788 lines, 12+ responsibilities)** — lifecycle,
  page order, ink custody, layer-list authority, save orchestration, asset
  reclamation, import pipeline, runtime ownership, render coordination,
  content bridging, cache policy, lifecycle hooks, tool forwarding. The
  nested `Page.Ink` state machine (lines 108-144) is well-designed and
  should be extracted as-is; everything around it has no protocol seams
  (concrete `DocumentStore`, `StaticLayerRenderer`, `PagedCanvasController`
  constructed inline at lines 401/410/399). Natural splits: `PageState`,
  `SaveCoordinator`, `ImportPipeline`, `LayerMutationService`, `CachePolicy`.
- **`PageCanvasController.swift` (1211 lines, 11 responsibilities)** —
  canvas lifecycle, zoom/geometry, static-layer rendering, lens rendering,
  shape-tool commit, selection/transform, drawing transfer, PencilKit
  delegate, page-boundary decoration, retirement, test hooks. Split into
  Zoom/Backdrop/Lens/ShapeTool/Selection coordinators, leaving the
  controller as orchestrator + delegate.
- **`StaticLayerRenderer.swift` (884 lines, 4 concerns)** — cache management,
  in-flight dedup, orchestration, and ~680 lines of compositing in one
  actor. Extract `RenderCache`, `RenderRequestDeduplicator`, `LayerCompositor`.
- **Test-only backdoors as public API** — 16 `…ForTesting` declarations
  across the app target (e.g. `EditorSession.staticRendererForTesting` at
  line 337, `StaticLayerRenderer.setRenderGateForTesting` at line 93 — a
  mutable injection point on the renderer actor, and `PageBackdrop`'s
  private `CALayer`s). These widen the production API permanently and let
  tests couple to implementation. Use `@_spi(Testing)` or `#if DEBUG`
  accessors instead.
- **Test-suite duplication and fragility** — 11 duplicate `Scratch`
  temp-directory helper classes (verified) and 26 `Task.sleep`-based timing
  assertions across the suite. One format change touches 11 files; the
  sleeps are flaky on fast/slow runners. Extract one shared
  `TestScratch` helper and replace sleeps with a mock clock or version
  counter.

---

## Verified correct (no bugs found)

The save path and the state machine are the strongest parts of the branch.
Checked and found sound:

- **Save state machine** — `Page.Ink` transitions, `beginSave` capture,
  `performOneSave` acknowledge/refuse/retry. Capture is total; the
  generation is coherent; `saveSucceeded` clears `layersUnsaved` only if
  the list did not change during the save; `saveFailed` preserves held
  bytes without double-encoding.
- **Write order** — assets → layer files → page files → index, enforced at
  the store, not just by caller discipline. `plan(for:)` refuses a save
  that would name a missing asset; the index is withheld when a refused
  page has no file on disk.
- **`refuseIfThisWriteWouldDropAnUnrewritableLayer`** — reads the actual
  on-disk page file, not an in-memory record, so it holds for every store
  instance; a dropped layer is checked against the file, not a stale cache.
- **`reloadPage` guard** — only rebuilds placeholders, never canvases, so
  it cannot overwrite ink drawn since the last load.
- **Retirement handover** — `retired(handingOver:)` is synchronous before
  release, so unsaved ink is preserved when a page leaves the live window.
- **`evicted()`** — drops only the `durable` cache, never the held
  `UnsavedInk` payload; a `.held` page with `durable = nil` still rebuilds
  correctly from its held bytes.
- **Composite in-flight dedup** — a superseded render answers its own
  awaiters but is not cached, so a stale transform cannot park under a key
  forever.
- **`writeAsset` write-once** — real enforcement: the actor serializes
  calls, and the `fileExists` check plus `AssetError.assetAlreadyExists`
  prevents overwrites.
- **Off-main-thread discipline in the heavy paths** — PDF rasterization is
  `nonisolated async` (`PDFSource.swift:55-96`), serialization is awaited
  off the PencilKit callback, asset writes are async. `DocumentStore` and
  `StaticLayerRenderer` are actors (off main by construction);
  `EditorSession`, both controllers, and the views are `@MainActor`.
- **`[weak self]`** used consistently in every closure/Task; no retain
  cycles found.

---

## Priority order

1. Fix the crash-on-touch hit-test precondition (#1) and the crash-on-layout
   geometry preconditions (#2) — real crash vectors on interaction/layout
   paths.
2. Resolve the `MainActor.assumeIsolated` undo assumption (#3) — get device
   evidence or make it a real hop.
3. Move the synchronous `PKDrawing` decode off the settle path (#7).
4. Address the `appendPage` durability defect (#6) and the
   `lastSerializeDuration` measurement (#8).
5. Remove the spike `#if` blocks from the production controller (#9).
6. Fix the O(n²) dirty check (#5) and the O(n log n) cache sort (#4) before
   page/layer counts grow.
7. Then the structural splits (EditorSession / PageCanvasController /
   StaticLayerRenderer) and the test-only backdoor / test-duplication
   cleanup.
