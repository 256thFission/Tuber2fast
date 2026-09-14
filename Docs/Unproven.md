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
grep -rn "KNOWN DEFECT" TuberNotesApp/ Modules/ TuberNotesTests/
```

`Modules/` and `TuberNotesTests/` are in that command because blocks live in
both: the canvas runtime and the renderer moved into `Modules/` and took their
defects with them, and a check that is wrong about what it proves is a defect
at the check.

Nothing here is a reason not to ship. It is a reason not to be surprised.

---

## Never exercised by hand

- **The library browser has been launched and seen, and almost nothing in it
  has been tapped by a hand.** Two launches in the pinned simulator produced
  screenshots (the spine, then the integrated build) showing the sidebar, the
  toolbar, and a document's cell — an adopted one, in a build that still
  adopted. Every flow — create, open, Back,
  rename, move, trash, recover, duplicate, favorites, sort, filter, search,
  multi-select — is proven by unit tests driving models and stores, which
  proves the logic and nothing about the touch. The handover's ten-minute
  walk is the missing evidence, and the popover/sheet feel on a real screen
  is Phillip's verdict.
- **`EditorSession.close()` has no device evidence, and it needs it.**
  `EditorSession.swift` is on CONTRIBUTING's device-evidence list. The
  retain-if-dirty drain — a dirty close surviving behind the browser, the
  banner, the blocked opens, the eventual drain — has been exercised only
  through a gated test store, never against a really-failing disk, and never
  on an iPad. Required but not done.
- **Off-main `PKDrawing` thumbnail rendering is measured on the simulator
  only.** ~52 ms cold / 2–14 ms warm per thumbnail, deterministic across
  runs — on a Mac's CPU through a simulator PencilKit. No inequality about
  an iPad follows from it, in either direction; same caveat as the settle
  decode benchmark below.
- ~~Adoption has run only against scratch roots~~ — **gone, not proven.**
  `LibraryStore` no longer adopts a pre-library `JustACanvas.tubernotes`; the
  shim was deleted with the rest, and the store now reads, moves, and adopts
  nothing outside its own tree. Any such document on an iPad is now invisible
  to the library rather than imported by it, which is the deliberate
  consequence of having no live users.
- **Library name collisions have never met a case-sensitive volume.**
  `LibraryStore` resolves collisions by asking the file system (`fileExists`
  on the real path), never by string-comparing listings, precisely because
  the device's data volume is case-sensitive while the pinned simulator's is
  not — so `Notes` and `notes` are one name in CI and two on an iPad. The
  mechanism is the right one, but its case-sensitive behavior has only ever
  run where case does not exist; it belongs on the device checklist.
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
- **PencilKit's lasso has never been held by a real Pencil.** The lasso tool
  reaches the live canvas and the conversion is pinned by a test, so the
  marquee, the selection drag, and the edit menu are PencilKit's and are
  presumed to work. Presumed: whether a finger can drag a selection the
  Pencil enclosed while the drawing policy is `.pencilOnly`, whether one
  selection drag is one drawing change — one undo entry — or one per frame,
  and whether the edit menu appears over the selection at all, are live-touch
  facts the simulator cannot express. Until someone looks, "the lasso works"
  is a claim about a tool assignment.
- **Nobody has seen an object selected, moved, scaled, rotated, or deleted.** The
  selection frame is an overlay in the canvas runtime and the object under it
  is the composite the notebook rendered, so the picture keeps the old
  placement until the re-render lands: the frame moves under the finger and
  the image jumps to it at the drop. How long that gap is, whether the jump
  reads as a bug, whether the corner handles and the rotate knob are the
  right size under a finger at fit zoom and at 4x, and whether a drag on the
  frame really does beat both the canvas pan and the page-turn pan are device
  evidence and Phillip's verdict. Whether the frame's `UIEditMenuInteraction`
  presents its Lock and Delete actions at all is in the same bucket: the
  tests can drive the actions, not the presentation.
- **Nobody has seen an object locked.** The tests drive `lockRequested` and
  the composite that answers it, and they check the recognizer is disabled
  and the handles hidden. Whether a finger on a locked frame really does
  fall through to the canvas pan, whether the menu's Unlock is reachable
  under a finger at fit zoom and at 4x, and whether the grey border and the
  lock badge read as "locked" rather than "broken" are device evidence and
  Phillip's verdict.
- **No camera has ever been opened by this app.** The Take Photo row is
  hidden wherever `UIImagePickerController.isSourceTypeAvailable(.camera)` is
  false, which is every simulator, so nothing in CI reaches
  `CameraCapture` — not the presentation, not the delegate, not the
  `UIImage` to JPEG encode, and not the permission prompt.
  `INFOPLIST_KEY_NSCameraUsageDescription` is in the built bundle and
  `plutil` says so, which proves the key is there and proves nothing about
  what iOS does with it. Whether the first tap prompts rather than
  terminating, whether a denial leaves the row harmless, and whether the
  captured photo lands centred on the page are device evidence.
- **VisionKit's scanner has never been presented.**
  `VNDocumentCameraViewController.isSupported` is false in a simulator, so the
  Scan Document row is hidden there and no test reaches `DocumentScanner`: not
  the delegate, not the `didFailWithError:` spelling, not the per-page
  `autoreleasepool`, and not the full-screen cover. The pages a scan makes are
  covered by `TNTests/EditorViewModelTests.swift`, which hands `importScan`
  bytes directly — everything from `Data` inwards is proven and everything
  from the camera to `Data` is not. Two of its failure paths have no other
  evidence at all: a scan forced to fail must close the cover and banner
  rather than leave a cover with no exit, and a page that yields no encodable
  data must banner rather than be silently dropped.
- **A scanned page's legibility is a verdict nobody has given.** A scan is
  re-encoded twice on its way in — JPEG at quality 1 from the scanner, then
  HEIC at 0.9 by `ImageImport.normalize` — and whether dense text survives
  that at fit width and at full zoom has only been reasoned about. The
  fallback if it does not, a `CGImage` entry point into `TNRender` that skips
  the first encode, is not built.
- **The loading/unreadable placeholder has never been seen on a device**, and
  the refusal of Pencil input on it — the placeholder accepts no input at all —
  is a device check by nature; the simulator has no Pencil.
- **The writing loop's hand-exercised checks were never performed** — launch
  first-contact ink, scroll and zoom against the page, background-flush
  survival, autosave spacing under continuous writing, and the five-second
  retry ceiling.
- **No rotation has ever been watched, and rotation is now reachable.** The
  portrait pin was lifted (the library browser letterboxed on a landscape
  iPad), so a rotation is now an ordinary viewport resize hitting the same
  re-centre path Split View does — plus the browser re-laying its grid. The
  paired bound moved (`widestSupportedViewportPoints` 1032 → 1376, smallest
  displayable page 103.2 → 137.6 points) and the pairing is machine-checked;
  what no eye has seen is a live rotation over an open canvas, or over the
  browser, on any device or simulator.
- **No window has ever been resized.** `PagedCanvasController` now re-centres
  the current page when the viewport width changes, and the tests drive that by
  setting the hosted view's frame and laying out — which proves the arithmetic
  and nothing about Split View or Slide Over. What a real resize does to the
  live canvases inside the slots (their fit-width scale and content offset are
  `PageCanvasController`'s, not this one's), and whether the re-centre is
  invisible or a visible jump, are device evidence and Phillip's verdict.
- **Nothing has been dragged in the library, and nothing has been marked on a
  page.** A library item now drags onto a folder cell and onto the back
  chevron, a folder carries a colour and a symbol, and a page carries a mark
  that the page grid's Marked tab lists. Every one of those is proven by tests
  over the browser, the store, the notebook and the view model — which prove
  the move, the sidecar, the index and the mirrors, and nothing about the
  touch. Three things in particular are unproven and are touch facts: whether a
  drag off a grid cell beats the grid's own scroll, whether the drop highlight
  reads at a glance, and whether marking the current page from the toolbar
  turns no page and reloads no canvas. Required but not done.
- **Pencil feel, stroke fidelity, palm rejection, and Pencil/touch separation
  are unrendered.** They are Phillip's verdict alone, and no mechanical evidence
  substitutes.
- **Almost every width the tool strip offers is a guess.** `InkKind.points` and
  `EditorTool.pixelEraserPoints` are twelve numbers, three per ink kind and
  three for the pixel eraser, and eleven of them are taste. The twelfth, the
  thinnest pixel eraser, is PencilKit's own minimum, because a narrower one is
  silently widened. The tests prove the three of a kind differ, that each is a
  width PencilKit keeps, and that each reaches it unchanged. All of that is
  arithmetic. Whether thin is thin, whether the highlighter covers a line of
  handwriting, and whether the pixel eraser bites at the size it looks are a
  device's answer and Phillip's verdict.
- **The text tool's numbers are taste too.** `TextStyle.body` (the system face
  at 16 pt, black), the seven sizes the text popover offers, and the 240 by 96
  box `Notebook.createTextBox` opens at the tap have met no Pencil and no
  finger. Whether a new box reads as a note and whether the sizes cover a
  heading and a caption are Phillip's verdict on the iPad.
- **Scribble has never written into a box.** The simulator has no Pencil
  and Scribble does not run there, so the hosted test proves only the
  configuration: the interaction is on the live view, its delegate refuses
  a start outside the bounds, and spelling and autocorrection are on. That
  handwriting becomes the typed runs, that a Scribble scratch-out inside
  the box deletes a word and leaves the ink alone, that a stroke starting
  just outside the box is ink and not a word, and that autocorrection's
  substitutions read as prose are a device's answer and Phillip's verdict.
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
- **No `image` layer has ever been seen by an eye.** The durable half saves,
  loads, round-trips a transform, and reclaims its asset; the rendering half
  composites it, and the composite is asserted pixel by pixel — stacking order,
  orientation, and placement all fail if they are wrong. What is unproven is
  everything between that texture and a person:
  - **the mirrored sibling has never registered against real ink.** The
    transform is asserted arithmetically at three offsets and zooms, which
    proves the formula and nothing about 120 Hz. Whether the stack holds
    position with ink through pinch, fling, and rubber-band is device spike 1,
    and it has not run. Every page carrying an image renders on the presumption
    that it does.
  - **the overdraw cost of a transparent `PKCanvasView` is an estimate nobody
    has measured.** The fork doc prices it at "≥ 2×, routine for M-series
    iPads"; that is arithmetic, not a frame capture. What the code does about
    it is narrower than the fork doc proposed — the canvas goes transparent
    only on a page that has something beneath it to show, which since paper
    landed means static layers **or** a template other than `blank`, so a
    genuinely blank page in a blank notebook still keeps its opaque surface and
    pays nothing. "One blended full-screen layer is free on this hardware"
    remains unmeasured either way, and a ruled notebook now takes that cost on
    every page rather than on imported ones alone.
  - **the placeholder tint and the refusal tint have never been seen.** Both
    are colours chosen by an agent against a written requirement that they be
    "loudly distinguishable from blank". Whether they read as chrome rather
    than as content, and whether ink over them is comfortable to write, is
    Phillip's verdict.
  - **softness under zoom has never been looked at.** A pinch shows the
    fit-width composite scaled, deliberately: no decode is triggered by a
    gesture frame. Whether that softness is acceptable, or whether phase 3's
    base-and-lens is needed sooner than planned, is a thing to see rather than
    to reason about.
  - **The import UI exists and no hand has used it.** `RootCanvasView`'s
    photo button presents a `PHPickerViewController` and calls `importImage`;
    neither the presentation nor the picked-asset path can run headless, so
    every image the suite imports is bytes handed straight to the session.
- **The render cache's byte bound has never met a real photograph.** The 96 MB
  bound is derived from the fork doc's estimate of 22 MB per fit-width
  composite, which is itself unmeasured. The eviction *mechanism* is tested;
  the *number* is arithmetic on an estimate.
- **No `pdf` layer has ever been seen by an eye, and the same doubt is larger.**
  The kind is durable — one import becomes one page per source page, the asset
  is written once and never rewritten, refs round-trip with their source page
  index and their placement — and since phase 3c the rendering half exists
  too: `OpenPDFDocument` turns a source page into pixels, `StaticLayerRenderer`
  draws those pixels into the base composite and into the lens, and
  `PageCanvasController` asks for the lens at settle. `PDFPageRasterizerTests`,
  `PDFLayerRenderTests`, `LensTests`, and `PrefetchWarmTests` hold it.
  - **The unit-square payload is no longer unproven — it is decided, by the
    renderer that was supposed to decide it.** This entry used to say the
    source page's point size might have to become durable and that phase 3's
    rendering half would find out. It found out, and the answer is no. The
    composite's pdf case needs the display size and needs the `CGPDFPage`
    itself two lines later, so a durable size saves no read; the lens derives
    the same geometry from the same document; hit-testing never asks
    (`PageSpaceTransform.containsUnitSquarePoint` touches no asset, and `pdf`
    layers are not selectable anyway); and paging and layout read
    `PageRecord.geometry`, which for an imported page already *is* the
    source's point size. A payload field would be a third copy of a number
    two places already hold. **Recorded as settled by evidence rather than by
    argument**, which is what this file asks of a claim before it stops being
    listed here.
  - **What is still owed to an eye is everything between those pixels and a
    person.** No PDF has been rendered on a physical iPad. Whether an imported
    worksheet reads as paper, whether the soft-base-to-sharp-lens swap at
    settle is visible as a flash, and what the lens costs in latency on a
    dense textbook page are all unmeasured — spike 2 is scaffolded and
    unthreaded and still owes a number.
  - **Also unproven: that CropBox-with-`/Rotate` is the rectangle users mean**
    — no PDF with a CropBox smaller than its MediaBox, and no rotated page,
    has been imported from the wild; both are simulator fixtures. The
    arithmetic is asserted; the judgment is not.
  - **The import UI exists and no hand has used it**, and the same is true of
    the one button that undoes a mis-import: `RootCanvasView`'s Files picker
    calls `importPDF`, and its trash button calls `deletePDFLayers`. The
    Files picker cannot run headless either, and the refusal alert
    ("This page has no PDF behind it.") has never been read off a screen.
- **No ruled page has ever been looked at, and paper is the one feature whose
  whole point is how it looks.** The template is durable, told down to the
  runtime, stroked into the base composite and re-stroked into the lens, and
  pixel-tested at every spacing — which proves that marks land where the
  arithmetic says and nothing about whether the result is paper. Owed to an
  iPad, in the order the eye meets them:
  - **The metrics are a proposal, not a verdict.** `ruleSpacing` 24 pt (US
    wide-ruled, rounded to a third of an inch, chosen wide because stylus
    handwriting on glass runs larger than pen on paper); `gridSpacing` and
    `dotSpacing` 18 pt (the quad-ruled quarter-inch square, deliberately not
    equal to the line pitch so a grid is not a lined page with columns);
    `dotRadius` 0.6 pt; `ruleWidth` 0.5 pt (one device pixel at 2× at
    fit-width); `topMargin` 72 pt, on `lined` alone. Every one of those is an
    agent's number against a written intention. Whether the ruling reads as
    *paper* rather than as a screenshot of paper is Phillip's verdict and
    nothing else.
  - **Rule contrast under live ink is unknown.** The mark colour is one
    constant — sRGB (0.58, 0.65, 0.75) — and 0.5 pt of it must recede under a
    black stroke without disappearing under nothing. Both failures are
    invisible to a pixel test, which asserts the mark is *there*. It needs
    checking at `lined` density and again at the denser 18 pt lattices, where
    four times as many marks compete for the same page.
  - **Whether the soft-base → sharp-lens swap on a ruled page shows as a
    flash.** This is a worse case than anything shipped so far and it is worth
    saying why: ruling is high-frequency edge content across the *whole* page,
    where a photograph's detail is local. The base is compositor-scaled during
    the gesture and the lens re-strokes at the settled scale, so the two
    pictures differ most exactly where the eye is looking.
  - **Whether a template change on a live page shows a visible blank frame.**
    `setTemplate` tears the composite down, bumps the generation, invalidates
    the lens, and re-requests; the new picture lands off-main some frames
    later. Nothing in the suite can see what is on screen in between.
  - **Lens latency on a dense page still owes a number**, and that is not a
    new debt: it is spike 2, recorded above under the `pdf` entry as
    *scaffolded and unthreaded*. A ruled page is a second dense fixture for
    the same unrun bench, not a second bench.
  - **The picker has never been tapped, and nothing mechanical can tap it.**
    There is no view test in this project at all, so `RootCanvasView`'s four
    buttons, their lit state, and `.disabled(session.currentPageCarriesPDF)`
    are unasserted as *view*. What is asserted is the property the disabled
    condition hangs on: `currentPageCarriesPDF` follows the visible page onto
    an imported PDF page and back off it when the PDF is deleted, with the
    document's paper unchanged underneath. Whether SwiftUI re-renders the
    picker promptly on a settled turn — the observation is published from
    `alignedWithIndex`, the load path, and `deleteLayer` — is a claim about
    Observation that only a screen can settle.

- **Mixed geometry has never been swiped through.** Per-page geometry landed
  in phase 3b, so the letterboxing is gone: an imported landscape worksheet is
  a landscape page, and the blank page a swipe past the end appends is
  canonical portrait beside it. Every claim about that is about files and
  arithmetic. What nobody has *seen* is the turn itself — whether the scale
  changing under you as you cross from a portrait page to a landscape one reads
  as correct or as a glitch, whether a landscape page opening at its own
  fit-width and leaving room above and below looks deliberate, and whether the
  grey either side of a narrower page in a uniform slot is comfortable. All of
  it is Phillip's verdict on a physical iPad; none of it is a thing a simulator
  can answer.
- **The zoom cap's number has never been felt.** Twenty device pixels per page
  point is now the ceiling on every device, where before it was the same number
  on most of them and a little less on the smallest. Nobody has zoomed to it on
  an iPad and decided whether it is deep enough to write small, or whether the
  composite's softness at that depth is worse than it was. The *arithmetic* is
  tested; the depth is a verdict.
- **`PKCanvasView`'s zoom clamp is measured on one iOS version.** Assigning a
  `maximumZoomScale` above 10 reads back as 10, on iOS 26.5 in the simulator. It
  is not documented by Apple, so it is a behaviour rather than a contract, and
  the durable cap is pinned against it. A test asserts the clamp so that a
  future iOS lifting it fails loudly rather than silently leaving the cap
  shallower than it needs to be.
- **The exit test proves which bytes moved, and nothing about time.** "Ink on
  page 4 of a large import writes one small file" is asserted as a set of
  files; that the resulting save is *fast*, on a device, with a 50 MB import
  and a real Pencil, is unmeasured — as is everything else in *No numbers
  exist*.

## Nothing exercises a touch

**No automated check delivers a touch to the canvas.** A first-stroke crash
inside `-[UIGestureRecognizer _delayTouchesForEvent:]` passes the structural
tests, the unit tests, and a clean simulator launch — every mechanical check
the project has — so that crash class is caught by a person on an iPad or not
at all, after CI and after review. The known price of closing this gap:
XCUITests that tap, drag, and pinch the real canvas cost four cold app
launches — 34.5s of a 41s test run, roughly six times the wall clock of the
entire unit suite under load — and can assert only that the process is still
running. `RootCanvasView` carries accessibility identifiers throughout —
`page.canvas`, `page.error`, `save.error`, and one per control on the shape
picker, the template picker, and the page actions — and **nothing reads any of
them.** They are the hooks such a suite would need, kept because writing them
after the fact is the expensive half; they prove nothing on their own, and a
count of them is not coverage.

## No numbers exist

- **No performance baseline exists.** Nothing has been measured on the device,
  so there is no numeric budget for anything, and no evidence about whether
  save cost scales with page count.
- **The settle-path decode was measured on the simulator only, and that
  bounds nothing.** `TuberNotesTests/SettleDecodeBenchmark.swift` generates a
  20k-stroke / 4.64 MB page and reports two medians on the pinned simulator:
  32 ms for one `PKDrawing(data:)`, and 219 ms for a settle that decoded five
  such pages on main. The decode moved off main on the strength of those
  numbers, so **that decision is provisional**. A simulator runs a Mac's CPU
  with a Mac's memory bandwidth through a PencilKit built for the simulator;
  it is neither an upper nor a lower bound on an iPad, and no inequality may
  be inferred from it in either direction.

  What is owed is the same suite against a device destination — the command is
  in the benchmark's own doc comment. What it can overturn is the *residual*:
  the settle now costs 0.35 ms on main for those same five pages, and if the
  iPad's residual is anywhere near a frame budget, the controller construction
  and `PKCanvasView` setup still left on the settle path are the next thing to
  measure. What it cannot overturn is the direction: a 32 ms decode is over a
  16 ms budget on any machine that reports a number like it.
- **Nobody has seen a page turn while its ink decodes.** A page whose bytes are
  held but not yet decoded is now a loading placeholder for as long as the
  decode takes — on the simulator that was 230–340 ms for five heavy pages at
  once, and on a page of ordinary ink it is too short to time. Whether the
  brief placeholder reads as responsive or as a stutter is Phillip's verdict on
  the iPad, and it is the price paid for the 219 ms freeze it replaced. The
  nearest page is built first so its decode starts first; whether that ordering
  is enough to make the current page feel immediate is part of the same
  verdict.

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

- **`DocumentStore.save` reports a page absent from the index as
  `missingPageFile`**, which names the wrong condition on a diagnostic path.
- **`deleteOrphanedPages` has no caller**, so orphans from a failed save
  accumulate for the life of the document.

Two are fixed and gone from that list. **The runtime is no longer index-keyed**
— identity crosses the canvas seam, `SlotHost` captures a page ID rather than a
position, and `setPages` reconciles a list that changed; the S8 opaque-token
idea was considered and not built, because the codebase already had a stable
identity and a translation layer is exactly what the change exists to remove.
**`fetchPageData` now takes its candidate identities before its first await**,
and its post-await writes go through a lookup that tolerates a page deleted
while its load was in flight.

## Page management has never been used by a person

Insert, delete, reorder, and duplicate exist and are exercised only by tests
driving `EditorSession` directly. Specifically unproven:

- **No UI calls any of them.** There is no button, no menu, no drag, and no
  delete confirmation — and the confirmation is not decoration: deleting a page
  discards any unsaved ink on it, which is the trade taken deliberately in
  place of an undo (`Contract.proposed.md` P4). Until that UI exists, the
  destructive operation has no guard in front of it.
- **Nothing has been felt.** Whether the offset restatement under a finger is
  invisible or a visible jump, whether a live reorder reads as the pages moving
  or as a jump, and whether deleting the page you are looking at lands
  comfortably on its successor are all Phillip's verdict on a physical iPad.
  The tests drive `setPages` and assert arithmetic.
- **The re-quiesce inside `duplicatePage` has no test of its own.** A duplicate
  whose source has been pruned must fetch its bytes, and it drains the save
  machinery a second time afterwards because a drain performed before a
  suspension has not been performed. Constructing a save that begins inside
  that window needs a store that can hold a *page load* open, and
  `HeldSaveStore` only holds saves. The reasoning is in the code; the check is
  owed.
- **A serializing queue for page edits was written and deleted**, because
  nothing could observe it — including a test written specifically to catch
  it, an insert issued beside a page together with that page's deletion. What
  actually enforces "a capture and a list mutation never overlap" is the drain
  *loop* plus the absence of any suspension inside a mutation. If a future
  operation needs real mutual exclusion, the queue comes back **with the test
  that fails without it**; `EditorSession`'s page-management section records
  the experiment so it is not re-added on intuition.
- **No document has been through a delete on a device**, so the reclamation
  order — index, page file, layer files, assets — has been proven only against
  a simulator's file system, where the volume is case-insensitive and
  `removeItem` never contends with anything.

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

`.github/workflows/ci.yml` and `device.yml` are written and committed, but no
push has exercised either. An unrun workflow is not CI; it is a YAML file that
has never been contradicted. See `prove-ci` in [`Queue.md`](Queue.md).

---

## Environment traps

Not gaps — properties of the tooling that read as project defects when hit.

- **Undo/redo cannot be unit tested here.** `undoManager` walks the responder
  chain, so an unhosted controller always reports `nil`. It is device evidence.
- **The simulator has no Apple Pencil.** Drawing, erasing, palm rejection, and
  pressure cannot be proven off-device at all.
- **`#expect(aCGFloat == aDouble)` fails on identical bit patterns.** Swift's
  implicit CGFloat/Double conversion does not survive Swift Testing's macro
  expansion, so `#expect(layer.bounds.width == PageGeometry.canonical.width)` fails while
  printing `(… → 612.0) == (… → 612.0)` — the two operands' `bitPattern`s were
  compared and are the same. Convert explicitly (`Double(layer.bounds.width)`)
  at every mixed comparison. Cost of not knowing this: an hour spent looking
  for a bug in code that was correct. The same trap wears a second face:
  *literal arithmetic* on the right of the comparison infers `Int` rather than
  the left side's type, so `#expect(scroll.contentSize.width == 500 * 9)` fails
  printing `(→ 4500.0) == (→ 4500)`. Bind the constant with a type
  (`let width: CGFloat = 500`) and compare against `width * 9`.
- **`Thread.isMainThread` is unavailable from an asynchronous context** under
  Swift 6, which is reasonable for the question it usually answers and useless
  when the thread genuinely is the question. `pthread_main_np() == 0` is the
  spelling that compiles, and it is what `StaticLayerRenderer` uses to check
  the contract's own "never on main" rule.
- **`UIScrollView.contentSize` is already multiplied by `zoomScale`.** An
  assertion expecting the unzoomed page width sees `612 × 1.3399 = 819.99` and
  reads as PencilKit ignoring page space; the implementation is right and the
  assertion is wrong. "Fixing" it in the code silently corrupts page space to
  view space.
