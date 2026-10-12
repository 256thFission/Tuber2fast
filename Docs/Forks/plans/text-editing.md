# Text box editing

A plan, not code. Typed text as a tool: create a box, type, style runs, move and
resize it, edit it later. Where a file and this plan disagree, the file is right.

Nothing here preserves compatibility with anything. Every decision below is meant
to be the shape of the feature, not a default to revisit.

**In short.** Text is a tool. Tapping paper with it makes a box; the box is a live
`UITextView` inside the `PKCanvasView`, owned by the runtime for the session the
way a stroke in flight is, and the whole `TextLayer` is reported at the end. The
notebook omits the layer from the composite while the session is open and one
typesetting builder feeds both CoreText and TextKit so the swap does not jump.
This is the one plan that changes the seam, and it lands last: it builds on
`tool-picker.md`'s `EditorTool`, palette, and `RGBA8` colour, and owes
`page-navigator.md` its content-version bumps. Section 9 and `README.md` in this
directory have the details.

## Where the session lives

The live `UITextView` must pan and zoom with the ink, so it sits inside the
`PKCanvasView` the way `backdropView` does (`Modules/TNCanvas/PageCanvasController.swift`,
`viewDidLoad`), and the app cannot name `TNCanvas` (`Docs/Contract.md`, Structure). So
the **editing session is runtime state in `TNCanvas`**, held by `PageCanvasController`,
in the custody position of "the drawing during a stroke" (`Docs/Contract.md`, Custody):
the draft is the canvas's until the session ends, then the whole value is reported and
the notebook's copy is the real one. The notebook stays the one writer of the layer:
told a session began (so the composite omits the layer), told the committed value (so
it validates, stores, re-renders), never reading the text view. `TNEditor` only routes.

Dependency on the queue item "Selecting and moving layers. `layerTransformed` has no
caller": none. A text layer's placement is its `rect`, and `Layer.validated()` refuses
a non-identity transform on one (`Modules/TNModel/Layer.swift`), so move and resize
happen inside the session and travel in the committed `TextLayer`. The one shared
piece is the `updateComposite` widening in section 2, which that item needs as well.

**Rejected: text never enters the composite.** A `TextLayer` is resolution-independent,
so the runtime could draw a live view for every text layer on every live page and the
swap problem would not exist. Rejected because flatten and thumbnails still render
through `Renderer.drawText`, which would move any CoreText-versus-TextKit divergence
from a few frames at session start to a flattened page, permanently; and because the
overlay draws above the ink (section 4) and a permanent overlay would put every text
layer above the ink for good.

## 1. Data shape

New in `Modules/TNModel/TextStyle.swift`. No format change: `TextRun` keeps its flat
keys; `TextStyle` is a run minus its string, so a style can be applied to a selection.
(`TNTests/FormatTests.swift` pins the payload keys `rect`, `runs`, `alignment`,
`Modules/TNFormat/Codecs.swift`; the keys inside a run are synthesized `Codable`, which
ignores extras. No run key is added, so this is a note, not a gap.)

```swift
package struct TextStyle: Sendable, Equatable {
    package let font: String; package let size: Double
    package let bold: Bool; package let italic: Bool; package let underline: Bool
    package let color: RGBA8                        // tool-picker.md's type; TextRun.color stays a String
    package static let body: TextStyle              // "system", 16, black
}
extension TextRun {
    package init(string: String, style: TextStyle)  // formats color through RGBA8.hex
    package var style: TextStyle { get }            // parses through RGBA8(hex:), which isValid already ran
}
```

`RGBA8` is `tool-picker.md`'s one colour parser (`README.md`, conflict 2). A
`String` here would be a second one.

The committed value is a whole `TextLayer` (rect, runs, alignment), the type the file
stores (`Modules/TNFormat/LayerFile.swift`); adjacent equal runs are merged at commit.

Seam values, `Modules/TNModel/Seam.swift`:

```swift
package struct PagePoint: Sendable, Equatable { package let x: Double; package let y: Double }
/// What the runtime is told to open: the layer as the notebook holds it.
package struct TextEditStart: Sendable, Equatable { package let layer: LayerID; package let text: TextLayer }
/// Ink is a PKTool; text is a style to type with, and the drawing gesture is off.
package enum CanvasTool: @unchecked Sendable { case ink(PKTool); case text(TextStyle, TextAlignment) }
package struct CanvasEnvironment: @unchecked Sendable { package let tool: CanvasTool }
```

There is no cancellation. Every way a session ends commits: tap outside, retire,
tool switch, page change. A cancel affordance has no gesture and no control today, so
a `.cancelled` case would be a field reserved for a future feature (`Docs/Contract.md`,
Forbidden). `textEditingEnded` carries the `TextLayer` directly.

The runtime's state machine, in `PageCanvasController`:

```swift
enum TextEditPhase {
    case idle
    /// Reported a request; no view yet. The overlay goes up when the omitting
    /// composite lands, in the same drain (section 4, the swap).
    case opening(layer: LayerID)
    /// The overlay is up and first responder.
    case editing(layer: LayerID, view: TextEditingView)
}
/// Overlays whose end was reported and whose composite has not landed. Inert.
/// A side map, not a phase: closing A and editing B happen in one tap.
var closing: [LayerID: TextEditingView]
```

The notebook's mirror is one field on `PageContent` (`Modules/TNNotebook/PageState.swift`):
`var textEditing: LayerID?`. Never saved; it is what `rerenderComposite` reads to
leave that layer out. A begin while it is set is unreachable (the runtime ends the
open session first, section 3) and traps with `TNPrecondition`.

**Undo.** The contract's stack holds ink values (`Docs/Contract.md`, Undo; `InkHistory`
in `PageState.swift`). Two things hold at once. While a session is open, typing undo
is the text view's own `UndoManager`, which `UITextView` vends itself; it dies with
the session and holds nothing durable, the same shape as PencilKit holding a stroke
in flight. Whether the responder chain actually reaches it past `FilteringUndoManager`
is unproven; the failure mode is stroke undo mid-typing, and it is on the device list
(section 5). After commit a text edit is a layer change, and no layer change is
undoable today: `addLayer`, `transformLayer`, `deleteLayer` in
`Modules/TNNotebook/Notebook.swift` call `edited()` and never `history.recordEdit`.
For joining the stack: a user who types a box then undoes expects the box to go, not
the stroke before it; a stack that skips text edits reorders history invisibly.
Against: it is a `CONTRACT:` change to Undo and to `HistoryEntry`. So two steps. Step
one commits text with no notebook undo and a `KNOWN DEFECT:` block at
`Notebook.endTextEditing` naming this paragraph. Step two, if Phillip signs it
(section 8), widens the entry and takes the other three layer mutations with it:

```swift
package enum Restored: Sendable { case ink(PKDrawing); case layers([Layer], inkIndex: Int) }
package struct HistoryEntry: Sendable { package let page: PageID; package let value: Restored }
```

A restored layer list re-marks every changed layer's file pending, the way a commit
does; `pendingLayerFiles` semantics do not change.

## 2. Seam diff

`Modules/TNModel/Seam.swift`, `CanvasSurface`:

```swift
func updateComposite(on page: PageID, _ composite: Composite, layers: [Layer])   // widened
func beginTextEditing(on page: PageID, _ start: TextEditStart)
func endTextEditing(on page: PageID, layer: LayerID)
func apply(_ environment: CanvasEnvironment)                                    // CanvasTool inside
```

`updateComposite` carries the list it was rendered from because the runtime's hit
rects (`linkRects`, now text rects too) must match the picture; today `transformLayer`
re-renders and never restates layers, so link rects go stale after a move. The
notebook side of the same fix: `snapshots[page].layers` is updated with the render,
so a rebuilt canvas inherits current rects, not the ones it was built with.

`CanvasReporting`:

```swift
func textBoxRequested(on page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment)
func textEditRequested(on page: PageID, layer: LayerID)
func textEditingEnded(on page: PageID, layer: LayerID, _ text: TextLayer)
```

The request carries the style so `EditorBinding` stays a forwarder
(`Modules/TNEditor/EditorBinding.swift`) and stores no environment to answer it.

Neither request is answered in the same pass. The Custody sentence "the answer comes
back as a command in the same pass" describes questions with a return value (the end
boundary, the layer list); a text request has none. The answer is `beginTextEditing`
queued **after** the omitting `.compositeUpdated` in the same continuation, so the
drain installs the bitmap without the text and raises the overlay with it in one pass.
`textEditingEnded` is answered with `endTextEditing` queued after the committed
`.compositeUpdated`, the same way in the other direction. No frame shows the text
twice and no frame shows it zero times. The cost is one render between tap and caret;
on a page with an asset that render decodes the asset. Measured on device (section 5);
if it is felt, the overlay goes up at once with its text hidden and reveals it when
the composite lands, which is a fourth phase and not designed until the number says so.

`NotebookChange` (`Modules/TNNotebook/NotebookChange.swift`) gains
`.textEditingBegan(PageID, TextEditStart)`, `.textEditingEnded(PageID, LayerID)`, and
`layers:` on `.compositeUpdated`; step two adds `.layersRestored(PageID, [Layer])`.

**Render currency.** `rerenderComposite` (`Notebook.swift`) fires a bare `Task` with
no currency check; two renders of one page can land out of order whenever
`composite()` suspends in asset decode. Begin and commit are two renders milliseconds
apart, so the stale one landing last would erase committed text from the bitmap and
from `snapshots`. `PageContent` gains `renderGeneration: UInt64`; every render takes
the next value and the continuation drops a result whose generation is not current,
the idiom page loading already uses (`installLoaded`, `Notebook.swift`). The text
changes are queued by the same continuation, after the currency check, so a
superseded render queues nothing and the current one queues everything.

**Teardown is not conditional on the render.** `endTextEditing` settles state
(clears `textEditing`, replaces the payload) and queues `.textEditingEnded` from the
render continuation whether `composite()` returned a picture or `nil`. A `nil` render
with the overlay left up forever would be a permanent double draw.

## 3. File by file

**TNModel.** `TextStyle.swift` as above. `TextTypesetting.swift`, `import CoreText`
and `import UIKit`: `resolve(_: TextStyle) -> CTFont`, the body of which is the font
lines of `Renderer.drawText` today (`CTFontCreateUIFontForLanguage`,
`CTFontCreateCopyWithSymbolicTraits`, `Modules/TNRender/Renderer.swift`), and
`attributed(_: [TextRun], alignment:) -> NSAttributedString`, **one builder for both
engines**. It moves down because `TNCanvas` imports `TNModel` and nothing else of ours.

The builder emits UIKit's keys with UIKit values: `.font` (a `UIFont`, bridged from
the `CTFont`), `.foregroundColor` (a `UIColor`), `.paragraphStyle`
(`NSMutableParagraphStyle`), `.underlineStyle`, and a private `.tnStyle` carrying the
`TextStyle`. Font, paragraph style and underline keys are the same strings as
CoreText's; the colour key is not (`kCTForegroundColorAttributeName` is a different
string and `CGColor` does not bridge to `UIColor`), so the single builder rests on
CoreText honouring UIKit's colour attribute, which it does on iOS but which the
fidelity test in section 5 is the proof of. If that test fails on colour alone, the
builder grows one `forCoreText: Bool` that swaps the colour key; nothing else splits.

The checker (`TuberNotesTests/ContractStructureTests.swift`, `uiFrameworkModules`)
does not scan CoreText today, so this would pass by omission. Close the hole: add
`"CoreText"` to `uiFrameworkModules` and permit it in the `TNModel`, `TNRender`,
`TNCanvas` rows of `moduleUIFrameworkPolicy`. Add
`"TextTypesetting.swift": ("TNModel", ["PencilKit"])` to `filesPlacedByDesign`. Update
the `TNModel` comment in `project.yml` ("PencilKit and CoreGraphics for value types
only"): font resolution is not a value type.

**TNRender.** `Renderer.drawText` calls `TextTypesetting.attributed` and keeps its
zero-inset `CTFramesetter` frame, the reference geometry the overlay copies.
`Renderer.color(_:)` goes; the `CGColor` comes from `RGBA8`'s four bytes and nothing
re-parses the string. `composite(...)` is unchanged. Committed
text renders at `baseCompositeScale` (2x) and stays soft at deep zoom; `detailNeeded`
exists and nothing calls it (`Docs/Queue.md`, "Not wired"). Recorded as a limitation
of this plan, not fixed by it.

**TNNotebook.** `PageContent.textEditing`, `PageContent.renderGeneration`. Split
`addLayer` into a synchronous `insertLayer(_:on:) throws(FormatFault)` (validate,
insert at `inkIndex`, `pendingLayerFiles`, `edited()`, `markDirty`, re-render) and the
existing `async` shell that writes the asset first, so a text box can be made in the
tap's own pass. New:

```swift
package func createTextBox(on page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment)
package func beginTextEditing(on page: PageID, layer: LayerID)
package func endTextEditing(on page: PageID, layer: LayerID, _ text: TextLayer)
```

No return values; the drain pushes what the continuation queues. `beginTextEditing`
traps if `textEditing` is set, sets it, re-renders; the continuation queues
`.compositeUpdated` then `.textEditingBegan`. `createTextBox` inserts an empty text
layer at a default rect at the point, then begins. `endTextEditing` clears
`textEditing`; runs `Layer.validated()` and traps on failure, because the overlay's
gesture math (below) cannot produce an invalid rect and a clamp is forbidden;
replaces the payload, marks the file pending, deletes the layer instead if every run
is empty; re-renders; the continuation queues `.compositeUpdated` then
`.textEditingEnded`. A report for a page the notebook no longer holds never arrives:
`page-navigator.md` makes every report from a canvas in `retiring` a dead letter that
the runtime does not forward, and the text forwarder in `PagedCanvasController`
follows the same rule (`README.md`, conflict 4). The notebook keeps its trap for a
page it does not have.

`addTextLayer` loses its only app caller when `addTextBox()` goes. It is deleted;
tests that used it build a `TextLayer` and call `insertLayer`.

**TNCanvas.** `TextEditingView.swift`: a `UITextView` subclass, zero
`textContainerInset` and `lineFragmentPadding`, `isScrollEnabled = false`;
`attributedText` comes from `TextTypesetting.attributed`; typing inherits the style
via `typingAttributes`; commit walks `.tnStyle` runs and never reverse-maps a `UIFont`.
A run with no `.tnStyle` (paste, dictation, marked text from an IME) commits with the
session's current typing style. **Overflow:** the box grows. `textViewDidChange` asks
`sizeThatFits` at the fixed width and sets the frame height; this is a synchronous
layout query inside UIKit's own callback, inside the boundary the Structure sentence
names (section 6). The grown rect travels in the commit. **Chrome:** a border and
corner handles drawn in page space; they scale with zoom and are large at 10x, which
is accepted. **Move and resize:** two pan recognizers on the overlay, deltas taken
with `translation(in: overlay)`, which is already unzoomed page space (the codebase
has burned a test on the zoomed-versus-unzoomed confusion, `CONTRIBUTING.md`). Resize
keeps width and height at or above one line of the current style and finite, so the
committed rect is always valid. Its `contentScaleFactor` is set at insertion from the
current `zoomScale` and again in `scrollViewDidEndZooming` (reachable already:
`PKCanvasViewDelegate` is a `UIScrollViewDelegate`), once per gesture, never per frame.

**Gesture arbitration** while a session is open:
- The tap recognizer's `gestureRecognizerShouldBegin` returns `false` for a touch
  inside the live overlay; caret placement and selection are the text view's. This
  also kills the re-begin loop where a tap in the open box's own rect would report
  `textEditRequested` for the layer already open.
- The inner `PKCanvasView` pan and the outer paging scroll view's pan both
  `require(toFail:)` the overlay's move and resize recognizers, so a border drag
  neither scrolls the page nor turns it. Turning the page retires the canvas, which
  commits the session and destroys the view mid-gesture; requiring failure is what
  prevents that.
- `drawingGestureRecognizer.isEnabled` follows the **tool**, not the session:
  `apply(.text)` disables it, `apply(.ink)` enables it. There is no window where the
  text tool is selected and the Pencil draws.

**Tool switch during a session.** `apply(.ink)` with a session open ends it,
`.committed`, before the drawing gesture is re-enabled; a stroke never lands under a
live overlay. `apply(.text(style, alignment))` with a session open forwards the style
to the selection if there is one, else to `typingAttributes`.

**Z-order.** The overlay is added as a subview of `canvasView` like `backdropView`
and sits above PencilKit's drawing surface; a stroke crossing the box during a session
draws under the live text, and the committed layer sits under the ink. This inversion
is accepted for the session's duration; there is no public API to place a subview
beneath the ink.

**Keyboard.** `PageCanvasController` observes `keyboardWillShow` and
`keyboardWillHide`, sets the inner canvas view's `contentInset.bottom` to the overlap,
and scrolls the overlay's frame clear. Without this a finger-typed session is covered
on the first keystroke.

`PageCanvasController`: holds the phase and the closing map; `setLayers` collects text
rects too; `handleTap` drops the `linkRects.isEmpty` early return, hit-tests text
rects and link rects as one list in layer order, topmost wins, and with the text tool
a tap in a link rect edits nothing and activates nothing (links are the ink tools'
affair). With the text tool: a tap inside a text rect reports `textEditRequested`; a
tap on paper reports `textBoxRequested`; either one with a session open first reports
`textEditingEnded` for it, moves its view to `closing`, then reports the new request,
in that order, in the same handler. `beginTextEditing` for the layer in `.opening`
adds the overlay, restates its frame, makes it first responder (the controller is in
a window whenever this runs; the hosted test builds one). `endTextEditing` removes the
named overlay from `closing`, or is a no-op for an unknown layer. `retire()` with a
session `.editing` reports it committed before the final ink report, synchronously;
with a session `.opening` reports nothing and returns to idle, and the notebook's
`textEditing` is cleared by the page's release. `retire()` while a stroke is in flight
already defers; a session end during a deferred retire follows it. `updateGeometry`
restates the overlay's frame beside `backdropView`'s through the one shared placement
function. `PagedCanvasController`: routes commands to the page's controller and
forwards reports via `PageCanvasOwner`.

**TNEditor.** Written against `tool-picker.md`'s shapes (`README.md`, conflict 1).
`EditorTool` gains `case text(TextStyle, TextAlignment)`; `pkTool` becomes
`canvasTool` returning a `CanvasTool`, and `EditorViewModel.tool.didSet` pushes that.
`tool` is `private(set)` there, so the intentions are `selectText()` (restores the
last text style, `TextStyle.body` until one is remembered) and `setTextStyle(_:)`
and `setTextAlignment(_:)`, which trap on any tool but `.text` the way `setColor`
traps on the eraser. The tool is the one owner of the style; there are no separate
`textStyle` or `textAlignment` properties. `ToolPalette.Kind` gains `.text` and the
palette gains a `textStyle` slot (`README.md`, decision 2), so `remember(.text(...))`
writes both and a new tab opens on text if text was last; `selectText()` restores
that slot. `palette.used(_:)` is not called for text (decision 3): a colour typed
with is never a recent.
`EditorBinding` and `ReportForwarder` forward the three reports and push the two
changes. `EditorViewModel.addTextBox()` and its "Text" placeholder are deleted.
`TNTests/EditorBindingTests.swift`'s `RecordingSurface` gains the commands.

**TuberNotesApp.** `ToolStrip` gains a text button, one more `EditorToolButton`
case. Tapping it selects the text tool; tapping it again opens its popover, which is
where the style controls live (bold, italic, underline, size, alignment, and a
colour row of `ToolColor.defaults` then the well, with no recents). "Text box" leaves
`insertMenu`. It still names nothing in `TNCanvas`.

## 4. Rendering fidelity

Both engines must lay the same runs on the same lines at the same baselines, or text
jumps at begin and at commit.

- **Attributes.** One builder, `TextTypesetting.attributed`, feeds `CTFramesetter`
  and `UITextView`. The divergence class "two builders drift" does not exist; what
  remains is the two layout engines.
- **Geometry.** `drawText` frames text in the rect with no inset (its path is the
  rect at the origin). The overlay matches: inset zero, padding zero, frame is the
  rect. Wrapping width is therefore identical.
- **Wrapping and alignment.** `CTFramesetter` and TextKit break lines by the same
  Unicode rules and honour the same alignment; the known divergence is line height
  under font leading and TextKit 2's fragment rounding. Pin it with the hosted test
  in section 5 rather than a belief. If it fails, `UITextView(usingTextLayoutManager:
  false)` selects TextKit 1, whose `NSLayoutManager` matches `CTFramesetter` for these
  fonts, and nothing else in the plan moves.
- **The swap.** By construction (section 2) the overlay appears in the drain that
  installs the composite without the text, and leaves in the drain that installs the
  composite with it. There is no overlap frame, so there is nothing for engine
  agreement to hide. (Overlap would not have been invisible even with perfect
  agreement: antialiased edges composited twice darken, and the overlay rasterizes at
  zoom while the bitmap is fixed at 2x.)
- **Scale.** The overlay is sharper than the bitmap at any zoom past the composite's
  2x. At the swap the text softens or sharpens by that much. Accepted; see the
  `detailNeeded` note in section 3.

## 5. Tests

Hostless, `TNTests`:
- `NotebookTests`: begin sets `textEditing` and the next composite omits the layer,
  and queues `.compositeUpdated` then `.textEditingBegan`; commit replaces the
  payload, marks the file pending, updates `snapshots[page].layers`, queues
  `.compositeUpdated` then `.textEditingEnded`; a commit whose render returns `nil`
  still queues `.textEditingEnded`; all-empty runs delete the layer; a commit for a
  deleted page is dropped; two renders completing out of order install the newer one
  and queue nothing for the older (a renderer stub that resolves on demand); begin
  while `textEditing` is set traps; an invalid committed rect traps.
- `EditorBindingTests`: `textBoxRequested` is followed by `updateComposite` then
  `beginTextEditing` in one drain; `textEditingEnded` by `updateComposite` then
  `endTextEditing`; the request carries the tool's style.
- `TNModelTests`: run merging; equal styles resolve equal fonts; a run without
  `.tnStyle` commits as the typing style. `FormatTests`: unchanged.

Hosted, `TuberNotesTests`. `hosted()` (`TNCanvasTests.swift`) builds no `UIWindow`
today, so `becomeFirstResponder` returns `false` and a real tap recognizer never
reaches `.ended`. It gains a window, and hit-testing moves out of `handleTap` into a
pure function `textHit(at:rects:) -> TextTap?` that the tests drive directly.
- `TNCanvasTests`: `beginTextEditing` adds one overlay and makes it first responder;
  `apply(.text)` disables the drawing gesture and `apply(.ink)` re-enables it, session
  or no session; a tap outside reports the typed runs; a tap in a second text rect
  reports the first committed, then the second requested, and leaves one overlay in
  `closing` until `endTextEditing`; `retire()` reports the draft before the ink; a
  `setPages` that drops the page ends the session with a report and no trap;
  `apply(.ink)` mid-session commits; a resize gesture cannot produce a rect below one
  line; typing past the bottom grows the frame; `updateGeometry` restates the
  overlay's frame; `keyboardWillShow` sets the inset.
- **Fidelity.** For a fixture of text layers (a wrapping paragraph, mixed sizes and
  colours on one line, each alignment, a trailing newline, an underlined run) render
  through `Renderer.composite` at 2x and through a laid-out `TextEditingView`
  snapshotted at 2x, and compare per-line ink bounds within one pixel and per-run
  colour exactly. This is the whole of section 4's evidence, and the colour
  comparison is the single-builder experiment's pass condition.

Device only, recorded in the PR template: Scribble into the overlay; the undo gesture
undoes typing, not a stroke; a pinch mid-session keeps the caret on the text; the
overlay stays registered with the ink under a fast pinch; a border drag moves the box
and neither scrolls nor turns the page; the software keyboard leaves the caret
visible; a stroke across an open box during a session (the z-order inversion, seen
and accepted); tap-to-caret latency on a page with asset paper. That fourth item is
the unproven claim `backdropView` already carries (`PageCanvasController.viewDidLoad`,
KNOWN DEFECT) and the queue's "Backdrop registration" check settles both, which is
why they share one placement function. Note `handleTap` divides by `zoomScale` while
`backdropView` is framed unzoomed; the device reconciles that pair, not this plan.

## 6. Contract sentences

Custody table, add after "The drawing during a stroke":

> | The draft of a text box being edited | `PageCanvasController` | until the session ends |

The seam, commands, append; and reports, append:

> - `beginTextEditing`: the layer and its value; arrives with the composite that
>   omits the layer, and the runtime raises a live text view over it.
> - `endTextEditing`: arrives with the composite that has the committed text; the
>   runtime takes the live view down.
> - `updateComposite`: the image and the layer list it was rendered from.

> - `textBoxRequested`, `textEditRequested`: the tool's style rides with the first.
>   Answered by `beginTextEditing` once the composite omits the layer.
> - `textEditingEnded`: the whole committed value. Answered by `endTextEditing` once
>   the composite has the text.

Rendering, replace "A composite is the paper and every static layer" with:

> A composite is the paper and every static layer except a text layer being edited,
> which the runtime draws live over the composite until the edit is committed. A
> composite result that a later render has superseded is dropped.

Structure, replace "Nothing runs per Pencil sample except PencilKit" with:

> Nothing runs per Pencil sample except PencilKit, and nothing runs per keystroke
> except UIKit's text system: no observation, no task, no actor hop, no file access.
> A synchronous layout query inside the text system's own callback is inside it.

Undo, after "The canvas hands the responder chain a `FilteringUndoManager`", only once
the device list in section 5 has shown it:

> While a text box is being edited, the text view's own undo manager answers the
> chain for typing. It dies with the session and holds nothing durable.

Undo, step two only, replace "holding ink values, one entry per report" with:

> holding ink values and layer lists, one entry per ink report or committed layer change

Each is a `CONTRACT:` commit and Phillip's to write; this wording is a proposal.

## 7. Out of scope

Rich text beyond the runs the format has: paragraph spacing, indents, lists, links in
text, fonts beyond `system` and a PostScript name. Text recognition of ink. The toolbar
reflecting the style under the caret (a fourth report, later). Selecting a text box
with a non-text tool, the queue's own item. Undo of layer changes (step two). A
cancel affordance. Sharper committed text at deep zoom (`detailNeeded`). Format
version stays 2; no key is added.

## 8. Open questions for Phillip

1. Does a committed text edit join the notebook's undo stack (step two) or stay
   outside it? The Undo rule is yours to author.
2. Which gesture opens a box: the text tool's tap, as planned, or a tap on any text
   box with any tool, GoodNotes style? The second hit-tests every pen tap on paper.
3. An abandoned empty box: deleted silently, as planned, or kept as an empty rect?
4. The default style and size of a new box (`TextStyle.body`, 16 pt, black): taste,
   recorded in `Docs/Unproven.md` until a Pencil has been held to it.
5. Tap-to-caret latency: is one render acceptable on asset pages, or does the
   hidden-text overlay variant (section 2) get designed?

## 9. Cross-plan

`README.md` in this directory. This plan is wave 2 and lands after the other
three.

- `tool-picker.md` (conflicts 1 and 2). Sections 1 and 3 above are written against
  its `EditorTool`, `private(set) tool` with intentions, `ToolStrip`, and `RGBA8`.
  If it has not landed when this one starts, the notebook, render, and canvas
  sections have no dependency on it and can proceed; only `TNEditor` and the app
  wait.
- `page-navigator.md` (conflicts 3 and 4). This plan adds the `contentVersion` bump
  in `endTextEditing` and in `insertLayer` (the bump the navigator put in `addLayer`
  moves with the split), and in step two's `.layersRestored`, and extends the
  navigator's `NotebookTests` list, which is that invariant's only enforcement. The
  text forwarder drops reports from a canvas in `retiring`, the navigator's rule.
  `renderGeneration` here and `contentVersion` there are different counters
  (conflict 6).
- `page-size-and-paper.md`. No relation.
