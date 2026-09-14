# Pencil gestures: triggers and effects

A plan, not code. Branch `v2-rewrite`. Every claim below is grounded in a
file it names, with a line where the claim is about code; where the code
moves, the file wins.

**In short.** A gesture is a pair. A trigger is a shape the pen made, found
in one committed stroke after PencilKit has drawn it: a scribble, later a
double circle. An effect is what happens to the strokes the trigger
points at: erase, later a hand-off to something outside the notebook.
Bindings map triggers to effects, and they are a preference the person
edits. The notebook recognises the trigger inside `inkChanged`, looks up
the effect, and applies it as a restore, the path undo already uses. The
canvas changes not at all. The first pair is scribble to erase. One edit
removes the scribble and every stroke it crosses, one undo entry brings
them back, and a scribble over blank paper stays as ink. Decided with
Phillip on 2026-09-14, reviewed twice the same day (section 8). Section
10 is the order of work. A probe, five steps for the first pair, then a
second trigger that proves the trigger axis. The effect axis is proven
the day something exists to hand off to.

## 0. The decisions this plan rests on

**Recognition is post-hoc.** The stroke renders in PencilKit like any
other, and recognition runs once on the committed `PKStroke`. This is the
Fork A decision of 2026-07-22 restated for v2. It is what lets a gesture
work with whatever ink tool is in hand, with no trip to the toolbar, and
it costs nothing per sample. Live interception before render would mean
replacing `PKCanvasView`, and is not on the table.

**The notebook recognises, not the canvas.** The July note put the
classifier in the canvas controller. The v2 contract argues the other
way, and Phillip accepted the argument on 2026-09-14:

- Custody. Deleting strokes is a decision about the ink, and the
  notebook holds the ink (`Docs/Contract.md`, Custody). A canvas that
  decides is a second decider. Undo is the precedent. It lands on the
  canvas as `restoreInk`, a restore the notebook chose, and this is the
  same shape.
- Undo is one entry for free. `Notebook.inkChanged`
  (`Modules/TNNotebook/Notebook.swift:273`) captures the revision before
  the report and records one entry to the revision after it
  (`recordEdit`, line 317). If the effect applies inside that call, the
  entry runs from before the trigger stroke to after the effect. In the
  canvas, the trigger stroke would commit and be recorded, the effect
  would be a second entry, and undo would resurrect the scribble before
  restoring the ink. Fixing that means a second echo latch.
- Nothing new on the canvas. The edited drawing rides the existing
  `.inkRestored` change; `PagedCanvasController.restoreInk`
  (`Modules/TNCanvas/PagedCanvasController.swift:228`) remembers it in
  the snapshot and hands it to the live canvas, and the echo latch in
  `PageCanvasController.restoreInk`
  (`Modules/TNCanvas/PageCanvasController.swift:460`) swallows the round
  trip. No change to `TNCanvas`, so a threshold tweak owes no device
  evidence. The editor binding and the log module do owe it
  (`CONTRIBUTING.md:104-116`), and steps 2 and 3 say when it is paid.
- Testable without a Pencil. The recogniser is a pure function over
  PencilKit values, and `TNTests/NotebookTests.swift` already drives
  `inkChanged` with synthetic drawings.

The one argument for the canvas is latency, and it does not hold. The
notebook path is synchronous inside PencilKit's own callback. The canvas
reports (`PageCanvasController.swift:750`), `EditorBinding.inkChanged`
forwards and drains (`Modules/TNEditor/EditorBinding.swift:216`, `:144`),
the notebook edits and emits, `push` calls `restoreInk`, the canvas
adopts. No frame passes between the pen lifting and the trigger stroke
leaving the drawing. The stroke is on screen for its whole duration
under the pen, as any stroke is, and for no frame after the lift. Step 0
proves the one new mechanical fact in that chain.

**Triggers and effects are two lists, and bindings join them.** A
trigger knows how to find itself in a stroke and which strokes it points
at. An effect knows what to do with strokes it is handed. Neither knows
the other. The join is a dictionary from trigger to effect, and it is a
preference like the pen width, so the person decides that a scribble
erases and, one day, that a double circle sends a diagram somewhere. A
new trigger is one case and one reading. A new effect is one case and
one arm. Neither touches the other list. Nothing exists to order or
dispatch between triggers until there are two; step 6 adds that with
both in hand.

**A trigger with no subject is ink.** A scribble that crosses nothing, a
circle around blank paper. A deliberate zigzag, a hand-drawn "w", a
scratched-in texture, a ring on a diagram. None of those are gestures,
and GoodNotes agrees about the scribble.

**Whole strokes.** The subject of a trigger is whole strokes, as
`PKEraserTool(.vector)` erases them. Trimming the crossed part of a long
stroke is out (section 6).

**Bindings are a preference, and scribble ships bound to erase.** They
live in the ink popover, beside the widths and colours, because a
gesture belongs to the pen in hand. One set of bindings for pen, pencil
and highlighter, persisted with the palette. The person who asked for a
gesture that never visits the toolbar should not have to visit the
toolbar to switch it on.

**Any ink kind, never an eraser or lasso.** "While writing" means a
gesture is a property of an ink stroke, so a highlighter scribble erases
too. The notebook does not know the tool. On every report the binding
asks the view model which bindings apply to the stroke in hand, and the
view model answers from the tool and the palette, so an eraser or lasso
pass, which adds no stroke anyway, is never examined. Asked, not copied:
a copy would need refreshing at the initialiser, at every tool change,
and in every other tab sharing the palette, and the first review found
the first of those missing.

**No case for an effect that does not ship.** The contract forbids a
field reserved for a future feature. `GestureEffect` holds `erase` on the
day it lands, and nothing else. Section 6 names the hand-off effect in
prose so its shape is on record, and it gets a case when something
exists to hand off to. A cut effect was in an earlier draft and Phillip
removed it on 2026-09-14; it had no destination to paste into that this
app owns.

## 1. The data shape

New file `Modules/TNNotebook/StrokeGestures.swift`. `TNNotebook` already
imports PencilKit (`Notebook.swift`, `PageState.swift`) and may import
nothing else of Apple's (`TuberNotesTests/ContractStructureTests.swift:730`);
`CGFloat` and `CGRect` come through Foundation, and a literal
`import CoreGraphics` fails the structure suite.

```swift
/// A shape the pen can make that means something. One case per shape;
/// the reading for each lives beside it in this file.
package enum GestureTrigger: String, CaseIterable, Codable, Sendable {
    case scribble
    // step 6 adds doubleCircle
}

/// What a trigger can do to the strokes it points at. Only the cases
/// that ship; a case is never added ahead of its arm.
package enum GestureEffect: String, CaseIterable, Codable, Sendable {
    case erase

    /// The drawing after this effect on `subject`. The trigger stroke at
    /// `added` goes with the subject whatever the effect.
    package func apply(to drawing: PKDrawing, subject: IndexSet, added: Int) -> PKDrawing
}

/// Which trigger does what. A trigger absent from the map is off. Lives
/// on the palette record beside the other presets; the notebook holds
/// no copy, because a preference is never notebook state.
package typealias GestureBindings = [GestureTrigger: GestureEffect]
```

The scribble reading:

```swift
/// What was measured about one stroke, whether or not it matched. One
/// place for the numbers, so the device tuning in step 4 edits
/// constants and not logic.
package struct ScribbleReading: Equatable, Sendable {
    /// Sharp turns along the path: a heading change of more than
    /// `turnAngle` between one sampled segment and the next. A "w" has
    /// two; a scratch-out has four or more; a loop has none, because a
    /// loop turns gently, which is what keeps a double circle out of
    /// this trigger.
    package static let minimumTurns = 4
    package static let turnAngle: CGFloat = 2 * .pi / 3
    /// Path length over bounding-box diagonal. A zigzag folds several
    /// widths of ink into one box; a letter does not.
    package static let minimumFolding: CGFloat = 2.5
    /// Points, in drawing space, on top of the two strokes' half widths.
    package static let hitSlack: CGFloat = 4

    package let turns: Int
    package let folding: CGFloat
    /// Nil when the shape thresholds failed and the hit test never ran.
    /// The hit test is the one pass that scales with the page, and it
    /// runs only for a stroke that already looks like a scribble.
    package let hits: IndexSet?
    /// `hits` when it is non-empty; nil is ink. Indexes the drawing the
    /// reading was taken from and never includes the stroke itself.
    package var subject: IndexSet? { get }

    /// `index` is the stroke that just landed, always the last one,
    /// because PencilKit appends. Pure: no state, no clock, no tool.
    package static func measure(stroke index: Int, in drawing: PKDrawing) -> ScribbleReading
}
```

Scribble recognition, in order:

1. Sample the added stroke at `path.interpolatedPoints(by: .distance(2))`
   and map each point through `stroke.transform`, because `renderBounds`
   is in drawing space and the path is not. Every stroke a fresh pen
   makes carries the identity, but a stroke the lasso moved does not
   (`PKStroke.transform`, PencilKit interface line 41).
2. Turns: the heading of each sampled segment, and a count of
   consecutive headings that differ by more than `turnAngle`, ignoring
   segments shorter than one point. Fewer than `minimumTurns` means ink.
3. Path length over the diagonal of `renderBounds`. Under
   `minimumFolding` means ink.
4. Hits, only now: every other stroke whose `renderBounds` intersects
   the scribble's. For each, sample its path within its
   `maskedPathRanges` (a pixel-erased stroke keeps its whole path behind
   a mask), map through its transform, and count it hit if any sample
   is within `hitSlack` plus both strokes' half widths of any scribble
   sample. Half width is half the average of `PKStrokePoint.size.width`.
   The bounds test does most of the work; the distance test runs on the
   few that survive it. Empty means ink.

Erase removes the subject and `added` through the `strokes` setter
(`var strokes: [PKStroke] { get set }`, PencilKit interface line 200).
Whether that shares stroke storage with the drawing it came from, as a
canvas round trip does, is what step 5 measures; the method is the same
either way.

`Notebook.inkChanged(on:_:echoOf:)` gains `bindings: GestureBindings =
[:]`. Defaulted, so the forty-five existing call sites in the tests do
not change; the one production caller is `EditorBinding.inkChanged`, and
one binding test pins that it passes the answer. The body, in prose.
After the echo check and before `setInk`. If `bindings` is non-empty and
the reported drawing has exactly one stroke more than the captured
revision, take the scribble reading of the last stroke and log it
(step 2). If it has a subject and scribble is bound, apply the effect,
mint an `InkSeq`, set `pendingEcho` to it, append `.inkRestored`, and
fall through to the existing `setInk`, `recordEdit`, version bump and
`markDirty` with the edited drawing. One entry, from the revision before
the trigger stroke to the revision after the effect. A reading with a
subject and no binding is ink, and the log says so.

"Exactly one stroke more" is the whole test for "a pen stroke landed".
The eraser and lasso add nothing. The pixel eraser masks a stroke
rather than splitting it, so it adds nothing either, and the bindings
gate already excludes it; the count is a second guard, not the first.

`ToolPaletteRecord` (`Modules/TNEditor/ToolPalette.swift`) gains
`gestures: GestureBindings`, decoded with `decodeIfPresent` and the
default in `.builtIn` beside the other presets (`:57-68`),
`[.scribble: .erase]`, the way `text` arrived. A record written before
the field existed is a whole palette somebody keeps. `ToolPalette` gains
`private(set) var gestures` and `bind(_ trigger: GestureTrigger, to
effect: GestureEffect?)`, which writes; nil unbinds.

`EditorBinding` gains `bindingsForStroke: @MainActor () -> GestureBindings`,
installed once by the view model's initialiser beside `onInkReported`
(`Modules/TNEditor/EditorViewModel.swift:105`), and consulted on every
ink report. The view model's answer is one line, the palette's bindings
under `if case .ink = tool` and `[:]` otherwise.

Custody, after this plan:

| Value | Owner | Where it lives |
|---|---|---|
| Gesture bindings | `ToolPalette` | `UserDefaults`, with the other presets; never in the package |
| The bindings that apply to the stroke in hand | `EditorViewModel`, per tab | computed from the tool and the palette when the binding asks; nobody holds a copy |

## 2. The seam

No change. `CanvasSurface.restoreInk` and `CanvasReporting.inkChanged`
in `Modules/TNModel/Seam.swift` already carry everything. The `bindings`
parameter is on `Notebook.inkChanged`, below the seam, and on
`EditorBinding`, which is not the seam. Protocol diff: none.

## 3. File by file

**TNCanvas.** Nothing.

**TNCore.** `TNLog.swift`: a `gesture` case on `Category`.

**TNNotebook.**
- `StrokeGestures.swift`: new. The two enums, `GestureEffect.apply`,
  `ScribbleReading`, the typealias.
- `Notebook.swift`: `inkChanged` as described, with the log line.
  `retired(_:finalInk:)` is untouched; section 8 says why.

**TNEditor.**
- `ToolPalette.swift`: the field, `bind(_:to:)`, the record key, the
  default.
- `EditorBinding.swift`: `bindingsForStroke`, and `inkChanged` passes
  its answer. `retired` is untouched.
- `EditorViewModel.swift`: the initialiser installs `bindingsForStroke`;
  a new intention `bind(_ trigger:, to effect:)` calls the palette.
  Nothing in `tool.didSet` changes.

**TuberNotesApp.**
- `ToolStrip.swift`, `InkOptions`: a gestures block under the colours,
  one row per `GestureTrigger.allCases`. Each row names the trigger and
  holds a `Picker` over `GestureEffect.allCases` plus Off, calling
  `editor.bind(_:to:)`. With one trigger and one effect the picker
  renders as Erase or Off; it becomes a menu the day a second effect
  lands and the view does not change. Shown in all three ink popovers,
  because it is one set of bindings.
- `ToolPaletteDefaults.swift`: nothing. The record encodes itself.

## 4. Tests

The first test is the probe, and it runs before anything else is
written. It proves the one mechanical fact this plan adds to the system,
that a `restoreInk` arriving from inside the canvas's own
drawing-changed report lands, with the stroke-end bookkeeping around it
intact. Undo never does this, because it starts from a gesture and not
from a stroke report. The existing `restoreInkIsReportedAsAnEcho`
(`TuberNotesTests/TNCanvasTests.swift:250`) proves a programmatic set
outside any callback reports once with the echo; the probe proves the
nested case.

Hosted, `TuberNotesTests/TNCanvasTests.swift`:
- Through `PagedCanvasController` and the `RecordingReporter` (line
  1099), which gains `onInkChanged`, so the stale-sequence guard in
  `pageDidChangeInk` (`PagedCanvasController.swift:641`) and the
  snapshot rewrite in `restoreInk` (line 228) are on the path. Call
  `canvasViewDidBeginUsingTool`, set `canvasView.drawing` (that
  callback is dropped, as in production), call
  `canvasViewDidEndUsingTool`, then fire the commit change. The
  reporter answers the first report, synchronously, with `restoreInk`
  of a drawing one stroke shorter. Assert: two reports, the second
  carrying the restore's `InkSeq` as its echo; `pageStrokeDidEnd`
  observed once; the snapshot's sequence equals the canvas's; and
  `canvasView.drawing == restored` by `==`, not by count. The last
  assertion is also the answer to a second question the cost comment
  raises (`Modules/TNNotebook/PageState.swift:165-171`): `PKDrawing`
  equality is on stroke identity, and if PencilKit re-mints on
  assignment, `Notebook.retired`'s `content.ink != finalInk` would
  record a no-op entry on every retire after a gesture. If `==` fails,
  that compare needs an answer before step 2 lands.
- By hand on the simulator, finger input under the pen tool: scratch
  over a line and watch it go. The hosted test drives a programmatic
  set; this is the tool path, and the stop decision in step 0 rests on
  both.

Hostless, `TNTests`:
- `StrokeGesturesTests.swift`, new. Fixtures beside `Ink` in
  `NotebookTests.swift:126`: `Ink.zigzag(over: CGRect, turns: Int)`,
  `Ink.line(from:to:)`, `Ink.loops(around: CGRect, count: Int)`, a "w"
  with two turns, a line carrying a translation `transform`, and a
  line with a `mask` over half its length. A zigzag with four turns
  over two lines out of three has those two as its subject, and reads
  four turns. The "w" has no subject and reads two. Two loops around a
  line read zero turns, whatever the folding. A zigzag over blank paper
  has no subject, reads its turns, and its `hits` is empty. A straight
  line's `hits` is nil, because the shape thresholds failed first. A
  zigzag whose bounds intersect a stroke it does not come near has no
  subject. A zigzag drawn where a moved line's bounds are hits it;
  drawn where the line used to be, does not. A zigzag over the masked
  half of a masked line does not hit it. A thin zigzag across the edge
  of a wide highlighter line hits it. The thresholds in the test are
  `ScribbleReading`'s constants, not literals.
- `NotebookTests.swift`. With scribble bound to erase, a report of
  three lines plus a scribble over two leaves ink with one stroke, one
  `.inkRestored` change carrying a fresh `InkSeq`, and one history
  entry. Undo restores the three lines and no scribble. Redo removes
  them again. With `[:]`, the same report keeps all four strokes and
  emits no restore. A scribble over blank paper keeps the stroke either
  way. The notebook never examines a report that adds two strokes at
  once.
- `EditorBindingTests.swift`: the report reaches the notebook with the
  closure's answer.
- `EditorViewModelTests.swift`: a freshly built view model, with no
  tool selected, answers the palette's bindings, and that is the case
  that catches the initialiser; selecting the eraser answers `[:]`;
  unbinding scribble under a pen answers `[:]`.
- `ToolPaletteTests.swift`: the record round-trips the map; a record
  without it reads as `.builtIn`; `bind(_:to:)` writes and nil removes.

Hosted, `TuberNotesTests/HistoryEntryCostTests.swift`: step 5's one new
shape, and a timing case for the reading beside it, in this file's own
manner (`:150-152`, `:198-213`): fastest of five after a warm-up, under
10 ms for one zigzag against the 20k-stroke fixture. Not in hostless
`TNTests`, and not at a millisecond. A wall-clock gate on a shared CI
machine at that threshold is a step that cannot reliably land green.

Device, not a test: the thresholds, per step 4.

## 5. Contract sentences to change

Proposals; the rule is Phillip's to write.

Custody, "The notebook holds the ink", add one sentence at the end of the
paragraph:
> "The notebook recognises a Pencil gesture from the stroke it was sent
> and applies its effect as a restore. The canvas never interprets a
> stroke."

Custody table, the `ToolPalette` row, quoted:
> "Tool presets, colour recents, the last-used tool | `ToolPalette` | `UserDefaults`, through `ToolPaletteDefaults`; never in the package"

Proposed:
> "Tool presets, colour recents, the last-used tool, gesture bindings | `ToolPalette` | `UserDefaults`, through `ToolPaletteDefaults`; never in the package"

Undo, after "Every edit of a page's ink or layers records one entry, a
committed text session included, and only when the revision moved":
> "A gesture and its effect are one entry, and the stroke that was the
> gesture is in neither side."

Undo, the bound. Step 5 measured the `strokes` setter and it copies, so
a byte bound is due. Quoted (`Docs/Contract.md:323`):
> "The stack holds at most 100 entries."

Proposed:
> "The stack holds at most 100 entries and at most 64 MB of them,
> estimated when an entry is recorded and summed over the undo side;
> past either bound the oldest entries go. A drawing the canvas handed
> over shares its strokes and an entry holding one is estimated at 406
> KB whatever it holds; a drawing this app built for itself copies, and
> an entry holding one is estimated at 420 bytes a stroke. Which of the
> two it is, the edit says; a stroke count that fell does not, because
> an eraser pass and a lasso delete both come back from the canvas."

`Docs/Queue.md` gets a Pencil gestures line under the parity work,
closed when this lands. `Docs/Unproven.md` lists the thresholds, and the
editor-binding and log-module device evidence, until step 4 records the
device run.

## 6. Deliberately out of scope

- The hand-off effect. A trigger that sends its subject to something
  outside the notebook: an AI sidebar, a share sheet. Its shape is a
  `NotebookChange` carrying the page and the subject rendered to an
  image, which the binding routes upward, and the trigger stroke removed
  as its only ink edit. A render discarded when the hand-off ends is not
  a second copy of ink. It gets a `GestureEffect` case when a sidebar
  exists to receive it, and not before, because the contract forbids a
  reserved case.
- Trimming the crossed part of a stroke. The pixel eraser's job, and it
  would make a gesture's outcome depend on stroke geometry in a way no
  test can pin down.
- Draw and hold for shapes. The hold is readable from the committed
  path's timing, so it is Fork A and it would fit as a trigger whose
  effect replaces the stroke. It was step 8 of an earlier draft and
  Phillip cut it on 2026-09-14 in favour of the second trigger below.
  It stays possible.
- Double tap and squeeze. Pencil hardware gestures need
  `UIPencilInteraction` in `TNCanvas` and a new report; the tool-picker
  plan's section 6 parks those two.
- Judging the stroke a retiring canvas hands over. Section 8 records
  why there is no such stroke.
- Per-notebook bindings, or bindings in the package. A gesture is a fact
  about the person.
- A digest table for the tuning log. `grep 'TN\[gesture\]' | column -t`
  is the table at one trigger. A parser arrives if a second trigger
  makes the columns a reading problem.
- Keeping a scribble's colour out of the recents. The report carries
  the tool's colour, not the stroke's, and `ToolPalette.used`
  (`Modules/TNEditor/ToolPalette.swift:196-207`) writes nothing when
  that colour is already first, so the case is a fresh colour whose
  first stroke is a scribble that erased. It is a colour the person
  used.

## 7. Questions, and how they closed

Four were open on 2026-09-14 and Phillip closed them the same day.

1. Scribble ships bound to erase. GoodNotes ships it on, and the point
   of the gesture is not visiting the toolbar.
2. The history byte bound lands in this plan, step 5, on my judgement.
   The reviews moved the judgement one notch. Step 5 measures the one
   shape that could make the bound unnecessary, and designs the bound
   only if the number says it is due.
3. A double circle points at containment. Strokes whose bounds the
   outer loop encloses, not strokes its path crosses. Crossing would make
   a circle a rounder scribble; enclosure is what a ring around a diagram
   means, and it is what a hand-off will want.
4. Cut is removed. It was a placeholder for a second effect and had no
   destination this app owns. The second effect is the hand-off, when a
   sidebar exists.

Nothing is open.

## 8. Review disposition

**Correctness pass.** Three reviewers, three models, read the plan
against the code on 2026-09-14. Adopted, and folded into the sections
above:

- The bindings never reached a fresh tab. `EditorViewModel.init` sets
  the tool without running `didSet` (`EditorViewModel.swift:107-109`
  says so and compensates for the tool by hand), and the plan set the
  bindings only from `didSet`. A second tab sharing the palette would
  also have gone stale. The copy is gone; the binding asks a closure.
- A double circle passed scribble's thresholds. Two loops are four sign
  changes along an axis and fold at about 4.4, so scribble would have
  won first and taken the crossed strokes. Scribble now counts sharp
  turns, which a loop has none of, and the double-loop case is a
  scribble test from step 1.
- The hit test mixed drawing space with path space and ignored
  `mask`. Samples go through `transform`, the hit test samples
  candidates within `maskedPathRanges`, and the target's half width
  counts. The hit test also runs only after the shape thresholds pass,
  so an ordinary handwriting stroke never pays the page-sized pass.
- The probe drove a fake owner and never set the in-flight flags, so
  two of its assertions were vacuous and the paged controller's guards
  were off the path. It now runs through `PagedCanvasController` with
  the tool-use callbacks, asserts `==` on the restored drawing, and is
  paired with a by-hand tool-path run.
- The retiring-stroke step is gone. A deferred retire runs from
  `pageStrokeDidEnd`, which the commit report precedes
  (`PageCanvasController.swift:764-766`), so no retire carries an
  unreported pen stroke; the only differing `finalInk` is the
  deferred-restore case, which is not one stroke more than the restored
  revision. And the canvas is not gone when the retire report runs:
  `retire(_:)` and `retireLiveCanvas`
  (`PagedCanvasController.swift:335`, `:593`) release it after
  `retire()` returns, so a restore would have written to a
  delegate-less canvas.
- The cost step re-measured a published number. The erase-shaped
  rebuild on the 20k fixture is already in
  `HistoryEntryCostTests.swift:97` and reads 8.4 MB in
  `Docs/Forks/plans/undo.md:338`. A proposed sum over both stacks was
  half dead, because `record` clears redo first
  (`PageState.swift:187-190`). The bound changed a contract sentence
  with no hunk. And the `strokes` setter had never been measured for
  sharing. Step 5 is that measurement.
- The editor binding and the log module are on the required-evidence
  table (`CONTRIBUTING.md:104-116`). Steps 2 and 3 name the debt and
  step 4 pays it with a Release capture.
- "The scribble is never visible for a frame" was false; it is visible
  under the pen for its whole duration. Section 0 and step 4 now say
  "for no frame after the lift".
- A sub-millisecond wall-clock assertion in hostless CI would not land
  green reliably. It is hosted, fastest of five after a warm-up, at
  10 ms, beside the cost test that already does this.
- Smaller: the stale pixel-eraser sentence corrected, it masks and does
  not split; "tap and hold" removed from the parked list, the
  tool-picker plan parks double tap and squeeze only; the
  `import CoreGraphics` trap named in section 1; the second trigger's
  "nothing else changes" replaced by the list of what does.

Rejected: taking the byte bound out of this plan, because Phillip
decided it lands here and step 5's measurement may delete it on its
own.

**Simplification pass.** One reviewer, the same day, with the question
"would the plan be smaller without this, and what is lost". Adopted,
every finding:

- An `Examination` type holding one field per trigger, with a
  first-match rule, was a registry with one entry and a tie-break with
  nothing to break. Gone. The notebook takes the scribble reading
  directly; step 6 adds the sequencer when there are two readings to
  order, and decides the order with both in hand.
- A `TriggerMatch` type restated the reading's `hits` with a `trigger`
  field that was always `.scribble`. Gone; `subject` is a computed
  property on the reading.
- An `InkReport` return value, added by the correctness pass to keep a
  scribble's colour out of the recents, cost a three-case enum, a
  switch, and five assertions for a case that only fires on a fresh
  colour's first stroke. Reversed; section 6 records the wrinkle as
  accepted.
- A `GestureBindings` struct with two statics was a dictionary with a
  coat on, and the first pass's rejection of the bare dictionary was
  wrong. The house pattern is raw collections on the record with the
  defaults in `builtIn`. It is a typealias; the `.off` and `.none`
  paragraph went with it.
- A tuning-log step with an `awk` parser in the digest and a fixture to
  test the parser was a dozen lines of log dressed as a PR. The
  category and the line fold into step 2; the table is a grep at one
  trigger.
- The byte bound was fully designed against a number nobody had. Step
  5 is the measurement, and the bound's shape is written if the number
  says it is due.
- A caseless `GestureEffects` namespace for one static that switched on
  `GestureEffect` was two homes for one thing. It is a method on the
  effect.
- A Structure hunk restated the existing per-sample rule with the word
  "gesture" in it. Dropped; the Custody and Undo sentences carry the
  new facts.
- Four tests asserted the same fact twice or an absence: the
  highlighter-ink zigzag (no code path reads the ink type), two
  scribbles in a row (the echo case and the probe's `==` cover the only
  sources of a spurious entry), two view models on one palette (the
  closure reads the palette live, and the fresh-view-model case proves
  there is no copy), and the `.echo` return. Gone.
- Forty-five test call sites for a parameter one production caller
  passes. The parameter is defaulted; one binding test pins the caller.
- `EditorTool.isInk`, the delivery table, and the prose that described
  the deleted types. Gone.

**Implementation pass.** Three reviewers read the finished diff on
2026-09-14, before the merge. Adopted:

- An unbound scribble swallowed a bound double circle, because the
  trigger was picked before the bindings were read. Recognition is now
  one pure entry point, `GestureTrigger.recognise`, that takes the first
  trigger in order that has a subject and is bound; the notebook reads
  the strokes once, hands it the array, and logs what it returns.
- Erase went through the `strokes` setter once per removed stroke. One
  local array, one set.
- Double circle containment tested the union of the loops' boxes, so a
  stroke in a corner outside the ring went with it. It tests the outer
  loop's sampled polygon, every point of the candidate inside, masked
  ranges only.
- A rebuilt entry was priced below a shared one on any page under a
  thousand strokes. The estimate is the shared figure plus per stroke.
  The `rebuilt` flag has no default at either layer, and the test-only
  accessor is behind `#if DEBUG` with the suffix the structure suite
  checks.
- The coarse hit filter forgot `hitSlack`, and on the fixture that
  dropped 232 strokes the fine test accepts. The timing case now covers
  the whole recognition, both readings and the log: 25 ms Debug at 957
  crossings, 3.4 ms clear of the ink.

Left for Phillip: the two Contract hunks in section 5, with a `CONTRACT:`
subject. Considered and not done: a hosted test that drives the canvas,
the binding and the notebook together through one scribble; the probe
and the binding test each cover half the chain.

## 9. Cross-plan

Independent of every open plan. Touches `ToolStrip.swift`'s ink popover,
`ToolPalette.swift`'s record, `EditorViewModel.init`, `EditorBinding`,
`TNLog.Category`, and `Notebook.inkChanged`, none of which the wave-4
plans or the stickers item touch. The Scribble-and-spellcheck goal named
beside this one on 2026-09-14 is text-box work and shares nothing here
but the word.

## 10. The steps

Each step is a PR, green on the simulator, and each leaves the app
working. Steps 1 to 3 are the first pair. Steps 4 and 5 make it
trustworthy on a device and settle the cost. Step 6 adds to the trigger
axis and touches nothing on the effect axis, which is the test of
whether the shape is right. Order matters everywhere except 5, which is
independent of 4.

### Step 0. The probe

The hosted re-entrancy test in section 4 and the by-hand simulator
scribble beside it, and nothing else.

Verification is the test itself. If it fails, stop. Section 0's second
decision is wrong, and the plan is rewritten before step 1 starts. If
the echo arrives on a later turn than the latch, that is the same stop.
If only the `==` assertion fails, step 2 waits for an answer to
`Notebook.retired`'s compare (`Notebook.swift:386`), which undo already
depends on.

### Step 1. The recogniser

`Modules/TNNotebook/StrokeGestures.swift` with the two enums,
`ScribbleReading`, and the typealias. Not `GestureEffect.apply`, which
is step 2's.

Verification. `TNTests/StrokeGesturesTests.swift`, the cases in section
4, asserting on the reading as well as the subject. The double-loop case
is here, not in step 6: it is a claim about scribble.

### Step 2. The notebook applies it, and says what it saw

`Notebook.inkChanged` with the defaulted `bindings` parameter,
`GestureEffect.apply`, and the tuning line. That is a `gesture` case on
`TNLog.Category`, and one event per examined stroke from `inkChanged`,
in key=value pairs:

```
TN[gesture] page=<id> scribble.turns=<n> scribble.folding=<x.xx> scribble.hits=<n|-> effect=<erase|off|none>
```

One line per stroke, never per sample, so it sits inside the Structure
rule as written. `hits=-` is a shape that failed before the hit test
ran. `effect` says what the bindings did, so a reading with a subject
and no binding is visible as such. `Tools/device` already mirrors every
event to the console log under `TN_TRACE`. The binding passes nothing
yet, so nothing changes for a person; this step is the notebook and its
tests.

Verification. The `NotebookTests` cases in section 4. The `TNLog` case
owes a Release capture on an iPad (`CONTRIBUTING.md:114-118`); step 4
is that capture, and this PR names the debt in `Docs/Unproven.md`.

### Step 3. The bindings and the popover

`ToolPaletteRecord.gestures`, `ToolPalette.bind`,
`EditorBinding.bindingsForStroke` and the pass-through in `inkChanged`,
`EditorViewModel.init` installing the closure and the `bind` intention,
the gestures block in `InkOptions`. After this step a person has the
feature.

Verification. The `EditorViewModelTests`, `EditorBindingTests`, and
`ToolPaletteTests` cases in section 4. On the simulator, by hand with
finger input under the pen tool. Open a notebook and scratch over a
line before touching the toolbar, and watch it go; undo, watch it return
without the scribble; set scribble to Off, scratch again, watch the
scribble stay. This PR touches `EditorBinding.swift`, which owes device
evidence; the PR names the debt in `Docs/Unproven.md` and step 4 pays
it.

### Step 4. The device run

The protocol, so two runs are comparable:

1. On a ruled page, write a line of text at normal speed, including
   words with "w", "m", "x", and "xxxx". Nothing should erase.
2. Scratch out one word, one whole line, one stroke of a diagram, and
   one letter inside a word. Each should erase what it covers and
   nothing else.
3. Scratch on blank paper. It stays.
4. Draw a deliberate zigzag border along a margin. It stays, because it
   crosses nothing; note if it does not.
5. Draw a ring, then a double ring, around a word. Both stay. No
   double-circle trigger exists yet, and neither must read as a
   scribble.
6. Move a word with the lasso, then scratch it out where it now is.
7. Repeat 1 and 2 with the highlighter.

`Tools/device --release` captures the session, which is the Release
capture the log module owes. The gesture lines, grepped from the
capture and pasted, go in the PR. Where a stroke in 1 or 5 read as a
scribble or a stroke in 2 read as ink, the line says which threshold
was on the wrong side, and the constants move. I expect the turn count
to be the one that moves. A second session with the moved constants is
the evidence. The `Docs/Unproven.md` lines from steps 2 and 3 come out
when the PR records the second session, and the verdict on feel is
Phillip's. The device also answers what no test can: that the scribble
is on screen for no frame after the pen lifts, and that a highlighter
scribble erases pen ink under it.

### Step 5. The history cost, measured

One new shape in `HistoryEntryCostTests`, beside "erase five scattered
strokes" (`:97`). The same five removed through the `strokes` setter on
a copy of the revision's drawing, instead of `PKDrawing(strokes:)`. The
existing shape's reading, 8.4 MB on the 20k fixture (`undo.md:338`), is
the rebuilt figure; nobody has measured whether the setter shares.

If the setter shares, as an appended stroke does at 406 KB, the
tripwire comment in `PageState.swift:165-176` is rewritten to say the
setter is the way to edit a drawing and `PKDrawing(strokes:)` is not,
and no bound lands.

If it copies, a byte bound lands here: a `rebuilt` flag on the gesture
path's `recordEdit`, an estimate per entry at record time from the
stroke count and the two measured per-stroke figures, and eviction of
the oldest undo entries past 64 MB, with the count bound kept as the
second limit. Its shape, its tests, and the section 5 hunk are written
when the number is in, not before.

Verification. The cost test reports both readings.

### Step 6. The second trigger: double circle

`GestureTrigger.doubleCircle` and `DoubleCircleReading`. A double circle
is one stroke that closes on itself twice. The path returns to within a
closing distance of its start, keeps going, and returns again, with the
two loops' bounds overlapping by most of their area and each loop
roughly round, measured as bounds aspect and as path length over the
ellipse perimeter the bounds predict. Its subject is every stroke whose
`renderBounds` lie inside the outer loop's bounds (section 7, question
3). Empty subject is ink, as for every trigger.

This is also where two readings first need ordering. The step adds
a small sequencer over the two, with scribble first, because a
scratch-out drawn in loops must erase what it crosses. It is decided
here, with both readings to test it against, and not in step 1 by
fiat.

What changes, honestly: the case; the reading type; the sequencer and
the notebook's call into it; the dotted keys in the log line; a
`ToolPaletteRecord` question, answered here, that an existing record
with only scribble bound reads double circle as unbound, because the map
is the record and `builtIn` is only the fallback for a missing map. What
does not change: the popover, which renders a row per case; the effect
method, which does not know which trigger fired. If either changes, the
shape in section 1 was wrong and this step is where it shows.

`.builtIn` leaves the double circle unbound. A person binds it to erase
in the popover, and later to whatever section 6 adds.

Verification. `StrokeGesturesTests`: two loops around two of three
strokes have those two as their subject; a single loop has none; two
loops around blank paper have none; two loops that cross a stroke and
enclose nothing have none for either trigger, and a scribble drawn in
loops over a line is scribble's. `NotebookTests`: bound to erase, the
circled strokes and the circle go, one entry. `ToolPaletteTests`: a
record with only scribble bound reads double circle as unbound. Device:
the step 4 protocol's line 5 becomes a match, with the gesture lines.
