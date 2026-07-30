# TuberNotes data and ownership contract

Status: normative for Just a Canvas
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
| Active tool, `dirty`, `saveInFlight`, debounce, current page height | `EditorSession` | interaction | app session |
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
7. `PageCanvasController` renders the page height it is given. It never chooses
   page geometry and never derives an extension from where ink landed.
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
- `pageWidth` is immutable for the life of a document, and `pageWidth <
  pageHeight` always holds.
- `pageHeight` is mutable and grows only, under the rules in §5a. A file at the
  initial height and a file at a grown height are both valid format version 1;
  a grown height is not a new format and there is nothing to migrate.
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

## 5a. Page extension

The page grows downward. Immutable geometry is overruled: a writing surface that
cannot be lengthened is not the product, and deferring growth would mean
building the geometry, zoom, and validation paths twice.

Only height changes, and only upward:

- `pageWidth` is fixed at creation and never changes.
- `pageHeight` starts at the initial height and increases by exactly one whole
  initial-height increment per extension.
- Valid heights are therefore whole multiples of the initial height, within a
  bounded number of extents. Any other height is invalid geometry and is
  rejected by `load` and by `save`.
- The bound exists because every save rewrites the whole file: unbounded height
  reintroduces the cost that infinite canvas was rejected for. The current bound
  is a bound, not a measurement — G4 revises it from save-cost-versus-height
  evidence.
- An extension at the maximum is refused and changes nothing.

Ownership is exact:

- `EditorSession` owns the current height, decides whether an extension is
  permitted, and enters the ordinary autosave path afterward. Height travels
  with the drawing in one captured generation, so a save never pairs one
  extension's height with ink captured under a different one.
- `PageCanvasController` renders the height it is told: the page gains
  addressable area at the bottom and nothing else changes. Ink keeps its page
  coordinates, and zoom scale and content offset are untouched. The zoom floor
  derives from width and the *initial* height, never the current height, so the
  viewport does not drift outward as the page grows.
- Extension is a user intention only. Testing ink position against page bounds
  on the Pencil path is forbidden.

Extension is not undoable, and PencilKit's undo manager never learns about it.
Because the page only grows, an extension loses no ink, so the absence of undo
cannot lose work.

Growing the page changes what the durable file may contain, not what it means.
Width remains the one geometry value a document can never renegotiate: a file
whose width differs from the application's canonical width is rejected, not
adapted. Supporting a second page width — landscape, A4, or imported source
geometry — requires a `CONTRACT:` amendment defining per-document width and
the migration for files written before it.

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

- an editor session constructs and retains exactly one `PKCanvasView`, and the
  application constructs canvases at exactly one code site. The process is *not*
  required to hold only one live canvas: scene-scoped and virtualized page
  editors must be able to own independent active canvases, so a process-global
  singleton is the wrong invariant. What is forbidden is a session holding two,
  or a canvas being replaced by anything other than the session that owns it;
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

Mechanical acceptance requires no synchronous file I/O on main, one canvas per
editor session, no crash, no lost acknowledged save, and no monotonic retention
of canvas controllers or completed save tasks. Phillip alone judges Pencil feel.

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
trip, and page extension — that a valid extension persists exactly one
increment, that an unreachable height is rejected, that the maximum refuses and
changes nothing, and that ink keeps its page coordinates across an extension.
Instruments and physical-iPad evidence enforce the performance section.
Compilation alone is not behavioral proof.

This contract says nothing normative about additional pages, PDF or image
backgrounds, overlays, text input, caches, thumbnails, import/export, sync, AI,
or annotations. Each requires a later contract amendment that adds only the
state and owners needed for that milestone.
