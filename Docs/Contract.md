# The contract

The rules in force for this project. This file carries no history and keeps nothing for reference. Where the code disagrees with this file, the code is wrong.

**Every rule here is written by a human.** No agent authors a rule, and no agent's output becomes a rule by having been committed. 

**Invalid states fail loud.** You are a bull in a china shop.  When this contract says something must NOT happen, fail as loudly as humanly possible. Nothing is clamped, adapted, 'corrected', or replaced with a default unless I say so.

**With permission, move fast, and burn things down**
This is a pre-pre-pre release test about finding good fundementals. We are perfectly willing to burn literally anything given good rationale. Never implement legacy support or backwards shims unless I say to.

Cite sections by name, not number; this document is not immutable.

---

## Owners

Concrete owners, one direction of durable flow:

```text
EditorLifecycle -- scene transitions --.
                                       v
SwiftUI root ------- intentions --> EditorSession
                                  |       ^
                                  |       | drawing changed
                                  v       |
                          PagedCanvasController
                                  |  (one live canvas per visible page)
                                  v
                          PageCanvasController
                                  |
                                  | immutable drawing bytes
                                  v
                           DocumentStore.save
                                  |
                                  v
                        one file per changed page
```

| State | Sole writer | Frequency | Lifetime |
|---|---|---|---|
| Live `PKDrawing` | `PKCanvasView` inside `PageCanvasController` | Pencil/input | canvas session |
| Pan, zoom, gestures, page projection | `PageCanvasController` | frame/input | canvas session |
| Which pages are live, the paging viewport, the active tool | `PagedCanvasController` | user action | app session |
| Page order, page identity, current page index | `EditorSession` | user action | app session |
| Dirty page set, `saveInFlight`, debounce | `EditorSession` | interaction | app session |
| Held page bytes and their in-flight fetches | `EditorSession` | turn/save | app session |
| Saved document | `DocumentStore` | autosave | across launches |
| SwiftUI navigation and visible controls | SwiftUI root | user action | view session |
| Background-execution lease | `EditorLifecycle` | scene transition | scene session |

Golden rules:

1. Each value has one writer.
2. SwiftUI never mirrors `PKDrawing`, pan, zoom, or Pencil samples.
3. `DocumentStore` receives immutable values and never reaches into a canvas.
4. `PageCanvasController` never reads or writes files.
5. `EditorSession` coordinates owners and keeps no second mutable drawing. A page with a live canvas has exactly one authority, that canvas. A page without one — retired from the live window, not yet saved — may be held as an immutable value, which is custody rather than a second copy.
6. Recreating a SwiftUI view never recreates a live canvas controller or its undo manager.
7. A `PageCanvasController` owns exactly one page's live drawing and renders the geometry it is given. It is blind to page numbers and turns: it is told, and never asks.
8. `EditorLifecycle` owns the UIKit background-execution lease and nothing else.

`dirty` is the set of page IDs whose live drawing differs from the last successful save. `saveInFlight` means one call to `DocumentStore.save` has started and has not returned or thrown. Both are private session state.

Held page bytes are the session's copy of what is on disk for the pages it may shortly need, keyed by page ID because an index means a different page once the list changes. They are the cache *Performance* requires to state a bound, and the bound is the live window plus the pages fetched ahead of it, plus any page whose ink is not yet saved. A page's authority is its live canvas whenever it has one; a held entry is never a second drawing.

Durable value types import Foundation only. UIKit and PencilKit may be imported only by the owners of frame-frequency canvas state and by the owner of the background-execution lease.

## Durable form

A document is a directory:

```text
JustACanvas.tubernotes/
  document.plist          the index
  pages/<pageID>.plist    one file per page
```

`document.plist` holds the format version, `documentID`, page geometry, an ordered list of page IDs, and the current page index.

A page file holds its own `pageID` and its opaque drawing bytes

- **A save writes only what changed.** One changed page writes one page file, and the index is rewritten only if page order or the current index changed. Rewriting an unchanged page file is a defect rather than an inefficiency: it is the whole-document rewrite this format exists to prevent.
- **Every individual write is atomic**, by temporary file and rename. There is no atomicity across files, and the format is built so none is needed.
- **A dangling page ref is fatal; an orphan is not.** A page file no page ID references is ignored.
- **Write order is load-bearing: page files first, then the index**, so an interrupted save leaves an orphan and never a dangling ref.
- **A document always has at least one page.**
- **Page IDs are unique and stable within a document** 
- **The current page index must address an existing page.**

Geometry fields are finite page points greater than zero, with `pageWidth < pageHeight`, and equal the application's canonical geometry. 

`nil` from `load` means no document exists; an invalid file is a failure, never `nil`. 




## Saving

PencilKit owns live drawing and display. Its change notification invokes one coarse `drawingChanged` callback carrying no Pencil/drawing payload.

On `drawingChanged`: mark that page dirty, reset the debounce unless a save is already in flight, and start `saveIfNeeded` when the timer fires.

`saveIfNeeded` is serialized:

```text
guard dirty is non-empty && !saveInFlight
saveInFlight = true
capture every dirty page: a live page yields its drawing, a page that has
  left the live window yields the value it handed over as it retired
capture is total — a dirty page yielding neither is a violation, not an omission
clear the dirty set only for the pages actually captured
create drawingData outside the PencilKit callback
record the serialize duration; it sets the next debounce interval
await DocumentStore.save(page files, then the index if it changed)
saveInFlight = false
on success, clear the retry backoff
on failure, restore those page IDs to dirty, report the error,
  and reschedule after the backoff
if still dirty, arm a fresh debounce rather than serializing again immediately
```

Work arriving during a save receives a fresh debounce after that save returns.

On failure, the first retry waits the ordinary debounce and further tries back off exponentially, capping at five seconds. There is never more than one capture/save operation in flight — a page leaving the live window hands over a value rather than starting a second capture — so stale generations cannot exist, and no page carries a version number.

`canvasView.drawing` is read on the main actor after the debounce fires, never inside PencilKit's change callback. If drawing-data creation must run on main and causes an observable hitch, resolve that measured bottleneck; do not invent an unsupported cross-actor transfer.

Durability is strict:

- after `save` returns successfully, the next successful `load` reproduces exactly those pages and drawings;
- a save that throws is not acknowledged, and its pages stay dirty; and
- if the process ends during a save that never returned, the next launch recovers complete files only — never a partial one.

## Geometry and coordinates

The page does not grow. `pageWidth` and `pageHeight` are fixed at creation. No existing owner mutates geometry: `EditorSession` holds no height state, and `PageCanvasController` writes `contentSize` exactly once, at construction. The zoom floor derives from the fixed page, so the viewport cannot drift.

More writing surface comes from turning to the next page. Supporting flexible geometry (landscape, A4, an imported source) requires a `CONTRACT:` amendment defining per-document geometry.

| Space | Owner | Durable |
|---|---|---:|
| Page space | the document's width and height | yes |
| Canvas space | `PageCanvasController` | no |
| View space | UIKit view hierarchy | no |

Page-space origin is top-left; positive x points right, positive y points down; bounds are `[0, pageWidth] × [0, pageHeight]` in logical page points, independent of display scale.

Ink is authored in page space. The canvas controller alone converts between page, canvas, and view coordinates. Pan, zoom, safe areas, and screen frames are never persisted.

Rotation, crop, PDF source coordinates, normalized coordinates, and annotation anchors do not exist.

## Navigation

Pages are ordered and turned horizontally, one page per swipe, snapping to a page boundary. There is no resting position between two pages.

`PKCanvasView` is itself a `UIScrollView` and owns pinch-zoom, so a paging scroll view and the canvas contend for a horizontal drag. The rule: a turn is available at fit-width scale, or once panning reaches the page's own horizontal edge. Zoomed in and away from an edge, a horizontal drag pans within the page and DOES NOT turn.

A nested scroll view chains to its parent once, and only once, it can scroll no further.

Swiping past the last page yields a blank writable page immediately; a turn that lands on nothing is not a page turn. Whether that page becomes durable is decided by *Empty trailing pages*.

Turning and appending are navigation, not editing: neither is undoable, and PencilKit's undo manager never learns of them. An unwritten appended page is not durable, so no ink can be lost by the absence of undo.


A page leaving the live window hands its ink to the session **before** its controller is released. Releasing first would silently discard edits on a page the user merely scrolled away from.

## Lifecycle

On backgrounding, the editor cancels the debounce and makes one best-effort save pass in the execution time iPadOS provides. It is a single pass, and does not run the retry backoff. Only a successfully returned `save` clears dirty state. The lease is held until no write is outstanding, which is not the same as until the flush call returns: a flush that finds another save already writing waits for it rather than hand the lease back underneath it. Suspension is not a crash, and the atomicity in *Durable form* does not cover one — an interrupted process loses a write that never completed, not one that tore.

Foregrounding reuses retained live state and never replaces newer live ink with an older load result.

The document index loads once, when the editor session is created, before any page is built. Ink loads per page, whenever a page needs it: the live window is bounded and pages leave it, so a page's ink is read again when it returns. For each page the order is fixed and happens once — its ink is installed, and only then does that page's canvas become editable. A canvas that has become editable is never installed into again, and installing ink is never reported as an edit.

On first launch, `load` returns `nil`; the app generates the IDs and the canonical geometry, constructs an empty drawing, and saves.

## Undo

PencilKit and its live undo manager own stroke undo and redo, and system-owned UI may invoke that manager directly. There is no interception and no semantic undo domain.

If app-authored undo controls are added later, each invokes the same live undo manager exactly once, and the resulting change follows the ordinary save path. Saving never clears undo.

## Performance

Hard invariants:

- `PKCanvasView` is constructed at exactly one code site.
- The live canvas count is bounded by a small constant and never grows with page count, however far the user pages. A canvas retired from the visible window is released, not retained against a future return.
- Held page bytes are pruned on every turn to the live window, the pages fetched ahead of it, and any page whose ink is not yet saved. Nothing else is retained: bytes that accumulate with pages visited are the same failure as a canvas count that does.
- A canvas is replaced or retired only by the session that owns it.
- Pencil samples, pan ticks, and zoom ticks stay inside the canvas runtime.
- No SwiftUI observation, task creation, actor hop, file access, or property-list encoding occurs per input sample.
- File encoding and disk I/O never run on main.

In-memory caching is ordinary runtime state, not a forbidden pattern. A cache
states its owner, its bound, and what evicts it, at its declaration. One that
cannot state all three is forbidden.

## Forbidden patterns

- undefined placeholder fields for future features;
- a durable derived artifact — a thumbnail, a checksum table, an asset
  manifest. Nothing written to disk restates what the ink already says.


