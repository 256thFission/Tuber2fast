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
  performed by anyone. The unit tests drive turns by setting `contentOffset`
  and firing the settle callbacks, which proves the bookkeeping and nothing
  about the gesture.
- **Turns now settle at rest, and no one has felt it.** The window refresh,
  first-responder move, and page-change commit moved off the drag path onto
  the settle callbacks. A fast multi-page flick may briefly show a loading
  placeholder where the old runtime built canvases mid-drag. This is the
  largest feel change in the tree and it is entirely Phillip's verdict.
- **The loading/unreadable placeholder has never been seen on a device**, and
  the refusal of Pencil input on it — the placeholder accepts no input at all —
  is a device check by nature; the simulator has no Pencil.
- **The writing loop's hand-exercised checks were never performed** — launch
  first-contact ink, scroll and zoom against the page, background-flush
  survival, autosave spacing under continuous writing, and the five-second
  retry ceiling.
- **Pencil feel, stroke fidelity, palm rejection, and Pencil/touch separation
  are unrendered.** They are Phillip's verdict alone, and no mechanical evidence
  substitutes.
- **No Release build has ever been seen to emit a trace.** `CanvasLog`'s stderr
  mirror now ships in every configuration, gated on `TN_TRACE` alone, and a
  Release build compiles — but no iPad has been watched printing through it, and
  Release is the configuration `device.yml` distributes. Until then "the build
  five people hold is loud" is a claim about a compiler flag, not an observation.
- **The fixed crash digest has never read a real crash.** `Tools/device-tests`
  proves the digest calls a trap a crash across seven hand-written consoles. No
  console in that set came off an iPad, and a device console can carry
  interleaving and framing those fixtures do not reproduce.
- **The shape tool has never met a Pencil.** What a shape *is* is proven
  mechanically — the strokes, the ink they carry, and the pixels PencilKit
  renders from them are all asserted in `ShapeToolTests`. Everything between
  the Pencil and those strokes is not, and none of it can be:
  - that a Pencil drag reaches `PencilDragRecognizer` at all, and that
    recognizing on touch-down beats the enclosing scroll views to the claim
    rather than losing the first few points to a pan;
  - that a finger still pans, pinches, and turns the page with the tool on —
    the recognizer refuses non-Pencil touches, but only a hand proves the
    scroll views still see them;
  - that `PKCanvasView.isDrawingEnabled = false` suppresses freehand ink
    without suppressing anything else, and that it restores cleanly;
  - that the `CAShapeLayer` preview is visible *above* existing ink rather
    than beneath it, and that it tracks the Pencil without lag;
  - that a committed shape is **one** undo step. `undoManager` is `nil` for an
    unhosted canvas, so whether PencilKit registers an undo of its own for a
    programmatic `drawing` assignment is unmeasured, and the commit is written
    to be correct either way. One Cmd-Z must remove a whole rectangle;
  - and whether a shape feels like the pen that drew it. That is a verdict,
    not a measurement.

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
untested checker can go dead and keep passing. The enumeration is recursive, and
its recursion is itself covered: sources planted in a subdirectory of a temp
tree must trip each rule.

**The rules are a token scan, not a type checker**, so three things pass it: a
`PKCanvasView` subclass constructed by its own name, `let v: PKCanvasView =
.init()`, and a forbidden token reached only through string interpolation. Each
is recorded as a `KNOWN DEFECT:` block beside the rule it limits. All three
under-report, which is the direction that goes quiet.

**The forbidden-pattern list is not checked.** No test looks for placeholder
fields for future features, or for a cache, thumbnail, checksum table, or asset
manifest. Those are held by code review alone.

Swift 6 actor isolation and warnings-as-errors cover two more rules for free.

## A review's findings, most now reproduced and fixed

An agent read the whole of `TuberNotesApp/` against the contract and asserted a
list of defects, all reasoning from source. Most have since been reproduced and
fixed and are gone from this list — each now has a test that fails against the
code as it was: a page retiring with unsaved ink losing it to a save that read
the last durable bytes; opening a document marking every page in the opening
window dirty; a page retiring during a failed save losing its ink to the retry;
a not-yet-loaded page accepting and then dropping Pencil input; a half-drag
treated as a settled turn; an append silently refused during a save; work
arriving during a flush parked with no timer; and one unreadable page file
failing the whole launch. None of the fixes has been exercised on the device,
which is a different gap and is recorded above.

Still asserted and not reproduced:

- **`fetchPageData` computes its bounds before awaiting and indexes after.**
  Latent only: nothing removes pages today.
- **`DocumentStore.save` reports a page absent from the index as
  `missingPageFile`**, which names the wrong condition on a diagnostic path.
- **`deleteOrphanedPages` has no caller**, so orphans from a failed save
  accumulate for the life of the document.
- **The runtime is index-keyed while the session is identity-keyed.** Correct
  today because the page list is append-only; the first delete or reorder
  makes every callback a wrong-page write. The Handovers proposal's S8 (opaque
  page tokens) is the answer, deliberately not built until such a feature
  exists.

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
