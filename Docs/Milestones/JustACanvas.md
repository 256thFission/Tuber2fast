# Milestone 0 — Just a Canvas

Status: specified; implementation not started
Purpose: prove the smallest trustworthy writing loop before adding notebook
features.

## 1. Product target

Launch TuberNotes and get one blank portrait page. Write, erase, undo, redo,
pan, and zoom with native behavior. Leave the app, return, and find every
successfully saved stroke in the same page coordinates.

This is a production-shaped vertical slice, not a mockup.

## 2. User journey

1. Launch the normal app.
2. See one blank portrait page against a neutral workspace.
3. Draw immediately with Apple Pencil.
4. Select pen or eraser through the system PencilKit tool picker.
5. Undo and redo through PencilKit/system UI.
6. Pan and zoom with touch without moving ink relative to the page.
7. Extend the page downward when the room runs out, and keep writing.
8. Background and foreground the app and continue drawing.
9. Wait for a successful autosave.
10. Force-quit, relaunch, and see exactly the successfully saved drawing.

## 3. Included

- a new iPad-only application and Xcode project;
- one stable document ID and page ID;
- one portrait page: fixed width, and a height that grows downward one increment
  at a time to a bounded maximum (`DataContract.md` §5a);
- one `PKCanvasView` per editor session, hosted by a minimal SwiftUI root;
- PencilKit pen, eraser, system undo, and system redo;
- touch pan and pinch zoom;
- one drawing-change callback;
- editor-owned debounce, `dirty`, and `saveInFlight` state;
- one binary property-list file;
- concrete asynchronous load and atomic save;
- first-launch creation, autosave, recovery, and lifecycle handling;
- development signposts needed for the baseline trace; and
- focused tests for geometry and persistence correctness.

## 4. Excluded

- multiple pages, ordering, page navigation, thumbnails, or virtualization;
- PDF/image import, backgrounds, templates, crops, or rotation;
- custom tool UI, lasso actions, annotations, overlays, or text input;
- notebook library, titles, covers, folders, search, tags, or sync;
- export, sharing, migrations from another TuberNotes implementation;
- Pins, AI, chat, retrieval, networking, or normalized coordinates;
- caches, manifests, referenced assets, checksums, or packages; and
- copied source, project files, fixtures, or formats from the old app.

## 5. Minimal source shape

This is illustrative, not a mandatory file manifest:

```text
TuberNotesApp/
  TuberNotesApp.swift
  RootCanvasView.swift
  EditorSession.swift
  PageCanvasController.swift
  DocumentStore.swift
```

The SwiftUI representable may live with `RootCanvasView`; durable values may
live with `DocumentStore`. Split files or introduce types only when size,
isolation, or demonstrated reuse earns the split. Just a Canvas requires no
custom Swift protocols.

## 6. Required behavior

### Launch

`DocumentStore.load` runs before editing begins. No file means first launch:
generate IDs, use the initial portrait geometry, create an empty drawing, and
save the initial file. Invalid or unsupported data shows an error and remains
untouched; it is never replaced with a blank drawing.

### Drawing and autosave

PencilKit owns live drawing. Its drawing-change notification calls the editor
without carrying the drawing. The editor marks `dirty`, debounces for 500 ms,
captures afterward, and starts at most one save.

If drawing changes during a save, `dirty` becomes true. After the save returns,
the editor immediately saves once more if dirty. Failure leaves dirty state and
allows retry. The exact algorithm and ownership are normative in
`Docs/Architecture/DataContract.md`.

### Persistence

The one file contains only format version, stable IDs, immutable width/height,
and opaque PencilKit drawing bytes. A successful save return guarantees that
the next successful load reconstructs exactly that drawing.

An interrupted save that never returned may leave the prior or new complete
file. It must never produce a partial file or silently overwrite invalid source
data.

### Pan and zoom

The canvas controller owns viewport state. Pan, zoom, safe areas, and screen
frames are not persisted or published at frame frequency. Ink remains in page
space through every viewport change.

Finger input navigates and Apple Pencil writes. The initial app may support one
device orientation to keep width fixed.

### Page extension

A visible control raises the page by one increment. The editor owns the height,
refuses an extension at the maximum, and enters the ordinary autosave path. The
canvas gains addressable area at the bottom and changes nothing else: ink keeps
its page coordinates, and zoom and content offset are untouched. Extension is a
user intention, never a consequence of where ink landed, and it is not undoable.
The rules are normative in `Docs/Architecture/DataContract.md` §5a.

### Undo and redo

PencilKit and its system UI operate the live undo manager directly. The app has
no undo router or semantic undo state. Undo/redo drawing changes use the same
autosave callback as every other drawing change. Autosave does not clear undo.

### Lifecycle

Backgrounding cancels the debounce and requests a best-effort save within the
time iPadOS provides. Only a returned save is acknowledged. An unfinished save
does not change what the app promises to restore.

Foregrounding reuses retained live state. It must not overlay an older loaded
drawing onto newer live ink.

## 7. Acceptance gates

All device gates use the normal app on Phillip's explicitly named physical
iPad. Simulator and unit tests supplement but do not replace device evidence.

### Build and structure

- The new project builds without inherited application code or dependencies.
- One `PKCanvasView` per editor session throughout the journey, constructed at
  one code site. A process-global single canvas is explicitly not required.
- SwiftUI reconstruction does not replace the canvas or undo manager.
- No custom protocol, document reducer, event bus, repository, package, cache,
  or future-feature placeholder exists.

### Persistence

- Fresh install creates exactly one valid file with stable IDs and geometry.
- Draw, erase, undo, and redo; after save returns, force-quit and relaunch
  restores exactly the saved drawing.
- Interrupt an unacknowledged save; relaunch produces the previous or new
  complete drawing, never corruption or a blank overwrite.
- Invalid format version, invalid geometry, and malformed drawing bytes fail
  without modifying the source file.
- Background/foreground preserves live changes and eventually saves them.
- Extend the page, draw below the old boundary, force-quit, and relaunch: the
  grown height and the new ink both return. An unreachable height and an
  extension at the maximum are refused without modifying the file.

### Spatial behavior

- Page origin, axes, width, and height survive encode/decode unchanged.
- Ink remains attached to the page through minimum/maximum zoom, pan to every
  edge, and return to the initial viewport.
- Host-view updates do not reset viewport or drawing state.
- Extending the page moves no existing ink, changes no zoom scale or content
  offset, and does not drift the zoom floor as the page grows.

### Performance invariants

- No file access or property-list encoding runs on main.
- No task, actor hop, SwiftUI publication, or archive capture occurs per Pencil
  sample, pan tick, or zoom tick.
- Autosave has at most one capture/save operation in flight.
- Autosave causes no mechanically attributable crash or immediate UI freeze.

### Baseline trace

On the named iPad, record:

1. five minutes alternating handwriting, erasing, undo, and redo;
2. twenty full-range zoom/pan cycles;
3. ten background/foreground cycles; and
4. force-quit/relaunch after confirmed save success.

Retain device/build identity, Instruments trace, main-thread hangs, attributable
hitches, memory start/end/peak, save durations, restore duration, console, and
crash status. This milestone records the baseline. A later `CONTRACT:` change
sets numeric budgets from evidence before feature work continues.

### Human verdict

Phillip judges initial contact, stroke fidelity, palm rejection, Pencil/touch
separation, pan/zoom feel, tool ergonomics, and confidence that saved ink is
stable. Mechanical evidence cannot substitute for his verdict.

## 8. Evidence packet

- commit and changed files;
- confirmation that no old implementation was copied;
- build result and pinned-device identity;
- normal-app install and launch result;
- encode/decode, invalid-data, exact-restore, and interrupted-save results;
- coordinate round-trip result;
- Instruments/signpost artifact paths and baseline measurements;
- screenshot or recording paths;
- console and crash status;
- human-only checks and Phillip's verdict; and
- unresolved issues.

## 9. Stop conditions

Stop when all mechanical gates and artifacts are complete and the app is ready
for Phillip's verdict. Stop earlier if the design would violate the data
contract, two attempts fail for the same unexplained reason, the next step would
weaken durability, or scope would enter an excluded feature.

No additional page, PDF, overlay, cache, text, or AI work begins before this
milestone is accepted.
