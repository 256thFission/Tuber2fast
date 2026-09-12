# Selection and transform on the page

A plan, not code. Branch `v2-mvp` (b84af06). Every claim below cites the
file it was read from.

**In short.** Half of this is already built and nobody has checked. The
lasso button becomes `PKLassoTool` and the runtime applies it, so
PencilKit's own lasso already selects, moves, cuts, copies, pastes,
duplicates, and deletes ink, and every one of those edits reaches the
notebook as an ink report and records an undo entry. What is missing is
objects: nothing on a page can be tapped, picked up, resized, rotated, or
deleted, although `Notebook.transformLayer` and `deleteLayer` exist,
validate, record, and are tested. This plan gives them a caller and
nothing else. With the lasso in hand, a tap on an image or PDF clipping
selects it: the runtime draws a frame with handles over the composite, a
drag moves the frame, a corner scales it, a knob rotates it, and the
drag's end is one `layerTransformed` report and one undo entry. The
notebook re-renders, the composite lands, and the image jumps to where
the frame is. Until then the picture shows the old placement under a
moving frame; that is the price of keeping every piece of selection state
in the runtime, and whether it is acceptable is Phillip's verdict on the
iPad. Delete is one new report. Two pull requests: a device check of the
built half, and the runtime.

## 0. Where it stands today

**Ink.** `EditorTool.lasso` (`Modules/TNEditor/EditorTool.swift:173`)
converts to `.ink(PKLassoTool())` (`EditorTool.swift:211-212`).
`EditorViewModel.selectLasso()` sets it (`Modules/TNEditor/EditorViewModel.swift:146`)
and the `didSet` pushes `CanvasEnvironment(tool: tool.canvasTool)` to the
binding (`EditorViewModel.swift:46-52`). `PagedCanvasController.apply`
forwards the environment to every live canvas
(`Modules/TNCanvas/PagedCanvasController.swift:348-353`) and
`PageCanvasController.apply(tool:)` sets `canvasView.tool = pkTool` and
enables the drawing gesture (`Modules/TNCanvas/PageCanvasController.swift:298-311`).
So the lasso is live. A Pencil drag with it draws PencilKit's marquee,
PencilKit's selection drags, and PencilKit's edit menu on the selection
offers Cut, Copy, Delete, and Duplicate. Each of those mutates
`canvasView.drawing`, and every mutation is one `canvasViewDrawingDidChange`
(`PageCanvasController.swift:631-648`), forwarded through `pageDidChangeInk`
(`PagedCanvasController.swift:605-617`) to `Notebook.inkChanged`
(`Modules/TNNotebook/Notebook.swift:273-289`), which records the entry at
line 285. PencilKit's own undo registrations are dropped by
`FilteringUndoManager` (`Modules/TNCanvas/FilteringUndoManager.swift:65-79`),
so the notebook's stack is the only one. The census row that calls the
lasso inert is wrong about the ink half: the runtime reads the tool at
`PageCanvasController.swift:303`, and `TNTests/EditorToolTests.swift:121-124`
pins the conversion. It is right that nothing of ours touches objects.

What has not been checked is whether that path holds under a real Pencil.
`drawingPolicy` is `.pencilOnly` on a device (`PageCanvasController.swift:200-204`),
so the marquee is the Pencil's; whether a finger can then drag PencilKit's
selection, whether a selection drag fires `canvasViewDidBeginUsingTool`
(`PageCanvasController.swift:607`) and so parks installs behind
`isStrokeInFlight` (line 92), and whether one drag fires one drawing
change or one per frame, are all unknown. One per frame would be one undo
entry per frame. None of it is observable in the simulator, which has no
Pencil (`CONTRIBUTING.md:98-101`). `Docs/Unproven.md` has no line for it.
That check is step 0.

The cost tripwire does not fire. `EditHistory`'s doc comment warns that a
lasso this app builds itself, through `PKDrawing(strokes:)`, costs 8 MB an
entry (`Modules/TNNotebook/PageState.swift:159-165`). PencilKit's lasso is
a canvas round trip: the value the notebook takes is `canvasView.drawing`,
the shape `TuberNotesTests/HistoryEntryCostTests.swift:86-108` measures as
a lasso pass. Nothing in this plan builds a drawing.

**Objects.** `Notebook.transformLayer(on:layer:to:)`
(`Notebook.swift:860-875`) validates through `Layer.validated()` (line
864), records the revision (line 869), and re-renders the composite (line
873), whose `.compositeUpdated` carries the moved layer list
(`Notebook.swift:618`). `Notebook.deleteLayer(_:on:)` (`Notebook.swift:877-889`)
records at line 884 and re-renders at 888. Both are pinned:
`TNTests/NotebookTests.swift:413` (transform then undo), `:431` (delete
then undo), `:452` (a refused transform and a transform to the one the
layer has record nothing), `:953` (a transform round-trips through the
store). `EditorBinding.layerTransformed`
(`Modules/TNEditor/EditorBinding.swift:211-215`) is the seam path up,
through `ReportForwarder.layerTransformed` (`EditorBinding.swift:39-42`),
answering `CanvasReporting.layerTransformed` (`Modules/TNModel/Seam.swift:154`)
synchronously with `.accepted` or `.refused`. Nothing in `TNCanvas` calls
it: the reporter's only caller is the test double at
`TuberNotesTests/TNCanvasTests.swift:740-742`. There is no delete on the
seam at all; `deleteLayer`'s callers are tests.

The runtime hit-tests two kinds. `HitRect` is `.link` or `.text` with an
axis-aligned `CGRect` (`PageCanvasController.swift:36-41`); `setLayers`
drops image and PDF layers on the floor (`PageCanvasController.swift:281-292`),
and it is called at build (line 165), on an install for a live canvas
(`PagedCanvasController.swift:490`), and with every composite
(`PagedCanvasController.swift:265`). `tapped(at:)` activates a link under
any `.ink` tool, the lasso included, and requests a text box or a text
edit under the text tool (`PageCanvasController.swift:555-572`). There is
no pan recognizer of ours on the canvas, no handles, no overlay for a
layer.

**Text boxes move already, inside their session.** `Layer.validated()`
refuses a non-identity transform on a text layer and on a link
(`Modules/TNModel/Layer.swift:270-275`), and `transformLayer` returns that
as `.refused(reason:)` (`Notebook.swift:864`), so the transform path cannot
move either kind. A text box's placement is its `rect`
(`Layer.swift:211-223`); `TextEditingView` carries a move handle and a
resize handle (`Modules/TNCanvas/TextEditingView.swift:20-28`), applies pan
deltas in page space (`TextEditingView.swift:132-156`), and the moved rect
travels in `committedLayer` (`TextEditingView.swift:92-98`) to
`Notebook.endTextEditing`, which records the session as one entry
(`Notebook.swift:850`). That is built and tested
(`TNCanvasTests.swift:627-640`). A link has no handle anywhere; section 7
says where that goes.

**The renderer applies the whole affine.** `PageSpaceTransform` is six
coefficients (`Modules/TNModel/PageSpaceTransform.swift:5-11`) with
`inverted` (lines 46-54) and `apply` (42-44); the format writes all six
(`PageSpaceTransform.swift:100-103`, `Modules/TNFormat/LayerFile.swift:100`);
`isValid` bounds only the determinant and the translation
(`PageSpaceTransform.swift:35-40`). `Renderer.draw(_ layer:in:)`
concatenates the full matrix before drawing an image or a PDF page into
the unit square (`Modules/TNRender/Renderer.swift:265-286`). Rotation is
representable, stored, and drawn today. It is a handle and nothing else.

**The overlay pattern exists once.** `TextEditingView` is a subview of
`canvasView` framed in page space (`PageCanvasController.swift:326`), so
it pans and zooms with the ink because the scroll view moves it; its
`contentScaleFactor` is set at insertion and at the end of a zoom
(`PageCanvasController.swift:374-383`); the canvas pan and the paging pan
`require(toFail:)` its recognizers (`PageCanvasController.swift:330-333`);
the tap recognizer refuses to begin inside it
(`PageCanvasController.swift:600-603`). The selection frame reuses each of
those and adds a third recognizer to the `require(toFail:)` list.

## 1. What GoodNotes does here, and what this plan matches

Matched: the lasso for ink, exactly as PencilKit provides it, which is
select, move, cut, copy, paste, duplicate, delete, each one undo step. Tap
to select an image or a PDF clipping, drag to move, corner to scale keeping
aspect, knob to rotate, tap for a menu with Delete. Every edit one undo
entry.

Deliberately not matched. The lasso path does not enclose objects; objects
are tapped, and only with the lasso in hand (decision 1). The selected
image does not travel live under the finger; the frame does, and the
image follows when the composite lands. PencilKit's ink selection has no
resize handles and none are added: resizing strokes means building a
drawing from strokes, the `PKDrawing(strokes:)` path
`EditHistory`'s comment prices at 8 MB an entry
(`PageState.swift:159-165`). No cut, copy, paste, duplicate, or crop of
objects, no multi-select, no z-order change. Convert-to-text and
snap-to-shape are the Pencil gesture lane's, and handwriting recognition
is deferred.

## 2. The data shape

Nothing is written to disk and nothing is added to the notebook. The
format is untouched: an image or PDF layer already carries the transform a
rotation needs.

```swift
// Modules/TNModel/Seam.swift, CanvasReporting, one report
/// Delete from the selected object's menu. Answered by the composite that
/// omits the layer, through `updateComposite`.
func layerDeleteRequested(on page: PageID, layer: LayerID)
```

`layerTransformed` (`Seam.swift:154`) is unchanged and is the drag's only
report.

```swift
// Modules/TNModel/PageSpaceTransform.swift
/// Whether `point` lies inside the unit square's image: the inverse applied
/// to the point lands in `0...1` on both axes. A hit test for a rotated
/// object, and for a link or text rect spelled as `unitSquare(to:)`.
package func contains(_ point: PagePoint) -> Bool
/// The lengths of the transformed unit edges, `hypot(a, b)` and
/// `hypot(c, d)`: the object's own width and height in page points,
/// whatever its rotation. The frame's bounds.
package var unitExtents: (width: Double, height: Double)
```

```swift
// Modules/TNCanvas/PageCanvasController.swift
/// One overlay at a time, structurally: a text session needs the text tool
/// and a selection needs the lasso, and `apply(tool:)` ends whichever is
/// open before the other can be asked for.
enum OverlayPhase {
    case idle
    case opening                                   // text: reported, no view yet
    case editing(layer: LayerID, view: TextEditingView)
    case selected(layer: LayerID, view: LayerSelectionView)
}

/// Every layer of the installed snapshot, in stack order, each as the
/// transform that places its unit square. Replaces `HitRect`: a rotated
/// image has no axis-aligned rect, and a link's rect is `unitSquare(to:)`.
struct HitTarget: Equatable {
    let id: LayerID
    let kind: LayerKind
    let transform: PageSpaceTransform
}

// Modules/TNCanvas/LayerSelectionView.swift, new
/// The selected object's frame: a border, four corner handles, a rotate
/// knob above the top edge, and one pan recognizer whose mode is decided
/// at `.began` by where it landed. No pixels of its own; the composite
/// beneath shows the object. Framed in page space as a subview of the
/// canvas view, like `TextEditingView`.
@MainActor final class LayerSelectionView: UIView {
    let layerID: LayerID
    /// The placement the notebook holds, restated by every `setLayers`.
    /// `working` is the one a drag is building; the frame shows `working`
    /// and reports it once, at the pan's end.
    private(set) var accepted: PageSpaceTransform
    private(set) var working: PageSpaceTransform
    let panRecognizer = UIPanGestureRecognizer()
    let tapRecognizer = UITapGestureRecognizer()
    init(layer: LayerID, transform: PageSpaceTransform)
    func move(by delta: CGPoint)                   // page points
    func scale(fromCorner corner: Corner, to point: CGPoint)
    func rotate(to angle: CGFloat)                 // about the centre
    /// The notebook refused, or restated: `working` becomes `accepted`.
    func adopt(_ transform: PageSpaceTransform)
}
```

Custody. What is selected is the runtime's, in `OverlayPhase`, beside
which pages have canvases and the tool (`Docs/Contract.md:48`), rebuilt
from nothing: a selection is dropped by a tap on paper, a tool change, a
retire, or a `setLayers` that no longer lists the layer. The placement
during a drag is the frame's, `working`, until the pan ends and the whole
transform is reported, which is the row "The drawing during a stroke |
`PKCanvasView` | until the stroke ends" (`Docs/Contract.md:49`) with the
nouns changed. Section 4 amends one row.

**One entry per drag, by construction.** The frame reports nothing until
the pan ends or is cancelled, then reports `working` once through
`layerTransformed`. `Notebook.transformLayer` records once
(`Notebook.swift:869`) and only when the revision moved (`recordEdit`,
`Notebook.swift:317-320`), so a drag that ends where it began is
`.accepted` and records nothing, which `NotebookTests.swift:452` already
pins. Nothing new records.

**The composite is the truth, one render late.** `.accepted` keeps
`working`; the re-render `transformLayer` runs (`Notebook.swift:873`)
arrives as `updateComposite` with the layer list, `setLayers` finds the
selected layer and calls `adopt` with its transform, which is the one just
reported. A restore (`Notebook.swift:359`) and a delete (`:888`) arrive
the same way: `setLayers` finds the layer moved and restates the frame, or
finds it absent and clears the selection. A `setLayers` that lands while a
pan is in flight records `accepted` and leaves `working` alone; the pan's
end reports, and the next composite restates. `.refused` calls `adopt`
with `accepted`, because the notebook's value is already the truth.

**A refusal is reachable only across ten pages.** `transformLayer` refuses
a transform that fails `Layer.validated()` (`Notebook.swift:864`): a
determinant near zero or a translation past ten page edges
(`PageSpaceTransform.swift:35-40`). The gesture floors the object's extents
at 8 page points, the way `TextEditingView.resize` floors at one line
(`TextEditingView.swift:150-156`), so the determinant cannot reach zero
from a handle. Nothing clamps.

## 3. The steps

Two pull requests. Step 0 is device evidence and one documentation edit.
Step 1 touches both canvas controllers and the binding, which the PR
template names, and needs device evidence of its own.

**Step 0. The built half, on an iPad.** Pick the lasso, draw the marquee
round three strokes, drag them, tap the selection and Delete, undo, redo.
Record which of these hold: a finger drags the selection under
`.pencilOnly`; one drag is one undo step (the toolbar's undo restores the
strokes in one tap, `TuberNotesApp/EditorView.swift:105-117`); a marquee
that encloses nothing does not park a later composite forever, which is
the end-of-turn clear at `PageCanvasController.swift:619-625`; PencilKit's
edit menu appears over the selection. If one drag is many
`canvasViewDrawingDidChange` callbacks, coalescing between
`canvasViewDidBeginUsingTool` and the change after
`canvasViewDidEndUsingTool` is a `PageCanvasController` change and its own
PR. The PR's edit to `Docs/Unproven.md` records what was seen, and the
same edit strikes the two bullets at lines 74-88, which name
`LayerDragRecognizer`, "Phase 4's arbitration", and "A10", none of which
exist under `Modules/`, `TuberNotesApp/`, or the tests, and rewrites the
bullet at lines 89-93 ("Nobody has seen a layer being dragged") to say
what step 1 will owe: the frame under a finger, and the jump when the
composite lands.

**Step 1. The runtime.** Device evidence required. Files:
`Seam.swift` (the report), `PageSpaceTransform.swift` (`contains`,
`unitExtents`), `EditorBinding.swift` (`ReportForwarder` forwards
`layerDeleteRequested`; the binding calls `notebook.deleteLayer` then
`drain()`, as the text reports do, `EditorBinding.swift:287-300`),
`PageCanvasController.swift`, `PagedCanvasController.swift`, and the new
`Modules/TNCanvas/LayerSelectionView.swift`. `ContractStructureTests`
needs nothing: the file is in `TNCanvas`, whose row permits UIKit
(`TuberNotesTests/ContractStructureTests.swift:718-740`), and constructs no
`PKCanvasView`. `EditorTool.swift` and `EditorToolTests` are untouched.

`PageCanvasController`. `TextEditPhase` becomes `OverlayPhase` with
`.selected`; `hitRects` becomes `hitTargets: [HitTarget]` built from every
layer, links and text boxes through `unitSquare(to:)`; `textHit` and
`linkHit` (`PageCanvasController.swift:576-588`) test `transform.contains`
instead of `rect.contains`, topmost first as today. `setLayers` also
restates or clears the selection as section 2 says. `tapped(at:)`'s
`.ink` arm (`PageCanvasController.swift:567`) binds the tool, and when it
`is PKLassoTool`: a hit on an image or pdf target selects it, building the
frame from the target's transform, adding it as a subview of `canvasView`,
setting its scale through `setOverlayScale`, making the canvas pan, the
paging pan, and `canvasView.drawingGestureRecognizer` `require(toFail:)`
its pan recognizer, and entering `.selected`; a hit on a different object
while one is selected replaces the frame; a hit on nothing clears it; a
hit on a link or text target does nothing. Under any other ink tool the
arm activates a link as it does today. `apply(tool:)` clears a selection
in every arm that is not the lasso, the way `.ink` commits a session
(`PageCanvasController.swift:298-311`). `gestureRecognizerShouldBegin`
(`PageCanvasController.swift:600-603`) also refuses the tap inside a
selected frame, whose own tap recognizer opens the menu. The frame's pan
end calls back with `working`; the controller reports `layerTransformed`
through the owner and, on `.refused`, calls `adopt(accepted)`. The frame's
tap presents a `UIEditMenuInteraction` with one action, Delete, which
reports `pageDidRequestLayerDelete`; the frame stays until the composite
without the layer lands and `setLayers` clears it. `retire()`
(`PageCanvasController.swift:450-466`) removes the frame; nothing is
reported, because a selection is not a value. `scrollViewDidEndZooming`
(`PageCanvasController.swift:380-383`) rescales the frame too.

`LayerSelectionView`. Bounds are `unitExtents`; `layer.anchorPoint` is the
origin; `layer.position` is `(tx, ty)`; the affine transform is the
placement with unit extents divided out, so the view is the object's own
rectangle rotated into place and its subviews keep page-point sizes. Four
12-point corner handles and a 14-point knob 24 points above the top
edge's midpoint, drawn in page space so they scale with zoom, which
`TextEditingView` accepts for its own (`TextEditingView.swift:23-28`);
`point(inside:)` admits the knob as the text view admits its handles
(`TextEditingView.swift:123-125`). The pan's mode is fixed at `.began`: a
corner scales uniformly about the opposite corner, floored at 8 points on
each extent; the knob rotates about the centre by the angle between the
touch and the centre; anywhere else moves. Deltas are
`translation(in: self)`, unzoomed page space, as the text view takes them
(`TextEditingView.swift:129-131`).

`PagedCanvasController`. `PageCanvasOwner` gains
`pageDidRequestLayerDelete`; the forwarder drops a report from a canvas in
`retiring`, the rule the text forwarders follow
(`PagedCanvasController.swift:619-635`).

Tests. `TNTests/TNModelTests.swift`: a point inside a rotated square is
contained and one just outside its edge is not; a rect spelled as
`unitSquare(to:)` contains its interior; `unitExtents` of
`placing(sourceWidth: 300, sourceHeight: 200, scale: 1)` is (300, 200) and
is unchanged by a rotation. `TNTests/EditorBindingTests.swift`: a delete
request drains a `.compositeUpdated` whose layers omit the layer, and
`canUndo`. `TNCanvasTests`, hosted through `hosted(_:)`
(`TNCanvasTests.swift:407-419`) and driven with page points as
`openSession` drives a text session (`TNCanvasTests.swift:438-455`), with
`RecordingReporter` (`TNCanvasTests.swift:718-769`) recording the delete:
a tap on an image with the lasso enters `.selected` with one
`LayerSelectionView` whose frame's origin is `(tx, ty)`; the same tap with
the pen selects nothing; a tap on paper clears; a tap on a second image
replaces the frame; `move(by:)` then the pan's end reports
`layerTransformed` once with the translated transform; a `.refused` answer
restores `accepted`; `setLayers` with the layer moved restates the frame,
and without the layer clears it, and during a pan leaves `working`; a
corner scale keeps `unitExtents`' ratio and cannot go below 8; a rotation
of a quarter turn yields `b` and `c` of the right sign and leaves the
centre where it was; `apply(.text(...))` clears; `retire()` removes the
frame and reports only the final ink; the delete action reports one
delete; a rotated image is hit inside its corner and missed just outside
it.

Device evidence, on the PR template's list: a finger drag on the selected
image moves the frame and a finger drag beside it pans; a Pencil drag on
it moves the frame and a Pencil drag beside it draws the marquee; the jump
when the composite lands, and how long after the finger lifts it comes;
the handles under a finger at fit zoom and at 4x; a drag across the page
edge is refused and snaps back; undo after a move moves the image back and
the frame with it. Record what was seen; the feel is Phillip's, and if the
still image under a moving frame is rejected, live pixels are a second
plan that gives the notebook a lifted layer to omit from the composite and
the runtime the layer's own bitmap.

## 4. Contract

Every hunk is Phillip's `CONTRACT:` commit; this is the proposal. Line
numbers are `Docs/Contract.md` on `v2-mvp`.

Custody table, quoted (`Docs/Contract.md:48`): "| Which pages have
canvases, the scroll position, the tool | `PagedCanvasController` | in
memory; rebuilt from one `setPages` and the installs that follow |".
Replace with: "| Which pages have canvases, the scroll position, the tool,
the selected object | `PagedCanvasController` | in memory; rebuilt from
one `setPages` and the installs that follow |".

The seam, Reports (`Docs/Contract.md:102-112`), add after
`layerTransformed`:

> - `layerDeleteRequested`: answered by an `updateComposite` that omits
>   the layer.

Nothing in Undo changes: undo.md's pending paragraph already names a layer
transformed or deleted as one entry, and this plan adds no record site.
Nothing in Vocabulary, Rendering, Durable form, Structure, or Forbidden
changes.

## 5. Out of scope

Live pixels under the finger, which is a second plan if the device says
so. Lasso enclosing objects, and any selection of ink by anything but
PencilKit's marquee. Cut, copy, paste, duplicate, and crop of objects.
Multi-select. Edge handles and non-uniform stretch. Two-finger rotation.
A hardware-keyboard delete. Z-order changes. A toolbar delete button, which
cannot know the runtime's selection. Moving a link or a text box with the
lasso (section 7). Coalescing PencilKit's drawing changes before step 0
says whether they need it. Scratch-to-erase, circle-to-select, and shapes,
which are the Pencil gesture lane's; nothing here is built for them. Any
change to the format, to `Layer.validated()`, to `Notebook`, to `Renderer`,
or to `TextEditingView`.

## 6. Decisions

1. Objects are selected only with the lasso tool, by a tap with a finger
   or the Pencil. A Pencil writing over a photo or a worksheet must never
   select it, and the tap recognizer does not know the touch type
   (`PageCanvasController.swift:250-252, 542-550`). Alternative: a finger
   tap on an object under any tool, which GoodNotes offers and which
   would need the tap to read `UITouch.type`.
2. Rotation is a knob above the top edge, dragged round the centre.
   Alternative: `UIRotationGestureRecognizer` on the frame with the canvas
   view's pinch required to fail, which puts a second two-finger gesture
   under the one that zooms.
3. Resize is uniform from a corner about the opposite corner, floored at
   8 page points. Alternative: edge handles that stretch one axis, which
   the format allows and GoodNotes offers for images.
4. Delete is one action on a `UIEditMenuInteraction` presented by a tap
   on the selected frame. Alternative: a trash badge on the frame.

## 7. Cross-plan

`README.md` in this directory. This plan lands after undo (merged at
b84af06) and assumes `recordEdit` and `apply(_:to:)` as they are in
`Notebook.swift:317-381`. It touches `Seam.swift`,
`PageSpaceTransform.swift`, `EditorBinding.swift`,
`PageCanvasController.swift`, `PagedCanvasController.swift`, the new
`LayerSelectionView.swift`, `Docs/Unproven.md`, and three test files. It
does not touch `Notebook.swift`, `Renderer.swift`, `EditorView.swift`,
`EditorViewModel.swift`, `EditorTool.swift`, `ToolStrip.swift`, or
`TextEditingView.swift`: the lasso button and `selectLasso()` exist and no
toolbar control is added.

A link cannot be moved by anything. Its placement is a rect and its
transform must stay identity (`Layer.swift:270-272`), so `transformLayer`
refuses it (`Notebook.swift:864`), and unlike a text box it has no session
with a handle. Giving it one means deciding whether the seam's transform
message becomes a rect edit for two kinds, which is a change to what
`layerTransformed` means and to the Transforms rule's reading, not a
handle. That belongs to `loose-ends.md` or its own plan; this one leaves a
link where the person put it.

## 8. Review disposition

One simplicity review was answered on 2026-09-11. Adopted, all twelve
findings. The notebook lift is gone: no `PageContent.lifted`, no
`LayerLift`, no `beginLayerLift`/`endLayerLift`, no lift and drop reports,
no `Renderer.lifted`, no `NotebookChange` cases, no `afterRender`
sequencing; selection is `OverlayPhase.selected` in the page canvas
controller, the frame carries no pixels, `setLayers` restates or clears
it, and the still image under a moving frame is named as the price and
put to the device. `CanvasTool.lasso` is gone; the runtime tests
`pkTool is PKLassoTool`. One report remains, `layerDeleteRequested`.
Links and text boxes as objects, with the rect-folding `transformLayer`,
are cut and handed to `loose-ends.md` in section 7. The overlay z-order
decision, the coalescing decision, and the two lift decisions are deleted;
the coalescing note is one sentence in step 0. The `Unproven.md` edit is
step 0's own, and the third bullet is rewritten rather than struck. The
GoodNotes description paragraph, the stroke-deferral paragraph, and the
per-sample paragraph are deleted; the rotation sentence leaves the
summary. The two citations that named no file are replaced: the census
row is described without a quotation, and the no-ink-resize claim now
rests on `PageState.swift:159-165`. The cross-plan section keeps the file
list and the link paragraph and nothing else. Five pull requests became
two; nine decisions became four. Rejected: none. Every citation the
findings rested on was re-checked against `v2-mvp` and held.
