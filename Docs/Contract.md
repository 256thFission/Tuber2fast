# The contract

The rules in force. This file carries no history and keeps nothing for
reference. Where the code disagrees with this file, the code is wrong.

**Every rule here is a human decision, worded by a Fable agent.** Phillip
decides what a rule says; an agent on the Fable model words it, in a
`CONTRACT:` commit of its own that cites the decision behind it. A design
law in `Docs/Design/Macaron.md` is worded the same way. The agent that
writes the code a rule governs never words that rule, so the code is held
to the rule and the rule is not bent to fit the code. Committing a rule
does not put it in force; Phillip's push does, and that push is the
approval: there are no pull requests (decided R2-01, M6, R2-02).

**Invalid states fail loud.** When this contract says something must not
happen, the code calls `TNPrecondition` and the app traps. Nothing is
clamped, adapted, corrected, or replaced with a default unless a rule below
says so by name.

**Burn things down with permission, until the first install outside
Phillip's iPad.** Until then there are no users and no data to keep: a
file's shape may change under the version number it already has, and a
library written in the old shape is deleted, not migrated. The permission
ends at the first install on any other device, and it does not come back.
From then on every format change bumps the version and lands with the
step that carries a package from the old version to the new one, so an
older notebook opens by migration and only a newer one is refused
(decided R2, F1). Neither regime has a shim: an old shape is deleted or
migrated, never read in place.

Cite rules by name, not number. A change to a rule edits this file, and the
commit subject starts with `CONTRACT:`.

---

## Vocabulary

A **library** is a tree of folders and **notebooks** under one root. A
notebook is a package of ordered **pages**. A page has **paper**, a stack
of **layers**, and **ink**. Ink is a `PKDrawing` in page coordinates. It is
not a layer, but it has a position in the layer stack. A **composite** is
the paper and every layer rendered to one image. A **thumbnail** is a
page's composite and ink rendered small. It is derived, never saved in the
package.

Identities are separate types: `NotebookID`, `PageID`, `LayerID`,
`AssetID`, `FolderID`. Each wraps a UUID and is written as the uppercase
UUID string. The compiler rejects one where another is expected. Pages are
referred to by identity everywhere; a page's position is computed from the
list and never stored.

## Custody

Each piece of state has one owner, and the owner holds the value.

| Value | Owner | Where it lives |
|---|---|---|
| A page's newest ink | `Notebook` | `PageContent.ink` |
| Page order, paper, geometry, page bookmarks | `Notebook` | `NotebookIndex` |
| A page's layer list | `Notebook` | `PageContent.layers` |
| Undo and redo history | `Notebook` | `EditHistory` |
| The current page | `Notebook` | `view.json` |
| Which pages have canvases, the scroll position, the selected object | `PagedCanvasController` | in memory; rebuilt from one `setPages` and the installs that follow |
| The tool in hand, and the text style typed with | `EditorViewModel`, per tab | in memory; the runtime is told and keeps a copy for canvases built later; a canvas with a tool use open takes the new tool when the use ends |
| The theme | `Workspace` | in memory, resolved from the choice and the system's appearance; each editor is told and tells its runtime with the tool, and the runtime is built with one, so it never lacks one, and keeps a copy for canvases built later |
| Tool presets, colour recents, the last-used tool | `ToolPalette` | `UserDefaults`, through `ToolPaletteDefaults`; never in the package |
| The drawing during a stroke | `PKCanvasView` | until its commit lands, or its use is ended without one |
| The draft of a text box being edited | `PageCanvasController` | until the session ends |
| Page thumbnails | `Renderer` | in memory, keyed by `ThumbnailKey`; rebuilt from the page |
| The saved package | `PackageStore` | see Durable form |
| The library tree, trash, stars, identity index | `LibraryStore` | see Library |
| Which notebooks are open | `Library` | the checkout ledger |
| Tabs and the background lease | `Workspace` | in memory |

**The notebook holds the ink.** When a stroke ends, and again when a canvas
is torn down, the canvas sends the whole `PKDrawing` to the notebook. From
then on the notebook's copy is the real one; the canvas keeps a working
copy that the notebook can overwrite, for example on undo. 

The notebook
never fetches ink from a canvas, and unsaved ink is never held only by a
view. A canvas that sends ink for a page the notebook holds in any state
but ready is a bug, and the app traps, the final ink at retire included.
The one report let fall is final ink for a page the notebook has already
deleted: the page went first, and its ink went with it (decided I2, card
09 C1).

**The canvas is told, never asks.** `TNCanvas` receives commands through
`CanvasSurface` and sends reports through `CanvasReporting`. It knows
nothing about notebooks, files, or rendering; it knows only the list of
pages it was last given, and the tool and the theme it was last told. When
it needs something, such as a new page at the end or a layer moved, it
reports the event, and the answer comes back as a command in the same pass
of the main loop. `EditorBinding` is the only type that uses both
protocols. The tool picker is the app's.
`PKToolPicker` is not used, because it would be a second writer of the tool.

**No dirty flag.** A page is dirty when its edit counter is ahead of its
saved counter (`editSeq > savedSeq`); the index likewise (`indexSeq >
savedIndexSeq`). Nothing sets or clears a flag. Turning a page is not an
edit. Loading ink into a canvas is not an edit.

**SwiftUI draws state and sends requests.** No view stores a `PKDrawing`,
a pan offset, a zoom level, or a Pencil sample. `Notebook` exposes five
properties for views to read: `pageCount`, `currentPageID`,
`dirtyPageCount`, `lastSaveError`, `isClosed`. All other state is
`@ObservationIgnored`, so a stroke never causes a view to re-render.

## The seam

`Modules/TNModel/Seam.swift` defines the two protocols, and
`Modules/TNEditor/EditorBinding.swift` defines `CanvasRuntime`, which
refines `CanvasSurface` with what the binding needs of the runtime itself.
This section describes all three; where they disagree, the file is wrong.

Commands, `CanvasSurface`:

- `setPages`: the whole page order, with a `StructureSeq`, and optionally
  the `ReportSeq` of the report it answers.
- `installContent`: one page's snapshot. Either ink plus composite, or a
  placeholder with the faults that refused the page.
- `restoreInk`: ink to put back, with the `InkSeq` the canvas will echo.
- `scroll(to:)`.
- `unload`: the notebook dropped this page's content in `prune()`. The
  runtime forgets its snapshot of the page, which waits as a placeholder
  until a later `installContent` gives it content again. Never sent for a
  page with a canvas; the runtime traps if it is (decided I2, card 09 C1).
- `updateComposite`: a sharper or refreshed backdrop for a live page, with
  the layer list it was rendered from, so the runtime's hit rects match
  the picture. Ink is untouched.
- `beginTextEditing`: the layer and its value; arrives with the composite
  that omits the layer, and the runtime raises a live text view over it.
- `endTextEditing`: arrives with the composite that has the committed
  text; the runtime takes the live view down.
- `apply`: the tool and the theme, as one `CanvasEnvironment`. The
  runtime acts on what changed and on nothing else. A changed tool goes to
  the canvases, each taking it when its use ends. A changed theme repaints
  the ground, every page's paper and outline, every placeholder and an
  open selection frame, and sends no tool. A canvas handed a tool is not
  left as it was: an ink tool commits an open text session and clears a
  selection, and the text tool restyles the words selected in an open box.
  Under the system choice the theme changes at sunset, under whatever the
  hand is doing, so a theme that re-sent the tool would do one of those to
  work nobody touched (decided I5; ink-06, deepen-canvas-03).
- `undoTyping`, `redoTyping`: one-way. The text view's own manager answers
  and nothing is reported back.

The runtime, `CanvasRuntime`. `EditorBinding` holds the runtime as one of
these and nothing narrower, so the close path a test proves is the one
production runs; there is no fallback for a surface that cannot answer
(decided I2; deepen-canvas-02, deepen-editor-02, simple-canvas-02):

- `retireAll`: tears the runtime down, which is terminal (see Lifecycle),
  and retires every live page. It returns the pages whose retire a stroke
  deferred; each of those reports `retired` when its use ends. There is no
  per-page retire on the seam, because nothing outside the runtime retires
  one page.
- `setUndoAvailability`: whether undo and redo are available, as the
  notebook says; see Undo.
- `isStrokeInFlight`: whether any canvas, a departing one included, has a
  stroke in flight. This is the one fact the binding asks of the runtime
  rather than is told. It reads the answer at the moment an undo or an ink
  report arrives and keeps no copy, because the stroke is PencilKit's and
  only the runtime can say whether one is open. `TNCanvas` itself still
  asks nothing (decided I1).
- `endToolUses`: the app left the foreground, so nothing can touch the
  canvases, and a tool use PencilKit did not end, ends. Told, never asked;
  see *Every tool use ends* (decided I2, card 09 C3).

Reports, `CanvasReporting`:

- `inkChanged`: the drawing, and the `InkSeq` it echoes if any.
- `layerTransformed`: answered at once with `.accepted` or `.refused`.
- `layerDeleteRequested`: answered by an `updateComposite` that omits the
  layer, which is also what takes the selection frame down.
- `layerLockRequested`: lock or unlock, answered by an `updateComposite`
  whose layer list carries the flag.
- `pageBecameCurrent`.
- `windowChanged`: the complete set of decoded pages. Sent when the set
  changes, never per frame.
- `endBoundaryReached`: answered by a `setPages` carrying its sequence.
- `linkActivated`.
- `retired`: the final ink, or nil for a placeholder.
- `undoRequested`, `redoRequested`.
- `textBoxRequested`, `textEditRequested`: the tool's style rides with the
  first. Answered by `beginTextEditing` once the composite omits the layer.
- `textEditingEnded`: the whole committed value. Answered by
  `endTextEditing` once the composite has the text.

Sequence numbers only go up, and each kind is its own type: a
`StructureSeq` cannot be passed where an `InkSeq` is expected. A
`setPages` whose sequence is behind the last one seen is a bug, and the
app traps.

## Durable form

```
<Name>.tubernotes/
  notebook.json           the index: order, geometry, paper, bookmarks
  view.json               currentPageID; disposable
  pages/<PageID>.json     hasInk, inkIndex, the layer list
  ink/<PageID>.tnink      a PKDrawing archive inside the TNIK container
  layers/<LayerID>.json   one layer, keyed by its kind
  assets/<AssetID>.heic | .pdf
```

A test pins the exact key set of every JSON file, and each key has a test
that deletes it and checks the file is refused. JSON is written with sorted
keys and ISO-8601 dates. Ink is a binary file: a 64-byte little-endian
header (`TNIK`, container version 1, notebook ID, page ID, payload length,
CRC32 of the payload, zeros to 64) followed by the archive. Any header
mismatch or bad checksum refuses the page. There is no separate checksum
table.

**Format version is 1**, in the package and in every versioned file the
library keeps beside it. The index carries it as `formatVersion`, and it
is the first thing read from a package, before any key is checked: a
version this build does not write refuses the notebook by its number,
never by a key, because the number is the one fact that says what the
rest of the file means. A newer version is refused in words that say the
notebook needs a newer TuberNotes. An older version is carried to the
current one by the steps that opening it runs, and refused only where no
step reaches it (*An older notebook is migrated on open*). Three keys of
the index never change name or type, at any version: `formatVersion`,
`notebookID` and `createdAt`. The library reads only those three to list
a package, so a notebook keeps its identity in the listing, in stars and
in the trash at a version this build cannot open, and a migration can
tell what it holds before it reads anything else. Adding or removing a
key changes the key-set pins, in `TNTests/FormatTests.swift` for the
package and in `TNTests/LibraryTests.swift` for a sidecar, which fail
until every file that carries the key round-trips, and once *Burn things
down with permission* has ended it bumps the version too (decided R2, F1,
F2, F3; tests-hostless-01).

**Layer kinds are `image`, `pdf`, `link`, `text`, and nothing else.** The
payload object is keyed by the kind name, so an unknown kind is detected
before its payload is parsed. Adding a kind is a `CONTRACT:` change.

**Ink is not a layer.** `inkIndex` is the ink's position in the stack. An
import inserts at `inkIndex` and increments it, so ink stays above imported
content. `hasInk` never goes back to false. Once it is true, the ink file
is written whenever the ink changes, an empty drawing included, and is
deleted only with the page. A save that changes only layers does not
rewrite the ink file.

**Bookmarks** are a list on the index, at most one per page, each naming
a page the index holds and carrying a title that may be empty. The outline
is that list in page order; nothing else is stored for it. A bookmark is
not a layer, is not ink, and is not undoable. Deleting a page takes its
bookmark with it, and a save that drops a page drops its bookmark too.

**Paper** is either drawn or an asset. Drawn paper is `none`, `blank`,
`lined`, `grid`, or `dotted`. Asset paper is an image (`.heic`) or one page
of a PDF (`.pdf` plus a page index), stored in `assets/` like any other
asset and named from the page's record in the index:

```json
{ "id": "UUID", "width": 612, "height": 792,
  "paper": { "kind": "image", "asset": "UUID.heic" } }
{ "id": "UUID", "width": 612, "height": 792,
  "paper": { "kind": "pdf", "asset": "UUID.pdf", "sourcePageIndex": 3 } }
```

Paper is not a layer: it cannot be selected, moved, or deleted, it always
fills the page, and a new page copies the current page's drawn paper
(`none` becomes `blank`) unless its creation specified a paper; after asset
paper a new page is `blank`. Asset paper
is drawn to fill the page rectangle exactly and is never stretched: the
page's geometry is set from the asset's aspect when the paper is applied,
and asset paper can only be applied to a page with no ink and no layers.
Applying it to a drawn page is refused. Drawn paper can be applied to any
page.

Asset paper comes from three places, and each is an asset import followed
by a paper change on an empty page: a photo, a page of a PDF, or a
**flattened page**, which renders another page's composite and ink to an
image at asset resolution. Flattening does not change the source page.
Importing a PDF creates one new page per PDF page, each with that page as
its paper; the `pdf` layer kind is for a PDF clipping placed on a page.

A page whose paper this build does not know is refused; the notebook still
opens. A page whose paper asset is missing is refused the same way.
`compact()` treats a paper asset as reachable from the page that names it.

**Geometry** is per page, chosen when the page is created from a
catalogue of named sizes or a custom size, finite, and within
`PageBounds`: `maxEdge` is 4096 points; `minEdge` is derived from `ZoomCap`
so that no page fits wider than the runtime can zoom. Both are constants
in code, not fields in the file. After creation it changes only when asset
paper is applied to an empty page; a page with ink or layers is never
resized. Page space has its origin top-left, y down, in logical points.
Ink outside the page rectangle is kept, never clipped. Pan, zoom, view
frames, and the tool are never saved in the package.

**Transforms.** Image and PDF layers carry an affine transform from the
unit square into page space. It must be finite, have `|det| > 1e-9`, and
translate by no more than ten page edges. Link and text layers carry the
identity transform and a rect in page space.

**Every layer carries `locked`.** A locked layer renders and exports like
any other; it refuses a transform and a delete, and says so.

**Assets** are immutable. An asset is written at import, before any layer
refers to it, and is limited to 256 MB and 16384 pixels on an edge; an
import past the limit is refused with the limit in megabytes. Images are
converted to HEIC at import; PDFs are stored as received. The limit is
independent of the renderer's asset cache, which stays at 48 MB: an asset
larger than the cache is read again for each render, a cost accepted for
the page turns of a big PDF (decided R2-10, I6).

**An asset is read mapped, never copied into memory.** `readAsset` hands
back the file's bytes mapped from the package, through `PosixFileSystem`
like every other read, so a 256 MB PDF is never 256 MB of heap for each
composite, thumbnail and export page that opens it. The index, page, layer
and ink files are read as copies: each is decoded at once and only the
decoded value is kept. A mapping is safe because an asset file is written
once and never rewritten in place, so a mapping never sees its bytes
change, and the unlink `compact()` runs leaves a live mapping valid (*Only
`compact()` deletes from a package*). Every asset is mapped, not only one
larger than the cache: `TNFormat` does not know the renderer's bound, and
one rule with no threshold is as safe as one with (decided R2-10; critique
C8).

**Refuse at the narrowest scope, and say why.** A bad index refuses the
notebook. A missing page file, a bad ink file, an unknown paper, or a bad
layer refuses that page only. A page with a refused layer is shown as a
placeholder that names the fault and cannot be edited. The only way out is
the user removing that layer. Nothing is dropped, adapted, or written back
unread. In the library the scope is the item a sidecar describes (*An
unreadable sidecar refuses only the item it describes*).

**`nil` is not an answer.** A missing package is an error, a missing
`view.json` means the first page, and nothing else is optional.

## One save

```
plan       validate; no I/O
stage      per page: ink file, layer files, page file, each written to a
           temp path with F_BARRIERFSYNC before close. A page that fails
           to stage is dropped from this save and reported as refused.
publish 1  rename every staged ink and layer file into place;
           fsync ink/ and layers/
publish 2  rename every staged page file into place; fsync pages/
publish 3  only if the index changed: write it listing only the pages
           whose files are present, and only their bookmarks (skip it if
           that list is empty);
           stage, rename, fsync the package root
report     which pages were refused, and which intended pages the written
           index left out. Nothing is deleted.
```

- **A save writes only what changed.** An unchanged page file is not
  rewritten. The index is rewritten only when order, paper, geometry, or a
  page bookmark changed. Rewriting an unchanged file is a bug.
- **Leaves first, then page files, then the index.** The test in
  `TNTests/FormatTests.swift` injects a fault at every write of a save,
  in three modes (fail, truncate, discard after rename), and checks that
  `load()` never returns an index that refers to a file that is not there.
- **Atomic per page, not across pages.** A crash between phases can leave
  an ink file for a page whose file says `hasInk: false`. Open treats the
  ink file as the ink and marks the page dirty.
- **An index written without a page this pass tried to save is not the
  saved index.** Publish 3 lists only the pages whose files are present,
  so a page that failed to stage is left out of the index written in the
  same pass, and the report says which pages were left out. The notebook
  advances `savedIndexSeq` only for an index that left out none of the
  pages the pass captured. After any other index the index stays ahead of
  its saved counter, the notebook stays dirty, and the next pass rewrites
  the index, so the page is named by the first index written after its
  file lands; the index on disk is not the intended one, so that rewrite
  is not a rewrite of an unchanged file. Only captured pages count: a page
  the notebook holds as a placeholder, one whose file is missing for
  instance, is never captured and is left out of every index written, and
  it neither keeps the index dirty nor blocks a clean close. The reason is
  the retry. A refused page stays dirty and its file lands on a later
  pass; had the partial index counted as saved, that pass would carry
  `indexChanged: false`, the page would commit and go clean, close would
  report clean, and the reopened notebook would list neither the page nor
  its ink (decided I2; contract-03, durability-01).
- **Only `compact()` deletes from a package.** Open, save, and close
  delete nothing a package holds. What an open removes after a migration
  is the copy the exchange left in Staging, which is no package anything
  lists (*An older notebook is migrated on open*).
  Compact removes files no page refers to, only if they are more than a
  day old, and skips a whole class of file if it could not read every file
  that might refer to it.
- **A missing file that the index refers to refuses the page. A file the
  index does not refer to is ignored** until compact.
- **`view.json`** is written by rename, without fsync, one second after a
  page turn. It has no version.

Save timing. Capture is synchronous: for every dirty page, the values and
their sequence numbers. Serialization runs once per save in a detached
task at utility priority. The write runs on the store actor. On success,
`savedSeq` advances for each written page. If the store refuses a page, it
stays dirty. If the write fails, the serialized bytes are kept (up to 64
MB across the batch) so the retry does not encode again, and the retry
waits twice as long each time, up to five seconds. Between edits, the save
waits four times the last serialize duration, clamped to 0.5 to 2 seconds,
and never more than five seconds after the first edit. While a save is
running, edits do not schedule another; the finishing save schedules the
next one if anything is still dirty.

After `save` returns, the next `load` returns the same values. A save that
throws is not acknowledged. A process that dies mid-save leaves complete
files or none.

## Undo

Undo belongs to the notebook. There is one stack per notebook of
`HistoryEntry` values: the page, and its revision before and after one
edit, where a revision is the ink, the layer list, and the ink's index.
Every edit of a page's ink or layers records one entry, a committed text
session included, and only when the revision moved; undo applies the
difference. It survives page turns. An undo restores the
page it happened on, whichever page is showing, and scrolls to it. If that
page has been unloaded, the restore waits as a pending revision and is
adopted when the scroll loads it.

**Undo waits for the stroke.** An undo or redo that arrives while any
canvas has a stroke in flight is ignored, whichever way it came, the bar
or the system gesture. `EditorBinding` asks the runtime `isStrokeInFlight`
at that moment and touches nothing: the stack is as it was, and the undo
after the stroke lands removes exactly that stroke. An ink report that
arrives while a stroke is in flight runs no gesture: it is a commit
landing under the next stroke, and it is kept as plain ink. So no restore
reaches a canvas mid-stroke, and the canvas traps if one does. The reason
is custody: the drawing under the Pencil is PencilKit's until it commits,
and a restore under it would replace ink the notebook has never seen
(decided I1; card 09 C2).

The canvas hands the responder chain a `FilteringUndoManager`. It records
nothing and undoes nothing itself: PencilKit's registrations are dropped,
and the system undo and redo gestures are forwarded as `undoRequested` and
`redoRequested`. The notebook tells the canvas whether undo and redo are
available; the canvas never computes it. A per-canvas undo stack is
forbidden, because it would be a second copy of the ink. While a text box
is being edited, the text view's own undo manager answers the chain for
typing. It dies with the session and holds nothing durable.

The stack holds at most 100 entries. Turning, adding, reordering, and
deleting pages are navigation, not edits, and cannot be undone; deleting a
page forgets its entries.

## Navigation and the window

Pages sit in equal slots, each one viewport wide, and the user turns them
horizontally with `UIScrollView` paging. The view never rests between two
pages. A page is scaled to fit its slot and centered. The minimum zoom is
that fit and the maximum is `ZoomCap`. A page turn is possible at fit zoom
or when the page is panned to its own horizontal edge; zoomed in and away
from an edge, a horizontal drag pans instead.

**Only a finger or a pointer turns a page; the Pencil never does.** The
paging scroll view's pan takes a direct touch and the indirect pointer, a
trackpad or a mouse, and no other touch type. A `UIScrollView`'s pan takes
the Pencil by default, so a Pencil drag PencilKit did not claim, one that
began at a page's edge, or one under the text tool, which turns the
drawing gesture off, turned the page under the Pencil. A pan inside a
zoomed page is not a turn: under the text tool `PKCanvasView`'s own pan
takes the Pencil, and that moves the view within the page's slot, never
past it. Finger navigates, Pencil writes, which is the design law in
`Docs/Design/Macaron.md` (*The finger never draws. The Pencil never drags
chrome*) at the page (decided M3 S2).

The set of loaded pages follows the scroll position: pages within one slot
of the current page get a `PKCanvasView`; pages within two get a decoded
placeholder. Every page has a slot; only the near ones have a canvas, so
the number of canvases does not grow with the notebook. When a canvas
leaves the window it reports its final ink at once and is released. If a
stroke is in progress, the release waits for the stroke to end. The
notebook drops content for a page that is outside the window, has reported
its final ink, and is clean; this happens in `prune()`, which has one
caller, and which tells the runtime with `unload`. The runtime then forgets
its snapshot, and the page comes back as a placeholder until the notebook
pushes its content again. A canvas is built only from an install, never
from a snapshot the notebook has let go, so a canvas exists only for a
page the notebook holds ready. The reason is the first stroke on a page
revisited by a navigator jump: built over a snapshot while the notebook
was still reloading, the canvas sent ink the notebook could not take
(decided I2, card 09 C1; contract-01, ink-01, durability-03).

**Every tool use ends.** A use is open from PencilKit's
`canvasViewDidBeginUsingTool`, and one of three things ends it. Its commit
lands: the drawing change that follows `canvasViewDidEndUsingTool` is the
stroke, and the use is idle as that report leaves. Nothing commits: a pen
use, which is any `PKInkingTool`, waits for its change up to `commitBound`,
500 ms, because PencilKit commits a pen stroke after the use ends and the
iPad has shown that commit landing later than one turn of the main loop;
any other tool's changes land during the use, so it ends one turn after
PencilKit ends it. Only a pen use that commits nothing reaches the bound,
and reaching it is logged, so a session on the iPad can show whether a real
stroke ever does. Nothing can touch its canvas any more: the runtime left
the window, or the app left the foreground. Either door ends a use that is
still drawing, after one turn so PencilKit's own cancel goes first, and
leaves a use that is already committing to its commit or its bound, so a
forced exit never pre-empts PencilKit. Each use carries a number, and a
timer or a hop armed for one use ends no other. A tool told to a canvas
while its use is open is held and applied when the use ends, after the
stroke's report has left: PencilKit's stroke is never handed a new tool
mid-flight, because the text tool turns the drawing gesture off, which
cancels the stroke under the Pencil. A use must end because everything
waits on it: installs, composites, window refreshes and the release of the
canvas wait for the use, and *Undo waits for the stroke*, so a use nothing
ended would freeze page turns and undo for the whole tab (decided I2, card
09 C3; ink-04, tests-hosted-05).

Swiping past the last page adds one. The runtime reports the boundary with
a sequence number and rubber-bands until a `setPages` answering that number
arrives in the same pass. If the notebook refuses to add a page, no answer
comes and the runtime springs back. A new page exists on disk only once
the index has been written.

## Rendering

A composite is the paper and every static layer except a text layer
being edited, which the runtime draws live over the composite until the
edit is committed. It is rendered by the `Renderer` actor at no more than
`maximumLongEdgePixels` (2800) on the long side, and sent to the canvas as
an immutable `CGImage`. A composite result that a later render has
superseded is dropped. Paper and
layers are never drawn per frame: the composite is drawn once, and the
page-sized view that holds it is placed and scaled to the canvas's offset
and zoom on each scroll and zoom tick, which is a frame change, not a draw.
The text box and the selection frame ride the same way above the ink.
Nothing of ours is a subview of the `PKCanvasView`: PencilKit zooms only its
own content view and paints its tiles opaquely over anything else. The renderer's asset cache (48 MB) and thumbnail cache
(32 MB) each declare their owner, their limit, and what evicts from them,
at the point they are declared. A cache that cannot state all three is
forbidden. A value larger than a cache's bound is not cached and evicts
nothing for it: under the 256 MB asset limit a PDF larger than the cache
is an ordinary case, and an insert that first emptied the cache would
have every other asset on the page decoded again for every render
(thermo-canvas-04, arch-canvas-03). A thumbnail is 480 pixels on the long
side and is rendered by the `Renderer` actor from the notebook's ink, or
from the page's files when the page is not loaded; rendering one loads
nothing into the notebook, marks nothing dirty, and is cancelled when
nothing wants it.

**An asset is read and decoded once, at render size, for every render
waiting on it.** A read in flight is recorded until it lands, and a render
that misses the cache while one is in flight waits on that read instead of
opening its own. The record is not a cache and declares no bound, because
nothing stays in it once the read lands. The `Renderer` actor is reentrant
across that read, so without the record the five window pages that open
on a lecture PDF read it five times, each a whole copy (thermo-canvas-04).
An image is decoded at no more than `maximumLongEdgePixels` on its long
side, the most any render draws, so a 24 MP photo costs about 31 MB and
stays cached instead of being decoded again on every layer change; an
image's aspect comes from the file's own pixel size, never from a decode
that may have rounded (arch-canvas-03).

`Paper` is a value in `TNModel` and drawing code in `TNRender`, and appears
nowhere else. Asset paper is decoded through the same cache as image and
PDF layers, and so is a page being flattened or exported.

An export is one or more pages drawn by the `Renderer` into a PDF context,
or one page into a PNG, by the code that draws a composite. Paper, text,
and an imported PDF page are vector; ink and image assets are pixels, the
ink drawn at asset resolution and an image as it was decoded, at no more
than `maximumLongEdgePixels` on its long side, so an exported or
flattened photo is at most 2800 pixels there and a layer stretched past
the page is drawn from that decode (arch-canvas-03). A ready page is drawn
from custody, unsaved ink included; any other page from its files, decoded
and discarded, installing nothing. Exporting marks nothing dirty, records
nothing, and is cancelled between pages. The document is built in memory
and handed to the system; no file is written.

## Library

One `Notebook` object per package. `Library` reserves the checkout
synchronously and then opens asynchronously, so a second tap during the
open gets `.alreadyOpen` rather than a second `Notebook`. A re-entrant
checkout traps. Renaming, moving, trashing, or duplicating an open
notebook, or any folder above it, is refused with the notebook's name.

Trash is `Trash/<NotebookID or FolderID>/<original name>` with an
`origin.json` beside it. Recovery restores the original name, adds a
suffix only if that name is taken, and falls back to the root if the
original folder is gone. Duplicate gives the copy a new `NotebookID` and
keeps every `PageID`. A folder has a `.folder.json` holding its
`FolderID`, its colour, and its symbol. Stars live in `Favorites.json`
beside `Notebooks/`, as identities, so a star follows a rename or a move
and comes back with a recovery.

**A sidecar is committed the way the index is, and before the item it
describes.** The library's sidecars are `.folder.json`, `Favorites.json`
and `origin.json`. Each is staged beside its final name with the barrier,
renamed into place, and followed by an fsync of its directory: the
sequence *One save* uses for the index, through the same file-system seam,
so `TNTests/LibraryTests.swift` injects the same three faults at each of
these writes and finds the old file or the new one, never a torn or empty
one. A sidecar is never written in place, and Foundation's `.atomic` is
not this sequence: it renames and never syncs. Trash writes `origin.json`
and syncs its container before the item moves in, so a process that dies
mid-trash leaves the item where it was, or the complete entry, and a
listing never meets an item whose sidecar a crash took. A temp file a
crash leaves beside a sidecar is a plain file, and a listing shows only
directories, so no sweep is owed. The library writes through the seam;
its reads, listings, copies and recursive deletes stay on `FileManager`
(decided F4).

**Trash deletes nothing that holds an item.** The container is named by
the item's identity, so a container that already holds an item is a second
item under one identity: a collision, refused with `.alreadyExists` and
both items left as they were, never resolved by deleting the first. A
container holding only its `origin.json` is what an interrupted trash or
recovery leaves; it holds nothing, so it is cleared and the name reused,
which is how the item it once named can be trashed again. An item whose
identity cannot be read goes under a fresh UUID, and a notebook's entry
then carries no `NotebookID`: the trash does not invent one, because an
invented identity is a default for a value the package failed to give
(decided F2; *Forbidden*).

**An unreadable sidecar refuses only the item it describes, and says so.**
`Favorites.json` describes the stars; `.folder.json` describes one
folder's identity, colour and symbol; `origin.json` describes where one
trashed item came from and when. A sidecar this build cannot read refuses
exactly that and nothing around it, and the refusal is shown, never
swallowed: a line in the library that names the file and the fault. It is
not a log line, and it is not a trap, because a file that will not read is
a fact about the disk, not an invalid state of the program. The writes
above leave no torn sidecar, so an unreadable one was written by another
build or damaged since, and either way the rest of the library is whole
and is shown. Per file:

- The stars. The listing shows none, the Favorites section is refused,
  and Documents, search and Trash list as usual. Starring and unstarring
  are refused the same way and the file is not written over: a set written
  from what could not be read would be a default for the set the file
  failed to give.
- A folder. It is listed, with the fault beside it, and has no identity,
  no colour and no symbol, so no star shows for it and a colour or symbol
  set on it is refused with that fault. The folder and what it holds are
  listed as they are, because they are not what the sidecar describes.
- A trash entry. It is listed, its name and kind taken from the one item
  inside its container and the fault in place of its date, and it can be
  recovered: the recovery lands at the root under that name, suffixed if
  the name is taken, since where the item came from is what the file could
  not say. Every container that holds an item is an entry, so Empty Trash
  offers the count of what it removes and takes nothing a person could not
  see; a container that holds no item is not an entry (*Trash deletes
  nothing that holds an item*).

A sidecar's version is read before any key, as the index's is, and a
sidecar has no ladder: one at any other version is refused the same way,
by its number. A list the library could not read is shown as refused,
never as empty, wherever it is shown, the move picker's folders included:
an empty list says there is nothing, and that is not what happened. This
is the scope *Refuse at the narrowest scope* gives a page, brought to the
library. Before it, one unreadable `Favorites.json` refused every section
and left no way in but a reinstall, and a trash entry whose record would
not read was hidden from the list and deleted unseen by the next Empty
(decided F4; format-06, format-07, durability-04, deepen-notebook-04,
format-04, policy-10, thermo-data-02).

**Staging is scratch, and an item enters the tree by one exclusive
rename.** `Staging/` sits beside `Notebooks/` and `Trash/`, outside the
scanned tree, and a new item is built there whole before anything lists
it: a folder with its `.folder.json` already committed inside it, a
notebook as a complete package, a duplicate as the copy carrying its new
identity. Each is then published into the tree by a single rename that
refuses an occupied target (`renamex_np` with `RENAME_EXCL`, which fails
with `EEXIST`) and never replaces one. The rename is the claim on the
name: a check before the build claims nothing, because a second create
can take the name across the build's await, so whatever the rename meets
is refused with `.alreadyExists` and left as it was, never deleted and
never written into. A rename, a move, a recovery and a duplicate's landing
are the same kind of rename, and every landing is followed by an fsync of
the directory it left and the one it entered, Staging's excepted, since
nothing in Staging is kept. So a listing never meets a half-built item: a
folder is listed only with its sidecar, which is how the sidecar comes to
be committed before the folder it describes; a notebook only with its
index; a process that dies before the publish leaves nothing listed and
the name free; and one that dies mid-move leaves the item at its old path
or its new one. What Staging holds is therefore a copy not yet published
or the leftover of a process that died, and can be removed at any time
without loss. That invariant is what a sweep of Staging and a migration
rely on, and it binds them: a migration that builds in Staging keeps the
original where it stands until the swap commits, because nothing live is
ever Staging's alone. So the store empties `Staging/` when it starts, and
a duplicate or a migration whose build fails removes the copy it was
building (decided F4, F1; durability-07).

**An older notebook is migrated on open, in Staging, and swapped in by one
exchange.** `TNFormat` holds the steps as a plain list, one for each
version this build has left behind, each carrying a package from its
version to the next; there is no protocol and no registry. A package at
version N runs the step for N, then the next, until it is current, all on
one copy, so a step is written once, against the shape its version wrote.
The decoders stay strict and know one version: a step is the only code
that reads an older shape, and it reads that shape as its own input, never
through a decoder taught to accept it. The list is empty today, because
every version is 1 and nothing older was ever written; the ladder, the
exchange and the sweep exist now so the first step lands as a step and
not as a rewrite of the open path.

The ladder runs in one place: inside `Library.checkout`, after the
reservation is taken and before `Notebook.open`, where that reservation
already refuses a rename, a move, a trash and a duplicate of the package
for as long as it is held. It is a call of its own, never part of
`PackageStore.load()`: a cover, a duplicate's identity rewrite and
`compact()` all load a package, and a ladder reached from any of them
could swap a stale copy in under a notebook that has already saved into
the live one. Each of those still refuses an older version, and the
listing, the stars and the trash read only the three stable keys, so an
older notebook keeps its name and identity and shows no cover until its
first open. Duplicate runs the same steps on its own copy in Staging
before it gives that copy its identity, and swaps nothing.

A migration is a build in Staging and one exchange. The original is
cloned into `Staging/`, and each step writes into the clone through the
seam a save writes through, staged with the barrier and published by
rename. The clone is verified by loading it as this build loads any
package, the index and every page, and is synced. Then the clone and the
original change places by one atomic exchange (`renamex_np` with
`RENAME_SWAP`, which is why `Staging/` and `Notebooks/` share a volume),
the directory the package lives in is synced, and the copy the exchange
left in Staging is removed. The live path is never empty and the only
copy is never in Staging, so a process that dies at any point leaves the
old package in place or the new one, and the next launch's sweep takes
what else was left. Two renames in place of the exchange are forbidden:
between them the only copy is in Staging, and the sweep would take it. A
step that throws ends the migration where it is: the clone is removed,
the original has not been touched, and the open is refused with the
step's fault. A page the clone refuses when it is verified is refused as
it would be on any open and does not refuse the migration: a step carries
a page's fault forward and does not mend it, and a notebook that held a
refused page before an update still opens after one (*Refuse at the
narrowest scope*). Verification is for a step that broke what it did not
mean to touch; what a step means to do is proved against a package
written at the version it leaves (decided F1, R2; format-02, format-03,
durability-07).

The identity index maps `NotebookID` to path. It is built off the main
thread and marks notebooks in the trash. If two packages share an
identity, the second one found gets a new one. A link followed before the
index is built is refused with "still loading".

## Links and tabs

A link layer points at a page, in this notebook or another. Tapping it is
a report; the editor turns the layer into a target; the app opens or
focuses that notebook's tab and scrolls to the page. Each notebook has at
most one tab. A missing target says so; so does a target in the trash.
Backlinks, if ever built, are computed and never saved.

## Lifecycle

`Workspace` takes the background lease and holds it until no write is
outstanding. It runs one forced save per open notebook, active tab first.
If the lease expires it is logged; the format recovers on next open. A
forced save runs on backgrounding and on close.

**Leaving the foreground ends every open tool use before the forced
save.** Leaving cancels every touch, and PencilKit may not end the use it
was in, so `Workspace` tells every editor `endToolUses` on the phase
change, before the flush: no tab comes back wedged on a use nothing would
end (decided I2, card 09 C3).

**A phase change during the flush makes it run again.** A phase change
that arrives while the flush runs is noted, not dropped, and when the pass
ends the task runs another; the lease ends only after a pass during which
nothing arrived. The reason is the pair `.inactive` then `.background`:
the first starts the flush, and a cancelled touch's late commit lands after
that pass has captured its pages, so the page is dirty when the lease ends
and a suspension kill loses the ink that the dropped second change would
have saved (decided I2, card 09 C6; round-two call: the lease takes a
second pass).

**Close tears down every canvas first, and the teardown is terminal.**
`retireAll` marks the runtime torn down: from then on it builds no canvas,
whatever install, settle, layout pass or stroke end arrives, and it does
not scroll; an install still stores its snapshot. A use still drawing on a
canvas outside any window is ended in the teardown, at once, because
nothing can touch that canvas and nothing else would end its use; a use
that is committing is left to its commit or its bound. Close then waits,
with no deadline, until every retire the teardown deferred has reported
`retired` for this close; a report from an earlier retire of the same page
counts for nothing. Then it runs the final save. If pages are still dirty
after it, the notebook stays open, the checkout stays held, and a banner
shows; the runtime stays torn down, placeholders and no scrolling, until
the close is retried or the notebook discarded, because more ink would not
save either. The only way past the banner is "discard unsaved and close",
which finds the runtime already empty, so it has nothing to retire. Only a
clean close releases the checkout. The reasons are two crashes. A canvas
built after the teardown, by a load landing during the final save or a
page turn after a refused close, went out with the tab without its final
report and trapped in `deinit`. And the two seconds close once gave a
deferred retire released a canvas still mid-use, so the stroke was lost
and the app trapped; the close glyph is only in the library, where no
canvas is in a window, so a use still drawing at close is one PencilKit
never ended, and a wait on it would never finish (decided I2, card 09 C4;
round-two calls: close waits for the lift, a refused close leaves the tab
torn down; arch-canvas-02, arch-app-01, thermo-canvas-01, contract-04,
ink-02).

Open reads the index and `view.json`, and no pages. A page's ink loads when
the window reaches it, tagged with a generation. A result from an old
generation is dropped. A load for a page that has left the window is
cancelled.

## Structure

`TuberNotesTests/ContractStructureTests` enforces the module graph. It
reads every source's `import` lines against one table of what that
module may import, of ours and of the system's; for ours, the table is
this graph:

```
TNCore <- TNModel <- TNFormat <- TNRender <- TNNotebook <- TNEditor <- App
                 \__ TNCanvas <-----------------------------/   TNLibrary <-/
```

- `TNCanvas` imports `TNCore` and `TNModel` and nothing else of ours. The
  app does not import `TNCanvas`; it gets the canvas as a
  `UIViewController`. Both are structure-test failures, not build errors:
  every target compiles against one products directory, and
  `transitivelyLinkDependencies` embeds `TNCanvas` in the app, so the
  compiler accepts an import this graph forbids. Only the checker refuses
  it.
- `PKCanvasView`, or any subclass of it, is constructed in exactly one
  file: a subclass is the same surface under another name, so the checker
  finds the subclasses in the sources rather than keeping a list of them
  (decided I2).
- The canvas's `tool` is assigned at exactly one site, where `apply`
  lands. `PKToolPicker`, which assigns it behind the runtime's back, is
  not named anywhere (*The canvas is told, never asks*). A second
  assignment by any spelling is a second writer of the tool, so the
  checker counts the assignments, not only the picker's name.
- No source in `TNCanvas` names `Theme.current` or `Theme.changed`. The
  theme reaches the canvas through `apply` and no other way: a global the
  canvas reads is the canvas asking, and the notification that once told
  it to repaint was a second route beside the seam, which reached the
  ground and the placeholders but not an open selection frame, and whose
  observer was never removed. The names are gone from `TNModel`, so the
  build refuses them today; the checker keeps them gone (decided I5;
  contract-16, theme-04).
- File I/O happens in `PosixFileSystem`, `LibraryStore`, and
  `ImportReader`, and nowhere else. The app's `ToolPaletteDefaults` and
  `LibraryViewDefaults` write preferences to `UserDefaults`; a preference
  is never notebook or library state, and an unreadable one is replaced by
  the built-in default.
- Modules below the app cannot import SwiftUI (the name is aliased away in
  `project.yml`). UIKit is imported only by `TNCanvas`, `TNEditor`, the
  app, and `TextTypesetting.swift` in `TNModel`, the one typesetting
  builder the renderer and the live text view share; the checker names
  that file by name. PencilKit re-exports UIKit, and the modules below
  those three import PencilKit for `PKDrawing`, so the import line alone
  cannot keep UIKit out of them: in every module other than those three,
  an identifier spelled `UI` followed by a capital letter is a
  structure-test failure as well, `TextTypesetting.swift` excepted.
- Members that exist for tests are inside `#if DEBUG`.
- Nothing runs per Pencil sample except PencilKit, and nothing runs per
  keystroke except UIKit's text system: no observation, no task, no actor
  hop, no file access. A synchronous layout query inside the text system's
  own callback is inside it. Per-frame work lives in `TNCanvas`.
- `project.yml` is the only source for the Xcode project.

## Forbidden

- A second copy of ink anywhere other than the notebook, the live canvas,
  and the runtime's snapshot of a page the notebook has pushed and not
  told it to unload. That snapshot is the last install, brought up to date
  by the final ink the page's canvas reported when it retired. It is kept
  so a page that leaves the live window and comes back is rebuilt without
  a reload, and it is dropped the moment `unload` arrives, so it never
  outlives the notebook's own copy (decided I2, card 09 C1). A drawing
  decoded for a render and discarded when the render ends is not a copy.
- A field reserved for a future feature.
- A file in the package that restates what other files already say.
  `hasInk` is the one exception: it records whether ink was ever
  committed, which the files alone cannot say.
- Clamping, defaulting, or repairing a value this contract calls invalid.
- A shim for a file shape this build never wrote.
