# Review: `canvas-feature-complete` — corrected and rescoped

This replaces an earlier review of the same branch. Every claim below was
re-checked against the source; where the earlier verdict did not survive that
check, the correction is stated with its evidence rather than quietly dropped.
Line references are against `f8a06df`.

**Scope — two prerogatives, both first-class:**

1. **Defects** — states the code can reach that lose a document, crash, or
   misbehave under the hand.
2. **Legibility and maintainability** — whether a future engineer can read this
   and change it safely. This is *not* subordinate to "smallest change that
   proves the queue item," which governs how a queue item is closed, not how
   much complexity the codebase may accrete while closing them.

**Two method corrections, which move several verdicts:**

- The earlier review asserted a crash path without checking whether it was
  guarded. It was, 130 lines away in a file it had open. Nothing here is ranked
  on plausibility; a defect is listed only with its reachable route named.
- **Complexity findings are not graded against today's numbers.** The corpus in
  hand — ~4 cached composites, one 20,000-stroke page, a few layers — is not a
  representative stress test. A GoodNotes-parity notebook is a scanned 50-page
  PDF with photos and clippings on a page. "Cheap at current scale" describes
  the test corpus, not the code, and it is the argument that keeps an O(n²) alive
  until the first real document meets it.

---

## Part 1 — Defects

### 1. A legal PDF can brick a document permanently

`PageCanvasController.establishZoomIfNeeded` — PageCanvasController.swift:480-485

```swift
precondition(
    CGFloat(ceiling) >= fitWidth,
    "page \(geometry.width)x\(geometry.height) is smaller than the "
        + "document's zoom cap allows: …"
)
```

The arithmetic: the canonical cap is `1/20` page points per pixel
(DocumentIndex.swift:126), so `maximumZoomScale` at 2× is exactly `10`.
`fitWidth` is `viewport.width / geometry.width`. On an ~820-point viewport this
trips for any page narrower than **~83 points — about 1.1 inches**.

Nothing refuses such a page. `PageGeometry.isValid` (PageGeometry.swift:37-39)
checks only *finite and greater than zero*, so `DocumentIndex.validated()`
accepts it. Import takes the source's box verbatim (EditorSession.swift:1416)
and sets `indexDirty` (EditorSession.swift:1442) — **the geometry is durable
before any canvas lays out**.

So: import a receipt, a ticket, a business card, a cropped figure → the page is
written → the first layout pass traps → **the document crashes on open, every
launch, with no way back in.** No corruption and no hand-editing required; a
legal PDF is enough.

The comment at PageCanvasController.swift:479 says such a page is "a page this
build refuses rather than rounds." **That sentence is the second defect.** The
build does not refuse it — it accepts it, persists it, then traps. A comment
asserting a guarantee no code provides is worse than no comment: the next
engineer reads it and stops looking for the check.

*Fix shape.* A minimum page width derived from `runtimeMaximumZoomScale`, stated
beside `finestReachablePagePointsPerPixel` (PageGeometry.swift:118) where the
sibling limit already lives, enforced at import with a named error before
anything is written. `validated()` cannot do it alone — it has no viewport — so
what has to be shared is the constant, not the check.

### 2. Synchronous ink decode on the settle path, now five pages deep

`PagedCanvasController.makeSlot` — PagedCanvasController.swift:457-472
(already a `KNOWN DEFECT`)

`try PKDrawing(data:)` runs synchronously on the main actor, reached from the
settle callbacks through `refreshWindow`. **This got worse on 2026-08-07 and the
change is mine**: raising `windowRadius` from 1 to 2 took the worst-case flick
from 3 newly-built slots to 5. The `KNOWN DEFECT` block predates that and now
understates it.

The block has said "unmeasured" since it was written, and the window grew
underneath it without anyone re-asking. That is the failure mode of a `KNOWN
DEFECT` block: it converts an open question into a settled one.

*Fix shape.* Measure first, against a representative page — the heaviest measured
is 20,000 strokes / 4.6 MB, and the settle path can now decode **five** of those
in one pass. If it hitches, decode off-main and install on arrival; the
`.retained` path already proves a canvas can take a drawing after construction.

### 3. `appendPage` makes trailing pages durable immediately

`EditorSession.appendPage` — EditorSession.swift:822-833 (already a `KNOWN DEFECT`)

An appended page is held with empty bytes and written on the next pass;
`DocumentStore.save` has no emptiness check. An accidental swipe past the last
page **permanently grows the document**, and nothing reclaims it.

The block calls this "a knowing divergence" and says the contract is the side
that is right. A divergence the code itself judges wrong is a defect with a note
attached, not a resolved question — and this is something a person does by
accident, repeatedly.

*Fix shape.* Defer durability to first ink, which is *Empty trailing pages* as
written; or drop never-inked trailing pages at save. The first is the contract's
shape, the second is smaller.

### 4. `changedStaticLayers` is O(n²) behind a getter that reads free

`EditorSession.Page.changedStaticLayers` — EditorSession.swift:102-104

```swift
var changedStaticLayers: [LayerEnvelope] {
    staticLayers.filter { !savedStaticLayers.contains($0) }
}
```

`Array.contains` on a value type is a linear scan, so this is quadratic in the
page's layer count, and it runs in `beginSave` for every dirty page on every save
pass (EditorSession.swift:1040). The save path is debounced, so it fires on
every edit. `LayerEnvelope` is a synthesized `Equatable` over `layerID`, `kind`,
`payload: Data`, `pageSpaceTransform` and `locked` (LayerEnvelope.swift:200-220),
so each comparison includes a buffer compare — a small one, since the payload is
an encoded asset ref rather than image bytes, but paid n² times.

Two things make this worth fixing regardless of corpus:

- **The cost scales with the thing the layer split was built to enable.** Many
  layers per page is the feature; this is the loop that punishes it.
- **It is a computed property.** Nothing at the call site suggests a cost, so the
  next person to need it inside a loop will put it there. A getter that looks
  free must be free — that is a legibility rule, not a performance one.

*Fix shape.* Hold saved layers as `[UUID: LayerEnvelope]` and write
`staticLayers.filter { saved[$0.layerID] != $0 }` — O(n), with exactly one value
comparison per layer. Note the call site immediately maps the result to
`Set<...layerID>`, so nothing downstream needs the envelopes at all.

### 5. `trimToByteBound` makes the backstop the most expensive path in the cache

`StaticLayerRenderer.trimToByteBound` — StaticLayerRenderer.swift:562-575

`cache.sorted(by:)` allocates a full copy of every entry on every `remember` that
exceeds the bound, on the render actor's hot path, usually to evict one entry.

The framing that matters: **the bound is a backstop.** The design intent is that
the cache sits under it most of the time — which means the sort fires precisely
when the system is already under pressure, e.g. a prefetch warm pushing the cache
over. The rarest path is the most expensive one, and it runs at the worst moment.

*Fix shape.* A tracked LRU list or a min-heap: O(log n) eviction, no array
allocation, and eviction policy that reads as LRU instead of being inferred from
a sort predicate.

### 6. `lastSerializeDuration` measures the wrong quantity, twice

`EditorSession.adaptiveDebounce` — EditorSession.swift:951-960 (already two
`KNOWN DEFECT` blocks)

The duration **sums across every dirty page**, so the debounce widens with *how
many pages changed* rather than with what writing one page costs; a save of only
restored pages records zero and discards the previous warm measurement.
Separately it is **warm-only** — it starts at zero, so the first save of a session
gets no backoff. Measured 126 ms cold against 48 ms warm: the save most likely to
be interrupted by backgrounding is the one systematically under-estimated.

Both halves compound under exactly the load nobody has run — five dirty pages of
real ink.

*Fix shape.* Record the per-page maximum, not the sum. Seed the cold value from a
constant or the previous session's measurement.

### 7. Zoom dies with the retired controller

`PageCanvasController` — PageCanvasController.swift:424-431 (already a `KNOWN DEFECT`)

A page retired from the live window is released with no zoom saved, so turning
back rebuilds it at fit-width while pages still inside the window keep their
scale. **The window change made this less predictable, not more**: zoom now
survives two turns and then resets, so the boundary sits further from the hand
and is harder to learn.

*Not a code decision.* Whether zoom should persist across a turn is a feel
question and Phillip's. Mixed geometry sharpens it: a shared *scale* across pages
of different sizes means a turn changes how much of the page you see. **Evidence
recorded; verdict left.**

### 8. `MainActor.assumeIsolated` in the undo handler is unexercised

`PageCanvasController.commitLayerTransform` — PageCanvasController.swift:1074-1083

The comment asserts undo arrives on the main thread via the responder chain, which
is almost certainly true: `UndoManager` invokes handlers on whichever thread
called `undo()`, and the responder chain is main. `Unproven.md` is right that it
has never been checked on a device, and `undoManager` is `nil` for an unhosted
controller, so no test reaches it either.

The earlier review called a wrong assumption here "undefined behavior." It is
not — `assumeIsolated` is a documented runtime trap. The concern is real; the
consequence was overstated.

*Fix shape.* None to the code. **One device session** — move a layer, undo, redo —
converts this from unproven to proven, and that is the whole cost.

---

## Part 2 — Maintainability

The earlier review listed five structural complaints as forward risk. Three of
them are not independent complaints. **They are one root cause and its symptoms**,
and naming it that way is what makes the work tractable instead of a refactor with
no end condition.

### 9. One missing seam is generating the test suite's entire shape

`EditorSession` constructs its collaborators concretely and inline —
`DocumentStore`, `StaticLayerRenderer`, `PagedCanvasController`
(EditorSession.swift:399-410). There is no protocol between the session and
anything it depends on. Everything below follows from that:

| Symptom | Verified count | Why the missing seam causes it |
|---|---|---|
| `Scratch` temp-directory helper classes | **11 copies** | A test cannot substitute a store, so every suite builds a real one on real disk |
| `Task.sleep` timing assertions | **26, across 10 files** | A test cannot control the store's clock, so it waits out the real one |
| `…ForTesting` declarations in the app target | **15** across 6 files (21 mentions incl. comments) | A test cannot observe through a seam, so the production type grows an observation point |

Each was reported as its own bullet with its own cleanup. Doing them as three
separate cleanups leaves the cause in place and the counts grow back.

The seam is in fact **already there, in disguise**:
`StaticLayerRenderer.setRenderGateForTesting` (StaticLayerRenderer.swift:91-93) is
a mutable injection point on a production actor, built for tests, spelled so it
cannot be mistaken for API. That is an admission that the dependency wants to be
substitutable; it simply was not given a type.

The direct cost of the 15 backdoors is that they are **permanently shipping app
API**, all `internal` — nothing but discipline stops production code from using
them, and two of them can *suspend* a production path:
`EditorSession.serializationDelayForTesting` (EditorSession.swift:486) is awaited
as a `Task.sleep` on the save path, and `setRenderGateForTesting` is an awaited
arbitrary closure inside the render path.
`EditorSession.staticRendererForTesting` (EditorSession.swift:337) and
`PageBackdrop`'s four `CALayer` accessors let tests couple to implementation —
which is how a suite ends up preventing the refactors it exists to protect.

*Fix shape, in this order — each step makes the next smaller.* A protocol for the
store first; it is what most of the `Scratch` helpers and sleeps work around. Then
one shared `TestScratch` for the tests that genuinely need disk. Then a controlled
clock, which retires most of the 26 sleeps. Then `@_spi(Testing)` or `#if DEBUG`
for whatever backdoors survive, so they stop being shipping API.

### 10. Spike instrumentation woven through the production controller

Nine `#if TN_SPIKE_MIRROR` sites in `PageCanvasController`, plus `#if TN_SPIKE_LENS`
in TuberNotesApp.swift:12. They compile out and the flag-off build is green, so
this is not a defect — it is a **legibility cost paid on every future edit** to the
two hottest files in the project, including near the layout and PencilKit delegate
paths.

What makes it actionable now rather than eventually: **the spikes have no
verdicts.** Spikes 1 and 2 await device evidence and spike 3 was never built.
Dead-by-default code with no owner and no end condition is the definition of what
accretes. Either the spikes get their verdicts and the hooks come out, or the hooks
come out now and `Spike*.swift` keeps its own copies.

### 11. Two files carry most of the project's responsibilities

`EditorSession.swift` (**1,797 lines**) and `PageCanvasController.swift`
(**1,263 lines**), with `DocumentStore.swift` at 949 and `StaticLayerRenderer.swift`
at 884 behind them.

This one deserves the most caution, because "split the big file" applies to every
big file and therefore carries little information. Two things make it specific
here:

- The `Page.Ink` state machine (EditorSession.swift:108-144) is the best-designed
  thing on the branch, and it is nested inside the largest file where nothing
  signals that it is the load-bearing part. It should be extractable
  **unchanged** — which is also the test of whether a split is real or cosmetic.
- The size is what forces #9. A type with twelve reasons to change is hard to give
  seams to, and the missing seams are what shaped the test suite.

*Fix shape.* Extract `Page` / `Page.Ink` verbatim into its own file first — the
smallest possible move, and it makes the state machine legible as the centrepiece
it is. Judge the larger splits (`SaveCoordinator`, `ImportPipeline`) **after** the
store protocol exists: the seam will show where the real boundaries are, and
guessing at them first is how a refactor produces five files that all still know
about each other.

---

## Part 3 — Rejected, with evidence

**"`preconditionFailure` in the hit test crashes on a touch"** —
LayerEnvelope.swift:127-135. The claimed route does not exist. There are exactly
two callers of `containsUnitSquarePoint` and both are guarded:

- Durable layers are refused at load — DocumentStore.swift:458 and :474 both
  `guard envelope.pageSpaceTransform.isInvertible`.
- Gesture candidates are refused per frame — LayerSelectionRuntime.swift:343,
  `guard let candidate = …, candidate.isInvertible else { return }`.

The premise was that "the `precondition` guards the commit, not the frame-by-frame
preview." The preview guard is line 343 of a file the review cites elsewhere. The
`preconditionFailure` stands as written, and LayerEnvelope.swift:97-101 already
explains why `inverted` returns `nil` while the hit test traps.

**"Verified correct — no bugs found."** The earlier clean bill of health for the
save path, the state machine, the write order and the `[weak self]` audit is **not
carried forward, in either direction.** It states conclusions with no stated
method, and the same document asserted a crash in a guarded path. Those areas
should be treated as *unreviewed*, not as cleared. If they are worth clearing they
are worth clearing with the route named, which is the standard the rest of this
document is held to.

---

## Order of work

Grouped by what each stage buys.

**Stage 1 — stop the bleeding.**
1. **#1**, the sub-83-point page. The only item that destroys a document with no
   recovery. Fix the comment at the same time.
2. **#3**, `appendPage` durability. Reachable by accident, and it accumulates.

**Stage 2 — cheap, and they remove a misleading read.**
3. **#4**, the O(n²) dirty check. Roughly a one-line change; the reason is the
   free-looking getter as much as the cost.
4. **#5**, the cache trim. Makes the backstop stop being the expensive path.
5. **#6**, per-page maximum instead of sum; seed the cold value.

**Stage 3 — close the measurement gaps before they compound.**
6. **#2**, settle-path decode: *measure* against five heavy pages, then decide.
7. **#8**, one device session to prove or disprove the undo isolation.

**Stage 4 — the structural work, in dependency order.** This is where the
compounding cost actually is, and the order matters more than the items.
8. **#9**, the store protocol → one `TestScratch` → controlled clock → demote the
   21 backdoors.
9. **#11**, extract `Page` / `Page.Ink` verbatim. Hold the larger splits until #9's
   seam shows where they belong.
10. **#10**, spike hooks out of `PageCanvasController`, gated on the spikes getting
    their verdicts.

**Not scheduled — Phillip's verdict.**
- **#7**, whether zoom survives a page turn. Evidence recorded; the call is a feel
  question, sharpened rather than settled by mixed geometry.
