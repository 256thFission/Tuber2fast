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

### Phase 2, rendering half — the decisions

6. **A `CALayer`, not a sibling view.** The fork doc's presumed structure says
   "sibling view under a transparent `PKCanvasView`". The stack is a `CALayer`
   instead, for the reason `pageBoundary` and the shape tool's preview are:
   layers never participate in touch handling. The sibling *view* would not
   reproduce the recorded `_delayTouchesForEvent:` crash — it is a subview of
   the controller's root, not of the canvas — but it buys nothing a layer does
   not, and this project has one recorded crash caused by putting a view where
   a layer would do.
7. **Transparency is paid per page that has a stack, not once for the app.**
   The fork doc says the ink surface goes transparent and "a full-screen blend
   under the ink is the floor cost everywhere, forever". It does not have to
   be: a page with no static layers installs no backdrop and keeps its opaque
   white canvas, so every page in a blank notebook is untouched by this
   feature. A **narrowing of the fork doc's own cost claim**, and worth an
   amendment to that paragraph if Phillip agrees.
8. **Level of detail is fit-width × display scale, not zoom.** Deriving detail
   from `zoomScale` would put a decode behind every pinch. The composite is
   re-asked for only at layout — a rotation or a Split View resize moves
   fit-width — and never from a gesture callback. Capped at a 2,800 px long
   edge, so a composite costs at most about 24 MB. Deep zoom shows this texture
   scaled and soft; sharpening it is phase 3's lens and needs spike 2.
9. **The render cache is in memory only, and the on-disk one is deferred.**
   A7 (the derived-artifact narrowing) has not been adopted, and an image does
   not need it to become visible. Nothing is written to disk by this lane.
10. **The cache's bound is 96 MB and its eviction is the live window.** Bytes,
    not pages, per the contract's *Performance* rule and the fork doc's
    explicit refusal of pages as a unit. `retain(layerIDs:)` — driven by
    `EditorSession` on every turn, beside `pruneDurableBytes` — is the policy;
    the byte bound is the backstop that trims least-recently-used entries. The
    renderer never learns a page ID, which is what lets `PageCanvasController`
    stay blind to which page it is (golden rule 7): the cache keys on layer
    IDs.
11. **A refusal is total.** Every layer is decoded before anything is drawn,
    and one failure refuses the whole composite. A partial composite is the
    failure the layer model exists to prevent: it looks correct and is not.
    Refusals are cached at zero bytes, which is safe only because assets are
    write-once — a render of an immutable source can be missing but never
    stale.
12. **A tint carries the placeholder, and no sentence.** The page-level
    placeholder (`PagedCanvasController.makePlaceholder`) is grey with a label
    because it *replaces* a page. The backdrop's is an opaque pale teal with no
    label, because it sits under live ink on an editable page — a label there
    would be unreadable the moment anyone wrote on it. Refusal is a pale red,
    a different colour on purpose: a refusal that looks like a slow load is a
    refusal nobody acts on. Both colours are an agent's choice against
    "loudly distinguishable from blank" and are Phillip's to overrule.
13. **Prefetching neighbour composites is deliberately not built.** The fork
    doc names `turn-settles-once` as a direct dependency: today a turn fires at
    the midpoint of a drag, so prefetching decodes would start work twice on an
    abandoned half-drag. The cache *permits* a neighbour's composite to
    survive; nothing creates one before its page is built.

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

14. **`#expect(aCGFloat == aDouble)` fails on identical bit patterns.** Swift's
    implicit CGFloat/Double conversion does not survive Swift Testing's macro
    expansion. `#expect(layer.bounds.width == PageGeometry.width)` failed while
    printing `(… → 612.0) == (… → 612.0)`; the two `bitPattern`s were compared
    and are the same integer. Every mixed comparison in this repository needs
    an explicit `Double(...)`. Recorded in `Unproven.md` — Environment traps,
    because it will cost the next person an hour otherwise.
15. **`Thread.isMainThread` is unavailable from an async context** in Swift 6.
    `pthread_main_np() == 0` is the spelling that compiles, and it is how the
    renderer checks the contract's own "never on main" rule from inside a
    `nonisolated` function.
16. **XcodeGen writes a static file list, so a new test file is silently not
    run.** `xcodebuild test` reported `TEST SUCCEEDED`, 129 tests in 13 suites,
    with a whole new 22-test suite on disk and absent from the project. The
    build of the file that does not exist cannot fail. **Re-run `xcodegen
    generate` after adding any file, and check the suite count moved** — a
    green run that never compiled your tests is exactly the wrong verdict the
    shared-simulator discovery was about, arriving by a different road.
17. **`PKCanvasView` tolerates being made transparent after construction.**
    `backgroundColor = .clear` and `isOpaque = false` set on a live canvas
    behave; the ink still renders. Simulator evidence only — PencilKit's ink
    surfaces are its own business and this is exactly the kind of thing that
    differs on device.
18. **The fork doc's payload choice survives contact with a compositor.** The
    durable half stores an asset ref plus a transform of the image's *unit
    square* and deliberately does not store the source's pixel size. That is
    the right shape: the compositor needs the placed extent (the transform's
    column lengths), not the source's, and it needs it *before* it decodes —
    which is precisely what makes `kCGImageSourceThumbnailMaxPixelSize`
    computable without opening the file. `Unproven.md` asked whether the
    payload was what the compositor wanted. It is.

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
- **Rendering-half judgment calls, all listed as decisions 6–13 above.** The
  two that are design forks rather than taste: transparency paid *per page
  with a stack* rather than app-wide (decision 7 — it narrows a cost claim the
  fork doc makes in prose, so that paragraph wants amending), and the 96 MB /
  2,800 px numbers (decisions 8 and 10 — arithmetic on the fork doc's own
  unmeasured 22 MB estimate; spike 2 is what corrects them).
- **The backdrop's two tints.** Pale teal for loading, pale red for refused,
  no label on either. Written to "loudly distinguishable from blank" and
  nothing more; if they look wrong they are two constants in
  `PageBackdrop.swift`.
- `Tools/device-tests` deliberately not wired into CI, because
  `CONTRIBUTING.md` says CI calls no script in `Tools/`.
- Whether phase 5's shape tool activation UI matches your taste at all —
  it was built to the smallest honest affordance, not to a design.

### 4. Verdicts no agent may render

Pencil feel, stroke fidelity, turn feel after settling, and whether a
synthesized shape *looks like ink*. Recorded as evidence, left to you.
