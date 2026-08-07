# Overnight log — CanvasFeatureComplete grind

Written by the agent while Phillip sleeps. Every decision taken without him,
every discovery, and every item that needs him in the morning. Newest entries
appended at the bottom of each section. Branch: `canvas-feature-complete`
(off `postoai`).

## Done and green before the grind started (evening, with Phillip)

- **Phase 1 — ink becomes a layer**: `3a1a627`, reviewed
  (approve-with-nits), review fixes in `dee6044` (refused-save guard reads
  disk not memory; duplicate-layerID invariant; corrupt-legacy tests;
  suite converted to Swift Testing). 77 tests green.
- **CONTRACT: amendment** `f6522bd` — Phillip authorized the Owners golden
  rule 5 generalization and the Durable form layer-envelope block. Already
  in `Docs/Contract.md`; the parallel contract below builds on top of it.
- **Spike 1 scaffolding** `f78a050` — mirror-fidelity spike behind
  `TN_SPIKE_MIRROR`, variants A (sibling) and B (inside-PKCanvasView).
  Green with flag off, builds with flag on.
- Both merged into `canvas-feature-complete` at `277786b`.

## Decisions taken overnight

1. **`loud-by-default` and phase 5 were pulled forward** out of queue/proposal
   order. `loud-by-default` because the morning's device session is worthless
   if the Release build emits nothing and a Swift trap reads as "NO TRACE
   CAPTURED" — and spike 1 variant B is *expected* to trap. Phase 5 because it
   depends on nothing in phases 1–4; its late position in the proposal was
   presentation, not dependency.
2. **The parallel contract is a separate file** (`Contract.proposed.md`), not
   edits to `Contract.md` — the contract says no agent's output becomes a rule
   by having been committed, so staging respects that literally.
3. **The refused-save guard reads disk, not memory** (phase 1 review fix), and
   the weaker in-memory mechanism was deleted rather than kept beside it.
4. **`UserDefaults` was added to the file-I/O token list** by the checker lane
   — a judgment call flagged for reversal: not file I/O by name, but durable
   state reaching disk without passing through `DocumentStore`. One line to
   delete if Phillip disagrees.
5. **`Tools/device-tests` is not wired into CI**, because `CONTRIBUTING.md`
   states CI calls no script in `Tools/` deliberately. Left as Phillip's call.
6. **A `pdf` layer's payload stores no source page size** — it follows the
   same unit-square convention `image` does. This was phase 3's one genuinely
   open call and the case against it is real: a PDF page has an intrinsic size
   in points, which a bitmap does not, so "the source states its size" is a
   fact rather than a convenience. Overruled on four counts, argued in full in
   `Contract.proposed.md` A13; the shortest is that under A8 an imported
   page's *geometry* is its source's size in points, so a durable size in the
   payload would be the same number in a third place. **Reversible as one
   field plus one migration, and easier to add later than to remove.**
7. **A `pdf` layer carries no `format` field**, unlike an `image` layer. Its
   asset is a PDF by definition of the kind, so a format field could only
   repeat the kind and then disagree with it. Consequence accepted and
   documented at the type: `pdf` has no unsupported-format refusal.
8. **The source rectangle is the CropBox, falling back to MediaBox, with
   `/Rotate` applied.** A PDF page has five boxes and a rotation, so "the
   page's size" is a choice; it is made in `PDFSource` and nowhere else. This
   is also the strongest argument against storing the size durably — freezing
   the choice into every payload lets it drift from the renderer's silently.
9. **An `image` layer may not name a `pdf` asset.** Adding `pdf` to
   `AssetFormat` silently made `"pdf"` a valid *image* format, which would
   have handed a PDF to a bitmap decoder. `ImageLayerRef.recognizedFormat` is
   now an exhaustive switch that refuses it, so a future format cannot be
   added without deciding this again.
10. **The caller states what changed; the store checks rather than trusts.**
    The alternative — the store comparing each envelope against disk — would
    read the ink layer back on every save to discover it had not changed,
    which is the read the format exists to avoid. So `EditorSession` supplies
    the changed set, and before any write the store refuses a claim that would
    leave a page file naming a layer with no file. What it cannot detect is a
    caller understating a change to a layer that *does* have a file: those
    bytes stay stale. That is the trust boundary, documented at `PageWrite`.
11. **`DocumentStore.save` gained a second entry point, not a replacement.**
    `save(index:pages:)` takes `PageWrite`s; `save(index:changedPages:)`
    remains as a thin adapter meaning "every layer changed", used by the first
    save of a document and by tests whose subject is validation rather than
    granularity. One implementation, one adapter.
12. **`PageFile` encodes only the current form.** Three forms are read
    (pre-layer, phase 1–2 inline, phase 3 split) and exactly one is written,
    so no code path can put a superseded form back on disk. Tests needing an
    older form own the fixture, as phase 1's `LegacyPageFile` already did.
13. **Importing a PDF does not turn to it.** The pages land at the end and the
    visible page is unchanged, because turning on import is navigation and
    navigation is the import UI's decision. Consequence: a first-launch
    document plus an import leaves one blank page in front of the worksheet.
14. **`CoreGraphics` was added to the contract checker's banned-import set**,
    with `PDFSource.swift` as its one allowlist entry. It is not a UI
    framework, so this stretches the rule's name to serve its purpose — the
    ban is on acquiring a graphics framework's whole vocabulary, and
    `CGPDFDocument` arrives with `CGContext` and `CGImage` attached. One line
    to revert; reverting means any file can import it unnoticed. `PDFKit` was
    rejected for the same job: a document *view* stack for two answers.

## Discoveries

1. **Cross-lane semantic merge conflict, caught by the compiler, not by git.**
   The `loud-by-default` lane called `ContractStructureTests.codeOnly`; the
   checker lane had moved that helper into a new `ContractChecker` enum. Both
   were correct against their own base, git merged the text cleanly, and the
   build failed. Fixed in `71c6099`. **The lesson for the rest of the grind:
   a clean text merge proves nothing; every merge gets a full build.**
2. **Undo is unprovable off-device in this project.** `undoManager` walks the
   responder chain, so an unhosted controller always reports `nil`
   (`Unproven.md`, "Environment traps"). This makes proposed amendment A10
   (one manager, two clients) genuinely unverified — phase 4's whole undo
   design rests on PencilKit tolerating foreign registrations, which nothing
   has checked.
3. **The old contract checker was blind in more ways than the queue item
   claimed.** Beyond non-recursion: the import rule matched exactly one
   spelling (`@preconcurrency import UIKit`, `import struct UIKit.X`, and
   doubled whitespace all passed); `PKCanvasView.init(` was missed; and the
   rules were counted over all sources *joined without a separator*, so a file
   ending in `PKCanvasView` next to one starting with `(` would have formed a
   phantom construction site.
4. **Two blind spots remain in the checker and are now recorded as
   `KNOWN DEFECT:`** — string interpolation is discarded with its enclosing
   string (so `"\(FileManager.default)"` is invisible to every rule), and
   `"""` literals scan as a pair of empty strings. Both under-report; the fix
   is a real Swift lexer.
5. **Warnings-as-errors is doing real work.** A deliberate sabotage of the
   canvas-construction rule failed to *build* rather than failing the test,
   because an unmutated `var` is an error here.
6. **`CanvasLog`'s cost per event was already correct** — the gate is a
   `static let`, so the environment is read at most once per process, and no
   call site is on the frame path. Nothing needed fixing there.
7. **A C function pointer trap:** inside `NSSetUncaughtExceptionHandler`'s
   closure, every static must be spelled `CanvasLog.…` — an unqualified
   reference reads as captured context and fails to compile.
8. **THE IMPORTANT ONE — parallel agents silently corrupt each other's test
   verdicts.** The pinned simulator is a single shared instance and every
   build carries the same bundle identifier, so one agent's `xcodebuild test`
   can execute *another agent's* installed bundle. The phase 2 agent caught
   this: its run reported suites that do not exist in its tree (`Shape
   synthesis`, `Contract structure — the checker`), its own new suite never
   appeared, and an untouched test failed. **This is not a flake; it is a
   wrong verdict, in both directions.** I saw the same thing from the
   integration side — one run reported "21 tests in 3 suites failed with 1822
   issues" and the identical tree passed 94 seconds later.
   *Mitigation used:* the phase 2 agent finished on a private simulator cloned
   from the same device type, then deleted it; and every integration verdict
   in this log was re-run with no agents active. *Standing rule adopted for
   the rest of the grind:* each parallel agent creates and destroys its own
   simulator, and no green is trusted that was recorded while another agent
   was running. **Worth a queue item** — per-agent bundle IDs or per-agent
   simulators, because this will bite any future parallel work.
9. **`PKStrokePath` is a B-spline**, which makes four strokes for a rectangle
   *mandatory* rather than merely preferable: measured, a one-path rectangle
   cuts every corner by a third of its depth (control points evaluate as
   `(P0+4P1+P2)/6`). The fork doc guessed right for the wrong reason.
10. **PencilKit end-clamps the spline itself**, so the endpoint-triplication
    workaround the shape agent built was measured as dead weight and removed.
    Storage is also reduced-precision — a location round-trips within
    ~1.5e-5 pt, `opacity 1 → 0.99998` — so "endpoints exactly the corners" is
    not achievable and the tests assert what PencilKit actually keeps.
11. **`PKDrawing.image(from:scale:)` rasterizes in the simulator**, so "the
    ink actually lands on the shape" *is* CI-testable. That was not obvious
    and it is the only pixel-level guarantee this project has.
12. **The save path derived "which pages changed" from ink state alone**, so
    an import onto a page with clean ink produced no write at all. Found and
    fixed during phase 2. The same gap would have let the first ink save
    after an import silently delete the image, because the session had
    nowhere to keep the page's layer list — the contract already named
    `EditorSession` its one writer; it simply had nothing to write.
13. **`UndoManager` does not retain an action's target**, so a page leaving
    the live window must call `removeAllActions(withTarget:)`. Consequence,
    now a `KNOWN DEFECT:` at the site: a shape committed on a page you turn
    away from and back is no longer undoable. A dangling target is a crash;
    this takes the safe half.

14. **The split makes "a save landed" invisible to anything watching
    `pages/`.** An ordinary ink save now writes *only* a layer file, so
    `EditorSessionTests`' `savedAt` probe — which polled page-file mtimes —
    waited forever and failed one adaptive-debounce test. It went unnoticed
    through the whole implementation because the *first* save of a page still
    writes both; only a test measuring a second save's timing could see it.
    **Anything future that watches page files to detect a save is wrong now**,
    and the same trap is waiting for a file-coordination or sync layer.
15. **Two existing tests quietly stopped proving their point.**
    `savingOnePageDoesNotRewriteTheOther` and
    `turningAwayAndBackDoesNotRewriteThePage` assert a page file's mtime is
    unchanged — which after the split is trivially true for *every* ink save,
    including a wrong one. They passed while proving nothing. Both now also
    assert the page's ink *layer* file, which is where its bytes actually are.
    The general lesson: a change of granularity can turn a real assertion into
    a tautology without failing, and only re-reading the tests finds it.
16. **The dangling-layer-ref refusal cannot fire for a page with no file, and
    that is correct rather than a gap.** A page whose file does not exist, and
    a page still in a pre-split form, both write every layer forward whatever
    the caller claims — none of their layers has a file to be unchanged. The
    first version of the exit-adjacent test asserted a refusal in exactly that
    case and failed, which is how the rule got stated precisely instead of
    approximately.
17. **The split made orphan detection cheaper, not dearer.** "Does any page
    still name this layer?" now reads page files that are lists of UUIDs,
    where before answering any structural question meant decoding every
    envelope on the page including its ink. Asset reclamation scans every
    layer file — a strictly larger set than the referenced ones, so strictly
    more conservative — plus any pre-split page file's inline envelopes, which
    is what makes a half-migrated document answer correctly.
18. **The exit test was verified by sabotage.** Coarsening the save path to
    mark every static layer changed makes it fail naming the `pdf` envelope as
    a second rewrite. It compares the whole document package by both
    modification date *and* bytes: mtime alone would miss a rewrite inside the
    filesystem's timestamp resolution, and bytes alone would miss a rewrite of
    identical content — which is still the whole-file write the format exists
    to avoid.
19. **`UIGraphicsPDFRenderer` makes multi-page, mixed-geometry PDFs testable in
    the simulator**, including per-page bounds via
    `beginPage(withBounds:pageInfo:)`. A 5-page, 794 KB fixture builds in
    ~150 ms, so the exit test's "large import" is real bytes rather than a
    stand-in — this is the second CI-testable thing in this project that was
    not obvious, after `PKDrawing.image(from:scale:)`.

## Morning items — Phillip must address

### 1. The device session (do this first — three items resolve at once)

`Tools/device` now has a `--release` flag and forwards the spike variable,
so one session answers spike 1, proves `loud-by-default`, and gives phase 1
its device pass.

```bash
Tools/device --check              # unlock the iPad first — DDI mounts on unlock
```

Put `TN_SPIKE_CONDITIONS = TN_SPIKE_MIRROR` in `Local.xcconfig` (remove it
after), then:

```bash
Tools/device --release                                   # variant A, the sibling mirror
TN_SPIKE_MIRROR_VARIANT=inside Tools/device --release    # variant B, the crash test
```

Ctrl-C ends the session and prints the digest. Console lands in
`Artifacts/device/<utc>-<sha>/console.log`; re-read any past one with
`Tools/device --digest <path>`, no iPad needed.

**Variant A — what to look for.** Ink a line along a 100 pt grid line and a
circle around the centre fiducial. Then pinch fast with mid-gesture
reversals; fling vertically at high zoom through deceleration; rubber-band
past the page edge and past fit-width. The observable is *line position*
during motion — ink peeling away from the pattern is the failure. Softness
at deep zoom is expected and is not the failure.

**Variant B — one Pencil stroke.** Survive or trap is the entire result. A
trap now prints a crash banner rather than `NO TRACE CAPTURED`; that fix is
what makes this result visible at all. Per the fork doc, even survival does
not let this branch win until it explains the recorded
`_delayTouchesForEvent:` crash.

**This is the verdict everything downstream waits on.** Phases 2–4 render
through the sibling mirror on the presumption that variant A holds.

### 2. The contract lags the code — close it

`Docs/Contract.proposed.md` stages every amendment, marked LANDED / FORCED
(code is written and green; the contract has not caught up) / AHEAD (adopt
with its phase). Read the four open questions at the bottom; two are real
design forks, not formalities:

- **A10 (undo: one manager, two clients) is written as if the spike passed,
  and it has not run.** Undo cannot be tested off-device here at all.
- **A5** pays one amendment per kind by design. Confirm you want that
  friction, or amend once for `image` and `pdf` together — cheaper, weaker.

### 3. Judgment calls to confirm or reverse

- `UserDefaults` added to the checker's file-I/O token list (defensible,
  one line to delete).
- `Tools/device-tests` deliberately not wired into CI, because
  `CONTRIBUTING.md` says CI calls no script in `Tools/`.
- Whether phase 5's shape tool activation UI matches your taste at all —
  it was built to the smallest honest affordance, not to a design.

### 4. Verdicts no agent may render

Pencil feel, stroke fidelity, turn feel after settling, and whether a
synthesized shape *looks like ink*. Recorded as evidence, left to you.
