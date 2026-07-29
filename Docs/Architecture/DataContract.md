# TuberNotes data and ownership contract

Status: normative for Just a Canvas
Applies from: first line of application code
Change policy: a change to an owner, durable field, coordinate rule, or save
meaning requires a `CONTRACT:` commit and a `Docs/Plan/PLAN.md` entry.

## 1. Purpose

This contract defines the smallest trustworthy one-page drawing system. It
exists to prevent shared mutable state, work on the Pencil path, ambiguous
coordinates, and false claims that ink was saved.

There are four concrete owners and one direction of durable flow:

```text
SwiftUI root -- intentions --> EditorSession
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
| Active tool, `dirty`, `saveInFlight`, debounce | `EditorSession` | interaction | app session |
| Saved canvas file | `DocumentStore` | autosave | across launches |
| SwiftUI navigation and visible controls | SwiftUI root | user action | view session |

Rules:

1. A value has one writer.
2. SwiftUI never mirrors `PKDrawing`, pan, zoom, or Pencil samples.
3. `DocumentStore` never reaches into the canvas. It receives immutable values.
4. `PageCanvasController` never reads or writes files and never chooses save
   policy.
5. `EditorSession` coordinates owners but does not keep a second mutable
   drawing.
6. Recreating a SwiftUI view must not recreate the live canvas controller.

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
operates the live PencilKit view.

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
- `pageWidth < pageHeight`; geometry is immutable after first creation.
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
2. Reset a 500 ms debounce timer unless a save is already in flight.
3. When the timer fires, start `saveIfNeeded`.

`saveIfNeeded` is serialized:

```text
guard dirty && !saveInFlight
dirty = false
saveInFlight = true
capture the current drawing value
create drawingData outside the PencilKit callback
await DocumentStore.save(the complete CanvasFile)
saveInFlight = false
if dirty, saveIfNeeded again
```

If capture, encoding, or save fails, set `dirty = true`, clear
`saveInFlight`, report the error, and allow retry. There is never more than one
capture/save operation in flight, so stale-save generations cannot exist.

Reading `canvasView.drawing` occurs on the main actor after the debounce fires,
not inside PencilKit's change callback. The implementation locates
`PKDrawing.dataRepresentation()` according to the supported SDK's concurrency
contract and measures it on the target device. File encoding and disk I/O are
always off-main. If drawing-data creation must run on main and causes an
observable hitch, stop and resolve that measured bottleneck; do not invent an
unsupported cross-actor transfer.

## 6. Lifecycle and recovery

On backgrounding, the editor cancels the debounce and makes a best-effort call
to `saveIfNeeded` using the execution time iPadOS provides. There is no promised
flush duration. Only a successfully returned `save` clears dirty state.

If execution time expires before return, the save is unacknowledged. If the
process survives, the editor remains dirty and retries after foregrounding. If
the process ends, relaunch restores the last successfully returned save or, for
an interrupted atomic replacement, another complete file.

Foregrounding reuses the retained canvas and must not replace newer live ink
with an older load result. Loading happens once when creating the editor
session, before the canvas becomes editable.

On first launch, `load` returns `nil`; the app generates the two IDs and fixed
portrait geometry, constructs an empty `PKDrawing`, and saves the initial file.
On load failure, the app shows an error and leaves the source file untouched.

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

- exactly one live `PKCanvasView` exists;
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
3. ten background/foreground cycles; and
4. force-quit and relaunch after a confirmed successful save.

Record build, device and OS, trace duration, main-thread hangs, animation
hitches attributable to app work, memory at start/end/peak, save durations,
restore duration, and crashes. G4 then proposes evidence-based numeric budgets
in a `CONTRACT:` change before another feature is added.

Mechanical acceptance requires no synchronous file I/O on main, exactly one
live canvas, no crash, no lost acknowledged save, and no monotonic retention of
canvas controllers or completed save tasks. Phillip alone judges Pencil feel.

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
successful-save restoration, interrupted atomic replacement, and page-space
round trip. Instruments and physical-iPad evidence enforce the performance
section. Compilation alone is not behavioral proof.

This contract says nothing normative about additional pages, PDF or image
backgrounds, overlays, text input, caches, thumbnails, import/export, sync, AI,
or annotations. Each requires a later contract amendment that adds only the
state and owners needed for that milestone.
