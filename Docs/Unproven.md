# Unproven

Claims this project has not earned. Not defects — gaps where evidence is simply
absent, and reporting any of them as working would be a lie.

This file holds only what cannot live closer to the thing it describes. It
carries **no line numbers and no verification date**, deliberately: a document
that must be re-verified against source on a schedule is rot with a
maintenance ritual attached.

**Known defects live in the code**, at the site of the defect, as a
`KNOWN DEFECT:` block. They move when the code moves and die when it is fixed.
To read the current list:

```bash
grep -rn "KNOWN DEFECT" TuberNotesApp/
```

Nothing here is a reason not to ship. It is a reason not to be surprised.

---

## Never exercised by hand

- **Nothing has been exercised on the device since page turning landed.** No
  swipe, turn, zoom-versus-swipe, append, or multi-page relaunch has been
  performed by anyone. The unit tests drive turns by setting `contentOffset`,
  which proves the bookkeeping and nothing about the gesture.
- **The writing loop's hand-exercised checks were never performed** — launch
  first-contact ink, scroll and zoom against the page, background-flush
  survival, autosave spacing under continuous writing, and the five-second
  retry ceiling.
- **Pencil feel, stroke fidelity, palm rejection, and Pencil/touch separation
  are unrendered.** They are Phillip's verdict alone, and no mechanical evidence
  substitutes.

## Nothing exercises a touch

**No automated check delivers a touch to the canvas.** A first-stroke crash
inside `-[UIGestureRecognizer _delayTouchesForEvent:]` passes the structural
tests, the unit tests, and a clean simulator launch — every mechanical check
the project has — so that crash class is caught by a person on an iPad or not
at all, after CI and after review. The known price of closing this gap:
XCUITests that tap, drag, and pinch the real canvas cost four cold app
launches — 34.5s of a 41s test run, roughly six times the wall clock of the
entire unit suite under load — and can assert only that the process is still
running. `page.canvas`,
`page.error`, and `save.error` remain as accessibility identifiers in
`RootCanvasView`; nothing reads them.

## No numbers exist

- **No performance baseline exists.** Nothing has been measured on the device,
  so there is no numeric budget for anything, and no evidence about whether
  save cost scales with page count.

## The contract is only partly enforced

Three structural rules are machine-checked as ordinary tests in
`TuberNotesTests/ContractStructureTests.swift`: one `PKCanvasView` construction
site, the UIKit/PencilKit import allowlist, and file I/O confined to
`DocumentStore`. Each is an allowlist, so a new file breaks the test without
anyone remembering to update anything, and the checker has its own tests — an
untested checker can go dead and keep passing.

**The forbidden-pattern list is not checked.** No test looks for placeholder
fields for future features, or for a cache, thumbnail, checksum table, or asset
manifest. Those are held by code review alone.

Swift 6 actor isolation and warnings-as-errors cover two more rules for free.

## A review's findings, none reproduced

An agent read the whole of `TuberNotesApp/` against the contract and asserted
the following. Every one is reasoning from source — no failing test, no device
run, no reproduction — which is what puts them here rather than in the code as
`KNOWN DEFECT:` blocks. Reproducing one is what promotes it.

Two have since been reproduced and fixed, and are gone from this list: a page
retiring with unsaved ink losing it to a save that read the last durable bytes,
and opening a document marking every page in the opening window dirty. Both now
have tests that fail against the code as it was. Neither has been exercised on
the device, which is a different gap and is recorded above.

- **A dirty page with neither a live canvas, retired ink, nor held bytes now
  traps rather than being dropped.** It is still reachable — a page that
  entered the live window before its bytes arrived accepts Pencil input and is
  excluded from retirement, so it arrives at a save dirty and empty-handed. The
  `KNOWN DEFECT:` block at the trap says so, and `unloaded-page-is-not-a-canvas`
  closes it by refusing the input.
- **`scrollViewDidScroll` treats the halfway point of a drag as a settled
  turn.** Asserted consequences, all mid-gesture: canvas construction with a
  synchronous drawing decode, a first-responder steal, a prefetch task and its
  actor hop, and the index marked dirty for a turn the user then abandoned. An
  aborted half-drag does all of it twice.
- **Swiping past the last page does nothing while a save is in flight.**
  `appendPage` guards on `saveInFlight` and returns without feedback, which
  contradicts *Navigation*'s "immediately". The guard carries no rationale.
- **One unreadable page file stops the whole prefetch window.** `fetchPageData`
  throws out of its loop and both callers discard the error with `try?`.
  Asserted: the page stays non-editable and renders as blank forever, with no
  signal to the user and no negative caching, which is *Invalid states fail
  loud* inverted on the path that most needs it.
- **`fetchPageData` computes its bounds before awaiting and indexes after.**
  Latent only: nothing removes pages today.
- **`DocumentStore.save` reports a page absent from the index as
  `missingPageFile`**, which names the wrong condition on a diagnostic path.
- **`deleteOrphanedPages` has no caller**, so orphans from a failed save
  accumulate for the life of the document.

## Doc comments are not checked against the code

Roughly half of `TuberNotesApp/` is prose, and nothing verifies any of it. The
*why* comments — the `_delayTouchesForEvent:` crash stories, the write-ordering
rationale — are the reason the density is defensible. The claims *about what the
code currently does* are a second specification that drifts, and it already has:
a comment naming a member that was renamed, a comment claiming the save path
reads a property only tests read, a comment asserting a turn callback fires only
once settled, a comment asserting the retirement race is safe, and two files
describing themselves as "the spike" against a despiking proposal no longer in
the tree.

Three of those sit next to the findings above, which is not a coincidence: a
comment that asserts an invariant is the reason nobody re-checks whether the
code still provides it. Deferred deliberately — the drift is a symptom, and
correcting the sentences before the structure would only re-decorate it.

## CI has never run

`.github/workflows/ci.yml` and `device.yml` are written but uncommitted, and no
push has exercised either. An unrun workflow is not CI; it is a YAML file that
has never been contradicted. See `prove-ci` in [`Queue.md`](Queue.md).

---

## Environment traps

Not gaps — properties of the tooling that read as project defects when hit.

- **Undo/redo cannot be unit tested here.** `undoManager` walks the responder
  chain, so an unhosted controller always reports `nil`. It is device evidence.
- **The simulator has no Apple Pencil.** Drawing, erasing, palm rejection, and
  pressure cannot be proven off-device at all.
- **`UIScrollView.contentSize` is already multiplied by `zoomScale`.** An
  assertion expecting the unzoomed page width sees `612 × 1.3399 = 819.99` and
  reads as PencilKit ignoring page space; the implementation is right and the
  assertion is wrong. "Fixing" it in the code silently corrupts page space to
  view space.
