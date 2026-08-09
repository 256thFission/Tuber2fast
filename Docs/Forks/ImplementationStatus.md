# CanvasFeatureComplete — implementation status

What has actually landed against
[`CanvasFeatureComplete.md`](CanvasFeatureComplete.md), and what is still
prose. Written by the agent grinding overnight; Phillip edits or deletes it
freely. Branch: `canvas-feature-complete` off `postoai`, and since row 6
`pdf-templates`, which carries that branch's work forward and is measured
against [`pdf-templates-proposal.md`](pdf-templates-proposal.md) instead.

The rule this file follows: **a claim here names the commit and the evidence.**
"Implemented" means code is in the tree and the suite is green. It never means
proven on a device — CI is silent about ink, and every device-only claim is
listed under *Owed evidence* rather than counted as done.

## Phases

| Phase | State | Commit | Evidence |
|---|---|---|---|
| 1. Ink becomes a layer | **landed, reviewed, green** | `3a1a627` + review fixes `dee6044` | Independent review returned approve-with-nits; all findings fixed, the boundary test verified by reverting the fix |
| 2. One `image` layer under the ink | **both halves landed, green** | `8e79ad6` (durable) + `8254cf6` (rendering) | Composite order, composite y-orientation placement, the decode bound, the cache's byte bound and window eviction, and total refusal are asserted. **Import UI now exists** (`ImportPickers.swift` + `RootCanvasView`): PHPicker for images, the Files picker for PDFs, both calling the session's import entry points; the EXIF hole (review finding 8) is closed at the seam — `ImageImportPreparation` passes the orientation-applied extent, pinned by `ImportPreparationTests` with an orientation-6 JPEG (the suite's first non-1 EXIF assets), verified by reverting the swap. Device-only for the import UI: the picker presentations themselves (PHPicker and the Files picker cannot run headless), the placed image/pdf against real camera HEICs, and the feel of the flows. Registration with ink at 120 Hz, overdraw, and both placeholder tints remain device-only. |
| 3a. `pdf` kind + the `layers/` split | **landed, green** | `b52221f` | Exit test verified by sabotage: a 5-page, 794 KB import, ink on page 4, asserts exactly one layer file rewritten by mtime **and** bytes. Amendments A13, A14 staged. |
| 3b. per-page geometry, zoom cap | **landed, green** | `f212587` | Mixed-geometry paging, per-page zoom floors, one shared ceiling, v2→v3 index read-forward. Found that `PKCanvasView` clamps `maximumZoomScale` to 10, which decided the cap's value. Contract half **reverted** — see below. |
| 3c. base-and-lens, prefetch decode | **landed, green** | pdf-in-composite, lens, prefetch warm — three commits, this branch | All three moments of the fork doc's zoom story are in the real page path. **Rendered pdf pages** (resolves review finding 4): `StaticLayerRenderer.render` rasterizes `pdf` layers through `OpenPDFDocument`, one open per render, decode bounded by the placed extent; pixel-tested against byte-exact fixtures, including image-over-pdf and every remaining refusal (`PDFLayerRenderTests`). **The lens**: during a gesture, compositor only — asserted that no gesture frame requests anything; at settle, the visible sub-rect renders off-main at the settled zoom and swaps in above the base; stale lenses are generation-dropped, the rect is clamped to the page before the rasterizer, sharp-at-scale is pinned by pixels (stripe fixture: grey at 1 px/pt, pure columns at 2), in memory only (`LensTests`). The fork doc's "an image past a size threshold renders through the same path" is **not done**: images in the lens are present and placed but bounded to the base's detail cap — sharp-at-depth is pdf-only for now. **Prefetch warm**: a settled turn warms the prefetch window's composites through the existing cache; the neighbour's canvas is later served the identical render (`===`), the visible page's composite is protected from byte-bound eviction, and a warm never counts as an LRU use (`PrefetchWarmTests`). Device-only, owed to spike 2: lens swap latency against a dense textbook, and the feel of soft-then-sharp; no latency number exists. |
| 4. Transformable `image` layers | **landed, green** | `34acbe8` | Selection, handles, minus-one composite, `locked`; layer-edit undo: inverse-commit path asserted, undo registration device-only. Arbitration, feel, and undo are device-only; spike 3 is owed. |
| 5. The shape tool | **landed, green** | `6f72d18` | Synthesis and rasterized pixels asserted; everything between Pencil and stroke is device-only |
| 6. One paper template, and the shims' deletion | **landed, green** | fourteen commits on `pdf-templates`, `fa4260d`…`7d4df4d` | Against [`pdf-templates-proposal.md`](pdf-templates-proposal.md) revision 3; steps 2 and 4 are Phillip's and are not done. **PDF:** `OpenPDFDocument` opens the source once per render rather than twice, byte-identical against the existing fixtures. **The shims are gone:** the index's version-2 read path and its write-forward machinery, `PageFile`'s pre-split and pre-layer forms, `locked`-absent, and the pre-library adoption — `currentFormatVersion` is 1 and one form is read. Two corrupt-file tests retargeted; A19 is *forced* by this and staged, not adopted. **The cache evicts by page** (`StaticLayerRequest.pageID`, `CompositeKey.pageID`, `retain(pageIDs:protecting:)`), which closes a real hole: the empty set is disjoint with every set, so a layer-less page's composite used to be evicted on every turn including while it was on screen. **Paper:** `PageTemplate` is one durable name on the index — not a layer, not per page — refused by `validated()` if unknown; `PaperTemplateRenderer` strokes it into the base composite *and* re-strokes it into the lens, so ruled paper is resolution-independent at any zoom rather than a resampled raster; delivery is `setTemplate` told down the runtime exactly as the shape tool is. A page carrying a `pdf` layer draws no template (`StaticLayerRequest.effectiveTemplate`) — enforced at the render, never on disk, so the durable value survives underneath and a deleted PDF reveals it. A genuinely blank page in a blank notebook still short-circuits to `.empty` and keeps its opaque canvas, pinned by test. **UI:** one picker for the document in `RootCanvasView`, four buttons in the shape picker's idiom, disabled on a PDF page via `EditorSession.currentPageCarriesPDF`; no custom spacing, colour, per-page override, or thumbnails, each named out of scope in §i. Changing paper is **not undoable** by decision (§g5) and that decision wants Phillip's verdict. A16, A17, A19 staged. Device-only: every metric, rule contrast under ink, the base→lens swap on a ruled page, a template change on a live page, and the picker itself — see `Unproven.md`. |

## Contract

`f6522bd` adopted the phase 1 amendments (Owners golden rule 5 generalized;
the *Durable form* layer-envelope block) — the only human-authorized contract
change in this branch. Everything else is staged in
[`Contract.proposed.md`](../Contract.proposed.md) as A3–A19, marked LANDED /
FORCED / AHEAD.

**The contract lags the code, deliberately and in known places.** The most
visible: `Contract.md` still says `pageWidth < pageHeight` while the code
accepts landscape pages and tests them. One agent (phase 3b) wrote its
amendments straight into `Contract.md`; that edit was **reverted** and its
text staged with the rest, because the contract says no agent authors a rule
and every other lane staged. Closing the gap is one deliberate editing pass,
which is exactly what the proposed file is shaped for.

Two staged items want a decision rather than a rubber stamp: **A15**, where an
agent *widened a machine-checked rule* to ban `CoreGraphics`, and **A10**,
whose premise (PencilKit tolerating foreign undo registrations) no spike has
tested. **A19 is forced**: the shim deletion has landed, so `Contract.md`'s
sentence about reading the pre-layer page form is describing code that no
longer exists. So is the template's absence from *Durable form* (A16).

## Device session findings, 2026-08-07

Phillip hand-tested a Release build (`8ccc656`) on an iPad Air 5, iPadOS
26.5.2. Three findings, in his words, each fixed on this branch:

1. **Dead-space zoom** — the page could be zoomed out past fit-width, leaving
   dead space at the borders. Verdict: must not happen; the floor is
   fit-width. Fixed in `PageCanvasController.establishZoomIfNeeded` — the
   overview floor is gone, `minimumZoomScale` is the page's own fit-width;
   vertical panning within the page still works at the floor.
2. **Grey flash on append** — turning to the appended blank page flashed the
   whole area grey before the page popped in. Root cause shared with finding
   3: the bookkeeping was already synchronous (a blank slot needs no load and
   was never a placeholder — now pinned by test), so the grey beat was the
   overscroll region held on screen while UIKit's pre-armed bounce fought the
   offset `setPages` wrote.
3. **Rubber-band on append** — the turn onto the appended page sometimes
   failed and rubber-banded back. UIKit computes the deceleration target
   before `scrollViewDidEndDragging`, against the contentSize that still ends
   at the old last page, and arms that animation after the delegate returns —
   overriding the in-callback offset. Fixed in
   `PagedCanvasController.scrollViewDidEndDragging`: when the session's append
   landed, the target is re-asserted one runloop turn later, which cancels the
   bounce. The session still owns the page list; the runtime re-asserts only
   an offset for a page that already exists.

The bookkeeping is test-pinned; the feel re-verdict on all three is
Phillip's, on hardware.

## Spikes

| Spike | State | Notes |
|---|---|---|
| 1. Mirror fidelity | **DELETED, and its question answered by shipped code.** Scaffolding landed `f78a050`; the eight `#if TN_SPIKE_MIRROR` hooks came out of `PageCanvasController` at Stage 2 item 12, leaving a file that compiled and installed nothing. Variant A — a sibling under a transparent `PKCanvasView`, mirrored by one transform per scroll tick from the delegate callbacks — **is what shipped**, as `PageBackdrop`, driven from `PageCanvasController`'s scroll callbacks, running since phase 2. Variant B asked whether a subview *inside* `PKCanvasView` survives a first stroke; the design took the other branch on the grounds that this project already crashed UIKit doing it, so B is a question about a structure nobody chose. | Registration through a fast pinch is still open and still measured — by `ZoomRegistrationProbe`, which is live in the shipping controller and is the instrument that can actually run. |
| 2. Lens latency | **DELETED, superseded by the real lens.** The one `#if TN_SPIKE_LENS` hook in `TuberNotesApp.swift` came out at Stage 2 item 12, after which building with the flag compiled the spike and still opened the editor. Its own header said it stood alone "because base-and-lens integration is phase 3c proper" — and 3c shipped: `StaticLayerRenderer.renderLens`, generation-guarded, pixel-tested, and now stroking paper as well as PDF. | **No latency number exists, and this is still owed.** Getting one now means instrumenting the real lens on hardware, not a synthetic worksheet in a scene the app cannot reach. |
| 3. Manipulation feel and undo | not built | Phase 4 |

## Decisions taken without Phillip

Recorded because they were judgment calls, not transcription. Each is
reversible; none is load-bearing enough to be worth waking someone for.
This list covers phase 1 only; the full register continues in
[`OvernightLog.md`](OvernightLog.md)'s decisions sections.

1. **The refused-save guard reads disk, not memory.** Phase 1 first recorded
   refused pages in per-instance memory; review found a second `DocumentStore`
   instance could overwrite a refused layer's bytes. Chosen fix: `save`
   re-decodes each changed page's existing file and refuses if it carries an
   unknown kind. The weaker in-memory mechanism was deleted rather than kept
   alongside — one rule, one mechanism. Verified by reverting the fix and
   watching the new test fail.
2. **An undecodable existing page file also refuses the save.** Not asked for;
   the agent extended the same reasoning — overwriting bytes this build cannot
   read is the same blind drop with a different cause.
3. **The parallel contract is a separate file, not edits to `Contract.md`.**
   The contract says every rule is written by a human and no agent's output
   becomes a rule by having been committed. Staging respects that literally.
4. **`loud-by-default` was pulled forward** out of queue order, because the
   morning's device session is worthless if the Release build emits nothing
   and a crash reads as "no trace captured" — and spike 1 variant B is
   *expected* to crash.
5. **Phase 5 was pulled forward** to run parallel with phase 2. The proposal
   sequences it last, but it depends on nothing in phases 1–4: it commits
   ordinary strokes and changes no durable form. Sequencing it late was a
   presentation choice, not a dependency.

## Owed evidence — nothing below is proven

- **Every device claim.** No stroke, pinch, fling, or turn has been performed
  on hardware against any of tonight's code.
- **Whether the mirrored sibling holds registration with the ink at 120 Hz**
  through pinch, fling, and rubber-band. This was spike 1 variant A; the spike
  is deleted and the question is not, because `PageBackdrop` *is* that design
  and the entire rendering direction of phases 2–4 rests on it. The live
  instrument is `ZoomRegistrationProbe`. The other half of spike 1 — does a
  subview inside `PKCanvasView` survive a first stroke — is not owed: nothing
  was built that way.
- **Phase 1 on device** — it touches the editor session and the durable form,
  so the PR template's device pass is owed regardless of the green suite.
- **Undo of any kind.** `undoManager` walks the responder chain, so an
  unhosted controller reports `nil`; undo is device evidence in this project
  by construction, and phase 4's design (one manager, two clients) is
  *unverified* — PencilKit may not tolerate foreign registrations at all.
- **Every number in the proposal's memory budget.** Still no measurement;
  `Unproven.md`'s "no numbers exist" stands.
- **Every template metric, and whether ruling reads as paper.** Row 6 ships
  spacings, a mark colour, and a margin that no eye has judged, and the
  base→lens swap on a ruled page is a worse case than any photograph shipped
  so far. Enumerated in `Unproven.md` rather than here; spike 2 is the same
  unrun bench it was.
