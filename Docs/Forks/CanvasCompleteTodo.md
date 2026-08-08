# Canvas complete — the todo, ordered for co-maintainers

Status: active plan, revision 2 — the first draft was adversarially reviewed
and every finding that survived checking is folded in. Supersedes the *order
of work* in `scratch.md` and the fix-status ordering in
[`ReviewFindings.md`](ReviewFindings.md). Those documents remain the
evidence; this one is the sequence.

**Why this ordering exists.** Three co-contributors are about to join. The
premise of this plan: **whatever the codebase looks like on the day they
arrive is what it will look like forever.** A contributor who reads a
contract that lies learns not to read the contract. A contributor who copies
an 1,800-line session class produces a second one. A contributor who finds
twelve copies of a `Scratch` helper writes the thirteenth. So the order is
not severity order — it is: make the *rules* true, then make the *structure*
teach the right thing, and only then burn down the correctness list, which by
that point lands in code that can absorb fixes legibly.

Provenance and grade: every item traces to one of three reviews — the
corrected defect review (`scratch.md`), the six-lane adversarial review
([`ReviewFindings.md`](ReviewFindings.md)), or the architectural review of
2026-08-07 — and this document itself was then reviewed the same way. Line
references are against `f8a06df` and drift as the code does.

---

## Parallel track — infrastructure that never waits on code

These touch no application code, so they run alongside every stage rather
than after them — and the doors-open premise makes them urgent, not last:
four people cannot share a repository whose home is undecided and whose
verdict is decorative.

- ~~**Settle where the repository lives.**~~ Settled: `Tuber2fast` is the
  home, and the work is pushed there.
- ~~**`prove-ci`**~~ — done to green and to red; the red run put a readable
  assertion on the run page. What survives is not mechanical: the exit says
  *a PR from a fork* and the repository is private. Queue.md carries it.
- ~~**`branch-protection`**~~ — applied to `main`: required check, one
  approving review, administrators included. Note that `main` is far behind
  this branch, so these rules are first met by whoever merges it.
- **`tooling-review`** — one real defect found and fixed (`Tools/machines`
  blamed a healthy Mac on a clean clone); the review and the questions left
  for Phillip are in
  [`ContractPass/00-ToolingReview.md`](ContractPass/00-ToolingReview.md). Its
  exit needs a person who is not Phillip and is not an agent's to close.
- **`device-branch-builds`** follows as Queue.md sequences it — untouched,
  still waiting on the Apple and Firebase setup.

---

## Stage 0 — exceptions that do not wait for the plan

1. **The sub-83-point page bricks a document on import.** The one defect
   that destroys a document with no recovery, and its guard is hours of
   work. `PageCanvasController.establishZoomIfNeeded` traps
   (PageCanvasController.swift:480-485) for any page narrower than
   `viewport / runtimeMaximumZoomScale` ≈ 83 pt, and nothing upstream
   refuses one: `PageGeometry.isValid` checks only finite-and-positive,
   import takes the source box verbatim and persists it before first
   layout. A receipt or a ticket crashes the document on every subsequent
   open. Fix: a minimum page dimension derived from the zoom cap, stated
   beside `finestReachablePagePointsPerPixel` (PageGeometry.swift:118),
   enforced at import with a typed refusal before anything is written.
   Rewrite the comment at PageCanvasController.swift:474-479 in the same
   commit — "a page this build refuses rather than rounds" names the trap
   on the next line, and a trap is a crash, not a refusal; which of the
   two it *should* be is exactly a stage-1 taxonomy question.

2. **A width change misdisplays the current page; the next gesture writes
   the wrong index durably.** `PagedCanvasController` handles no viewport
   change — no `viewWillTransition`, no trait hook. Stated precisely,
   because the first draft overstated it: a resize alone writes nothing;
   it relays out slots at the new width while `contentOffset` stands, so
   the wrong page is *shown*. The durable damage lands on the user's next
   scroll, when `settle()` (PagedCanvasController.swift:596-600) divides
   the stale offset by the new width, rounds to nearest, and the result
   reaches `EditorSession.currentPageChanged` (EditorSession.swift:903),
   which writes `currentPageIndex` durably. A navigation defect, not a
   document-destroyer — it sits in stage 0 because the honest fix is
   small: rescale `contentOffset` by the width ratio across the bounds
   change, so a resize re-centres the same page. Rotation is already
   pinned to portrait and multi-scene is already off (project.yml), so
   the live routes are Split View / Slide Over single-window resizes.
   `UIRequiresFullScreen` is **not** a verified stopgap: it is deprecated
   under iPadOS 26's windowing model and this target builds against the
   26.0 SDK — do not ship it as the answer without seeing it hold on
   hardware first.

---

## Stage 1 — the contract, made true

Nothing in stage 2 can be reviewed without an authoritative text to review
against, and a co-contributor's first act is reading `Contract.md`. Every
item here is prose plus a decision; almost none is code. All contract edits
are Phillip's to author — agents propose exact wording, per the staging rule
`ImplementationStatus.md` records.

3. **The Saving section is durability-critical and false in two places.**
   Verified 2026-08-07 (and re-verified by this document's own review):
   the one durability-relevant area with *no* staged amendment in
   `Contract.proposed.md`.
   - The contract says "a save that throws is not acknowledged, and its
     pages stay dirty" (Contract.md:139). The code is more subtle and more
     correct: on `DocumentStore.PageSaveRefusal`, **pages the refusal does
     not name were written and are acknowledged clean**
     (EditorSession.swift:1209-1230) — partial acknowledgement under a
     thrown save, tested end-to-end, stated nowhere.
   - The contract's capture pseudocode models one dirty axis. `Page.isDirty`
     has two: ink state *and* `layersUnsaved` (EditorSession.swift:138-144).
   Both rules are first-rank durability semantics living only in the code.
   Given "contract changes are explicit," this is the gap most likely to be
   broken by a well-meaning contributor and least likely to be noticed when
   it is. Write both into *Saving*.

4. **The `Contract.proposed.md` editing pass — the whole file, not just
   A3–A15.** One deliberate sitting: adopt, amend, or refuse every staged
   amendment (A1–A15 *including A6b*), answer the file's own "Open
   questions for Phillip" section, and disposition the A8/A9 correction
   sections — the file is 827 lines and the exit is that none of it is
   load-bearing anymore. Items inside the pass that are decisions rather
   than transcription:
   - **A11 must be rewritten to reality — and the reality has a hole.** A11
     says "a `pdf` or `image` layer is selectable"; the code says image-only
     (LayerEnvelope.swift:297), and the code's own doc comment quotes the
     contract text it contradicts. This is not wording: **selection is the
     only producer of a `layerID` for `deleteLayer`, so a pdf layer can
     never be selected, transformed, or deleted from the UI. A fifty-page
     mis-import is permanent.** Decide which side wins. A11's own rationale
     ("selection is how *replace the worksheet* has a UI path at all")
     argues for the contract side; if image-only stands, a delete path for
     pdf layers must exist some other way. Either answer closes the hole.
     A11's *second* falsity rides along (ReviewFindings #6): "a drag
     beginning anywhere else deselects and falls through" — the recognizer
     fails without deselecting (LayerSelectionRuntime.swift:602-607); only
     a tap deselects. Write the code's behaviour, which is the better side.
   - **The envelope's fifth field.** `locked` is durable, absent decodes as
     `false` (LayerEnvelope.swift:285), and no amendment touches the
     envelope-shape sentence. Bless or strike absent-as-false; amend the
     shape. (ReviewFindings #5, Phillip-deferred.)
   - **A15** widened a machine-checked rule by agent authorship (the
     CoreGraphics ban) — ratify or revert, and note `ImageIO` is absent
     from the widened list its own rationale implies.
   - **A10**'s premise — PencilKit tolerating foreign undo registrations —
     is untested until spike 3; adopt it only with its evidence grade
     marked, or hold it for the spike.
   - The **silent drift** list (ReviewFindings, *Silent drift* section),
     all five: immediate saves bypassing the ink debounce; the composite
     LOD policy; the kind/format cross-check; append-without-navigate; and
     the A9 refusal of coarser-than-1-page-point-per-pixel caps
     (DocumentIndex.swift:275-280), enforced and stated nowhere. Four are
     prose. The fifth drift item is **code, not prose**:
     `RootCanvasView.@State shapeKind` (RootCanvasView.swift:15) holds a
     copy of the tool whose owner is `PagedCanvasController` — the exact
     copy `EditorSession.setShapeTool` refuses to hold, held one level up.
     A one-writer violation; fix it, don't document it.

5. **The failure taxonomy** (`failure-has-a-taxonomy`, Queue.md). The
   classifier — trap / alarm / typed error / event, first answer wins, no
   log-and-continue bucket — needs its `## Failure` section in
   `Contract.md`. Sequenced *here*, ahead of the structural work, because
   stage 2 item 10 (the fail-open closures) has no principled fix without
   it. **This knowingly overrides Queue.md's "*Blocked by:*
   `loud-by-default`"** — Queue.md itself invites that when the ordering no
   longer holds, and it no longer holds for the *authoring* half: the
   classifier and the contract section need no device. Only the
   trap-observation exit (a hand-corrupted page seen refusing on hardware)
   still waits on `loud-by-default`, and it stays in stage 4's device
   backlog. The `try?` ban and `precondition`-never-`assert` ride along.

6. **`image-format-is-heic` — decided, and it belongs in this stage.**
   Phillip overruled the mixed-format design on 2026-08-07 (Queue.md):
   image assets consolidate on HEIC; `AssetFormat` narrows; the *Durable
   form* closed-set line and the small-export comments change meaning.
   The amendment is stage-1 work (a decided rule not yet in the contract —
   exactly what this stage exists to clear); the implementation surface is
   real code and test-fixture churn across `ImageLayerTests`,
   `ImportPreparationTests`, `StaticLayerRenderTests`, and `LensTests` —
   land it **before or with** stage 2's `TestScratch` consolidation so the
   fixtures move once, not twice. Queue.md carries the alpha-round-trip
   pin that must land first; do not discover HEIC's auxiliary-alpha
   behaviour on a device.

**Stage 1 exit:** a new contributor can read `Contract.md` and nothing in
`Contract.proposed.md` is load-bearing. No rule the code enforces is
unstated; no stated rule is false.

---

## Stage 2 — structure: modules, seams, and the megaclass

This is the stage the co-maintainer deadline is really about, and the order
inside it matters more than the items — each step shrinks the next.

7. **The store protocol seam first.** The dependencies are already
   injected — `DocumentStore` is constructed in `EditorLifecycle.swift:29`
   and handed in; the runtime and renderer at EditorSession.swift:353 and
   :502 — but every declaration is a *concrete type*
   (EditorSession.swift:401, :410), so no test can substitute anything.
   That single missing seam is generating the test suite's entire shape:
   **12** copies of a `Scratch` temp-directory helper across 11 files (two
   in `LayerSelectionTests` alone), **26** `Task.sleep` timing assertions
   across 10 files, **15** `…ForTesting` declarations — 14 of them
   internal, shipping as app API, two able to *suspend production paths*
   (`serializationDelayForTesting` is awaited inside `performOneSave` at
   EditorSession.swift:1168-1170; the render gate is awaited inside both
   the composite and lens paths, StaticLayerRenderer.swift:177-179,
   :250-251). Fix order, each making the next smaller: protocol for the
   store → one shared `TestScratch` → a controlled clock (retires most of
   the 26 sleeps) → demote surviving backdoors to `@_spi(Testing)` or
   `#if DEBUG`. Do this **before** the module split: the seam decides
   where the module boundary honestly is.

8. **Modules, not a directory.** `TuberNotesApp/` is one flat target of 26
   files; the import discipline is enforced by `ContractStructureTests`
   token-scanning, whose banned set (`ContractStructureTests.swift:219`)
   deliberately omits SwiftUI — so **golden rule 2's import half (SwiftUI
   never touching ink, pan, zoom, or Pencil state) is machine-checked by
   nothing**, and the allowlist is one flat file-path set across three
   frameworks, so a file allowlisted for CoreGraphics can add
   `import PencilKit` silently. The module split converts the *import*
   half of that rule class from a homemade scanner into the compiler: a
   target that does not link SwiftUI cannot import it. Said honestly, the
   link graph buys only that half — a SwiftUI view in the app target
   mirroring state it shouldn't (the `shapeKind` copy, stage 1 item 4)
   remains scanner-and-review territory.

   Proposed cut, via `project.yml` framework targets. **The first draft's
   version of this cut did not compile; the corrections are the
   instructive part:**
   - **TuberCore** (bottom) — `CanvasLog`. It is imported by the store,
     the renderer, and the snapshot, so it cannot live at the top of the
     graph. Foundation + os only.
   - **TuberModel** — `LayerEnvelope`, `PageGeometry`, `DocumentIndex`,
     `AssetRef`. Foundation + CoreGraphics only. **`DrawingSnapshot` is
     the exception that shapes the graph:** it imports PencilKit — it *is*
     the `PKDrawing` box — and it crosses every seam the plan draws. It
     goes in its own thin **TuberInk** target (PencilKit-linking, above
     TuberModel, below the store), or TuberModel links PencilKit and the
     "no PencilKit ever" claim is dropped. Decide which; do not fudge it.
   - **TuberStore** — `DocumentStore` and the durable-form machinery.
     Depends on TuberModel, TuberInk, TuberCore.
   - **TuberRender** — `StaticLayerRenderer`, `PDFSource`, the lens.
     **Depends on TuberStore** (the renderer holds the store — a real
     edge the first draft omitted). ImageIO + CoreGraphics; **not
     PDFKit** — `PDFSource.swift:22-23` refuses PDFKit by recorded
     decision and uses `CGPDFDocument`; a plan listing PDFKit invites a
     contributor to undo that.
   - **TuberCanvas** — the canvas runtime: `PagedCanvasController`,
     `PageCanvasController`, `InkCanvasView`, `LayerSelectionRuntime`,
     `PageBackdrop`. UIKit + PencilKit; cannot import SwiftUI, by link
     graph.
   - **App target** — `EditorSession`, `EditorLifecycle`,
     `RootCanvasView`, pickers, the SwiftUI shell.

   Nine files are deliberately unassigned above (`ShapeSynthesis`,
   `ShapeToolRuntime`, `EditorLifecycle`, `ZoomRegistrationProbe`,
   `PagedCanvas`, `PageFile`, `TuberNotesApp`, both `Spike*` files) —
   their placement is judged after item 7's seam exists, and
   `EditorLifecycle` is the interesting one: it imports UIKit *and*
   constructs the store, so it sits exactly on the App↔Store boundary the
   split is drawing. Budgeted as part of this item, not discovered during
   it: every entry in the structural checker's allowlist is a hardcoded
   repo-relative path, and `allowlistsNameFilesThatExist`
   (ContractStructureTests.swift:672) fails wholesale the moment files
   move — re-scoping the checker per-module is a prerequisite for the
   split landing green, not a refinement afterward. What survives in
   `ContractStructureTests`: the rules the compiler cannot hold —
   file-I/O outside the store, the `try?` ban, the forbidden-pattern
   list.

9. **The megaclass breakup, smallest real move first.**
   `EditorSession.swift` is 1,797 lines and `PageCanvasController.swift`
   1,263. Extract `Page` — the whole struct, EditorSession.swift:49-313,
   `Ink` and the named transitions and all — **verbatim** into its own
   file first. It is the best-designed thing on the branch,
   extraction-unchanged is the test of whether a split is real rather
   than cosmetic, and it makes the state machine legible as the
   centrepiece a new contributor should imitate. Judge the larger splits
   (save coordination, import pipeline) only after items 7–8: the seam
   and the module graph will show where the boundaries are; guessing
   first is how a refactor produces five files that all still know about
   each other.

10. **The seam between session and runtime stops failing open.** Ten
    optional closures cross the boundary (eight on `PagedCanvasController`,
    two on `PageCanvasController`), and they fail open in two ways: five
    substitute a permissive value — `staticLayersForPage ?? []` (:297,
    :545), `projectionForPage ?? .canonical` (:332, :501),
    `contentForPage ?? .blank` (:465), `onLayerTransformed ?? true` (:533;
    PageCanvasController.swift:1062) — and the rest silently drop the call
    (`?.()`), which is arguably worse: an unwired `onPageRetiring` loses a
    handover with no trace. `contentForPage ?? .blank` is the emblem: an
    editable blank canvas is precisely the state
    *page-without-bytes-is-not-a-canvas* forbids, wired in as the nil-case
    default so tests can host the runtime without a session. None fires in
    production today; all ten document the wrong behaviour at the seam.
    With stage 1's taxonomy in force and item 7's seam in place, replace
    optional-closure-with-default by a required protocol the runtime
    cannot be constructed without — the test host implements it
    explicitly, and the seam's failure mode becomes a compile error.

11. **One cancellation idiom.** Seven hand-rolled staleness mechanisms
    coexist (`liftGeneration`, `compositeGeneration`, `lensGeneration`,
    `flushGeneration`, task-identity comparison, `pageLoadsInFlight`,
    `renderedRequest`-as-dedup), and because nothing is ever cancelled, a
    five-page flick runs every superseded decode to completion — work
    competing with the Pencil, against the project's own priority order.
    ReviewFindings #13 is the same finding from the memory side. Pick one
    idiom (structured cancellation where the work is droppable; a
    generation check only where a result must be compared, not raced),
    write it down in `CONTRIBUTING.md`, and migrate the seven. Same pass:
    collapse the three competing off-main idioms (`actor`,
    `nonisolated static async`, `Task.detached`) to a stated choice per
    situation.

12. **The spike hooks come out of the production controller.** Nine
    `#if TN_SPIKE_MIRROR` sites in `PageCanvasController` plus
    `TN_SPIKE_LENS` in the app entry, all dead by default, no owner, no
    end condition — a legibility tax on the two hottest files, paid by
    every future reader. Either spikes 1–2 get their device verdicts now
    and the hooks die with them, or the hooks come out and `Spike*.swift`
    keeps its own copies. Do not hand three contributors files threaded
    with conditional compilation for experiments nobody is running.

**Stage 2 exit:** the module graph enforces the import rules; the session
has seams a test can use without backdoors; `Page` is a file someone can be
pointed at; no `#if TN_SPIKE` in production controllers.

---

## Stage 3 — correctness, in code that can now absorb it

The remaining verified defects, cheapest-legible-fix order. Each is small;
none is worth doing badly early to avoid doing well here.

13. **`appendPage` durability** (EditorSession.swift:822-833, `KNOWN
    DEFECT`). An accidental swipe past the last page grows the document
    permanently. Defer durability to first ink (the contract's shape) or
    drop never-inked trailing pages at save (smaller).
14. **`changedStaticLayers` O(n·m)** (EditorSession.swift:102-104). Hold
    saved layers as `[UUID: LayerEnvelope]`; the sole call site
    (EditorSession.swift:1040) only wants IDs. The reason is the
    free-looking getter as much as the cost — graded against the feature's
    designed scale, not the current test corpus.
15. **`trimToByteBound`** (StaticLayerRenderer.swift:557-575; the sort is
    :559). The backstop is currently the most expensive path in the cache
    and fires exactly under pressure — and the eviction loop sorts once
    but never re-sorts, so the policy is inferred, not stated. Tracked LRU
    or min-heap; eviction that reads as policy.
16. **`lastSerializeDuration`** (EditorSession.swift:951-960, two `KNOWN
    DEFECT`s). Record the per-page maximum, not the sum across dirty
    pages; seed the cold value so the first save of a session gets
    backoff.
17. **Settle-path decode: measure, then decide**
    (PagedCanvasController.swift:457-472). Up to five synchronous
    `PKDrawing(data:)` decodes per settle since the window widened.
    Measure against five heavy pages (the 20k-stroke / 4.6 MB fixture);
    if it hitches, decode off-main and install on arrival — the
    `.retained` path already proves a canvas takes a drawing late.
18. **One device session for the undo isolation assumption**
    (PageCanvasController.swift:1074-1083). Move a layer, undo, redo, on
    hardware. Converts `MainActor.assumeIsolated` from unproven to
    proven; no code change unless it traps.

---

## Stage 4 — the device-evidence backlog

What remains after the parallel track has done its work: the verdicts only
hardware and Phillip can give. Spikes 1–3, `turn-feel`,
`handovers-landed`'s settle feel, `loud-by-default`'s exit (which also
closes the deferred half of stage 1 item 5 — a planted trap observed
through the digest on hardware), and `testflight-release` once
`device-branch-builds` is real.

**Not scheduled — Phillip's verdict, evidence already recorded:** whether
zoom survives a page turn (PageCanvasController.swift:424-431); the
mixed-geometry seam feel; A11's final wording beyond the two decisions
named in stage 1.

**Noted for the roadmap, not this todo:** a page-overview grid — a
GoodNotes-parity feature — is currently blocked *by design*:
`StaticLayerRequest` excludes ink on principle, so nothing can render a
page thumbnail with its ink short of a live canvas, and the live window
caps those at five. If the grid is ever wanted, that is a contract
conversation first, not a feature branch.
