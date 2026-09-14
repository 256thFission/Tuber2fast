# The contract

The rules in force. This file carries no history and keeps nothing for
reference. Where the code disagrees with this file, the code is wrong.

**Every rule here is written by a human.** No agent authors a rule, and no
agent's output becomes a rule by having been committed.

**Invalid states fail loud.** When this contract says something must not
happen, the code calls `TNPrecondition` and the app traps. Nothing is
clamped, adapted, corrected, or replaced with a default unless a rule below
says so by name.

**Burn things down with permission.** There are no users and no data to
keep. No legacy support, no backwards shim, no migrator that reads a shape
this build never wrote.

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
| The tool in hand, and the text style typed with | `EditorViewModel`, per tab | in memory; the runtime is told and keeps a copy for canvases built later |
| Tool presets, colour recents, the last-used tool | `ToolPalette` | `UserDefaults`, through `ToolPaletteDefaults`; never in the package |
| The drawing during a stroke | `PKCanvasView` | until the stroke ends |
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
view. A canvas that sends ink for a page the notebook has not loaded is a
bug, and the app traps.

**The canvas is told, never asks.** `TNCanvas` receives commands through
`CanvasSurface` and sends reports through `CanvasReporting`. It knows
nothing about notebooks, files, or rendering; it knows only the list of
pages it was last given. When it needs something, such as a new page at
the end or a layer moved, it reports the event, and the answer comes back
as a command in the same pass of the main loop. `EditorBinding` is the
only type that uses both protocols. The tool picker is the app's.
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

`Modules/TNModel/Seam.swift` defines the two protocols. This section
describes them; if the two disagree, the file is wrong.

Commands, `CanvasSurface`:

- `setPages`: the whole page order, with a `StructureSeq`, and optionally
  the `ReportSeq` of the report it answers.
- `installContent`: one page's snapshot. Either ink plus composite, or a
  placeholder with the faults that refused the page.
- `restoreInk`: ink to put back, with the `InkSeq` the canvas will echo.
- `scroll(to:)`.
- `retire`: returns `.retired`, or `.deferred` when a stroke is in
  progress.
- `updateComposite`: a sharper or refreshed backdrop for a live page, with
  the layer list it was rendered from, so the runtime's hit rects match
  the picture. Ink is untouched.
- `beginTextEditing`: the layer and its value; arrives with the composite
  that omits the layer, and the runtime raises a live text view over it.
- `endTextEditing`: arrives with the composite that has the committed
  text; the runtime takes the live view down.
- `apply`: the tool.
- `undoTyping`, `redoTyping`: one-way. The text view's own manager answers
  and nothing is reported back.

Reports, `CanvasReporting`:

- `inkChanged`: the drawing, and the `InkSeq` it echoes if any.
- `layerTransformed`: answered at once with `.accepted` or `.refused`.
- `layerDeleteRequested`: answered by an `updateComposite` that omits the
  layer, which is also what takes the selection frame down.
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

**Format version is 3.** Adding a key means a version bump and a change
to the key-set pins in `TNTests/FormatTests.swift`, which fail until every
file that carries the key round-trips. There is no migrator and none is
written: a package this build did not write is refused by the key it is
missing, which is *Burn things down with permission*.

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

**Assets** are immutable. An asset is written at import, before any layer
refers to it, and is limited to 64 MB and 16384 pixels on an edge. Images
are converted to HEIC at import; PDFs are stored as received.

**Refuse at the narrowest scope, and say why.** A bad index refuses the
notebook. A missing page file, a bad ink file, an unknown paper, or a bad
layer refuses that page only. A page with a refused layer is shown as a
placeholder that names the fault and cannot be edited. The only way out is
the user removing that layer. Nothing is dropped, adapted, or written back
unread.

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
report     which pages were refused. Nothing is deleted.
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
- **Only `compact()` deletes.** Open, save, and close delete nothing.
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

The set of loaded pages follows the scroll position: pages within one slot
of the current page get a `PKCanvasView`; pages within two get a decoded
placeholder. Every page has a slot; only the near ones have a canvas, so
the number of canvases does not grow with the notebook. When a canvas
leaves the window it reports its final ink at once and is released. If a
stroke is in progress, the release waits for the stroke to end. The
notebook drops content for a page that is outside the window, has reported
its final ink, and is clean; this happens in `prune()`, which has one
caller.

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
layers are never drawn per frame: the composite is drawn once and the
scroll view scales it. The renderer's asset cache (48 MB) and thumbnail cache
(32 MB) each declare their owner, their limit, and what evicts from them,
at the point they are declared. A cache that cannot state all three is
forbidden. A thumbnail is 480 pixels on the long side and is rendered by
the `Renderer` actor from the notebook's ink, or from the page's files
when the page is not loaded; rendering one loads nothing into the
notebook, marks nothing dirty, and is cancelled when nothing wants it.

`Paper` is a value in `TNModel` and drawing code in `TNRender`, and appears
nowhere else. Asset paper is decoded through the same cache as image and
PDF layers, and so is a page being flattened or exported.

An export is one or more pages drawn by the `Renderer` into a PDF context,
or one page into a PNG, by the code that draws a composite. Paper, text,
and an imported PDF page are vector; ink and image assets are pixels, the
ink at asset resolution. A ready page is drawn from custody, unsaved ink
included; any other page from its files, decoded and discarded, installing
nothing. Exporting marks nothing dirty, records nothing, and is cancelled
between pages. The document is built in memory and handed to the system;
no file is written.

## Library

One `Notebook` object per package. `Library` reserves the checkout
synchronously and then opens asynchronously, so a second tap during the
open gets `.alreadyOpen` rather than a second `Notebook`. A re-entrant
checkout traps. Renaming, moving, trashing, or duplicating an open
notebook, or any folder above it, is refused with the notebook's name.

Trash is `Trash/<NotebookID or FolderID>/<original name>` with an
`origin.json` beside it. Recovery restores the original name, adds a
suffix only if that name is taken, and falls back to the root if the
original folder is gone. Duplicate gives the copy a new `NotebookID`,
keeps every `PageID`, and builds the copy outside the scanned tree before
moving it in. A folder has a `.folder.json` holding its `FolderID`, its
colour, and its symbol. Stars live in `Favorites.json` beside `Notebooks/`,
as identities, so a star follows a rename or a move and comes back with a
recovery.

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

Close tears down every canvas first, then runs the final save. If pages
are still dirty after it, the notebook stays open, the checkout stays
held, and a banner shows. The only way past it is "discard unsaved and
close". Only a clean close releases the checkout.

Open reads the index and `view.json`, and no pages. A page's ink loads when
the window reaches it, tagged with a generation. A result from an old
generation is dropped. A load for a page that has left the window is
cancelled.

## Structure

`TuberNotesTests/ContractStructureTests` enforces the module graph:

```
TNCore <- TNModel <- TNFormat <- TNRender <- TNNotebook <- TNEditor <- App
                 \__ TNCanvas <-----------------------------/   TNLibrary <-/
```

- `TNCanvas` imports `TNCore` and `TNModel` and nothing else of ours. The app does not
  import `TNCanvas`; it gets the canvas as a `UIViewController`. Both are
  build errors.
- `PKCanvasView` is constructed in exactly one file.
- File I/O happens in `PosixFileSystem`, `LibraryStore`, and
  `ImportReader`, and nowhere else. The app's `ToolPaletteDefaults` and
  `LibraryViewDefaults` write preferences to `UserDefaults`; a preference
  is never notebook or library state, and an unreadable one is replaced by
  the built-in default.
- Modules below the app cannot import SwiftUI (the name is aliased away in
  `project.yml`). UIKit is imported only by `TNCanvas`, `TNEditor`, the
  app, and `TextTypesetting.swift` in `TNModel`, the one typesetting
  builder the renderer and the live text view share; the checker names
  that file by name.
- Members that exist for tests are inside `#if DEBUG`.
- Nothing runs per Pencil sample except PencilKit, and nothing runs per
  keystroke except UIKit's text system: no observation, no task, no actor
  hop, no file access. A synchronous layout query inside the text system's
  own callback is inside it. Per-frame work lives in `TNCanvas`.
- `project.yml` is the only source for the Xcode project.

## Forbidden

- A second copy of ink anywhere other than the notebook and the live
  canvas. A drawing decoded for a render and discarded when the render
  ends is not a copy.
- A field reserved for a future feature.
- A file in the package that restates what other files already say.
  `hasInk` is the one exception: it records whether ink was ever
  committed, which the files alone cannot say.
- Clamping, defaulting, or repairing a value this contract calls invalid.
- A shim for a file shape this build never wrote.
