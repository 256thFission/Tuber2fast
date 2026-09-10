# TuberNotes v2: the rewrite specification

Status: finalized proposal, 2026-09-10, revised after three adversarial
reviews the same night. Every decision here was taken by Claude under
Phillip's standing instruction ("make your best decision, lock it, build")
and is Phillip's to overturn. Per `Docs/Contract.md`, no agent authors a
rule: nothing in this file is in force until Phillip writes it into the
contract in his own words. It is the map the build follows tonight.

Evidence base: the three-reader code audit of `4035bf7` (2026-08-13), the
three reviews of the first draft (durability, custody/runtime,
simplicity), and Phillip's product verdicts. Old docs were treated as
untrustworthy; old code was treated as evidence, never authority.

Constraints in force: no users exist, so no compatibility is owed to any
byte on disk; effort is not a constraint, quality and extensibility are the
only two; local-only forever; iPad, one window; PencilKit is the ink engine.

## Phillip's verdicts

1. Local-only, forever. The format serves durability and open speed.
2. Pages, with per-page dimensions inside stated bounds.
3. One window, as a rule rather than a build setting.
4. PKDrawing is the ink bytes, inside a versioned container of ours.
5. One tab per notebook. Reopening focuses the existing tab.
6. Links anchor to a page: `(notebookID, pageID)`.
7. Backlinks, if ever, are a rebuilt index, never bytes.

## Decisions taken tonight (D1 to D14)

D1. Undo is the notebook's. Per-page history of ink values, one entry per
tool-use session, capped at 50 entries or 32 MB per page. History lives
as long as the page's content does: the decoded window plus dirty pages.
Scroll two pages away and back and the undo stack is gone. That is a
product verdict, stated here so it is chosen rather than discovered. Layer transforms join the same history. Page
operations are not undoable in v2.0; deletion confirms. The mechanism for
keeping the system gestures (three-finger swipe, shake, Cmd-Z) is a
filtering `UndoManager` vended by the page controller that drops
PencilKit's registrations and forwards undo/redo to the notebook. The
policy is locked; the mechanism is stage 4's device spike.

D2. Page bounds. `minPageEdge = 137.6 pt`, derived: widest supported
viewport (1376 pt) times the zoom cap (0.05 pt per px) times the display
scale (2). `maxPageEdge = 4096 pt`, chosen so a pixel-capped composite is
still legible at fit-width; the number needs device evidence and is the
one constant here Phillip should expect to move. No area bound.

D3. Ink is not a layer. A page is ink plus a stack of static layers, with
`inkIndex` naming where the ink sits in the stack. This deletes the four
ink-layer validation rules the audit found on every path.

D4. Vocabulary. Notebook, not document. Paper, not template. Branded
identities: `NotebookID`, `PageID`, `LayerID`, `AssetID`. Package
extension `.tubernotes`. Library root `Notebooks/` under Application
Support.

D5. Typed text is not built. Layer kinds are an open set on disk and a
closed enum in code. An unknown kind refuses the layer.

D6. Recognition is derived data with no format provision.

D7. Composites travel down as values (`CGImage`, already decoded). The
zoom-detail push is a device spike. The fallback is a runtime-held
renderer fed only by value requests, stated as a carve-out if it happens.

D8. JSON for every structured file, sorted keys, uppercase hyphenated
UUIDs. Ink is a binary container.

D9. One package format version in `notebook.json` governs every file in
the package except the ink container, which carries its own. A key added
in version N+1 is required at N+1 and arrives with a registered, tested
migrator that rewrites the package by staged copy and atomic swap inside
`load()`. v2.0 ships the ladder with zero migrators. A newer version
refuses by number and is never swept.

D10. The commit protocol is stage, then publish in three ordered phases.
Every file is written to a temp path with `F_BARRIERFSYNC` on its
descriptor before close, so its bytes precede any rename. Publish then
renames all leaves (ink, layers), syncs their directories, renames all
page files, syncs `pages/`, renames the index if it changed, syncs the
root. Three ordering points, one per phase. Per-file barriers order data
before names; directory syncs order the phases. `Data.write(.atomic)` is
not used anywhere in the package. There is no per-page atomicity across
the phases: a crash between phases leaves new leaves under an old page
file, or a page file naming a leaf that is not there, and both are
page-scoped faults, never notebook ones.

D11. One deletion authority: `compact()`. Nothing is deleted on the open
path and nothing is deleted by a save. Compact runs at idle after open,
reads every page and layer file, and deletes files no committed page
reaches: orphan layers and assets, orphan page and ink files, and staging
temps. A file younger than twenty-four hours is left alone, so a crashed
save's uncommitted ink survives a day for inspection. If any layer file
is unreadable or names an unknown kind, asset reclamation is suspended
for the whole notebook: an unreclaimed asset is heavy, a reclaimed live
one is lost.

D12. The zoom cap is a code constant, not a durable field. It is pinned to
PencilKit's silent clamp of `maximumZoomScale` at 10 on a 2x display.

D13. `currentPageID` lives in a disposable `view.json`, outside the commit
path. Turning a page never rewrites the index.

D14. Coexist, swap, delete. New `TN*` targets land beside the `Tuber*`
targets, each stage green and committed on branch `v2-rewrite`. The app
swaps in stage 6a. `Tuber*` is deleted in 6c.

---

# Part 1: the tentative contract

Rules are cited by name. The priority ladder breaks every tie: ink
integrity, interaction latency, document durability, spatial correctness,
feature breadth.

## Custody

No orphan ink. The `Notebook` holds the authoritative newest ink for every
page it has content for. The runtime holds a working copy and reports
every change as a value. The one exception is the stroke under the Pencil
right now, which no report can carry until it commits; teardown defers
while a stroke is in flight.

Reports carry the ink. A drawing-changed report includes the drawing
value. A report that says "changed, come ask" is forbidden.

An install is never an edit. Pushing ink down (content arrival, undo
restore) stamps a sequence number; the runtime stamps the same number on
the report PencilKit fires for the programmatic set, and the notebook
drops that echo. The guarantee rests on installs running only when no
stroke is in flight and on the main actor serializing the set and its
callback; the latch clears on the first change after the set or at the
end of the turn, whichever comes first, so a set that fires no callback
cannot arm it forever. Whether the callback is synchronous and single is
part of stage 4's spike.

The final report. A page controller has one retire path, `retire()`,
which delivers its final ink report synchronously and records that it
did. `deinit` reads that record and traps through `TNPrecondition` if it
is unset. `retire()` is refusable: while a stroke is in flight it answers
"deferred" and delivers the report when the stroke ends. The notebook
asserts that every retire it asked for has reported, deferring the check
by exactly the retires that were deferred. A leaked controller is caught
by the notebook's check, a dropped one by `deinit`.

A save that lies is ink loss. "Saved" is claimed only after the publish
rename returns. Close reports clean only when no write is outstanding.

## Seams

Two channels, both values. Down: descriptors, snapshots, commands. Up:
value reports and answered questions. No mutable, shared-authority object
crosses in either direction. Immutable reference-backed values
(`PKDrawing`, `CGImage`) are values for this rule.

Identity, never position.

Answers are returned, never inferred. A request fulfilled later
(`windowChanged` asking for content) is answered by a push, never by a
synchronous pull.

No re-entry into a mutation. Each side finishes its own state change
before it delivers a message, and reports are the last thing a runtime
callback does. That is what makes a synchronous answer safe: the binding
drains the notebook's queued changes as soon as the report's handler
returns, still inside the same turn, so an append answers before the
next frame. `setPages` is applied as a diff keyed by page identity and
carries the sequence of the report it answers, if any.

Placeholder, never blank.

## Durability

Local-only, stated.

The package. One index, one page file per page, one ink container per
page with ink, one file per static layer, one file per asset. Opening
costs O(pages) stats and reads no page, ink, or layer file.

Plan, then stage, then publish. A save validates and plans before any
I/O, then stages every file, then publishes in the three phases of D10.
A page that fails to stage is dropped from the publish whole and
reported refused; nothing of it is published this save.

The index commits what is present. The index write is the commit point
when the index changed. Its content is the intended page list intersected
with the pages whose files are present after publish. A refused new page
is absent from this commit and stays dirty in memory. If the intersection
is empty the index is withheld and the whole save is reported refused.
The index never names a page file that is not there, and no page's ink
waits on another's.

Strict current version. A current-version file missing a required key
refuses, naming the key. Key sets are pinned by a delete-each-key test.

Apple's ink, our container.

Identity is minted by one function, called from create, duplicate, and
import. Duplicate re-mints the notebook identity during the staged copy
and preserves every page identity, which is what keeps internal links
internal. A colliding `notebookID` on arrival is re-minted for the
newcomer. Derived data keys on identity; page-scoped derived data keys
on `(notebookID, pageID)`, because duplicates share page identities.

Derived data is disposable. Every cache declares owner, bound, and
evictor. Deleting all of it loses nothing.

Geometry is the page's, inside `[minPageEdge, maxPageEdge]`, immutable
after creation. Paper is the page's and may change; the change rewrites
the index.

One writer, in the type. Package access is checked out from the library.
One `Notebook` per package, N packages open at once. Tree mutations
refuse by name on a checked-out package or an ancestor of one.

The library is not file-shared. Exposing it to Files is a `CONTRACT:`
change that needs an `NSFilePresenter` story.

A link is a soft identity. Internal links are page-relative, external
links are `(notebookID, pageID)`. Resolution runs at activation through
the identity index. A missing target is a surface, never a rewrite.

## The runtime

The frame path. Only the canvas runtime does frame-frequency work. Its
state is reconstructible from one `setPages` and N installs, except
viewport state, which the tab owns.

Never block on bytes. No file, encode, decode, PDF, or image work on an
interaction path or the main actor.

One slot per page, one viewport wide. Pages vary in size inside their
slot; slots do not vary. Slot width is the current bounds width; a bounds
change relayouts and re-anchors on the current page. Paging stays the
framework's. There is no resting position between two pages. A turn is
available at fit-width, or once a pan reaches the page's own horizontal
edge; zoomed in and away from an edge, a horizontal drag pans. The
current page is the slot the viewport rests on.

Window from viewport. The live window is the slots intersecting the
viewport plus one on each side; the decoded window is one more each side.
Both are one expression in one place. The runtime tells the notebook the
complete decoded window with `windowChanged(to:)` and installs the subset
it shows; the notebook prunes only pages the runtime has retired.

Never interrupt a stroke. `isStrokeInFlight` is set at
`canvasViewDidBeginUsingTool` and cleared after the drawing change that
follows `canvasViewDidEndUsingTool`. Installs, window changes,
first-responder moves, and teardown wait for it.

## The app

One window.

Snapshots down, intentions up.

Background tabs hold no frame path. Only the active tab has a runtime.
Backgrounding releases the runtime and drops composites; decoded ink for
the tab's window is kept, so foregrounding is not a cold reopen.

The lease outlives the write. `Workspace` owns the background-execution
lease. On leaving the foreground, every open notebook runs one forced
save pass, active tab first; the lease ends when no write is outstanding.
Files carry `.completeUntilFirstUserAuthentication` so a locked device
does not fail the write.

## Process

Contract changes are explicit. Evidence over green. Invalid states fail
loud. A seam earns its keep. Known defects live in the code. Every tuned
constant carries the evidence that set it, and where the evidence is
missing tonight it says so.

Programmer-error traps route through `TNPrecondition`, swappable under
`#if DEBUG`, so a trap is testable.

---

# Part 2: the durable format

```
<Name>.tubernotes/
  notebook.json           index; commit point when it changes
  view.json               disposable; currentPageID
  pages/<PageID>.json
  ink/<PageID>.tnink
  layers/<LayerID>.json
  assets/<AssetID>.heic | .pdf
```

## notebook.json

```json
{ "formatVersion": 2,
  "notebookID": "UUID",
  "createdAt": "2026-09-10T07:00:00Z",
  "pages": [ { "id": "UUID", "width": 612, "height": 792,
               "paper": { "kind": "lined" } } ] }
```

Validation, each refusing by name at notebook scope: version is 2; every
key present; at least one page; page IDs unique; each edge finite and
inside the bounds. An unknown paper kind refuses that page, not the
notebook. Paper kinds are `none` (a PDF-backed page shows its source),
`blank`, `lined`, `grid`, `dotted`. A new page copies the current page's
geometry and paper, except that `none` becomes `blank`. A new notebook
has one page, US Letter, blank paper.

The index changes on: insert, append, delete, move, paper change. Nothing
else rewrites it.

## view.json

```json
{ "currentPageID": "UUID" }
```

Written on page turn, debounced one second, by temp and rename with no
barrier. Disposable, so it is outside the version ladder. Missing,
invalid, or naming a page not in the index means the first page.

## pages/<PageID>.json

```json
{ "pageID": "UUID", "hasInk": true, "inkIndex": 2,
  "layers": ["LayerID", "LayerID"] }
```

`layers` is bottom to top and paper is below all of it. `inkIndex` is
the ink's position in that stack, `0...layers.count`. A new page has no
layers and `inkIndex` 0. An import inserts at `inkIndex` and increments
it, so ink stays above everything imported; moving a layer above the ink
is a later intention that decrements it. `hasInk` records whether the
page has ever committed ink and never returns to false: once true, every
save of that page writes the container, an empty drawing included, and
the container is deleted only with the page. `hasInk` true and no
container means `unreadable(.missingInk)`; `hasInk` false and a valid
container present means the container is the ink (a crash between two
publish phases), the page is marked dirty, and the next save records
true. A page file naming a layer file that is not there refuses that
layer. The container is its own integrity authority.

## ink/<PageID>.tnink

Sixty-four byte header, little-endian: magic `TNIK`; `UInt32` container
version 1; 16 bytes notebook ID; 16 bytes page ID; `UInt64` payload
length; `UInt32` CRC32 of the payload; twelve reserved zero bytes. Then
the PKDrawing archive. Any header disagreement or CRC mismatch refuses
the page. Ink outside the page rectangle is preserved, never clipped.

## layers/<LayerID>.json

```json
{ "layerID": "UUID", "kind": "image", "transform": [a, b, c, d, tx, ty],
  "image": { "asset": "UUID.heic",
             "naturalSize": { "width": 3024, "height": 4032 } } }

{ "layerID": "UUID", "kind": "pdf", "transform": [...],
  "pdf": { "asset": "UUID.pdf", "sourcePageIndex": 0,
           "sourceExtent": { "x": 0, "y": 0, "width": 612, "height": 792,
                             "rotation": 0 } } }

{ "layerID": "UUID", "kind": "link", "transform": [1, 0, 0, 1, 0, 0],
  "link": { "rect": { "x": 40, "y": 40, "width": 160, "height": 44 },
            "style": "button",
            "target": { "scope": "internal", "pageID": "UUID" } } }
```

The payload object is keyed by the kind name so an unknown kind is seen
before its payload is parsed. `transform` maps the source unit square
into page space for image and pdf; it must be finite, `|det| > 1e-9`,
and `|tx|, |ty| <= 10 × maxPageEdge`. For link it must be identity; the
rect is page space. `rotation` is degrees, one of 0, 90, 180, 270. The
render path re-derives `sourceExtent` and refuses the layer on
disagreement. `asset` is the file name and the only statement of the
asset's format. Assets are bounded at 64 MB and 16384 px on an edge;
images are normalized to HEIC at import, PDFs are stored as received.

External links to the containing notebook are never minted by the UI.

## One save

```
plan      validate intent · free-space preflight (volumeAvailableCapacity
          ForImportantUsage against the batch's byte size) · per-page plan ·
          no I/O
stage     per page: ink → layers → page file, each to a temp path with
          F_BARRIERFSYNC before close; a page that fails to stage is dropped
          whole and recorded as refused (assets were published at import)
publish 1 rename every staged ink and layer file; fsync ink/ and layers/
publish 2 rename every staged page file; fsync pages/
publish 3 if the index changed: content = intent ∩ present (withheld if
          empty); stage; rename; fsync the package root
report    per-page refusals to the caller; nothing is deleted
```

## Open

Read and validate `notebook.json`. Stat every page file; a missing one is
`unreadable(.missingPageFile)` for that page. Read nothing else, delete
nothing. Schedule `compact()` at idle (D11).

## Proof

Per JSON type: the exact key set, and one refusal test per deleted key
naming that key. The file primitive is a seam with three fault modes:
fail call N, truncate to k bytes, discard the payload after a successful
rename. The write-order test sweeps N through every write of a save
under each mode and asserts that `load()` never opens a notebook whose
index reaches content that is not there. Round trips compare decoded
values, never bytes.

---

# Part 3: layers, assets, and repair

Import decodes and validates off-main, writes the asset (its own atomic
publish) before the layer joins the page's list, and records
`naturalSize` or `sourceExtent` from the same call the renderer uses.

A transform commit returns `TransformOutcome`: accepted, or refused with
a reason. Refused means the runtime restores its gesture-local prior
transform, which dies with the gesture and is never a second authority.

Delete removes the layer from the list; compact removes the file and,
if no page reaches it, the asset.

Repair. A page carrying a refused layer is a placeholder and cannot be
edited. The one exit is the intention "remove this layer": the page file
is rewritten without it, the layer file is retained until compact.

---

# Part 4: the notebook

`Notebook` is `@MainActor @Observable`. Page states, ink, composites, and
history are `@ObservationIgnored`. The observed facts are stored mirrors
the notebook writes: `pageCount`, `currentPageID`, `dirtyPageCount`,
`lastSaveError`. A computed property over ignored storage would never
invalidate a view.

`PageState`: `unloaded(PageDescriptor)`, `loading(generation)`,
`ready(PageContent)`, `unreadable([PageFault])`. `PageContent` holds the
newest ink, the layer list, the composite, `editSeq`, `savedSeq`, the
history ring.

Dirty is `editSeq > savedSeq` per page, and `indexSeq > savedIndexSeq`
for the index. A page turn dirties nothing.

Generations change only when a page's inputs change, never because it
was asked for again. In-flight decodes are cancelled when their page
leaves the wanted set, and a result whose generation is stale is dropped
on arrival.

The save engine: capture synchronously (values and sequence numbers);
serialize detached at utility priority; write on the store actor; on
success set `savedSeq` per written page; on refusal keep the page dirty;
on I/O failure keep the serialized bytes (up to 64 MB across the batch;
past that the bytes are dropped and re-serialized on retry) and retry with
exponential backoff capped at five seconds; re-arm only at the pass's
exit. The forced backgrounding pass runs no compact. The idle
debounce is four times the last serialize duration, clamped to
`[0.5 s, 2 s]`, with a five-second ceiling from first dirty. A forced
pass runs on backgrounding, tab switch, and close.

Close: the tab drops the binding and the runtime first (retiring every
page, deferred retires included), then the notebook runs the final pass
and releases the checkout. No intention path exists during close because
nothing holds the notebook but the tab.

If spike zero shows reading `canvasView.drawing` at stroke end is too
slow, the fallback is a report on a short coalescing timer that still
carries the value. Custody stays with the notebook either way; the old
"changed, come ask" shape is not the fallback.

An ink report for a page not in `ready` is a programmer error and traps.

---

# Part 5: the seam, concretely

```swift
@MainActor package protocol CanvasSurface: AnyObject {
    func setPages(_ pages: [PageDescriptor], seq: StructureSeq)
    func installContent(_ snapshot: PageSnapshot)          // placeholder only
    func restoreInk(on page: PageID, _ ink: PKDrawing, seq: InkSeq)
    func apply(_ environment: CanvasEnvironment)
    func scroll(to page: PageID)
    func retire(_ page: PageID) -> RetireOutcome            // .retired | .deferred
}

@MainActor package protocol CanvasReporting: AnyObject {
    func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?)
    func layerTransformed(on page: PageID, layer: LayerID,
                          to transform: PageSpaceTransform) -> TransformOutcome
    func pageBecameCurrent(_ page: PageID)
    func windowChanged(to pages: [PageID])                  // complete set
    func detailNeeded(for page: PageID, scale: CGFloat)
    func endBoundaryReached(seq: ReportSeq)                 // setPages answers it
    func linkActivated(on page: PageID, layer: LayerID)
    func retired(_ page: PageID, finalInk: PKDrawing?)       // nil: was a placeholder
}
```

`endBoundaryReached` returns nothing: the notebook appends and the
`setPages` push arrives at the end of the turn; until then the runtime
rubber-bands, and if no push arrives it settles back.

Types. `TNModel` on disk is the type appendix; the ones the seam adds:
`PageDescriptor { id, geometry, paper }`. `PageSnapshot { id, ink:
PKDrawing?, composite: Composite?, layers: [Layer], isEditable, inkSeq }`
where `Composite` wraps an immutable `CGImage`. `CanvasEnvironment { tool:
PKTool }`. `StructureSeq`, `InkSeq`, `ReportSeq` are monotonic `UInt64`
wrappers. `TransformOutcome` is `.accepted` or `.refused(reason)`.
`RetireOutcome` is `.retired` or `.deferred`. `PageBytes { inkArchive:
Data?, layers: [Result<Layer, LayerFault>] }` is what `TNFormat` returns
and what `TNNotebook` decodes off-main.

---

# Part 6: the library

`Library` (main actor) holds the ledger, the in-memory tree, and the
identity index. `LibraryStore` (actor) does every byte of I/O.

Checkout reserves synchronously, then opens asynchronously, and returns
`.opened(Notebook)`, `.alreadyOpen(NotebookID)`, or `.failed(reason)`. A
failed open releases the reservation. The trap is for re-entrancy only.

The identity index maps `notebookID` to path, is built off-main at
library open, updated by every mutation, and flags trashed notebooks. A
link activated before it is ready refuses with "still loading". A link
to a trashed notebook offers "restore and open".

Trash: `Trash/<NotebookID or FolderID>/<original name>` plus
`origin.json { formatVersion, originFolderID, originPathHint,
originName, deletedAt }`. Recovery restores the original name, suffixes
only on a real collision, and falls back to the root when the origin
folder is gone. Duplicating or exporting a checked-out notebook refuses.
Staging for duplicate lives outside the scanned tree.

Sidecars: `library.json` and `.folder.json` are durable and versioned;
`favorites.json` is derived and rebuilt on mismatch.

`modifiedAt` for listing is the newest of the package's `notebook.json`,
`pages/`, `ink/`, and `layers/` mtimes; it works because every publish is
a rename into one of those directories, and compact can bump it.
Thumbnails live in the caches directory, outside the package, and key on
`(notebookID, firstPageID, paper, geometry, and the size and mtime of the
page file, the container, and each layer file)`: stats, no reads.

---

# Part 7: what the user sees

| Condition | Scope | Surface |
|---|---|---|
| Index refuses | notebook | "Can't open" with the reason; package untouched |
| Page file missing | page | placeholder, non-editable |
| Ink container refuses | page | placeholder "ink can't be read" |
| Paper kind unknown | page | placeholder naming the paper |
| Layer refused | page | placeholder naming the layer; "remove this layer" offered |
| Transform refused | gesture | layer snaps back; reason logged |
| Save I/O failure | pages | persistent banner; retry with backoff; close offers "discard unsaved and close" |
| Free-space preflight refuses | save | banner "Not enough space to save"; nothing written; pages stay dirty |
| Append refused (free space) | intention | rubber-band settles back; banner "Not enough space for a new page" |
| Lease expired with writes outstanding | notebook | logged; the format is resumable, the next open recovers |
| Link target missing | intention | "The linked page is no longer in your library" |
| Link target trashed | intention | "Restore and open" |
| Identity index not ready | intention | "Still loading your library" |
| Library mutation on open notebook | intention | "Close *name* first" |
| Double-tap open | intention | focuses the existing tab |
| Re-entrant checkout, unknown identity, ink on non-ready page, retire without report | programmer | `TNPrecondition` |

---

# Part 8: modules

```
TNCore     logging, TNPrecondition
TNModel    values: identities, geometry, paper, layers, descriptors,
           snapshots, reports (imports PencilKit and CoreGraphics for
           value types; no UIKit, no I/O)
TNFormat   package layout, codecs, container, planner, PackageStore
           (actor), the file-primitive seam
TNNotebook Notebook, PageState, save engine, history
TNRender   composites, paper, thumbnails (actor)
TNLibrary  Library, LibraryStore, identity index, trash
TNCanvas   the driven runtime; depends on TNModel only
TNEditor   EditorBinding, EditorViewModel; the only target that names
           both TNCanvas and TNNotebook; vends the canvas host as an
           opaque UIViewController
App        SwiftUI, Workspace, the representable; cannot name TNCanvas
```

Edges: `TNCore ← TNModel ← {TNFormat, TNCanvas, TNRender}`;
`TNFormat ← TNNotebook ← TNEditor`; `TNRender ← TNNotebook`;
`TNFormat ← TNLibrary`; `App ← {TNEditor, TNLibrary, TNModel}`.
`TNCanvas` never names `TNFormat`; the app never names `TNCanvas`. Both
are compile errors, not review notes.

Tests: `TNTests`, a unit-test bundle with no host app, embedding the
`TN*` frameworks. Fault injection lives in `TNFormat` behind the
file-primitive seam under `#if DEBUG`.

---

# Part 9: what Contract.md's rules become

| Contract.md rule | v2 |
|---|---|
| Every rule written by a human | kept; this file is a proposal |
| Invalid states fail loud | kept; traps via `TNPrecondition` |
| One writer | kept, moved into the checkout ledger |
| SwiftUI never mirrors PKDrawing/pan/zoom | kept |
| Store receives immutable values | kept |
| Page controller never touches files | kept; runtime depends on TNModel only |
| Custody: live controller else session value | replaced by custody-by-value |
| Recreating a view never recreates a canvas | kept; the tab owns the runtime |
| Page controller blind to page numbers | kept |
| Lifecycle owns the lease | moved to Workspace |
| Ink states clean/live/held/saving/loading/unreadable | deleted; dirty is seq-derived |
| Durable types import Foundation only | replaced: TNModel imports PencilKit and CoreGraphics for values |
| Ink is a layer, exactly one, last, identity | deleted (D3) |
| Unknown kind refuses the layer | kept |
| Save writes only what changed | kept; index only when it changed |
| Atomic per file, none across files | replaced by stage/barrier/publish with per-page atomicity |
| Dangling ref fatal, orphan not | kept, page-scoped |
| Page files first, then index | kept and strengthened |
| At least one page, unique IDs, current page valid | kept; current page moved to view.json |
| Geometry canonical, portrait | replaced by per-page bounded geometry |
| drawingChanged carries no payload | reversed: reports carry the ink |
| drawing read after debounce, never in callback | reversed; spike zero measures the cost |
| Capture is total; captured pages marked saving | kept as seq capture |
| Serialize duration sets the debounce | kept |
| Retry backoff capped at five seconds, never encode twice | kept |
| Page does not grow; geometry fixed | kept |
| One page per swipe, no resting position between | kept |
| Turn rule at fit-width or page edge | kept |
| Appending is navigation, not editing | kept |
| Synchronous handover before release | replaced by the final report |
| Background flush, lease until no write outstanding | kept, Workspace-owned, all open notebooks |
| Foreground never replaces newer ink with older load | kept by generations |
| Installing ink is never reported as an edit | kept, by sequence |
| Unreadable page refused, never blank | kept |
| PencilKit owns undo | reversed (D1) |
| One PKCanvasView construction site | one per canvas module during coexistence, one after 6c |
| Live canvas count bounded | kept |
| Held bytes pruned every turn | kept; prune on release |
| No observation/task/hop/file/encode per input sample | kept |
| Caches declare owner, bound, evictor | kept |
| No placeholder fields | kept; every field has a shipped reader |
| No durable derived artifact | kept, with one stated exception: `hasInk` restates which of two histories produced the state, which the files alone cannot say; the CRC is inside the ink container, not a table |

---

# Part 10: staging

Stage 0. Extend `ContractStructureTests` (module directories, UI
framework policy, I/O allowlist including `open(`, `fcntl`, `fsync`,
`rename`) to the `TN*` modules. Add `TNTests`. Commit.

Stage 1. `TNCore`, `TNModel`, `TNFormat`. Key-set pins, delete-each-key
refusals, the write-order sweep under three fault modes across the three
publish phases, container round trip, compact's conservatism.

Stage 2. `TNNotebook` headless: draw-during-close lands; a refused new
page is absent from the committed index and stays dirty; stale
generations drop; undo restores without echo; forced pass on close.

Stage 3. `TNLibrary`: ledger refusals, double-open focuses, trash round
trip restores the name, duplicate re-mints, identity index rebuilds.

Stage 4. `TNCanvas`: slot layout, window derivation, final-report trap,
the undo-manager filter. Lands immediately before stage 6a.

Stage 5. `TNRender` as an actor.

Stage 6a. Single-notebook app swap through `TNEditor`. 6b. `Workspace`
and tabs. 6c. Delete `Tuber*`. 6d. Link UI.

Device spikes Phillip runs before trusting stages 4 to 6: spike zero,
the cost of reading `canvasView.drawing` at stroke end at 20k strokes;
D7, the zoom-detail push at 120 Hz on a `maxPageEdge` page; D1, the
undo-manager filter and the system gestures. Stages 1 to 3 do not depend
on their outcomes: if spike zero fails, the report reads the value at
debounce instead, and nothing in the format or the notebook changes.
