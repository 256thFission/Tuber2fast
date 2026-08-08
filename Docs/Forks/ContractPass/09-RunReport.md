# The canvas-complete run — what landed, what waits on Phillip, what waits on hardware

Status: record of the implementation run of [`CanvasCompleteTodo.md`](../CanvasCompleteTodo.md)
revision 2, executed 2026-08-07/08 by parallel agents, integrated sequentially,
every merge pushed to `canvas-feature-complete` with CI live. This file is the
run's exit document: the two lists that outlive it are **Phillip's decisions**
and **the device-evidence backlog**. Everything here cites where the detail
lives; nothing here is the authoritative statement of anything.

## What landed

- **Parallel track** — CI proven green *and* red (real runs, failure annotated
  on the failing line), `main` protected, `Tools/machines` Artifacts defect
  fixed. Detail: [`00-ToolingReview.md`](00-ToolingReview.md).
- **Stage 0** — the sub-83-point import refusal (103.2 pt bound, derived and
  pinned against `project.yml`'s portrait-only claim), and the resize
  re-centre (offset restated from `currentPageIndex`, because a widening
  viewport clamps the offset before layout runs).
- **Stage 1, implementable half** — pdf layers have a delete path that is not
  selection; the `shapeKind` mirror is gone (the chrome reads the runtime's
  tool through the session); image assets are HEIC-only with the
  alpha-round-trip pinned in the simulator. The prose halves are
  [`01-Saving.md`](01-Saving.md), [`02-ProposedDisposition.md`](02-ProposedDisposition.md),
  [`03-Failure.md`](03-Failure.md), [`06-HEIC-amendment.md`](06-HEIC-amendment.md).
- **Stage 2, all six items** — `DocumentStoring` extracted from the consumed
  surface ([`07-StoreSeam.md`](07-StoreSeam.md)); six module targets with the
  SwiftUI ban compiler-enforced by `-module-alias`
  ([`08-Modules.md`](08-Modules.md)); `Page` extracted verbatim
  (byte-identical move); the session/runtime seam is two required protocols —
  an unwired runtime no longer compiles; one cancellation idiom, written into
  `CONTRIBUTING.md`, with superseded canvas work actually cancelled; spike
  hooks out of the production controllers, reinstall recipes in the spike
  files.
- **Stage 3, items 13–17** — never-written trailing pages are withheld from
  saves; `changedStaticLayerIDs` is a set-difference over a dictionary;
  cache eviction is a held LRU order instead of a sort under pressure;
  the serialize measurement is the slowest page, seeded cold; the settle-path
  decode is off-main (219 ms of main-thread freeze → 0.35 ms, measured, with
  the benchmark re-runnable against a device).

Test suite over the run: 301 → 328 tests; wall time 15.9 s → ~5 s; the
wall-clock flake list is cured by `TestScratch.freezeTimestamps()` and the
injected `TestClock`, with `aStaleLensIsDropped` deliberately still wall-clock
(the load-immune forms proved decorative — reason recorded in the test).

## Phillip's decisions, in one place

1. **The contract authoring sitting** — the whole point of stage 1. Work
   top-to-bottom through `01-Saving`, `02-ProposedDisposition` (its closing
   checklist names what is yours: A10, A15, the envelope's `locked` field),
   `03-Failure`, `06-HEIC-amendment`, plus the wording options in
   `07-StoreSeam` and `08-Modules`. `Contract.md` and `Contract.proposed.md`
   were never touched by an agent.
2. **From `01-Saving`'s residual questions** — the third dirty axis
   (`indexDirty`; an index-only pass writes no page files), and the
   poisoned-page behaviour: after a per-page refusal the backed-off retry
   loop can never succeed until the offending layer is deleted.
3. **The *Empty trailing pages* section is lost.** `Contract.md` — Navigation
   cites it; the docs restructure dropped it. Item 13 implements its first
   and third sentences but not "at most one never-written trailing page in
   memory". Original text and pointer recorded in `Docs/Queue.md`.
4. **Infra** — the repo is private but `prove-ci`'s exit says "a PR from a
   fork": go public or reword. No Xcode pin in CI (deliberate; ratify or
   add). `enforce_admins` blocks your own merges while you are alone (relax
   command in `00-ToolingReview`). `main` is far behind
   `canvas-feature-complete` and meets its new protection rules for the
   first time on that merge.
5. **A11's final wording** — the code side won and the delete path exists;
   the sentence itself is still yours to author in the disposition pass.
6. **The loading placeholder's look** — currently flat grey with a sentence.
   A contract-clean improvement exists (static composite as the placeholder
   backdrop — worksheet visible instantly, ink pops in after); a true ink
   thumbnail is a contract conversation (`StaticLayerRequest` excludes ink
   on principle — the same wall the page-overview grid sits behind).

## The device-evidence backlog

Nothing below is claimed. Green CI is silent about ink; every line here needs
an iPad and most need your eyes. Homes: `Docs/Unproven.md` where noted,
otherwise this list.

- **One editor session over the whole run's surface** — every wave touched
  `EditorSession` or the canvas runtime; the PR template's device-evidence
  rule applies to the sum, not just the parts.
- **Split View / Slide Over resize** — the re-centre's feel (invisible or a
  jump), and what a live resize does to the canvases inside the slots
  (`Docs/Unproven.md`).
- **The settle-path decode on hardware** — re-run
  `TuberNotesTests/SettleDecodeBenchmark.swift` against a device (command in
  its doc comment). The residual can overturn details; the direction it
  cannot. And the taste verdict: the brief placeholder during a fast flick
  is the price of the 219 ms freeze (`Docs/Unproven.md`).
- **HEIC on the hardware encoder** — import a transparent PNG on the iPad
  and confirm transparency survives; the device HEVC encoder is a different
  implementation of the same API.
- **The pdf delete button** — placement and width of the action cluster, the
  `trash` symbol, and the taste call: a destructive tap with no confirmation
  matches image delete exactly, and that is the one place "matches existing
  semantics" might be the wrong defence.
- **Undo isolation** (todo item 18, unscheduled by instruction) — move a
  layer, undo, redo on hardware; converts `MainActor.assumeIsolated` from
  unproven to proven.
- **Spikes 1–3** — 1 and 2 are now *unthreaded* (hooks out, reinstall
  recipes in the spike files, `ImplementationStatus.md` says exactly what a
  flag build does); 3 was never built. Verdicts owed as before.
- **`loud-by-default`'s exit** — a hand-corrupted page seen refusing on
  hardware through the digest; also closes the deferred half of the failure
  taxonomy.
- **Standing items** — `turn-feel`, `handovers-landed`'s settle feel, the
  zoom-across-a-page-turn verdict (evidence recorded, verdict yours).

## Deliberately not done

- **The larger megaclass splits.** The extraction pass left the boundary
  read for when they are wanted: save coordination extracts as *policy*
  only if capture is injected (`performOneSave` must reach the live runtime
  synchronously); the import/layers region's honest seam is "produce
  envelopes off-main" vs "commit envelopes on-main", not "import" vs
  "layers".
- **Page deletion.** The pdf delete path empties pages; nothing removes a
  page, so a fifty-page mis-import is fifty taps. Ergonomics, not a hole.
- **The page-overview grid** — blocked by design; a contract conversation
  first, as the todo's roadmap note says.
