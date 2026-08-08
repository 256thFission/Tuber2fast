# Proposal: PDF rasterization (status + remaining work) and a paper-template system

Status: proposal, **revision 2 — an adversarial review of revision 1 found both
proposed mechanisms unsound, and this revision replaces them.** Written by an
agent from a full read of the render path, the model types, the store, and the
docs; every claim below was re-verified against the code for this revision.
Nothing here is a rule; contract amendments are proposed as exact edits for
Phillip to author.

**What revision 2 changes, in one place, so a reader of revision 1 need not
diff it:**

1. The `PDFDocumentCache` **actor is withdrawn** — it cannot compile under
   Swift 6 (`CGPDFDocument` is not `Sendable`), and forcing rasterization
   inside it would serialize every composite onto one executor. Replaced by a
   **per-render open handle**, which kills the double parse with no
   cross-isolation lifetime at all (§b1).
2. "No new cache bound is needed" was **false**: `retain(layerIDs:)` evicts on
   `isDisjoint(with: live)`, and the empty set is disjoint with everything, so
   a templated layer-less page's composite is dropped on **every turn, while on
   screen**. The request now carries `pageID` and eviction is page-scoped
   (§b3, §c).
3. `PageProjection` was **the wrong carrier** for the template: it is a
   construction-time seam. Template changes now travel the mid-life seam beside
   `setStaticLayers` (§c).
4. The unknown-template refusal is **re-scoped to the page** and moved out of
   `init(from:)`, with the two alternatives argued rather than dismissed (§e8).
5. **A document-level default is back in scope.** Revision 1's cut made this a
   per-page override system rather than a template system (§b4), and it also
   removes the neighbour-inheritance rule that contradicted
   `EditorSession.appendPage`'s own reasoning (§e7).
6. `.mappedIfSafe` is **not** a free one-word win — it moves file reads out of
   `DocumentStore`, which golden rule 4 forbids. It is now a separate,
   contract-touching, optional step (§b2).

## 0. Correction to the brief's premise

**PDF rasterization is already built, wired, and pixel-tested.** The claim that
"nothing rasterizes a PDF page anywhere in the build" comes from
`Docs/Unproven.md:180-192`, which is **stale**: `ImplementationStatus.md` phase
3c records the landing, and the code is in the tree.

- `Modules/TuberRender/PDFSource.swift:184-338` — `PDFPageRasterizer`:
  `rasterize(_:sourcePageIndex:pixelsPerPagePoint:subRect:)` is `async` and
  `nonisolated`; `displaySize(of:sourcePageIndex:)` is **synchronous and
  throwing** (`:195`). CropBox→MediaBox fallback with non-zero origin,
  `/Rotate` 0/90/180/270, a single y-flip, opaque white ground, typed
  `PDFRasterizeError`.
- `Modules/TuberRender/StaticLayerRenderer.swift:850-904` — `case .pdf` in the
  base composite, decode bounded by the placed extent.
- Same file `:480-551` — `case .pdf` in the lens, sub-rect mapped back into
  source display points and intersected with the page.
- `Modules/TuberCanvas/PageCanvasController.swift:951-1021` — the settle-time
  lens request, generation-guarded.
- Tests: `PDFPageRasterizerTests`, `PDFLayerRenderTests`, `LensTests`,
  `PrefetchWarmTests`.

`PDFPageRasterizer`'s own doc comment (`PDFSource.swift:179-183`) still says
"Neither integration exists yet — this type answers the question and stops",
which is now false in the same way `Unproven.md` is. Both are fixed by step 1.

So part 1 below is not a design for something absent: it is the accurate
inventory, the point-size question **answered with evidence** rather than
argued, and the two real costs found by reading the code. Part 2 (templates) is
genuinely greenfield — a `grep` over `Modules` and `TuberNotesApp` for
template/lined/dotted/grid finds only an unrelated spike grid and
`LibraryStore.ViewMode.grid`.

---

## (a) Current-state inventory of the render path, precisely

**Durable side.** A page is `PageRecord { id, geometry }` in `document.plist`
(`Modules/TuberModel/DocumentIndex.swift:31-40`), plus a page file listing
layer IDs, with heavy layers split into `layers/` (A14). A layer is
`LayerEnvelope { layerID, kind: String, payload: Data, pageSpaceTransform,
locked }`. Kinds are `ink | image | pdf` (`LayerEnvelope.swift:187-194`) —
`Docs/Contract.md` still says "The only kind is `ink`", because A5 and A13 are
staged and unadopted, so **the contract already lags the code by two kinds**.

**Import.** `EditorSession.importPDF` (`TuberNotesApp/EditorSession.swift:1443-1532`):
`PDFSource.pages` off-main → refuse any source page smaller than
`PageProjection.smallestDisplayablePagePoints(zoomCapPagePointsPerPixel:)` (a
function of the document's cap, `PageGeometry.swift:178`) → write the asset
**once** → one `PageRecord` per source page whose geometry *is* the source's
display size → one `pdf` envelope per page with `.fittingSource(...)`, which at
equal aspect is edge-to-edge `{a: w, d: h, tx: 0, ty: 0}` → index rewrite →
immediate `saveIfNeeded()`.

**Render, base ("fit-width composite").**

1. `PageCanvasController.requestCompositeIfNeeded` computes
   `compositeDetail(viewportWidth:displayScale:geometry:)` =
   `min(max(fitWidth × displayScale, 1), maximumCompositeLongEdge / max(w,h))`,
   quantized to 1/100 (`PageCanvasController.swift:915-931`). Requested at
   layout, at a layer-list change, and at a selection change — **never in a
   gesture frame**.
2. `StaticLayerRenderer.composite(for:)` (actor) checks an LRU cache keyed by
   `CompositeKey{ layerIDs, scaleMilli, widthMilli, heightMilli }`, with a full
   `request` equality check on hit (so a moved layer misses rather than showing
   a wrong picture), joins an in-flight render only on whole-request equality,
   otherwise spawns `Task { Self.render(...) }`. `render` is `nonisolated`, so
   pixels are built on the global executor — off the actor and off main;
   `pthread_main_np()` is sampled and surfaced as `StaticComposite.builtOffMain`
   so a test can fail on it (`:792-805`).
3. `render` decodes **every** layer before drawing anything: `image` via
   `CGImageSourceCreateThumbnailAtIndex` bounded by `maxPixelSize(of:at:)`;
   `pdf` via `PDFPageRasterizer.displaySize` then `rasterize` at
   `rasterScale = max(placedW×scale/displayW, placedH×scale/displayH)`. Any
   failure refuses the **whole** composite — never a partial picture.
4. One opaque page-sized `CGContext` (`noneSkipFirst | byteOrder32Little`),
   white fill, one y-flip into page space, then per layer
   `concatenate(transform)` + a unit-square flip + `draw(image, in: unit square)`.
5. `PageBackdrop.show(_:)` (`PageBackdrop.swift:234-268`) assigns
   `page.contents` + `contentsScale` — **the pipeline's only main-thread step**.
   The backdrop is a `CALayer` stack (`clip` → `page` → sublayers `lens`,
   `lift`) inserted below the `PKCanvasView`'s layer and mirrored by one
   `CATransform3D` assignment per scroll tick. The canvas goes
   `isOpaque = false` only on pages that actually have static layers
   (`PageCanvasController.swift:816`).

**Render, lens ("sharp at settle").** At a settle callback, if
`lensScale > baseScale × 1.25`, no selection is active, and the page has static
layers, the visible rect is computed in page points, **clamped to the page**,
and `StaticLayerRenderer.lens(for:visibleRect:)` builds a *viewport-sized*
context on the caller's own task (no dedup, no cache, cancellation inherited).
`pdf` layers rasterize only the visible sub-rect at the settled scale —
genuinely sharp. `image` layers are capped at `lensImageMaxPixelSize = 2800`,
i.e. present and placed but no sharper than the base (a known, documented gap).
The result lands in `PageBackdrop.showLens(_:over:)`; any pan/zoom tick calls
`invalidateLens()`, which bumps a generation, cancels, and nils
`lens.contents`.

**Cache.** Declared with owner/bound/eviction per the contract's cache rule
(`StaticLayerRenderer.swift:39-70`): owner = the actor; bound = 96 MB (four
~22 MB fit-width composites, an unmeasured estimate); eviction =
`retain(layerIDs:protecting:)` as *policy*, LRU byte-bound trim as *backstop*,
passing over the just-inserted entry and the visible page's layers. Refusals
are cached at zero bytes. Lens and lift renders are deliberately not cached.

**Selection/lift.** A selected layer leaves the composite and is drawn by the
`lift` sublayer; the swap is ordered so no frame has the layer in neither
place. `pdf` layers are **not selectable** (`LayerEnvelope.isSelectable` is
`recognizedKind == .image`), which is what lets the lens assume a `pdf`
transform is axis-aligned and refuse otherwise.

**Library thumbnails.** `LibraryThumbnailStore` composites **ink over paper
only** — static layers are explicitly out of scope (`:18-27`, `:268-277`), so a
PDF-backed page already thumbnails as bare ink today.

---

## (b) Durable-form decisions

### b1. The PDF point-size field: **NO — and the renderer now proves it**

`Unproven.md` framed this as "the renderer will tell us". The renderer exists,
so read what it does:

- `render`'s pdf case needs the display size, gets it from `displaySize`, and
  needs the **`CGPDFPage` itself** two lines later. A durable size saves
  nothing: the bytes are already required, and the geometry is derived in the
  same pass that draws.
- The lens maps target→source using `display` and then rasterizes from the same
  document.
- Hit-testing never asks: `PageSpaceTransform.containsUnitSquarePoint`
  (`LayerEnvelope.swift:138-146`) is the whole hit test and touches no asset.
  `pdf` layers are not selectable anyway.
- Paging and layout — the one path that must answer without opening a 50 MB
  file — read `PageRecord.geometry`, which for an imported page already *is*
  the source's point size. A payload field would be a literal third copy.

A13's four grounds survive contact with the implementation. **Action: update
`Unproven.md` to record the decision as settled by evidence**, keeping the half
that is genuinely unproven (no wild CropBox/`/Rotate` PDF has been imported; no
device evidence; no latency number).

What the field was a proxy for is real, and is fixed directly.

**Defect P1 — the source document is parsed twice per pdf layer per render.**
`displaySize` builds a `CGDataProvider` + `CGPDFDocument` (`PDFSource.swift:195-223`)
and `rasterize` builds them again from the same `Data` (`:261`). Every
composite, every lens, and every prefetch warm pays two full document opens per
pdf layer.

**Fix: a per-render open handle, not a cache.** Revision 1 proposed
`actor PDFDocumentCache`. That does not work and would not have compiled:

- `SWIFT_VERSION: "6.0"` (`project.yml:19`). `CGPDFDocument` and `CGPDFPage`
  are **not `Sendable`**, so an actor cannot vend them to the `nonisolated`
  render path.
- Keeping them inside and rasterizing there would put every composite, warm,
  and lens on **one actor executor** — precisely what
  `StaticLayerRenderer.swift:792-805` and `:403-407` are `nonisolated` to
  avoid ("a second page asking for its composite must not queue behind this
  one's pixels").

A per-render handle has neither problem: it is created and destroyed inside one
`render` or `renderLens` call, on the global executor, never crossing an
isolation boundary, and it halves the parse cost — which was the whole point.

**Cross-render caching is dropped entirely**, and that is a decision rather than
an omission. Revision 1's bound (2 open documents) was wrong-shaped anyway: the
prefetch radius is 3 (`EditorSession.swift:781`) and the live window is 3, so up
to ~6 renders can be in flight over a span that a multi-import document can
easily spread across more than two distinct assets; and the `retain(assetIDs:)`
it needed would have meant decoding `PDFLayerRef` payloads on `@MainActor` every
turn — new main-thread work smuggled in as free. The residual cost after the
handle is **one parse per composite**, and `Unproven.md`'s "no numbers exist"
governs: measure on a device before adding a mechanism whose bound nobody can
state.

### b2. `.mappedIfSafe` — a real but contract-touching change, on its own

`DocumentStore.loadAsset` is `try Data(contentsOf: url)` with no options
(`Modules/TuberStore/DocumentStore.swift:109-111`), so a 50 MB import is a
50 MB read and a resident copy per composite, per lens, per warm.

`.mappedIfSafe` would change that, and revision 1 called it a one-word win. It
is not:

- **Safety is fine.** Reclamation deletes by path and `writeAsset` is
  atomic-by-rename, so POSIX inode semantics keep a mapping valid across a
  delete; there is no truncation-under-a-mapping path in this store.
- **The contract is not fine.** The read stops happening in `DocumentStore` and
  starts happening as page faults inside `drawPDFPage` on the render executor.
  Golden rule 4 says `DocumentStore` is the only thing that touches files, and
  `StaticLayerRenderer.swift:20-23` asserts exactly that about itself ("reads
  asset bytes *through* the store's own entry point and never opens a file
  itself"). Mapping makes that sentence literally false.

So it is proposed as a **separate, optional step gated on Phillip**, with the
amendment it needs (A18, §b5). The memory claim revision 1 made — "50 MB stops
being dirty memory" — is **unmeasured** and is withdrawn as a claim; what is
certain is only that the pages become file-backed and therefore reclaimable by
the OS.

### b3. Templates: a per-page durable property on `PageRecord`, not a layer kind

**Not a layer kind.** A kind buys a payload, an asset ref, refusal semantics,
reclamation, selection/hit-testing, and a position in the ordered list. A
template needs none of them and fights three:

- It has no asset and no bytes, so `RefusedLayer.Reason`'s taxonomy
  (`unknownKind`, `unreadablePayload`, `unsupportedAssetFormat`,
  `missingAsset`) is inapplicable — a closed enum of procedural patterns
  cannot fail to render.
- The layer list carries exactly one pinned position (`ink` last). A template
  must be *first*, always: a second order invariant, a second `LayerError`
  case, and a second thing every `staticLayers + [ink]` assembly must remember.
- It would put a layer on every blank page, turning `.empty` — "the case that
  must cost nothing" — into the uncommon one.

**Value:**

```swift
package enum PageTemplate: String, Codable, Sendable, Equatable, CaseIterable {
    case blank, lined, grid, dotted
}
```

A closed set of names and nothing else. **No spacing, colour, or margin
fields** — those are rendering constants, and a durable spacing number is the
"field a shipped kind does not read" pattern until a UI sets it. `blank` is a
real member rather than `nil`, so the render switch is exhaustive.

**Home: `PageRecord`, in the index.** The conclusion is the same as geometry's,
but **the argument is not the one `DocumentIndex.swift:23-26` makes, and
revision 1 was wrong to reuse it verbatim.** That argument has two halves —
"the layout needs it before page files are read" and "geometry is immutable
after creation, so it costs no writes" — and only the first transfers. A
template is **the first mutable durable per-page value in the index**. So the
argument stands on its own feet:

- *Why the index and not the page file:* the composite request for a
  **prefetched neighbour** is built by `EditorSession.warmNeighbourComposites`
  (`:666-688`) from what the index knows, before that page's file is read. A
  template in the page file would mean either warming with the wrong paper and
  re-rendering, or reading page files ahead of the window — the whole-document
  read the format exists to prevent.
- *What it costs, honestly:* one index rewrite per template change. That is a
  new write trigger, it is a **contract change** (A16, §b5), and it is small: a
  discrete user action writing one small file, at the same frequency the user
  turns pages — which already rewrites the index for `currentPageIndex`.

**Templates render beneath everything, including PDF**, rather than a page
being PDF-*or*-templated. Mutual exclusion would be a durable invariant needing
enforcement at import, load, and save, to prevent a state nobody can currently
create; `.fittingSource` letterboxes whenever a source's aspect differs from
its page; and it costs nothing, because the import path sets `.blank` on
imported pages. Structure permits it; the import path declines it.

### b4. The document-level default: **in scope, reversing revision 1**

Revision 1 cut this and thereby gutted the feature. `DocumentIndex.newDocument`
(`:307-314`) hardcodes a single `PageRecord(id:geometry:)`, so with no
document-level value **every new notebook is permanently blank paper, set page
by page, forever**. That is a per-page override system, not a template system.

**Decision: one durable document-level field, `defaultPageTemplate`, in
`DocumentIndex`**, chosen at document creation in the library's new-document
flow, used for page 1 and by every `appendPage`.

It is **not** a second home for the per-page value, and the distinction is the
one this project keeps making about values in two places: every page stores its
own **resolved** template, there is no `inherit` sentinel, and no page's
appearance is ever derived from the document field. The field answers a
different question that no page record can answer — *what paper does the next
page get* — and it is read by exactly two shipped call sites
(`newDocument`, `appendPage`), which is the test *Forbidden patterns* sets for
a field that would otherwise be a placeholder.

This also disposes of revision 1's neighbour-inheritance rule; see §e7.

### b5. Required `CONTRACT:` amendments — exact proposed edits

Stage as **A16–A18** in `Docs/Contract.proposed.md` (next free numbers; L1–L5
are the library lane). Do not write them into `Contract.md` — no agent authors
a rule.

**Prerequisite, not new:** adopt A5 and A13 first, or `Contract.md`'s "The only
kind is `ink`" contradicts three shipped kinds.

---

**A16. *Durable form* — a page carries a paper template — AHEAD**

Replace, in *Durable form*:

> `document.plist` holds the format version, `documentID`, page geometry, an
> ordered list of page IDs, and the current page index.

with:

> `document.plist` holds the format version, `documentID`, an ordered list of
> page records — each a page ID, that page's geometry, and that page's paper
> template — the current page index, the document's zoom cap, and the paper
> template new pages are created with.

Replace:

> - **A save writes only what changed.** One changed page writes one page file,
>   and the index is rewritten only if page order or the current index changed.

with:

> - **A save writes only what changed.** One changed page writes one page file,
>   and the index is rewritten only if page order, the current index, or a
>   page's paper template changed. A template is the one durable per-page value
>   that may change after page creation; geometry may not.

Add to the bulleted rules:

> - **A page's paper template is a name from a closed set** — `blank`, `lined`,
>   `grid`, `dotted` — stored in the page's index record beside its geometry. It
>   is a name and nothing more: no spacing, colour, margin, or measurement is
>   durable, because a template is drawn procedurally from constants the build
>   owns, and a stored measurement would be a second authority for one picture.
>   Adding a member is a `CONTRACT:` amendment, exactly as adding a layer kind
>   is.
> - **A template is not a layer.** It has no envelope, no payload, no asset, and
>   no position in the layer list; it cannot be selected, transformed, locked,
>   or reclaimed. It is drawn beneath every layer of the page, including a `pdf`
>   layer, and a page may carry both — a template a `pdf` layer fully covers is
>   invisible, not invalid.
> - **A page record written without a template reads as `blank`**, and a page
>   record naming a template this build does not know **refuses that page** —
>   the page is not editable and shows a refusal, the document opens, and every
>   other page opens normally, exactly as an unknown layer kind refuses its
>   layer. The unknown name is preserved verbatim and written back unchanged; a
>   refused page's template is never rewritten to `blank`.
> - **The document's `defaultPageTemplate` is the paper a newly created page
>   gets** — page one at document creation, and every page appended afterwards.
>   It is never consulted to *display* a page: every page record carries its own
>   resolved template, and there is no inherited or absent state.

**A17. *Geometry and coordinates* — where template geometry is measured — AHEAD**

Append to *Geometry and coordinates*:

> A paper template is drawn in **page space**, in absolute page points, from the
> page-space origin at the top-left. It is never a fraction of the page: pages
> differ in size within one document, and ruling that scaled with the page would
> put different line spacings on facing pages of one notebook.

**A18. *Owners* — memory-mapped asset reads — AHEAD, and optional**

Only needed if the `.mappedIfSafe` change (§b2) is taken. To golden rule 4, add:

> `DocumentStore` may hand out a memory-mapped read of an immutable asset. The
> mapping is still the store's read — the store opens the file, chooses the
> mapping, and owns the URL — and the fault that materializes a page later is
> not a second owner touching storage. This licence extends to assets only,
> which are write-once and never rewritten; page files and the index are read
> eagerly, as they always were.

*Also relevant and not this proposal's job:* `Contract.md`'s "Geometry fields
are finite page points greater than zero, with `pageWidth < pageHeight`" is
already false in code (landscape imports). That is A8.

---

## (c) Rendering pipeline design, with ownership

**The template is drawn by `StaticLayerRenderer`, into the same composite and
the same lens.** Not a `CAShapeLayer`, not a `CATiledLayer`, not a layer of its
own.

Why: base-and-lens already solves exactly the problem a procedural pattern has
(crisp at fit-width, crisp again at settled deep zoom, compositor-scaled in
between), already runs off-main and off-actor, already has generation-guarded
staleness, and already reduces to one `contents` assignment on main. A
`CAShapeLayer` would draw hundreds of paths **on the main thread** inside
`CALayer.display()` at every `contentsScale` change — what *Performance*
forbids — and would need its own registration with the mirror transform.
`CATiledLayer` draws on its own schedule and fades tiles in, which would fight
the mirror.

### c1. Delivery: the mid-life seam, not `PageProjection`

Revision 1 put the template in `PageProjection`. That is wrong and would have
left `setTemplate` with **no delivery path to the visible page**:
`PageCanvasController` holds `private let projection`
(`PageCanvasController.swift:52`), a `let` whose immutability is described as
the enforcement of "no owner mutates geometry after creation".

The template travels the seam `setStaticLayers` travels
(`PageCanvasController.swift:641-672`), which is the mid-life path that already
exists:

- `PagedCanvasSession` gains `template(forPageAt:)` beside
  `staticLayers(forPageAt:)`.
- `PageCanvasController.setTemplate(_:)` — sibling of `setStaticLayers` — is a
  no-op when unchanged; otherwise it nils `renderedRequest`, bumps
  `compositeGeneration`, cancels `compositeTask`, calls `invalidateLens()`,
  installs or removes the backdrop per the new emptiness rule, and calls
  `requestCompositeIfNeeded()`.
- `PageProjection` is **unchanged**. Nothing about a template is construction-
  time-only, so it has no business in the construction-time value.

### c2. Owner-table rows

| State | Sole writer | Frequency | Lifetime |
|---|---|---|---|
| A page's paper template | `EditorSession` (in the page record) | user action | app session → saved |
| The document's default page template | `EditorSession` (in the index) | document creation | across launches |
| The rendered template pixels | `StaticLayerRenderer` (inside the composite/lens texture) | layout / layer edit / template change / settle | render-cache entry |

Thread and actor placement is unchanged, which is the point: `EditorSession`
(`@MainActor`) owns the durable value and puts it in the request;
`StaticLayerRenderer` (actor) owns cache admission and dedup; `render` and
`renderLens` are `nonisolated` → global executor, and that is where template
paths are stroked; `PageBackdrop` on main does one `contents` assignment.
Nothing about templates touches disk.

### c3. The cache: page-scoped eviction, and why the bound needed fixing

Revision 1 claimed "no new bound is needed, `retain` still works". **False, in
exactly the case templates exist for.** `retain(layerIDs:)` drops entries where
`entry.layerIDs.isDisjoint(with: live)` (`StaticLayerRenderer.swift:671`), and
**the empty set is disjoint with every set**, so a templated layer-less page's
composite is evicted on every turn — including while it is the page on screen.
The trim's protection has the same hole (`:758`,
`entry.layerIDs.isDisjoint(with: protectedLayerIDs)`).

**Fix: the request carries the page's ID, and retention is page-scoped.**

```swift
package struct StaticLayerRequest {
    let pageID: UUID          // new
    let layers: [LayerEnvelope]
    let geometry: PageGeometry
    let template: PageTemplate // new
    package let pixelsPerPagePoint: Double
}

private struct CompositeKey: Hashable {
    let pageID: UUID           // new
    let layerIDs: [UUID]
    let scaleMilli: Int
    let widthMilli: Int
    let heightMilli: Int
    let template: PageTemplate // new
}

package func retain(pageIDs live: Set<UUID>, protecting visible: Set<UUID>)
```

This is strictly a simplification, and it pays for itself three ways: eviction
becomes a single-UUID test instead of a set-disjointness test over layer IDs;
`EditorSession.retainRenderedLayers` (`:635-646`) stops building a union of
every live page's layer IDs each turn; and the finding-11 worry about decoding
`PDFLayerRef` payloads on the main actor never arises, because nothing needs
asset identity.

It costs one claim in the renderer's own doc comment
(`StaticLayerRenderer.swift:166-168`): "Layer IDs are unique within a page …
so this needs no page identity". That claim was **only true while every cached
composite had at least one layer**, which templates end. `PageCanvasController`
is told its page ID at construction — it remains blind to page *numbers* and
*turns*, which is what golden rule 7 actually says; being told a UUID is
telling, not asking.

The 96 MB byte bound and the LRU backstop are unchanged: a template adds vector
strokes to a context that already exists, so byte cost per entry is unchanged.

### c4. Every empty short-circuit that must change (complete inventory)

A templated blank page has **no layers and is not empty**. Revision 1 named two
of these sites; there are seven.

| Site | Today | Becomes |
|---|---|---|
| `StaticLayerRenderer.composite` `:214` | `guard !request.layers.isEmpty else { return .empty }` | `layers.isEmpty && template == .blank` |
| `StaticLayerRenderer.warm` `:344` | same guard | same change |
| `StaticLayerRenderer.renderLens` `:408` | `guard !request.layers.isEmpty else { return .empty }` | same change — **missed by revision 1; without it step 9 ships a lens that returns `.empty` for every templated blank page** |
| `StaticLayerRender.empty`'s doc `:1092-1094` | "it is every page in a blank notebook" | must be reworded: it is every page with no layers **and** blank paper |
| `EditorSession.warmNeighbourComposites` `:677` | `!pageStates[pageIndex].staticLayers.isEmpty` | `|| template != .blank` |
| `PageCanvasController.setStaticLayers` `:652` | `guard !layers.isEmpty` → removes backdrop, `isOpaque = true` | the tear-down path must be conditioned on the template too, or setting layers to empty rips the paper off a templated page |
| `PageCanvasController.requestLensIfNeeded` `:963` | `!staticLayers.isEmpty` | `|| template != .blank` |

Plus the two opacity sites (`:663`, `:816`): the canvas goes transparent when
`!staticLayers.isEmpty || template != .blank`. A genuinely blank page keeps its
opaque canvas and pays nothing — the property `Unproven.md:151-157` cares
about, preserved deliberately.

### c5. Softness under zoom, and the dark-mode hook

Identical to `pdf`, and already shipped: base at `compositeDetail`;
compositor-scaled during the gesture (`magnificationFilter = .linear`); at
settle, if `lensScale > base × 1.25`, a viewport-sized lens re-**strokes** the
rules at the settled scale — genuinely resolution-independent, unlike a
re-sampled raster. No new mechanism.

**Dark mode: structural hook only, no field now.** Template colours are
renderer constants. When dark mode arrives it is one `appearance` term in
`StaticLayerRequest` and one more field in `CompositeKey` (a light and a dark
composite of one page are different textures), invalidated on a trait change.
**Do not add the field now** — an unread `appearance` field is the placeholder
*Forbidden patterns* bans. What this proposal guarantees is that the shape
admits it: the template is a *name*, resolved to pixels by code at render time,
never a stored colour.

---

## (d) Swift API surface sketches (signatures, not implementations)

```swift
// Modules/TuberModel/PageTemplate.swift  (new; Foundation only)

/// The closed set of paper templates. A name and nothing more: spacing and
/// colour are rendering constants, never durable.
package enum PageTemplate: String, Codable, Sendable, Equatable, CaseIterable {
    case blank, lined, grid, dotted
}

// Modules/TuberModel/DocumentIndex.swift  (edited)

package struct PageRecord: Codable, Sendable, Equatable {
    package let id: UUID
    package let geometry: PageGeometry

    /// The raw durable string, for the reason `LayerEnvelope.kind` is raw: a
    /// record written by a newer build must decode, and be refused by name,
    /// rather than fail to decode and read as a corrupt file.
    package let templateName: String
    /// The template, if this build knows it; `nil` is a refusal, not a default.
    package var recognizedTemplate: PageTemplate? { PageTemplate(rawValue: templateName) }

    package init(id: UUID, geometry: PageGeometry, template: PageTemplate = .blank)
    package init(id: UUID, geometry: PageGeometry, rawTemplateName: String)   // tests only
    package init(from decoder: Decoder) throws   // absent name decodes as "blank"
}

package struct DocumentIndex: Codable, Sendable, Equatable {
    // …existing…
    /// The paper a newly created page gets. Never consulted to display a page.
    package let defaultPageTemplate: PageTemplate
    package static func newDocument(documentID: UUID, pageID: UUID,
                                    template: PageTemplate) -> DocumentIndex
    package func withPageTemplate(_ template: PageTemplate, forPageID: UUID) -> DocumentIndex
}

package enum DocumentIndexError: Error, Equatable {
    // …existing…
    /// A page names a paper template this build does not know. Refuses the
    /// page, not the document — see §e8.
    case unknownPageTemplate(pageID: UUID, name: String)
}

// Modules/TuberRender/PDFSource.swift  (edited — defect P1)

/// One source PDF, opened once. **Not `Sendable` and deliberately not an
/// actor**: `CGPDFDocument` and `CGPDFPage` are non-Sendable under Swift 6, so
/// this lives and dies inside one `render`/`renderLens` call on the global
/// executor and never crosses an isolation boundary.
package final class OpenPDFDocument {
    package init(bytes: Data) throws                      // throws .notAPDF
    package func displaySize(sourcePageIndex: Int) throws -> CGSize
    /// Synchronous: it is compute-bound and already runs on the global
    /// executor; the current `async` has no suspension point to justify itself.
    package func rasterize(sourcePageIndex: Int, pixelsPerPagePoint: Double,
                           subRect: CGRect?) throws -> CGImage
}
// `PDFPageRasterizer`'s two free functions are replaced by this type, not kept
// beside it — two ways to open a PDF is two places the box decision lives.

// Modules/TuberRender/PaperTemplateRenderer.swift  (new)

/// The one place a template becomes marks. Pure geometry into a context whose
/// CTM is already page space (origin top-left, y down). Fills nothing, reads
/// nothing, allocates nothing beyond its path.
enum PaperTemplateRenderer {
    /// Page-point constants, stated once and absolute — never a fraction of the
    /// page (A17).
    enum Metrics {
        static let ruleSpacing: Double, gridSpacing: Double
        static let dotSpacing: Double,  dotRadius: Double
        static let ruleWidth: Double,   topMargin: Double
    }
    static func draw(_ template: PageTemplate, in context: CGContext,
                     pageSize: CGSize, clippedTo clip: CGRect)
}

// Modules/TuberRender/StaticLayerRenderer.swift  (edited — see §c3, §c4)

package struct StaticLayerRequest: Sendable, Equatable {
    let pageID: UUID
    let layers: [LayerEnvelope]
    let geometry: PageGeometry
    let template: PageTemplate
    package let pixelsPerPagePoint: Double
    package init(pageID: UUID, layers: [LayerEnvelope], geometry: PageGeometry,
                 template: PageTemplate, pixelsPerPagePoint: Double)
}
package func retain(pageIDs: Set<UUID>, protecting visible: Set<UUID>)

// Modules/TuberCanvas/PageCanvasController.swift  (edited — the mid-life seam)

/// Sibling of `setStaticLayers`: told, never asked. Bumps the composite
/// generation, invalidates the lens, installs or removes the backdrop, and
/// re-requests. `PageProjection` is untouched — a template is not a
/// construction-time fact.
func setTemplate(_ template: PageTemplate)

// Modules/TuberCanvas/PagedCanvasSession.swift  (edited)
func template(forPageAt index: Int) -> PageTemplate

// TuberNotesApp/EditorSession.swift  (edited)
func setTemplate(_ template: PageTemplate, onPage pageID: UUID) async throws
// One writer (the page's index record). Rewrites the index only — no page file.
// Refused for a page whose template this build does not recognize, for the same
// reason a save is refused for a page carrying a layer it cannot re-encode.

// Modules/TuberStore/DocumentStore.swift  (optional, §b2 + A18)
package func loadAsset(assetID: UUID, format: AssetFormat) throws -> Data
// body: try Data(contentsOf: assetURL(assetID, format), options: .mappedIfSafe)

// PageBackdrop.swift — UNCHANGED. A design claim, not an omission: the template
// arrives as pixels inside the composite and the lens.
```

---

## (e) Edge cases

### PDF (existing behaviour, verified by reading; each already decided)

| Case | Handling | Where |
|---|---|---|
| CropBox smaller than MediaBox | CropBox wins; MediaBox only on null/empty | `PDFSource.swift:137-138` |
| CropBox with non-zero origin | Cancelled by the final `translateBy(-box.minX, -box.minY)` in y-up space | `:326` |
| `/Rotate` 90/180/270 | Applied to the extent and the CTM; import fits the *displayed* extent, so a rotated landscape page becomes a landscape page | `:123-128`, `:313-325` |
| `/Rotate` not a multiple of 90 | `displayGeometry` → `nil` → `unreadableSourcePage` → the **whole** import refuses | `:141` |
| `sourcePageIndex` out of range | Not checked at load (that means opening every asset); refused at render as `pageOutOfRange` → refusal tint | `:214-216`, `LayerEnvelope.swift:503` |
| Sub-rect past the page edge | `rasterOutsidePage`, with 0.001 float-dust tolerance; the caller clamps first (`PageCanvasController:988`) | `:266-271` |
| Zero-pixel target / context failure | `rasterUnavailable` → composite refused whole | `:275-291` |
| A raster fails mid-composite | **The entire composite is refused** — refusal tint, logged reason, never a blank page | `StaticLayerRenderer.swift:900-904`, `PageBackdrop.swift:252-258` |
| Non-axis-aligned pdf transform in the lens | Refused rather than approximated; the soft base stays and stays correct | `StaticLayerRenderer.swift:500-505` |
| Missing asset | `RefusedLayer.Reason.missingAsset`, `isReconstructable == true`, so deleting the layer remains the repair | `LayerEnvelope.swift:403, 415-420` |
| Mixed geometry in one document | Per-page geometry, per-page zoom floor, one shared cap; the key carries width/height | `:173-189` |
| Source page too small for the zoom cap | Refused **at import**, before a byte is written | `EditorSession.swift:1463-1472` |

### Templates (new; each decided here)

1. **Template under a fully-covering `pdf` layer** — legal, invisible, not an
   invalid state. The import path sets `.blank`, so it costs nothing.
2. **Template under a partially-covering layer** — shows in the letterbox
   bands. This is the desired picture and the reason for beneath-everything.
3. **A page shorter than one rule spacing** — draws zero or one rule. Not
   clamped and not special-cased; absolute spacing means a small page has few
   rules. (`smallestDisplayablePagePoints` is ~103 pt at the canonical cap, so
   at 24 pt ruling the floor is ~4 rules.)
4. **Non-integral page size** — the last rule lands where it lands; the
   template is never stretched to fit, which would make spacing depend on page
   size (A17 forbids it).
5. **Landscape page** — same absolute spacing, more columns, fewer rows.
6. **Template changed on a page with ink** — permitted; ink is untouched. One
   index write, one composite invalidation, no page-file write. **Not
   undoable**: like turning and appending, it is not a PencilKit stroke edit
   (*Undo*: "There is no interception and no semantic undo domain"). Flagged as
   a judgment call worth Phillip's verdict — GoodNotes does make it undoable.
7. **The appended trailing page** — see §e7 below.
8. **An unknown template name** — see §e8 below.
9. **Cache thrash on a template change** — the superseded key stays cached at
   its bytes until the next `retain` or the byte bound drops it. Bounded and
   self-correcting: the same shape as the documented `KNOWN DEFECT` at
   `StaticLayerRenderer.swift:232-238`.
10. **Library thumbnails ignore templates** — `LibraryThumbnailStore` renders
    ink over paper and excludes static composites by design (`:18-27`,
    `:268-277`), so a templated page thumbnails as blank paper, exactly as a
    PDF-backed page already does. **Out of scope**, and named here so it is a
    decision rather than a surprise: fixing it means giving the thumbnail path
    a static composite, which is the per-cell decode that path was explicitly
    built to avoid.

### e7. Appended pages: canonical paper, not the neighbour's

Revision 1 said an appended page inherits the current page's template. That
contradicts `EditorSession.appendPage`'s own reasoning
(`EditorSession.swift:806-813`), which argues at length for canonical geometry
*always*, naming the defect precisely: "a blank page shaped like the last
import would make the shape of a new page depend on where you happened to be
standing."

That argument is right, and it applies to paper as much as to shape. One could
argue paper ≠ shape — geometry is structural and ruling is cosmetic — but the
defect named is not about structure, it is about **a new page's properties
being a function of scroll position**, and that is identical for both.

**Decision: an appended page takes the document's `defaultPageTemplate`, never
the neighbour's.** This is why §b4 reversed the document-default cut: it is
what lets append be principled instead of positional. A notebook created as
lined appends lined pages after a PDF import, which is the behaviour a user
means by "this is my lined notebook".

**And the withheld trailing page: the template is not lost, because the page is
not kept.** `durableIndex` (`EditorSession.swift:1011-1030`) truncates the
trailing run of `neverWritten` pages from every save, so an appended page that
never took ink does not survive a close **at all** — its template is not a
special casualty. Revision 1's edge case 7 implied otherwise and is corrected.

The alternative — letting a template choice clear `neverWritten` — is
**rejected**: it would make an accidental overshoot durable, which is exactly
what the withholding rule exists to prevent, and paper on a page with no ink is
not content. **State it loudly in the UI-facing note:** paper chosen on a page
you never write on does not persist, because that page does not persist.

### e8. An unknown template name refuses the **page**, not the document

Three candidate mechanisms; the third is proposed.

- **Refuse the document in `validated()`** (a typed `DocumentIndexError`). It
  gets the diction right — `DocumentIndex.swift:198-200` deliberately keeps
  refusals out of `init(from:)` so a newer file reads as newer rather than
  corrupt, and any template refusal must follow that — but the **scope is
  wrong**: an unknown *paper name* would make an entire notebook unopenable
  when nothing about its ink is at risk.
- **Read unknown as `blank` and refuse to rewrite the index.** Superficially
  the most contract-shaped option, and it **does not work here**: the index is
  rewritten whenever `currentPageIndex` changes, i.e. on every page turn, so
  "refuse to rewrite the index" is "refuse to turn a page". The notebook
  becomes read-only, which is a worse outcome than the first option and reaches
  it by a longer road.
- **Proposed: refuse the page.** `templateName` is stored raw, exactly as
  `LayerEnvelope.kind` is; `recognizedTemplate` returns `nil` rather than a
  default; `validated()` does **not** throw for it; the page joins the existing
  per-page refusal path (not editable, refusal tint, reason surfaced), the
  document opens, every other page opens normally, and the unknown string
  **round-trips verbatim** so nothing is lost and nothing is silently rewritten
  to `blank`.

The third is the contract's own philosophy applied at the level the value
actually lives: an unknown layer kind refuses its layer; an unknown paper name
refuses its page, because a page is where a template lives. It costs one
`DocumentIndexError` case, one raw string, and one branch in the existing
refusal path — no new mechanism.

---

## (f) Test plan

Per `CONTRIBUTING.md`, every new check must be able to fail for the reason it
names, and each is verified **by reverting the fix** — this repo's standing
practice (the EXIF swap, the refused-save guard).

**PDF**

- `PDFPageRasterizerTests` extension — `OpenPDFDocument` parses **once** for a
  `displaySize` + `rasterize` pair (count opens via an injected provider or an
  instrumented `Data`); the pixels are byte-identical to the current
  two-open path against the existing byte-exact fixtures. This is defect P1
  proven, and the byte-identity half is what keeps the refactor honest.
- `PDFLayerRenderTests` extension — a `sourcePageIndex` past the end refuses
  the whole composite with `pageOutOfRange`. The load path deliberately does
  not check this, so the render path is the only place it can be proven.
- Rotation, CropBox origin, y-flip: **already covered**; do not duplicate.
- If `.mappedIfSafe` is taken: `DocumentStoreTests` — bytes are identical, and
  a render **after the asset is deleted** still completes (the inode-semantics
  claim in §b2, asserted rather than believed).

**Templates**

- `PageTemplateDurableTests` — round-trip through `DocumentIndex`; a record
  written without a template decodes `blank` and is written forward on the next
  index write; an **unknown** name decodes without throwing, refuses its page,
  leaves the document openable, and **round-trips verbatim** through a save
  triggered by another page's edit; `setTemplate` writes the index and **no
  page file**, asserted by mtime *and* bytes, as the phase-3a exit test does.
  Note for whoever writes it: any golden-byte assertion over `document.plist`
  will see the new keys, so those fixtures move in the same commit.
- `PaperTemplateRenderTests` — pixel assertions on a small synthetic page for
  each member: `blank` leaves the context byte-identical to today's composite,
  `lined` marks exactly the expected rows and nothing between, `grid` rows and
  columns, `dotted` intersections only. Absolute spacing proven by rendering
  the same template into 612×792 and 842×595 and asserting the **same** spacing
  in points.
- `StaticLayerRenderTests` extension — template draws **beneath** an image
  (a pixel where the image covers a rule shows image); two requests differing
  only in template are two cache entries and the second is never served the
  first's texture; a `.blank` template with no layers still returns `.empty`
  and allocates no context.
- **`StaticLayerRendererCacheTests` — the eviction fix, and this is the test
  revision 1 would have shipped without.** A templated layer-less page's
  composite **survives** a `retain` naming it live, and is dropped when it is
  not. Written against the pre-fix code it fails on the first assertion, which
  is precisely the bug at `:671`.
- `LensTests` extension — a templated blank page at `base × 2` returns a
  composited lens rather than `.empty` (the `:408` guard), and its rules are
  one pixel wide at the settled scale rather than two — the existing stripe-
  fixture technique.
- `PageCanvasControllerTests` extension — a `.blank`, layer-less page builds no
  backdrop and keeps `isOpaque == true`; a templated layer-less page builds one
  and goes transparent; `setTemplate` on a live page bumps the composite
  generation, hides the lens, and re-requests (the §c1 delivery path, which has
  no other observable); no composite or lens is requested from any gesture
  frame.
- `EditorSessionTests` extension — `appendPage` uses `defaultPageTemplate` and
  **not** the current page's; a template chosen on a withheld trailing page does
  not persist, because the page does not (§e7, asserted so the behaviour is
  pinned rather than merely stated).
- `ContractStructureTests` — `PageTemplate` lives in a Foundation-only module;
  `PaperTemplateRenderer` imports CoreGraphics and not UIKit.

**Owed to a device, not obtainable from CI** — record in `Unproven.md`, do not
claim: whether the ruling reads as paper rather than as a screenshot of paper;
rule contrast under live ink; whether the soft-base→sharp-lens swap on a ruled
page is visible as a flash; lens latency on a dense textbook (spike 2 is still
scaffolded-but-unthreaded and owes a number).

---

## (g) Ordered implementation sequence

Each step is one commit, green on its own; none is a shim for the next.

**Truth-in-docs first, because everything downstream reasons from these files**

1. Rewrite `Unproven.md:180-192` (rasterization landed; the unit-square payload
   is decided **by evidence**, keeping the genuinely unproven half) **and**
   `PDFSource.swift:179-183`'s "Neither integration exists yet". *No behaviour
   change.*
2. Adopt A5 + A13 into `Contract.md` — Phillip's edit, tagged `CONTRACT:` — so
   the contract stops saying `ink` is the only kind.

**PDF: kill the double parse**

3. `OpenPDFDocument`; `render` and `renderLens` open once per call; the free
   `PDFPageRasterizer` functions are replaced, not kept alongside. Byte-identity
   tests against the existing fixtures.
4. *(Optional, gated on Phillip)* `.mappedIfSafe` + A18 staged + the
   delete-under-mapping test. Skippable without blocking anything.

**Templates: durable first, as every feature here was sequenced**

5. `PageTemplate`; `PageRecord.templateName`/`recognizedTemplate`;
   `DocumentIndex.defaultPageTemplate`; `newDocument(…template:)`;
   `EditorSession.setTemplate`; `appendPage` reads the document default; the
   unknown-name page refusal. `PageTemplateDurableTests`. Nothing renders yet.
6. Stage A16 and A17 in `Contract.proposed.md`. *No `Contract.md` edit.*

**The cache fix, before anything depends on it**

7. `StaticLayerRequest.pageID`, `CompositeKey.pageID`,
   `retain(pageIDs:protecting:)`, and the session's simplified
   `retainRenderedLayers`. `StaticLayerRendererCacheTests`. Independently
   valuable and correct with or without templates.

**Templates: rendering half**

8. `PaperTemplateRenderer` as a pure function plus its pixel tests, wired to
   nothing. Testable in complete isolation.
9. `StaticLayerRequest.template` + `CompositeKey.template` + the call in
   `render`; the `composite`/`warm` empty short-circuits and
   `StaticLayerRender.empty`'s doc comment (§c4).
10. The same call in `renderLens`, **including its own `:408` guard**, and the
    lens-worthwhile guard at `PageCanvasController:963`.
11. Delivery: `PagedCanvasSession.template(forPageAt:)`,
    `PageCanvasController.setTemplate`, the backdrop install/remove condition,
    both opacity sites, and `EditorSession.warmNeighbourComposites`'s guard —
    the rest of §c4. Blank pages provably still pay nothing.

**Last**

12. Minimal UI: a template picker for the current page in the editor chrome,
    and a template choice in the library's new-document flow. Two controls, no
    custom spacing, no marketplace.
13. `ImplementationStatus.md` gains a row; `Unproven.md` gains the device
    verdicts owed for templates.

**Explicitly out of scope**, each a sentence rather than a stub: custom
spacing, colour, or margins; template thumbnails (a durable one violates
*Forbidden patterns*); templated library thumbnails (§e10); dark-mode
inversion; undoable template changes (§e6); and making `pdf` layers selectable,
which is what today's axis-aligned lens assumption rests on.
