# CanvasFeatureComplete — implementation status

What has actually landed against
[`CanvasFeatureComplete.md`](CanvasFeatureComplete.md), and what is still
prose. Written by the agent grinding overnight; Phillip edits or deletes it
freely. Branch: `canvas-feature-complete` off `postoai`.

The rule this file follows: **a claim here names the commit and the evidence.**
"Implemented" means code is in the tree and the suite is green. It never means
proven on a device — CI is silent about ink, and every device-only claim is
listed under *Owed evidence* rather than counted as done.

## Phases

| Phase | State | Commit | Evidence |
|---|---|---|---|
| 1. Ink becomes a layer | **landed, reviewed, green** | `3a1a627` + review fixes `dee6044` | Independent review returned approve-with-nits; all findings fixed, the boundary test verified by reverting the fix |
| 2. One `image` layer under the ink | **both halves landed, green** | `8e79ad6` (durable) + `8254cf6` (rendering) | Composite order, composite y-orientation (EXIF orientations untested), placement, the decode bound, the cache's byte bound and window eviction, and total refusal are asserted. Registration with ink at 120 Hz, overdraw, and both placeholder tints are device-only. |
| 3a. `pdf` kind + the `layers/` split | **landed, green** | `b52221f` | Exit test verified by sabotage: a 5-page, 794 KB import, ink on page 4, asserts exactly one layer file rewritten by mtime **and** bytes. Amendments A13, A14 staged. |
| 3b. per-page geometry, zoom cap | **landed, green** | `f212587` | Mixed-geometry paging, per-page zoom floors, one shared ceiling, v2→v3 index read-forward. Found that `PKCanvasView` clamps `maximumZoomScale` to 10, which decided the cap's value. Contract half **reverted** — see below. |
| 3c. base-and-lens, prefetch decode | **renderer landed; integration not started** | rasterizer + spike-2 scaffolding, this branch | `PDFPageRasterizer` renders a page or a sub-rect (the lens shape) off-main, with `/Rotate`, CropBox origin, and the y-flip pixel-tested. Nothing in the real page path calls it yet — the composite is still fit-width detail and goes soft under deep zoom. Integration wants spike 2's verdict and `turn-settles-once`. |
| 4. Transformable `image` layers | **landed, green** | `34acbe8` | Selection, handles, minus-one composite, `locked`; layer-edit undo: inverse-commit path asserted, undo registration device-only. Arbitration, feel, and undo are device-only; spike 3 is owed. |
| 5. The shape tool | **landed, green** | `6f72d18` | Synthesis and rasterized pixels asserted; everything between Pencil and stroke is device-only |

## Contract

`f6522bd` adopted the phase 1 amendments (Owners golden rule 5 generalized;
the *Durable form* layer-envelope block) — the only human-authorized contract
change in this branch. Everything else is staged in
[`Contract.proposed.md`](../Contract.proposed.md) as A3–A15, marked LANDED /
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
tested.

## Spikes

| Spike | State | Notes |
|---|---|---|
| 1. Mirror fidelity | **scaffolding landed** `f78a050`, **verdict owed** | Behind `TN_SPIKE_MIRROR`. Variant A: sibling mirrored by one transform per scroll tick. Variant B: inside-`PKCanvasView`, expected to trap. **Phase 2's rendering half ships on the presumption variant A holds**, using the same technique with a `CALayer` rather than a view. |
| 2. Lens latency | **scaffolding landed, verdict owed** | Behind `TN_SPIKE_LENS`. The renderer exists now — `PDFPageRasterizer` in `PDFSource.swift`, rotation/CropBox-origin/y-flip pinned by pixel tests against byte-exact fixtures. The spike replaces the editor scene with a self-contained scroll-view bench over a dense synthetic worksheet: pinch-settle → visible-rect raster off-main → contents swap on main, one `SPIKE lens settled` line per settle with settle→decode→swap timestamps; `Tools/device`'s digest reprints them. Built and launched in the simulator only — **no latency number exists**, the fixture is synthetic rather than a textbook, and the verdict is Phillip's on hardware. |
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
- **Spike 1's two questions** — does the sibling mirror hold registration at
  120 Hz, and does the inside-`PKCanvasView` branch survive a first stroke.
  The entire rendering direction of phases 2–4 rests on the first answer.
- **Phase 1 on device** — it touches the editor session and the durable form,
  so the PR template's device pass is owed regardless of the green suite.
- **Undo of any kind.** `undoManager` walks the responder chain, so an
  unhosted controller reports `nil`; undo is device evidence in this project
  by construction, and phase 4's design (one manager, two clients) is
  *unverified* — PencilKit may not tolerate foreign registrations at all.
- **Every number in the proposal's memory budget.** Still no measurement;
  `Unproven.md`'s "no numbers exist" stands.
