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
| 1. Ink becomes a layer | **landed, reviewed, green** | `3a1a627` + review fixes `dee6044` | 77 tests; independent review returned approve-with-nits, all findings fixed |
| 2. One `image` layer under the ink | **both halves landed, green** | `8e79ad6` (durable) + the rendering half | 151 tests; composite order, orientation, placement, the decode bound, the cache's byte bound and window eviction, and total refusal are all asserted. Registration with ink at 120 Hz, overdraw, and both placeholder tints are device-only — see `Unproven.md`. |
| 3. `pdf` layers, `layers/` split, per-page geometry | not started | — | — |
| 4. Transformable `image` layers | not started | — | blocked on device spike 3 |
| 5. The shape tool | in progress overnight | — | independent of 1–4 by design |

## Contract

`f6522bd` adopted the phase 1 amendments (Owners golden rule 5 generalized;
the *Durable form* layer-envelope block). Everything else the milestone needs
is staged in [`Contract.proposed.md`](../Contract.proposed.md), marked LANDED
/ FORCED / AHEAD. **The contract currently lags the code wherever an
overnight lane landed a kind or a rule** — that gap is the first thing to
close in the morning, and the proposed file is written to make closing it a
matter of editing and moving text.

## Spikes

| Spike | State | Notes |
|---|---|---|
| 1. Mirror fidelity | **scaffolding landed** `f78a050`, verdict owed — and phase 2's rendering half now ships on the presumption it holds | Behind `TN_SPIKE_MIRROR`. Variant A: sibling mirrored one transform per scroll tick. Variant B: inside-`PKCanvasView`, expected to crash. Production `PageBackdrop` uses variant A's technique with a `CALayer` rather than a view. |
| 2. Lens latency | not built | Wants phase 3's PDF path to have something dense to render |
| 3. Manipulation feel and undo | not built | Phase 4 |

## Decisions taken without Phillip

Recorded because they were judgment calls, not transcription. Each is
reversible; none is load-bearing enough to be worth waking someone for.

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
