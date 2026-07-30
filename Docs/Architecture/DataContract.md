# TuberNotes data and ownership contract

Status: normative for Just a Canvas and Pages and Turning
Applies from: first line of application code
Change policy: a change to an owner, durable field, coordinate rule, or save
meaning requires a `CONTRACT:` commit and a `Docs/Plan/PLAN.md` entry.

## 1. Purpose

This contract defines the smallest trustworthy one-page drawing system. It
exists to prevent shared mutable state, work on the Pencil path, ambiguous
coordinates, and false claims that ink was saved.

There are five concrete owners and one direction of durable flow:

```text
EditorLifecycle -- scene transitions --.
                                       v
SwiftUI root ------- intentions --> EditorSession
                                  |       ^
                                  |       | drawing changed
                                  v       |
                           PageCanvasController
                                  |
                                  | immutable drawing bytes
                                  v
                           DocumentStore.save
                                  |
                                  v
                           one atomic file
```

This is an ownership diagram, not a request for Swift protocols, modules,
reducers, event buses, repositories, or dependency injection.

## 2. Owners

| State | Sole writer | Frequency | Lifetime |
|---|---|---|---|
| Live `PKDrawing` | `PKCanvasView` inside `PageCanvasController` | Pencil/input | canvas session |
| Pan, zoom, gestures, page projection | `PageCanvasController` | frame/input | canvas session |
| Page order, page identity, current page index | `EditorSession` | user action | app session |
| Active tool, `dirty` pages, `saveInFlight`, debounce | `EditorSession` | interaction | app session |
| Saved canvas file | `DocumentStore` | autosave | across launches |
| SwiftUI navigation and visible controls | SwiftUI root | user action | view session |
| Background-execution lease | `EditorLifecycle` | scene transition | scene session |

Rules:

1. A value has one writer.
2. SwiftUI never mirrors `PKDrawing`, pan, zoom, or Pencil samples.
3. `DocumentStore` never reaches into the canvas. It receives immutable values.
4. `PageCanvasController` never reads or writes files and never chooses save
   policy.
5. `EditorSession` coordinates owners but does not keep a second mutable
   drawing.
6. Recreating a SwiftUI view must not recreate the live canvas controller.
7. `PageCanvasController` renders the fixed page geometry defined by
   `PageGeometry`. It never chooses or mutates page geometry.
7a. `PageCanvasController` owns exactly one page's live drawing and does not
   know its own index, its neighbours, or how many pages exist. Turning a page
   is `EditorSession` deciding which page a recycled canvas now shows; the
   canvas is told, and never asks.
7b. Page turning is navigation, not editing. It is not undoable, and PencilKit's
   undo manager never learns about it. Appending a page is likewise not
   undoable — an unwritten appended page is not durable (see §4a), so no ink can
   be lost by the absence of undo.
8. `EditorLifecycle` owns the UIKit background-execution lease and nothing else.
   It holds no durable state, chooses no save policy, and may only ask
   `EditorSession` to flush or resume. Expiring the lease ends the lease, not
   the save.

`dirty` means the live drawing differs from the last successful save.
`saveInFlight` means one call to `DocumentStore.save` has started and has not
returned or thrown. These two booleans are private session state. They are not
persisted and are not product concepts.

## 3. Concrete implementation rule

Just a Canvas uses concrete types and direct calls. It requires no custom Swift
protocols. A one-owner closure or ordinary delegate callback may report
`drawingChanged` from the canvas to the editor.

Introduce a protocol, actor beyond the store, helper object, separate module,
or generic service container only when a second implementation, actual
isolation boundary, or otherwise impossible test requires it.

The durable value types import Foundation only. They do not import SwiftUI,
UIKit, or PencilKit. `PageCanvasController` is the only owner that imports and
operates the live PencilKit view. `EditorLifecycle` may import UIKit solely to
take and release the background-execution lease; it never touches canvas state.
The set of files permitted to import UIKit or PencilKit is enumerated in
`Tools/lib.sh`, and adding one is a contract decision.

## 4. Durable file

Just a Canvas persists one binary property-list file. It has no package,
manifest, background asset, drawing reference, checksum table, thumbnail, or
cache.

This section describes **format version 1**. From Pages and Turning a document
is a directory of many pages; §4a is normative for that form and supersedes the
single-file and no-package rules here. Version 1 remains normative as the format
that §4a migrates from, and files in it still exist.

Its complete logical contents are:

```swift
struct CanvasFile: Codable, Sendable {
    let formatVersion: UInt32
    let documentID: UUID
    let pageID: UUID
    let pageWidth: Double
    let pageHeight: Double
    let drawingData: Data
}
```

The field contract is exact:

- `formatVersion` is `1` for this milestone. Any other value is unsupported.
- IDs are UUIDs generated once at first creation, encoded by Foundation's
  property-list encoder, and preserved by every save.
- Width and height are finite logical page points greater than zero.
- `pageWidth` and `pageHeight` are both immutable for the life of a document,
  and `pageWidth < pageHeight` always holds. Both equal the application's
  canonical page geometry; any other value is a corrupt or foreign file and is
  rejected by `load` and by `save` rather than adapted.
- `drawingData` is the opaque result used to reconstruct `PKDrawing`.
- The blank white background is inherent to format version 1 and is not stored.

`DocumentStore` exposes one concrete async load method and one save method. The
exact signatures may follow Swift naming conventions, but their meanings are:

```swift
func load() async throws -> CanvasFile?
func save(_ file: CanvasFile) async throws
```

`nil` from `load` means no file exists. A decode error, unsupported version, or
invalid geometry throws and must not create or overwrite anything.

`save` encodes a complete `CanvasFile` and atomically replaces the one prior
file using Foundation file APIs. Encoding and file I/O do not run on the main
actor. The method returns only after atomic replacement succeeds.

The durability meaning is strict:

- after `save` returns successfully, the next successful `load` must reproduce
  exactly that file and drawing;
- if a save throws, it is not acknowledged and the editor remains dirty; and
- if the process ends during a save that never returned, the next launch may
  recover either the prior or new complete file, never a partial file.

There is no durable revision counter, document command, document event, writer
role, in-memory reducer, or second authoritative document copy.

## 4a. Durable form for many pages

Normative from Pages and Turning; supersedes §4's single-file and
"no package, no manifest" rules. §4 remains the description of the format
version 1 file that this one migrates from.

A document is a **directory**, not a file:

```text
JustACanvas.tubernotes/
  document.plist          the index
  pages/<pageID>.plist    one file per page
```

`document.plist` holds `formatVersion` (2), `documentID`, the page geometry, the
ordered list of page IDs, and the current page index. It holds no ink. A page
file holds its own `pageID` and its opaque drawing bytes, and nothing the index
also holds — a value stored twice is a value that can disagree with itself.

The rules that make this worth the added complexity:

- **A save writes only what changed.** Saving a document where one page changed
  writes that one page file, and rewrites the index only if the page order or
  current index changed. Rewriting an unchanged page file is a defect, not an
  inefficiency: it is the exact failure the *scale with visible or changed
  content* rule exists to prevent.
- **Every individual write is still atomic**, by the same temporary-file-and-
  rename mechanism §4 uses. There is no atomicity *across* files, and the format
  is designed so that none is needed — see the ordering rule.
- **Order of writes is load-bearing.** Page files are written first, then the
  index. A crash between them leaves an unreferenced page file, which is inert
  and ignored on load. The reverse order would leave the index naming a page
  file that does not exist, which is an unopenable document.
- **A dangling reference is fatal, an orphan is not.** If the index names a page
  file that is missing or unreadable, `load` throws and modifies nothing. A page
  file that no page ID references is ignored, and may be deleted by a later save.
- **The page list is never empty.** A document always has at least one page.
- **Page IDs are unique within a document** and stable for the life of a page.
- **The current page index must address an existing page.** An out-of-range
  index is invalid and is rejected rather than clamped, for the same reason an
  unreachable page height was: silently correcting a value hides whatever wrote
  it.

### Migration from format version 1

A version 1 file is a single page. It migrates to a one-page version 2 document
preserving `documentID`, `pageID`, and the drawing bytes exactly, at index 0.

This migration is real and owed — unlike the page-geometry change, version 1
files exist on Phillip's iPad. It runs once, on load, and the version 1 file is
left on disk untouched until the version 2 document has been written
successfully. Deleting it before that would turn an interrupted migration into
data loss.

Format version 2 does not accept a grown page height. §5a's rejection stands: a
version 1 file carrying one fails to load, and therefore fails to migrate.

### Empty trailing pages

A page appended by swiping past the end is durable only once it takes ink. At
most one never-written trailing page may exist in memory, and it is dropped at
save time. This is the only permitted divergence between the pages on screen and
the pages in the document.

## 5. Drawing-to-save flow

PencilKit owns live drawing and display. Its drawing-change notification invokes
one coarse `drawingChanged` callback. It does not report Pencil samples, an
interaction-ended event, a generation number, or a drawing payload.

When the editor receives `drawingChanged`:

1. Set `dirty = true`.
2. Reset the debounce timer unless a save is already in flight.
3. When the timer fires, start `saveIfNeeded`.

The debounce interval is `max(500 ms, 4 × the most recent serialize duration)`.
500 ms is a hard floor and the interval never goes below it, so a small document
behaves exactly as a flat 500 ms debounce did. A large one backs off in
proportion to what writing it actually costs, instead of chaining whole-document
serializations back to back for as long as the user keeps writing.

This exists because serialize cost scales with total ink and not with changed
ink — the format's defect, and the thing §9 measures. Adaptive debounce is the
mitigation available without changing the format: it widens the window in which
unwritten ink exists and buys a cheaper duty cycle with it. It is not a fix and
it does not retire the §9 disqualification test.

The interval is driven by measured duration and deliberately not by serialized
size, which was proposed and rejected. Bytes are a property of what the document
contains rather than of what the edit cost: once a milestone adds placed images
or lasso operations, a document holding one large image would sit permanently at
the ceiling and throttle ink saves it did not cause, and a single structural edit
would overreact to a transient spike. Duration at least tracks work actually
performed. Neither signal can separate "a little changed" from "the document is
large", because in a whole-file format every save costs the whole document; that
is the defect itself, and no control signal fixes it. Bounding the serialized
unit does.

`saveIfNeeded` is serialized:

```text
guard dirty && !saveInFlight
dirty = false
saveInFlight = true
capture the current drawing value and page height as one generation
create drawingData outside the PencilKit callback
record the serialize duration; it sets the next debounce interval
await DocumentStore.save(the complete CanvasFile)
saveInFlight = false
on success, clear the retry backoff
on failure, dirty = true, report the error, reschedule after the backoff
if dirty, arm a fresh debounce rather than serializing again immediately
```

Work that arrives during a save receives a fresh debounce after that save
returns. The editor does not re-enter serialization the instant a save
completes; that is the back-to-back case the adaptive interval exists to avoid.

If capture, encoding, or save fails, set `dirty = true`, clear `saveInFlight`,
report the error, and reschedule the save automatically. The first retry waits
the ordinary debounce interval, each further consecutive failure doubles the
wait, and the wait is capped at five seconds; a successful save resets the
backoff. The ceiling is deliberately short: the wait is time the document
spends knowingly unsaved, so a long ceiling buys nothing and only delays
recovery once the cause clears. Recovery does not depend on the user drawing
again or
finding a Retry control — a transient store failure that repairs itself must not
leave a document indefinitely unsaved. The error stays visible while dirty,
because an unsaved document is not a silent condition. There is never more than
one capture/save operation in flight, so stale-save generations cannot exist.

Reading `canvasView.drawing` occurs on the main actor after the debounce fires,
not inside PencilKit's change callback. The implementation locates
`PKDrawing.dataRepresentation()` according to the supported SDK's concurrency
contract and measures it on the target device. File encoding and disk I/O are
always off-main. If drawing-data creation must run on main and causes an
observable hitch, stop and resolve that measured bottleneck; do not invent an
unsupported cross-actor transfer.

## 5a. Fixed page geometry

The page does not grow. Downward growth was specified, built, and removed: a
lengthening page is not the reading model the product wants, and room to keep
writing comes from turning to the next page rather than from extending this one.
This supersedes the 2026-07-29 amendment that overruled immutable geometry.

- `pageWidth` and `pageHeight` are both fixed at creation and never change.
- There is exactly one valid height, so height validation is an equality check.
  Heights that the extension-era build could produce — whole multiples of the
  page height — are now as invalid as any other value, and a file carrying one
  is rejected rather than adopted. Accepting it would place ink below a page
  edge that no longer exists, with no way to reach it.
- No owner mutates geometry. `EditorSession` holds no height state and
  `PageCanvasController` writes `contentSize` exactly once, at construction.
- The zoom floor derives from the fixed page, and the viewport cannot drift.

Geometry is the one thing a document can never renegotiate: a file whose width
or height differs from the application's canonical geometry is rejected, not
adapted. Supporting a second page geometry — landscape, A4, or imported source
geometry — requires a `CONTRACT:` amendment defining per-document geometry and
the migration for files written before it.

Reaching more writing surface is a navigation concern, not a geometry one, and
is specified by the pagination milestone rather than here.

## 6. Lifecycle and recovery

On backgrounding, the editor cancels the debounce and makes one best-effort save
pass using the execution time iPadOS provides. There is no promised flush
duration. Only a successfully returned `save` clears dirty state.

The background flush is deliberately a single pass and not a loop. It does not
chase ink that changed during it, and it does not run the §5 retry backoff
against a failing store. The iPadOS execution lease is finite and may be cut off
at any point, so spending it on repeated attempts buys nothing that the
foreground path does not already provide. Whatever remains dirty is saved after
foregrounding, on the ordinary debounced path.

If execution time expires before return, the save is unacknowledged. If the
process survives, the editor remains dirty and retries after foregrounding. If
the process ends, relaunch restores the last successfully returned save or, for
an interrupted atomic replacement, another complete file.

Foregrounding reuses the retained canvas and must not replace newer live ink
with an older load result. Loading happens once when creating the editor
session, before the canvas becomes editable.

On first launch, `load` returns `nil`; the app generates the two IDs and the
initial portrait geometry, constructs an empty `PKDrawing`, and saves the
initial file. On load failure, the app shows an error and leaves the source file
untouched.

## 7. Coordinates

Just a Canvas has three coordinate spaces:

| Space | Owner | Durable |
|---|---|---:|
| Page space | `CanvasFile` width and height | yes |
| Canvas space | `PageCanvasController` | no |
| View space | UIKit view hierarchy | no |

Page-space origin is top-left. Positive x points right and positive y points
down. Bounds are `[0, pageWidth] × [0, pageHeight]` in logical page points,
independent of display scale.

Ink is authored in page space. The canvas controller alone converts page,
canvas, and view coordinates. Pan, zoom, safe areas, and screen frames are not
persisted.

Rotation, crop, PDF source coordinates, normalized coordinates, multiple-page
layout, and annotation anchors do not exist in this milestone. Their contracts
must be written when a milestone introduces them.

## 8. Undo

PencilKit and its live undo manager own stroke undo and redo. System-owned UI
may invoke that undo manager directly. Just a Canvas does not intercept or
reroute system actions and has no semantic undo domain.

If app-authored undo or redo controls are later added, each invokes the same
live undo manager exactly once. The resulting PencilKit drawing-change
notification follows the ordinary autosave path. Saving never clears undo.

## 9. Performance

Hard implementation invariants:

- the application constructs `PKCanvasView` at exactly one code site. The
  process is *not* required to hold only one live canvas, and from Pages and
  Turning an editor session deliberately holds several: the visible page and its
  immediate neighbours. What is forbidden is an unbounded number — the live
  canvas count must be bounded by a small constant and must not grow with the
  page count, however far the user pages — and a canvas being replaced or
  retired by anything other than the session that owns it;
- a canvas retired from the visible window is released, not retained against a
  future return. Retention that grows with pages visited is the multi-page form
  of the monotonic-retention failure §9 already forbids;
- Pencil samples, pan ticks, and zoom ticks remain inside the canvas runtime;
- no SwiftUI observation publication, task creation, actor hop, file access, or
  property-list encoding occurs per input sample;
- file encoding and disk I/O never run on main;
- autosave has at most one capture/save operation in flight; and
- rebuilding SwiftUI views does not rebuild the canvas or its undo manager.

G4 records a baseline before setting numeric budgets. The baseline uses the
named physical iPad, normal build configuration, and one documented trace:

1. five minutes alternating ordinary handwriting, erasing, undo, and redo;
2. twenty full-range pinch-zoom and pan cycles;
3. ten background/foreground cycles;
4. force-quit and relaunch after a confirmed successful save;
5. build the worst case the format permits — the page grown to the maximum
   extents of §5a and densely inked over its whole length — then save it and
   relaunch onto it, so what follows measures a real large document and not a
   transient canvas; and
6. repeat step 1 on that document, continuously, without letting the editor go
   idle between saves.

Steps 1 through 4 measure the ordinary case. Steps 5 and 6 measure the case that
decides whether the format survives, and they are not optional. Save cost scales
with total ink rather than with the ink that changed, so a trace that never
reaches a large near-maximum document produces a clean baseline, budgets adopted
from a best case, and a cliff discovered later in front of the maintainer.

Record build, device and OS, trace duration, main-thread hangs, animation
hitches attributable to app work, memory at start/end/peak, restore duration,
and crashes.

Save cost is recorded as a distribution, never as a single best-case sample:
p50, p95, and maximum serialize duration, and the same three for total save
duration, over every save in the trace. Record with them the bytes written per
save, the cumulative bytes written across the whole trace, the stroke count and
page extents in force at each measurement, and the device thermal state sampled
throughout. Steps 1–4 and steps 5–6 are reported as separate distributions; one
pooled distribution would hide the thing being looked for.

The disqualification criteria are committed here, before any measurement exists,
so that the evidence decides rather than being argued with afterward. If the
measured p95 serialize duration or the cumulative trace write volume breaches
its threshold, the one-file whole-drawing format is disqualified as the notebook
substrate: the package writer of `DESPIKING_PROPOSAL.md` becomes the next line
of `Docs/Plan/PLAN.md` rather than a deferred someday, and no further feature is
built on `CanvasFile`.

The thresholds are proposals awaiting Phillip's approval, not established
facts and not results: p95 serialize duration ≤ 50 ms, and cumulative trace
write volume ≤ 250 MB. Nothing has been measured yet. Both numbers are guesses
offered as starting points for him to accept or revise before G4 runs, and
neither carries authority until he does. G4 proposes evidence-based budgets in a
`CONTRACT:` change before another feature is added; Phillip alone adopts them.

Mechanical acceptance requires no synchronous file I/O on main, a bounded live
canvas count independent of page count, no crash, no lost acknowledged save, and
no monotonic retention of canvas controllers or completed save tasks. Phillip alone judges Pencil feel.

## 10. Forbidden patterns

- a second mutable `PKDrawing`;
- a document command bus, reducer, event stream, repository protocol, or service
  container;
- SwiftUI observation of Pencil, pan, or zoom samples;
- file I/O or property-list encoding on main;
- one task per input callback;
- persisted viewport or screen coordinates;
- undefined placeholder fields for future features;
- a background, asset reference, package, cache, or manifest for the blank
  one-page file; and
- implementation copied from the pre-greenfield app.

## 11. Enforcement and future scope

The milestone requires tests for file encode/decode, invalid field rejection,
successful-save restoration, interrupted atomic replacement, page-space round
trip, and geometry validation — that the canonical geometry validates, and that
any other height is rejected, including the grown heights the extension-era
build could write.

Pages and Turning adds tests for page-order round trip, version 1 migration
fidelity, that a save touches only changed page files, that a dangling page
reference fails the load without mutating disk, and that the live canvas count
stays bounded across a long page sweep.
Instruments and physical-iPad evidence enforce the performance section.
Compilation alone is not behavioral proof.

This contract says nothing normative about additional pages, PDF or image
backgrounds, overlays, text input, caches, thumbnails, import/export, sync, AI,
or annotations. Each requires a later contract amendment that adds only the
state and owners needed for that milestone.
