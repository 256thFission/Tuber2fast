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

### Phase 4, transformable `image` layers — the decisions

14. **A recognizer, not the chrome view.** The fork doc names a selection chrome
    view owning its own recognizers as the escape hatch if fall-through fights
    UIKit. It cannot be built: under the transparent `PKCanvasView` a chrome
    view gets no touches (the canvas is above it), and above the canvas it eats
    every Pencil touch over the selected image — you could no longer draw on a
    picture you had selected. `LayerDragRecognizer` asks the same unit-square
    question a view's `hitTest` would; it just asks it inside a recognizer that
    *fails* rather than inside a view that must sit somewhere in the z-order.
    Recorded in A11, because if this fights UIKit on device the finding is that
    neither structure works.
15. **The blank-page path grows nothing at all.** A page with no selectable
    layer builds no `LayerSelectionRuntime`, so it has no tap recognizer and no
    drag recognizer. The same narrowing decision 7 makes for transparency, and
    it turns the fork doc's "zero new gesture cost" into a fact about the object
    graph. A11 wants one sentence amended to say so.
16. **Scale and rotate are handle drags. There is no pinch recognizer.** A
    `UIPinchGestureRecognizer` contends directly with `PKCanvasView`'s own
    pinch-zoom, which *Navigation* hands to the framework outright, and winning
    that fight means either stealing zoom while an image is selected or losing
    the scale. Handles need no arbitration — they are a different *place*, and
    place is what the hit test already answers. Four corner handles scale
    (uniform in the layer's own frame, anchored at the opposite corner) and one
    handle above the top edge rotates about the centre. **This is a UX call an
    agent made and Phillip may hate it.**
17. **Rotation is applied in page space, scale in the layer's own frame**, and
    the asymmetry is load-bearing. `fittingSource` sets `a` and `d`
    independently, so a placed image is anisotropic in page space: rotating in
    unit space and then applying that mapping is a *shear*, and the handle would
    not track the finger. Scaling in the local frame is what preserves the
    placed aspect ratio, which a page-space uniform scale would silently
    destroy.
18. **Excluding the selected layer needed no new mechanism.** `CompositeKey` is
    already the list of layer IDs plus the scale, so the minus-one composite is
    an ordinary second cache entry. It is also *stable under the drag*: moving
    the selected layer changes nothing about the request that excludes it, so a
    whole gesture — and every commit inside it — causes exactly zero
    re-composites.
19. **The fork doc's no-ghosting ordering is one step wrong, and the code does
    the other order.** "Selection kicks off the minus-one recomposite; until it
    lands the moving layer renders live over the stale composite" assumes the
    live render is free. It is not — it needs a decode. So the code decodes the
    lifted layer *first* and only then asks for the minus-one composite; before
    the decode lands nothing has changed at all. The fork doc's order has a
    window in which the composite has dropped the layer and nothing has picked
    it up, and in that window the layer **vanishes**. Deselection is the mirror:
    the full composite is asked for while the lift is still up and the lift is
    dropped only when it lands.
20. **The lifted layer is a sublayer of `PageBackdrop.page`**, which already
    carries the mirror transform, so pan and zoom come free and the lift needs
    only the layer's own page-space transform. Its bounds are the source's pixel
    extent at `contentsScale` 1 and the pixel→unit-square scale is folded into
    the transform, so nothing is resampled by the layer tree. `page` also gained
    `masksToBounds = true`, so a layer dragged past the page edge clips exactly
    where the committed composite will clip it — otherwise the picture changes
    at the instant of commit.
21. **The lifted source is not cached.** One decode per selection, off-main,
    never during a drag. Putting it in the composite cache would mean a second
    kind of entry under a byte bound whose whole arithmetic is stated in
    page-sized composites.
22. **Undo registers *after* the session accepted, which is the opposite of the
    shape tool's order**, deliberately. The shape tool registers first because
    it is about to mutate `canvasView.drawing` and PencilKit may register its
    own undo for that assignment. A layer transform touches no drawing, so there
    is nothing to interleave with, and the only real hazard is the other one: an
    undo entry restoring a value the session refused. Asking first means exactly
    one registration per committed edit and none per refusal.
23. **The undo target is `self`, the page controller** — not a new object —
    specifically so that `willRetire`'s existing `removeAllActions(withTarget:)`
    already covers it. `UndoManager` does not retain a target; a second target
    would need a second retirement hook and would be a second way to leave a
    dangling one, which is a crash. Same `KNOWN DEFECT:` as the shape tool:
    a transform committed on a page you turn away from and back is no longer
    undoable.
24. **`locked` was added, because phase 4 genuinely reads it** — twice, in two
    owners — and it was given a *writer*, `EditorSession.setLayerLocked`, so
    that it is not a bit only a test can set. No UI calls it, exactly as no UI
    called `importImage` when phase 2 landed. **An envelope written before
    `locked` existed decodes as unlocked**, which is the read-forward rule
    *Durable form* already states for the pre-layer page form; the alternative
    is every page file on disk becoming unreadable for a bit that changes no
    other rule. One line to delete if Phillip would rather old files fail.
25. **A refused commit is put back rather than papered over.** The commit
    closure returns whether the session wrote it; on a refusal the selection
    runtime restores the transform the drag began from. A picture that disagrees
    with the file is worse than a drag that visibly did not stick.

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

19. **An `unowned` canvas reference makes a bare-runtime test fixture crash, not
    fail.** `LayerSelectionRuntime` holds its scroll view `unowned`, exactly as
    `ShapeToolRuntime` does, which is right in the app because
    `PageCanvasController` owns both. A test that wrote
    `LayerSelectionRuntime(canvasView: UIScrollView())` let the scroll view
    deallocate immediately — nothing else retains it, since a view retains its
    recognizers and not the reverse — and the whole test *process* died with
    "Attempted to read an unowned reference but the object was already
    destroyed", taking every later suite with it and printing "Executed 0 tests"
    over and over. It reads exactly like the shared-simulator wrong verdict
    (discovery 8) and is not one. The fixture must hold the view.
20. **`StaticLayerRenderTests`' pixel helper labels its bytes `(r, g, b)` and
    the sampling context does not hand them over in that order.** A pure red
    fill (`CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)`) sampled through
    that helper comes back as `(0, 0, 255)`, so index 2 is the red channel, not
    index 0. Green is symmetric under the swap, which is why the existing
    suite's green assertions pass; whether its `isRed`/`isBlue` assertions are
    testing the channel they name is **not** something this lane verified, and
    it is worth ten minutes. Phase 4's own composite test sidesteps the question
    entirely by comparing two pixels of two composites rather than naming a
    colour — the channel order cancels, and the claim being made ("the excluded
    layer is gone and the one beneath shows through") is stated more directly
    that way.

## A cross-lane warning I checked, and the answer

The phase 4 agent reported that `StaticLayerRenderTests`' pixel helper "labels
its bytes `(r,g,b)` and the sampling context doesn't deliver them in that
order — a pure red fill comes back as `(0,0,255)`", and worked around it
rather than trusting the helper. **I checked, and for that file the warning is
a false alarm. No action needed.**

The evidence, which is empirical rather than an argument from reading: the
fixture at `StaticLayerRenderTests.swift:75` is
`twoTonePNG(top: .blue, bottom: .yellow)`, and lines 82–83 assert `isBlue` on
the top and `isYellow` on the bottom. Both pass. Blue is `(0,0,255)` and
yellow is `(255,255,0)`, and **both are asymmetric under an R↔B swap** — a
swapped helper would read blue as `(255,0,0)` and fail `isBlue`, and would
read yellow as `(0,255,255)` and fail `isYellow`. Two independent asymmetric
assertions passing is proof the channel order is right.

Why the reader is correct by construction as well: it builds its own
one-pixel context with `premultipliedLast` and no byte-order flag, so memory
order is R,G,B,A; and the fixtures fill through `setFillColor(UIColor.cgColor)`,
which converts through the colour space rather than writing raw bytes, so the
fixture context's `byteOrder32Little` layout never reaches the test's
arithmetic.

The phase 4 agent was most likely observing its own helper in its own context,
not this one. Its workaround (comparing two pixels of two composites rather
than naming a colour) is harmless either way.

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

### 3b. Phase 4 by hand — the checklist an agent cannot run

None of this is provable off a device. Import an image onto a page first
(`EditorSession.importImage` is still the only entry point — there is no import
UI, so drive it from a test build or add a temporary call).

**Selection and the arbitration rule — the part most likely to be wrong.**

1. On a page with **no** image: pan, pinch, and swipe to turn. Everything must
   feel exactly as it did before phase 4. It should, because such a page builds
   no selection runtime at all — but this is the control, so do it first.
2. On a page **with** an image and nothing selected: pan, pinch, and swipe to
   turn, including a swipe that starts *on top of the image*. All three must
   still work. This is the "zero new gesture cost" claim; the tap recognizer is
   present here and must not be able to claim a drag.
3. Tap the image. Chrome appears: an outline, four corner dots, and a dot on a
   stalk above the top edge.
4. **With the image selected**, swipe from bare page to turn the page. It must
   turn, and the selection must go away as you begin. This is the fall-through
   rule and the thing most likely to fight UIKit.
5. **With the image selected**, at fit-width, drag horizontally starting *on
   the image*. It must move the image and **not** turn the page.
6. Zoom in past fit-width, then pan starting off the image — it must pan the
   page. Pan starting on the image — it must move the image.
7. Write with the Pencil over a selected image. Ink must land normally; the
   selection must not eat it.

**Move, scale, rotate feel.**

8. Drag the body: the image should track the finger exactly, with no lag and no
   rubber-banding.
9. Drag a corner: the *opposite* corner must stay nailed to the page and the
   aspect ratio must not change.
10. Drag the stalk handle: it should rotate about the image's centre and the
    handle should stay under the finger.
11. Do all three at deep zoom. Handles are sized in view points, so they should
    feel the same size at every zoom.
12. Watch for a flash or a double image at three moments: when you tap to select
    (the layer is lifted out of the composite here), during the drag, and when
    you tap away to deselect (it is folded back). There should be none at any of
    them; a brief soft-then-sharp is expected and is not the failure.
13. Drag the image half off the page edge. It must clip at the page edge while
    dragging and look identical after you let go.

**Undo — the one that decides whether A10 is adoptable.**

14. Move the image, then Cmd-Z (or the system undo gesture). **One undo must put
    the image back exactly where it was, and must not also undo a stroke.**
15. Cmd-Shift-Z must move it forward again.
16. Draw a stroke, move the image, draw another stroke. Three undos must reverse
    those three things in that order, one each.
17. If undo does nothing at all for the image move, that is the unverified
    claim failing: PencilKit is not tolerating a foreign registration in its
    manager. It fails *silently* — the move is still saved correctly — so this
    has to be checked deliberately rather than stumbled on. **A10 is not
    adoptable until this passes.**
18. Move the image, turn to the next page, turn back, then Cmd-Z. It will not
    undo the move — that is the recorded `KNOWN DEFECT:`, shared with the shape
    tool, not a new bug. Confirm it is *only* that, and that nothing crashes.

**Taste calls that are yours alone:** the handle size and shape, the dot-on-a-
stalk rotation affordance, the dashed handleless chrome for a locked layer, and
whether handle-drags are the right answer at all versus a two-finger pinch on
the layer. The reasoning for refusing the pinch is decision 16; the verdict is
not an agent's.

### 4. Verdicts no agent may render

Pencil feel, stroke fidelity, turn feel after settling, and whether a
synthesized shape *looks like ink*. Recorded as evidence, left to you.
