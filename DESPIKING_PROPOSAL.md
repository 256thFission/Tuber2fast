# TuberNotes despiking proposal

Status: proposal  
Scope: the first production notebook substrate after `Just a Canvas`  
Intent: preserve validated interaction lessons while replacing the spike's
document, runtime, persistence, and lifecycle architecture

## Executive decision

Do not evolve `CanvasFile`, the fixed application-support URL, the growing
single page, or `DrawingSnapshot` into the production notebook.

The spike proves a useful local fact: a UIKit/PencilKit runtime can own live ink
without publishing frame-frequency state through SwiftUI. It does not prove
that one `PKDrawing`, one canvas controller, or one file is a viable notebook.

The production architecture should be a clean replacement built around:

- a versioned document package;
- stable document, page, layer, and asset identities;
- page-local annotation persistence;
- immutable PDF and image source assets;
- a virtualized continuous-page viewport;
- one active writable ink overlay per editing context, not per process;
- transactional, recoverable generations;
- scene-scoped document sessions;
- disposable derived search, OCR, thumbnail, and AI indexes.

Feature work on PDFs, images, or AI should not begin in the spike format. Those
features are consumers of the replacement substrate and would make a later
teardown more expensive.

## What survives the spike

These are principles, not concrete types:

1. The UIKit canvas runtime owns Pencil samples, gestures, pan, zoom, and the
   active frame path.
2. SwiftUI renders coarse snapshots and sends user intentions. It does not
   mirror drawing or viewport ticks.
3. Page-space content is durable; viewport state is ephemeral unless a product
   requirement explicitly makes it durable.
4. File, PDF, image, OCR, database, and network work never runs on an
   interaction path.
5. A save acknowledges only a generation that was actually committed.
6. Invalid or newer documents are never replaced with blank content.
7. Performance scales with visible or dirty pages, not notebook size.

## What is torn down

The following spike concepts have no compatibility guarantee:

- `CanvasFile`
- `DocumentStore` as a one-file whole-document writer
- `PageGeometry` as one globally fixed growing page
- the fixed `JustACanvas.canvas` URL
- the global assumption that a process has only one editing canvas
- full-document `PKDrawing.dataRepresentation()` autosaves
- `DrawingSnapshot` as a whole-drawing persistence boundary
- synthesized `Codable` as the long-term schema definition

The replacement may import a spike file once and emit a new package, but
production code should not retain a dual model indefinitely.

## Durable document package

Use an ordinary package directory so independently changed content can be
replaced independently:

```text
Notebook.tubernote/
  manifest.cbor
  generations/
    0000000042/
      commit.cbor
      pages/
        <page-id>/
          page.cbor
          ink.pkdraw
          objects.cbor
  assets/
    sha256-<digest>.pdf
    sha256-<digest>.<image-extension>
  derived/
    thumbnails/
    ocr/
    search/
    ai/
```

The exact encoding is a measured implementation choice. The structural rules
are more important:

- `manifest` contains schema version, document identity, committed generation,
  ordered page IDs, and asset references.
- A page record contains canonical geometry, background reference and transform,
  layer order, and revision metadata.
- Ink is page-local and opaque to storage.
- Placed images and future non-ink objects have stable IDs and explicit
  transforms.
- PDF and image bytes are immutable, content-addressed assets. Editing placement
  never rewrites the source.
- `derived/` can be deleted without losing user-authored information.
- Filenames and field names are explicit schema, not Swift implementation names.

Large original PDFs may be represented by one immutable asset referenced from
many page records. They must not be copied once per page.

## Commit and recovery model

Each successful mutation belongs to a monotonically increasing document
generation.

1. Capture dirty page revisions.
2. Serialize only dirty pages outside the interaction actor.
3. Write new page/object records into a new generation.
4. Validate hashes, sizes, schema, page references, and asset references.
5. Atomically replace the small manifest or commit pointer.
6. Retain at least one previously validated generation.
7. Clean abandoned generations later on a maintenance task.

Opening a notebook selects the newest completely valid committed generation. If
it is damaged, recovery falls back to the prior generation and reports that
recovery occurred. It never silently creates a blank notebook.

The commit protocol needs deterministic fault-injection tests after every
write, rename, validation, and pointer-swap boundary.

## Canonical coordinates

Every durable geometry value must name its coordinate space. Raw `CGPoint` and
`CGRect` values must not cross model boundaries without a typed wrapper or an
explicit transform.

Required spaces:

- **page space:** top-left origin, positive y downward, logical points;
- **PDF space:** the source page's media/crop box, bottom-left origin, including
  page rotation;
- **object-local space:** image or placed-object coordinates before placement;
- **viewport space:** transient scroll/zoom coordinates;
- **device space:** transient pixels and display scale.

Each page record stores:

- canonical page size;
- background crop box;
- background rotation;
- one invertible background-to-page transform;
- object-to-page transforms for placed content.

Tests must prove round trips in both directions for every PDF rotation, non-zero
crop-box origin, portrait/landscape page, and placed-image transform. Rendering,
hit testing, selection, export, OCR regions, and AI citations must all consume
the same transform definitions.

## Virtualized canvas runtime

The continuous notebook viewport owns lightweight page hosts. It preloads a
small window around visible pages and evicts content outside that window.

Each page can be in one of four runtime states:

1. **unloaded:** geometry and ordering only;
2. **preview:** thumbnail or cached page render;
3. **rendered:** full background plus raster/vector rendering of saved
   annotations;
4. **editing:** rendered page with a live writable PencilKit overlay.

The runtime may have multiple rendered pages but only the minimum number of
live writable overlays required by current interaction. Normally that is one
per scene. A second scene can have its own active overlay and session.

Transitions must preserve page coordinates and undo ownership:

```text
unloaded -> preview -> rendered -> editing
editing -> committed page revision -> rendered -> preview -> unloaded
```

No transition may serialize all pages or scan the whole notebook. Preload
distance is driven by viewport velocity and a fixed memory budget, not page
count.

Inactive ink should be rendered from the committed page-local drawing. The
active `PKCanvasView` is an editor overlay, not the notebook's scrolling storage
container.

## Save scheduling

Drawing callbacks do only three things:

1. increment the active page's edit generation;
2. mark that page dirty;
3. arm or refresh an idle deadline.

Serialization is page-local. The iOS 26 `PKDrawing` value is `Sendable`, so the
active runtime can transfer a captured value to a serialization task without an
unchecked wrapper. Keep that transfer behind one reviewed adapter and maintain
the page-size bound. PencilKit types still do not enter the document, database,
PDF, or AI layers; those layers receive opaque serialized ink.

A save captures:

- page ID;
- edit generation;
- page geometry revision;
- immutable ink snapshot;
- dirty object revisions.

Completion acknowledges only that captured generation. Newer edits remain
dirty. Continuous drawing receives another idle window rather than an immediate
back-to-back serialization loop.

## Scene and multiwindow ownership

Ownership is scene-scoped:

```text
App
  DocumentRegistry
    DocumentIdentity -> shared durable coordinator

Scene
  EditorSceneSession
    selected document
    selected page
    viewport
    active page runtime
    scene undo context
```

Two windows may open different notebooks without sharing controllers. If two
windows open the same notebook, a shared durable coordinator serializes commits
and mediates page revisions. Each scene retains independent viewport and tool
state.

The single-writer rule applies per durable value, not per process. A document
coordinator writes the manifest; a page writer commits a page revision through
that coordinator; views never write package files.

Scene deactivation acquires a UIKit background execution assertion before
starting the flush. Expiration leaves unacknowledged generations dirty.
Foregrounding retries them. Normal autosave remains the primary durability
mechanism; background execution is a final opportunity, not the guarantee.

## PDF behavior

PDF import stores the original bytes once and creates page records referencing
source page indices and transforms.

- PDF rendering is tiled and cancellable.
- Rendering priority follows visible, adjacent, thumbnail, then export work.
- Annotation never mutates the original PDF.
- Search results and links retain source PDF page coordinates and are projected
  through the canonical transform.
- Export creates a new PDF by compositing selected annotation layers.
- Password-protected, malformed, huge, rotated, and unusually cropped PDFs have
  explicit import outcomes and tests.

## Image behavior

Imported image bytes are immutable assets. Page placement is a separate durable
object containing asset ID, transform, crop, opacity, and z-order.

Decode and downsample to the requested display size off-main. Never decode a
full-resolution image merely to draw a thumbnail. Derived renditions are
discardable cache entries keyed by asset hash and rendition parameters.

## AI sidebar boundary

AI is a consumer of committed notebook snapshots, not part of the frame path or
canonical page writer.

Derived records reference stable:

- document ID;
- committed generation;
- page ID;
- region in page space;
- source object or ink revision;
- extraction model/version.

Chat answers cite those anchors so the UI can navigate to and highlight source
regions. OCR, embeddings, summaries, and chat caches may be invalidated and
rebuilt. User-authored chat history can be durable, but it lives in a separate
schema and cannot make an implicit document mutation.

Any AI-authored insertion is an explicit editor intention that produces an
ordinary page object through the same document mutation boundary as a human
action.

## Modules and dependency direction

The production project should use explicit seams where they buy isolation and
fault injection:

```text
NotebookModel        Foundation-only schema and typed geometry
NotebookStore        package commits, recovery, migrations
AssetStore           immutable PDF/image assets and renditions
PageRuntime          active PencilKit editing and page projection
NotebookViewport     virtualization and preload policy
PDFPipeline          import, render, search, export
DerivedIndex         thumbnails, OCR, search, AI projections
AppUI                scenes, navigation, commands, sidebar
```

Dependencies point toward `NotebookModel`. `PageRuntime` never imports the
package implementation. `NotebookStore` never imports UIKit or PencilKit; an
adapter supplies opaque, already serialized page ink.

Protocols are appropriate at expensive or failure-prone boundaries such as the
store, asset loader, clock, and task scheduler. They should not be invented for
plain value transformations.

## Evidence required before feature work

The replacement substrate is accepted only with recorded evidence for:

- 120 Hz interaction while autosave runs;
- bounded main-actor snapshot time at the maximum supported dirty-page size;
- save cost independent of total notebook page count;
- memory bounded by the visible/preload window in a long notebook;
- navigation through at least a 500-page mixed-size PDF;
- repeated edit/save/evict/reload preserving stroke geometry;
- process termination at every commit boundary recovering old or new state;
- two scenes editing separate documents;
- two scenes opening the same document without stale overwrite;
- schema migration from checked-in historical golden fixtures;
- PDF coordinate round trips for 0°, 90°, 180°, and 270° rotation;
- large-image downsampling without full-resolution main-thread decode;
- visible, retryable disk-full and permission failures.

Test gates must require expected suites or test counts, not merely evidence that
one test executed. Performance gates record distributions and budgets, not a
single best-case sample.

## Replacement sequence

1. Freeze the spike format and add an importer fixture.
2. Implement typed page/PDF geometry with exhaustive transform tests.
3. Implement the package writer, generation recovery, migrations, and
   fault-injection harness without UI.
4. Build a virtualized page viewport using synthetic backgrounds and saved ink.
5. Attach one active page editor overlay and prove edit/evict/reload fidelity.
6. Add scene-scoped document sessions and multiwindow coordination.
7. Import and render PDFs through immutable assets.
8. Add placed images and rendition caching.
9. Add thumbnails, OCR, and search as disposable projections.
10. Add AI sidebar retrieval and citations over committed generations.
11. Remove `CanvasFile`, the fixed URL, the growing-page spike, and
    `DrawingSnapshot`.

The old and new persistence architectures should coexist only for a bounded
import window. There should be one authoritative format after migration, not a
permanent compatibility layer.
