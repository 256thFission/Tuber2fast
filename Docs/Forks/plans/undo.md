# Undo parity with GoodNotes

A plan, not code. Branch `v2-mvp`. Every claim below is grounded in a
file it names; where the code moves, the file wins.

**In short.** Today the notebook's stack undoes ink and nothing else.
Every other edit a person can make on a page, which is inserting a photo
or a link, committing a text box, and moving or deleting an object,
marks the page dirty and skips the stack, so an undo
after any of them removes the stroke before it instead. The fix is one
change of data shape: a history entry stops being "the ink a page had"
and becomes "the revision a page had", meaning its ink and its layer
list together. Every mutation records the revision it
replaces and the revision it produced, and one `restore` diffs the
revision against the page to decide what to push back down. Ink undo is
unchanged by construction. Page deletion stays outside the stack, as it
is in GoodNotes, and the history it strands is purged rather than
swallowed. An adversarial review on 2026-09-11 found two pre-existing
races that undo would widen and two holes in the first draft; all four
are closed in the steps below. Two device checks that the whole design
rests on are still unrun and are listed last.

## 0. Where undo stands

The machinery is complete for ink and the contract describes it exactly
(`Docs/Contract.md`, Undo). One notebook-wide `InkHistory` of
`HistoryEntry { page, ink }` in `Modules/TNNotebook/PageState.swift`,
bounded at 100 entries. `Notebook.inkChanged` records the previous ink
before taking the new one; `Notebook.undo()` and `redo()` pop and hand
the entry to `restore`, which either pushes `.inkRestored` for a `.ready`
page or stashes it in `pendingRestores` and loads the page, applying on
arrival in `installLoaded` (`Modules/TNNotebook/Notebook.swift`). The
binding turns `.inkRestored` into `restoreInk` plus a `scroll(to:)`
(`Modules/TNEditor/EditorBinding.swift`, `push`). The canvas installs the
value with an echo sequence so PencilKit's callback for the programmatic
set is not taken for a stroke (`PageCanvasController.restoreInk`). The
toolbar buttons and the system gesture both end at `undoRequested`, the
buttons through `EditorViewModel.undo()` and the gesture through
`FilteringUndoManager`, which drops PencilKit's registrations and
forwards the two verbs (`Modules/TNCanvas/FilteringUndoManager.swift`).

What is not on the stack, each a call to `content.edited()` with no
`history.recordEdit` beside it, all in `Notebook.swift`:

| Mutation | Reached from | Records |
|---|---|---|
| `insertLayer` | `importImage`, `addLinkLayer`, `createTextBox`, `addLayer` | nothing |
| `transformLayer` | `layerTransformed` report; no gesture drives it yet | nothing |
| `deleteLayer` | tests only | nothing |
| `endTextEditing` | every committed text session | nothing; `KNOWN DEFECT` block |
| `setPaper` | the paper menu in the toolbar | nothing; stays that way, decision 1 |

And three recorded doubts. `deletePage` leaves the page's entries and
any pending restore behind, and `restore` swallows an entry whose page is
gone (`KNOWN DEFECT` at `deletePage`; the `.unreadable, nil` arm of
`restore`). `InkHistory` is bounded by count because nobody has measured
what an entry costs (`KNOWN DEFECT` at `InkHistory`). And whether
PencilKit's registrations actually pass through `FilteringUndoManager`,
and whether a system undo gesture during a text session reaches the text
view's own manager rather than ours, are both estimates
(`FilteringUndoManager`, `Docs/Forks/plans/text-editing.md` section 1).

The parity ledger's two lines for this area are "Undo and redo of ink:
shipping" and "Undo of anything that is not ink: incomplete". This plan
closes the second and turns the first's device checks into evidence.

## 1. What GoodNotes undoes, and what this plan matches

GoodNotes keeps one stack per open document, cleared when the document
closes. Its undo covers every edit on a page: strokes, erasing, lasso
moves and deletions, inserting and transforming images and text boxes,
typing inside a text box while it is open, and template changes. Its
support article says plainly that "some actions are not currently
undo-able with the Undo and Redo icons", and page deletion is one of
them: a deleted page goes to the library's Trash Bin and is recovered
from there, not with the undo button. Page add and reorder are likewise
not on its stack.

So parity is:

- **On the stack.** Ink (done). Layer insert, transform, delete. A
  committed text edit. Whatever lasso and shape tools add
  later, which change ink and layers in one gesture.
- **Off the stack.** Turning, adding, reordering, and deleting pages,
  which the contract already calls navigation, and paper changes, which
  GoodNotes undoes and Phillip chose not to (decision 1). A page
  trash bin is the GoodNotes answer to an accidental delete; it is a
  library feature and not this plan's.
- **Inside an open text session.** Typing undo is the text view's own,
  and dies with the session, as it does in GoodNotes.

The verdict on record is "whatever GoodNotes has"
(`Docs/Forks/fundamental-rewrite.md`, verdict 8), and none of the above
adds a field to the format.

## 2. The data shape

One entry, one page, the revision it had before the edit and the revision
the edit produced:

```swift
/// What a page looked like at one moment. A value; ink is copy-on-write
/// and the layer list is small, so an entry costs what changed.
package struct PageRevision: Sendable, Equatable {
    package let ink: PKDrawing
    package let layers: [Layer]
    package let inkIndex: Int
}

package struct HistoryEntry: Sendable {
    package let page: PageID
    package let before: PageRevision
    package let after: PageRevision
}
```

Both sides, not one. Today `InkHistory.undo(current:)` builds the redo
entry at undo time from the page's current ink, and when the page is
unloaded it cannot, so `installLoaded` pushes the redo entry on arrival
from whatever the disk holds. That is one slot per page
(`pendingRestores`) and a redo entry made later than the undo. Two undos
into the same unloaded page before the load lands collapse into one redo
and lose the middle state; an undo on another page in between puts redo
out of order. With `after` on the entry, undo pushes a complete redo entry
at once whether or not the page is loaded, `pushRedo` and the `current`
closures are deleted, and `restore` never reads the page to decide what
redo returns to. Entry N's `after` is entry N+1's `before` on the same
page, and both are copy-on-write values, so the second side costs a
reference.

`InkHistory` is renamed `EditHistory`: `record(_ entry:)`, `undo() ->
HistoryEntry?` moves the entry to the redo stack, `redo()` moves it back,
`forget(_ page:)` drops every entry for a page from both stacks, the 100
bound, redo cleared by a new record. `pendingRestores` becomes
`[PageID: PageRevision]` and stays one slot, because with `after` on the
entry the last stash is the right answer.

Why one revision rather than an enum of `.ink` and `.layers` cases (the
shape `text-editing.md` section 1 sketched). The enum gives every case its
own restore path, and the first tool that changes ink and layers together
(lasso moving a selection that holds a stroke and an image) needs a third
case and a third path. A revision has one restore path that diffs, and a
mixed edit is one entry for free. The cost is that an ink entry also holds
a layer list it does not need, which is an array of small values, and
that the restore compares two drawings; the compare is measured in step 5
and, if it is slow at depth, an identity check on the drawing's storage
comes first.

`PageContent` gains one derived accessor, `revision`, so the capture at
every record site is one expression and cannot drift.

**Record iff the revision differs.** Every record site does the same
three things: capture `content.revision` before mutating, mutate, and
record only when `content.revision != captured`. Not "when the edit
counter moved": an abandoned empty box bumps `editSeq` twice and lands on
the revision it started from, and a drag that ends where it began is
`.accepted`. Either would push an entry that restores nothing and clear
redo on the way in. A refused transform or an invalid layer records
nothing for the same reason.

**Restore is one function**, `apply(_ revision: PageRevision, to page:)`,
and it diffs. Paper is not in the revision, so a restore never touches the
index and never emits a structure change:

- Ink differs: `content.setInk`, a fresh `InkSeq`, `pendingEcho`, push
  `.inkRestored`. Exactly today's path.
- Layers or `inkIndex` differ: set both; every layer in the revision that
  is absent from the current list or unequal (`Layer` is `Equatable`) to
  the one with its id goes into `pendingLayerFiles`; `content.edited()`;
  `rerenderComposite`, whose `.compositeUpdated` carries the new layer
  list to the runtime's hit rects. A layer the restore removed is not
  pending; its file stays on disk because only `compact()` deletes, and
  the page file stops naming it. Its asset likewise: immutable, written
  before any layer named it, and removed by `compact()` only once no
  committed page file names it and it is older than a day
  (`PackageStore.compact`). Compact knows nothing of the stack, so any
  layer that leaves the saved page and is restored from the stack a day
  later, an undone import redone or a deleted image undone, can name a
  missing asset; the page is then refused at the next load with
  `layerRefused`, the contract's answer to a missing asset, and it is
  recorded in `Docs/Unproven.md` rather than guarded.

Then `bumpContentVersion` and `markDirty`, once, if anything differed.

**A restore never runs under an open text session.** `apply` requires
`content.textEditing == nil` with `TNPrecondition`, because a restore
rewrites the layer list and can remove the layer a session is open on,
after which `endTextEditing` traps on a layer the page no longer holds.
The rule that keeps the precondition true is in step 3.

**A restore never runs under a stroke.** `PageCanvasController.restoreInk`
already requires no stroke in flight, and nothing upstream throttles an
undo request today, so a toolbar tap with the other hand mid-stroke traps
the app. The runtime knows the stroke; the notebook does not. So
`PagedCanvasController.restoreInk` and `updateComposite` defer while a
stroke is in flight on that page and apply when it ends, the way
`installContent` already defers, and the precondition in
`PageCanvasController.restoreInk` becomes the check that the deferral
worked. The notebook's value is already the truth by then; the canvas is
one stroke late in showing it.

**Pending layer files survive a save that was already in flight.** A
save captures `layerFiles` synchronously, writes them asynchronously, and
on success runs `content.pendingLayerFiles.subtract(item.layerFiles.map(\.id))`
(`performSave`). A restore that lands between capture and completion
re-pends a layer the save is about to un-pend, the page file is rewritten
on the next pass without it, and the notebook closes clean with the
undone value on disk. Ink is guarded by `inkSeq` against `savedInkSeq`;
layers have no sequence. The fix is one comparison: subtract a layer only
if the one in custody still equals the one captured. Pre-existing, but
today only two edits of one layer inside one save window reach it; undo
makes it ordinary.

## 3. The steps

Each step is a PR, green on the simulator, and each leaves the app
working. Order matters only where stated.

### Step 1. The revision

`PageState.swift`: `PageRevision`, `HistoryEntry.before` and `.after`,
`EditHistory`. `Notebook.swift`: `pendingRestores` retyped, `restore`
becomes `apply(_:to:)` with the two diffs and the two preconditions,
`installLoaded` applies a pending revision through `apply` so a layer
difference rerenders the composite the load built from the on-disk
layers, `thumbnail(of:)` reads the pending revision's ink and layers
instead of only its ink, `performSave` subtracts by value. `inkChanged`
records `HistoryEntry(before: captured, after: content.revision)`. No new
call site records anything yet.

Verification. Every existing undo test in `TNTests/NotebookTests.swift`
passes unchanged: `undoWithoutEcho`, `undoAcrossPages`, the undo cases in
`contentVersionBumpSites`, and the unloaded-page thumbnail test. New
tests: a revision whose layers equal the page's and whose ink differs
pushes exactly one `.inkRestored` and no `.compositeUpdated`; two undos
into the same unloaded page before the load lands, then two redos, walk
back through both states; an undo on an unloaded page then an undo on a
loaded one redo in the reverse order; an ink report during a held save
followed by a transform's restore leaves that layer pending after the
save completes (a `FormatTests`-style held store).

### Step 2. Layers

`insertLayer`, `transformLayer`, `deleteLayer` record after their own
validation, iff the revision differs. `EditorBinding.undoRequested` and
`redoRequested` call `surface.scroll(to:)` with the page `notebook.undo()`
returns, after the drain, and the scroll leaves `push(.inkRestored)`,
because the scroll is the answer to the undo whatever kind of change it
restored. `PagedCanvasController.restoreInk` and `updateComposite` defer
during a stroke on that page.

Verification, `NotebookTests`. Insert then undo removes the layer, restores
`inkIndex`, queues a `.compositeUpdated` whose `layers` omits it, and
redo brings it back with the file pending. Transform then undo restores
the transform and marks the file pending. Delete then undo re-lists the
layer at its position. A refused transform, and an accepted one to the
same transform, record nothing and `canRedo` is unchanged. An undo into
an unloaded page whose entry is a layer change loads the page, applies on
arrival, and queues a `.compositeUpdated` without the layer.
`EditorBindingTests`: an undo whose entry is a layer change scrolls to
that page. `TNCanvasTests` (hosted): a restore and a composite arriving
during a stroke apply after `canvasViewDidEndUsingTool`, and the report
that follows carries the echo.

### Step 3. Text sessions

The session, not the commit, is the edit. `PageContent.textEditing`
becomes `TextSession { layer: LayerID; before: PageRevision }`, one field,
so the two facts cannot drift. `createTextBox` captures before
`insertLayer` and opens the session with that capture; `beginTextEditing`
on an existing box captures at begin; the two share one private opener
that takes the capture, so `beginTextEditing` never captures a second
time under `createTextBox`. `endTextEditing` records `before` against
`content.revision` after its own commit, iff they differ, which makes an
abandoned empty box and an unchanged commit record nothing without a
flag. `insertLayer` takes its recording decision as a parameter so the
box's insertion is not a second entry.

**Routing while a session is open.** The notebook owns the fact
(`content.textEditing`), so the binding decides, for undo and redo alike:
if any page has an open session, the binding sends the surface
`undoTyping()` or `redoTyping()`, one-way commands with no answer, and
never calls `notebook.undo()` or `redo()`. The runtime forwards them to
the open `TextEditingView`'s own `undoManager`, and during the `.opening`
window before the view exists they are no-ops, where the first draft's
"ask the runtime whether a view exists" query would have reached the
stack. The toolbar buttons stay enabled throughout a session; mirroring
the text view's `canUndo` upward would be a report per keystroke, which
the Structure rule forbids. `EditorViewModel.importImage`, `importPDF`,
and `addLink` refuse while a session is open on the current page, with
the same banner the tool strip uses for a refused action, because an
insert during a session would record an entry out of order with the
session's. This is the rule that keeps `apply`'s precondition true.

Verification. `NotebookTests`: create, type, commit, undo removes the box
in one step and redo brings it back with its text; open an existing box,
change it, commit, undo restores the old runs; open and commit unchanged
records nothing; create and abandon empty records nothing; `apply` on a
page with an open session traps. `EditorBindingTests`: undo and redo
requested while a session is open reach the surface as `undoTyping` and
`redoTyping` and the notebook's stack is untouched; an import during a
session is refused. `TNCanvasTests` (hosted): `undoTyping()` with a session
open reaches the text view's manager; during `.opening` it does nothing.
Device, on the PR template's list: the three-finger undo gesture during a
session undoes typing, not the last stroke; the same gesture after the
session commits undoes the box.

### Step 4. Deleting a page purges its history

`deletePage` calls `EditHistory.forget(page)` and drops the pending
restore. So does the point a load ends `.unreadable`, which today clears
only the pending restore. The `.unreadable, nil` arm of `restore` splits:
`nil` becomes a `TNPrecondition`, because after `forget` an entry cannot
name a page the notebook does not hold; `.unreadable` calls `forget` and
logs, because a page can still become unreadable at a load the entry
predates. The `KNOWN DEFECT` at `deletePage` goes.

Verification. `NotebookTests`: edit a page, delete it, `canUndo` reflects
only the other pages' entries; an undo whose page was pending load when
deleted does not trap and restores nothing; a page whose load fails after
an entry was recorded drops the entry.

### Step 5. The bound, measured

Done, `TuberNotesTests/HistoryEntryCostTests.swift`. The count bound stood
in for a byte bound nobody had measured. A hosted test now measures four
shapes on the simulator, each as the difference between a run that records
a hundred entries and one that does not, at twenty thousand strokes. It
reads `mach_task_basic_info` resident size and `malloc_zone_statistics`
bytes in use side by side, because resident proved unusable at this
granularity: the simulator's allocator hands pages back mid-run, and one
unrecorded run read as minus 252 MB. Malloc was stable to the tenth of a
kilobyte across runs, and is what the assertion uses.

| Shape | Per entry |
|---|---|
| A stroke appended, read back from the canvas | 406 KB |
| A drawing rebuilt with strokes removed, erase-shaped | 8.4 MB |
| A drawing rebuilt with a contiguous run removed, lasso-shaped | 8.1 MB |
| A transform beside a hundred-kilobyte text layer | 0.4 KB |
| For comparison, an independent copy of the drawing | 16.4 MB |

Appends share, as expected. 406 KB per entry at twenty thousand strokes is
twenty bytes a stroke, the array and not the strokes, so a hundred entries
cost about 40 MB. The new term this plan adds, the layer list on an entry,
costs about 400 bytes: layers and text runs are copy-on-write and the
transform shape is free. The rebuild shapes do not share at all, because
`PKDrawing(strokes:)` mints a new stroke object for every stroke handed to
it.

**The count bound holds, because nothing in this app rebuilds a drawing.**
Every `PKDrawing` the notebook takes custody of comes from
`canvasView.drawing`, through `pageDidChangeInk` or the retire's final
report; `PKDrawing(strokes:)` appears nowhere on a path into custody. A
PencilKit eraser pass is a canvas round trip, which the test measures at
347 KB retained, not a rebuild. So a hundred entries cost tens of
megabytes, not hundreds, and the `KNOWN DEFECT` at `EditHistory` records
the numbers rather than the doubt.

The rebuild rows are a tripwire, not a present cost. The first tool this
app implements itself that builds a drawing from strokes, which is the
lasso in section 5, pays 8 MB an entry and 840 MB at the bound, which is
jetsam territory. The committed test fails when that lands. Two facts go
with it. `PKDrawing` equality is on stroke identity, not on points: a
value copied compares equal, a drawing decoded from the same bytes
compares equal, and two rebuilds of one stroke array compare unequal to
each other. So "record iff the revision differs" will record an entry for
a rebuilt lasso operation that removed nothing, at full price. A lasso
will need its own answer to both, and this is where it is written down.

The compare `apply` pays on every undo, `before.ink == content.ink` at
twenty thousand strokes, is 0.08 to 0.7 microseconds. The plan's fallback
of an identity check on the drawing's storage first is unnecessary and is
not written.

The simulator is not an iPad and the resident column is the one that
matters on a device. `Tools/device` builds and installs; it does not run a
test bundle, so the number comes from `Tools/device --check` for the UDID
and then `xcodebuild test -destination "platform=iOS,id=<UDID>"
-only-testing:TuberNotesTests/HistoryEntryCostTests`. That is the queue's
third device check.

### Step 6. The evidence that the design rests on

Not code. The two `FilteringUndoManager` doubts are the queue's first
device check and gate the word "parity". On an iPad: draw three strokes,
three-finger swipe left, and confirm the stroke that vanishes is the one
the notebook popped (`TNLog` prints "undo gesture reached the runtime"
and the toolbar's redo lights). Then the two text-session lines from step
3. Then undo tapped with a finger while a Pencil stroke is in progress,
which must apply when the stroke ends and not trap. If the gesture undoes
a stroke the notebook still holds, PencilKit is keeping a private manager
and the fallback is `canvasView.undoManager` observation, written in
`FilteringUndoManager`'s header. Record the result in the PR that lands
step 3 and strike the lines from `Docs/Unproven.md`.

## 4. Contract

Every hunk is Phillip's `CONTRACT:` commit; this is the proposal.

Custody table, the row `Undo and redo history | Notebook | InkHistory`
becomes `| EditHistory`.

Undo, replace the first paragraph with:

> Undo belongs to the notebook. There is one stack per notebook, holding
> page revisions: the ink and layer list a page had before one edit and
> after it. Every edit on a page records one entry, and only when the
> revision changed: an ink report, a layer inserted, transformed, or
> deleted, a text session that changed its box. It survives page turns.
> An undo restores the page it happened on, whichever page is showing,
> and scrolls to it. If that page has been unloaded, the undo loads it
> and restores on arrival. Deleting a page forgets its entries. A restore
> never runs under an open text session or under a stroke.

Undo, after the `FilteringUndoManager` paragraph, once step 6 has run:

> While a text box is being edited, the text view's own undo manager
> answers the gesture and the toolbar for typing. It dies with the
> session and holds nothing durable. Nothing else is inserted on that
> page while it is open.

Undo, the last paragraph, becomes: turning, adding, reordering, and
deleting pages, and changing paper, are navigation, not edits, and cannot
be undone. Step 5 may replace "at most 100 entries" with the measured
bound.

The seam, Commands, add `undoTyping` and `redoTyping`, one-way.

## 5. Out of scope

A page trash bin, which is GoodNotes' answer to an accidental page
delete and a library feature. Undo of page add, reorder, paper, or PDF
import as pages. Lasso and shape tools, which will record through the
same `revision` capture when they exist. Undo surviving close. A per-page
stack. Any change to the format. Hit rects between a restore and its
composite landing are stale for one render, as they are after any layer
edit today; a tap in that window on a removed text box's old rect is
answered by the notebook the way the runtime answers a begin it cannot
honour, and that is a one-line change in `beginTextEditing` folded into
step 2, not a design item.

## 6. Decisions

1. 2026-09-11: paper changes are navigation, not edits. The revision
   carries no paper record.
2. 2026-09-11: while a box is open, typing owns undo. The toolbar and the
   gesture drive the text view's own manager, and when the box closes the
   buttons return to the notebook's stack. Buttons enabled throughout.
3. 2026-09-11: one text session is one undo step. Create, type, close
   undoes as one; open, change, close undoes as one; open and close
   unchanged records nothing.
4. 2026-09-11, from review: entries carry both sides, so redo is pushed
   at undo time and the on-arrival redo push goes; record iff the
   revision differs; the notebook's session fact routes undo and redo;
   restores defer under a stroke; the save un-pends by value.
5. 2026-09-11, from building it: an undo tapped while a Pencil stroke is
   down discards that stroke. The restore waits for the stroke, and the
   report the stroke would have made is dropped, because the notebook
   already holds the restored value and that report would be taken for an
   edit of it. This follows from "the notebook's value is already the
   truth" and it is the one place this plan loses a person's ink.
   Phillip's to confirm on the device check in step 6.
6. 2026-09-11, from building it: `endTextEditing` asks two questions, not
   one. Whether the commit moved the page is what the save and the
   thumbnail read; whether the session moved the revision is what the
   stack reads. An abandoned empty box moves the first twice and the
   second not at all, and conflating them closes a notebook clean with
   the box still on disk.

## 7. Cross-plan

`README.md` in this directory. This plan lands after the four in it and
touches `Notebook.swift`, `PageState.swift`, `EditorBinding.swift`,
`EditorViewModel.swift`, `Seam.swift`, `PagedCanvasController.swift`,
`PageCanvasController.swift`, and the test files, none of them in a
region another open plan edits. `plan/library-browser` does not touch the
notebook. Steps 1 and 4 are `TNNotebook` and need no device evidence;
steps 2 and 3 touch `TNCanvas` and the binding and do.
