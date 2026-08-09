# Proposal: PDF rasterization, one paper template, and the deletion of every backward-compatibility shim

Status: proposal, **revision 3**. Revision 1 proposed two unsound mechanisms.
Revision 2 replaced them and was sound, but built a **per-page** template
system. Phillip's three constraints, given after reading it, collapse roughly
half of that revision and open a cleanup it could not have proposed:

1. **A page is a PDF or it is paper, never both.** Mutual exclusion, enforced
   as a render rule (§c4).
2. **The template is the same across all pages.** It is a property of the
   *document*, not of a page (§b3).
3. **No live users exist; any schema may change.** Therefore every
   backward-compatibility path in this codebase is dead code, and this
   proposal deletes all five of them and resets the format version to 1 (§d).

**What revision 3 changes, in one place, so a reader of revision 2 need not
diff it:**

- `PageRecord` is **untouched**. No `templateName`, no `recognizedTemplate`,
  no hand-written `init(from:)`. All 22 sites that build a `PageRecord` are
  unchanged.
- `defaultPageTemplate` and the per-page template **merge into one field**,
  `DocumentIndex.template`. There is no inheritance rule, so §e7 of revision 2
  — appended pages, inserted pages, the withheld trailing page — is deleted
  entire, and `appendPage`, `insertPage`, and `importPDF` take **zero diff**.
- §e8's three-way argument about unknown template names collapses to one
  refusal in `validated()`, at document scope, beside `invalidZoomCap`.
- `PagedCanvasSession` gains **nothing**. Delivery is a telling on
  `PagedCanvasController`, the mechanism `setShapeTool` already is.
- The template is **not** in `CompositeKey`, and that is now correct rather
  than sloppy — see §c3. Revision 2's edge case 9 (cache thrash on a template
  change) ceases to exist.
- Templates no longer render beneath a `pdf` layer. Revision 2 argued for
  beneath-everything on the strength of letterbox bands; **those bands cannot
  exist** (§c4 proves it from `fittingSource`), so the argument was defending a
  picture nobody can see.
- **New: §d, the shim deletion.** Five of them, with every call site.

Nothing here is a rule; contract amendments are proposed as exact edits for
Phillip to author.

---

## 0. Correction to the brief's premise

**PDF rasterization is already built, wired, and pixel-tested.** The claim that
"nothing rasterizes a PDF page anywhere in the build" comes from
`Docs/Unproven.md:180-192`, which is **stale**.

- `Modules/TuberRender/PDFSource.swift:184-338` — `PDFPageRasterizer`:
  `rasterize(_:sourcePageIndex:pixelsPerPagePoint:subRect:)` is `async` and
  `nonisolated`; `displaySize(of:sourcePageIndex:)` is synchronous and
  throwing (`:195`). CropBox→MediaBox fallback with non-zero origin,
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

**Three doc claims are stale, not one.** `PDFPageRasterizer`'s own comment
(`PDFSource.swift:179-183`) still says "Neither integration exists yet — this
type answers the question and stops". And `EditorSession.importPDF`'s comment
(`:1985-1986`) still says "No UI calls this yet", which
`LibraryCoordinator.importAndOpenDocument` (`:168`) has falsified — + New →
Import reaches it. All three are fixed by step 1.

Part 2 (templates) is genuinely greenfield: a `grep` over `Modules` and
`TuberNotesApp` for template/lined/dotted/grid finds only an unrelated spike
grid and `LibraryStore.ViewMode.grid`.

---

## (a) Current-state inventory, precisely

**Durable side.** A page is `PageRecord { id, geometry }` in `document.plist`
(`DocumentIndex.swift:30-40`), plus a page file listing layer IDs, with layers
split into `layers/` (A14). A layer is `LayerEnvelope { layerID, kind: String,
payload, pageSpaceTransform, locked }`. Kinds are `ink | image | pdf`
(`LayerEnvelope.swift:187-194`) — `Docs/Contract.md` still says "The only kind
is `ink`", because A5 and A13 are staged and unadopted, so **the contract
already lags the code by two kinds**.

**Import.** `EditorSession.importPDF` (`:1988-1532`): `PDFSource.pages`
off-main → refuse any source page smaller than
`PageProjection.smallestDisplayablePagePoints(zoomCapPagePointsPerPixel:)` →
write the asset **once** → one `PageRecord` per source page whose geometry *is*
the source's display size → one `pdf` envelope per page with
`.fittingSource(...)` → index rewrite → immediate `saveIfNeeded()`.

**Render, base.** `PageCanvasController.requestCompositeIfNeeded` computes
`compositeDetail(viewportWidth:displayScale:geometry:)` (`:915-931`), quantized
to 1/100, requested at layout, at a layer-list change, and at a selection
change — **never in a gesture frame**. `StaticLayerRenderer.composite(for:)`
(actor) checks an LRU cache keyed by `CompositeKey{ layerIDs, scaleMilli,
widthMilli, heightMilli }`, with a full `request` equality check on hit, joins
an in-flight render only on whole-request equality, otherwise spawns
`Task { Self.render(...) }`. `render` is `nonisolated`, so pixels are built on
the global executor; `pthread_main_np()` is sampled and surfaced as
`StaticComposite.builtOffMain` (`:792-805`). Every layer decodes before
anything draws; any failure refuses the **whole** composite.
`PageBackdrop.show(_:)` assigns `page.contents` — the pipeline's only
main-thread step. The canvas goes `isOpaque = false` only on pages that
actually have static layers (`PageCanvasController.swift:816`).

**Render, lens.** At settle, if `lensScale > baseScale × 1.25`, no selection is
active, and the page has static layers, the visible rect is clamped to the page
and `StaticLayerRenderer.lens(for:visibleRect:)` builds a *viewport-sized*
context on the caller's own task (no dedup, no cache, cancellation inherited).
`pdf` layers rasterize only the visible sub-rect at the settled scale. `image`
layers are capped at `lensImageMaxPixelSize = 2800` — a known, documented gap.

**Cache.** Owner = the actor; bound = 96 MB (an unmeasured estimate);
eviction = `retain(layerIDs:protecting:)` as *policy*, LRU byte-bound trim as
*backstop*. Refusals are cached at zero bytes. Lens and lift renders are
deliberately not cached.

**Selection/lift.** `pdf` layers are **not selectable**
(`LayerEnvelope.isSelectable` is `recognizedKind == .image`), which is what lets
the lens assume a `pdf` transform is axis-aligned and refuse otherwise.

**Library thumbnails.** `LibraryThumbnailStore` composites ink over paper only —
static layers are explicitly out of scope (`:18-27`, `:268-277`).

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
- Paging and layout read `PageRecord.geometry`, which for an imported page
  already *is* the source's point size. A payload field would be a third copy.

**Action: update `Unproven.md` to record the decision as settled by evidence**,
keeping the half that is genuinely unproven (no wild CropBox/`/Rotate` PDF has
been imported; no device evidence; no latency number).

What the field was a proxy for is real, and is fixed directly.

**Defect P1 — the source document is parsed twice per pdf layer per render.**
`displaySize` builds a `CGDataProvider` + `CGPDFDocument`
(`PDFSource.swift:195-223`) and `rasterize` builds them again from the same
`Data` (`:261`). Every composite, every lens, and every prefetch warm pays two
full document opens per pdf layer.

**Fix: a per-render open handle, not a cache.** Revision 1 proposed
`actor PDFDocumentCache`. That does not work and would not have compiled:

- `SWIFT_VERSION: "6.0"` (`project.yml:19`). `CGPDFDocument` and `CGPDFPage`
  are **not `Sendable`**, so an actor cannot vend them to the `nonisolated`
  render path.
- Keeping them inside and rasterizing there would put every composite, warm,
  and lens on **one actor executor** — precisely what
  `StaticLayerRenderer.swift:792-805` and `:403-407` are `nonisolated` to avoid.

A per-render handle has neither problem: created and destroyed inside one
`render` or `renderLens` call, on the global executor, never crossing an
isolation boundary, and it halves the parse cost.

**Cross-render caching is dropped entirely**, and that is a decision rather than
an omission: the prefetch radius is 3 and the live window is 3, so up to ~6
renders can be in flight across more distinct assets than any bound revision 1
could state, and the `retain(assetIDs:)` it needed would have meant decoding
`PDFLayerRef` payloads on `@MainActor` every turn. The residual cost after the
handle is **one parse per composite**, and `Unproven.md`'s "no numbers exist"
governs: measure on a device before adding a mechanism whose bound nobody can
state.

### b2. `.mappedIfSafe` — a real but contract-touching change, on its own

`DocumentStore.loadAsset` is `try Data(contentsOf: url)` with no options
(`DocumentStore.swift:109-111`), so a 50 MB import is a 50 MB read and a
resident copy per composite, per lens, per warm.

- **Safety is fine.** Reclamation deletes by path and `writeAsset` is
  atomic-by-rename, so POSIX inode semantics keep a mapping valid across a
  delete; there is no truncation-under-a-mapping path in this store.
- **The contract is not fine.** The read stops happening in `DocumentStore` and
  starts happening as page faults inside `drawPDFPage` on the render executor.
  Golden rule 4 says `DocumentStore` is the only thing that touches files, and
  `StaticLayerRenderer.swift:20-23` asserts exactly that about itself.

So it is proposed as a **separate, optional step gated on Phillip**, with the
amendment it needs (A18, §e). The "50 MB stops being dirty memory" claim is
**unmeasured** and withdrawn; what is certain is only that the pages become
file-backed and therefore reclaimable by the OS.

### b3. The template is one durable value on the document

**Not a layer kind.** The decisive argument is not the one revision 2 led with.
Revision 2 said a layer buys an error taxonomy a procedural pattern cannot use;
that is weak, and in one respect backwards — a refused layer already refuses its
whole page (`EditorSession.swift:618`), which is close to the behaviour a
template refusal wants. It also said a layer would put one on every blank page
and cost the `.empty` path; that is simply wrong, because a `blank` template
would add no layer and a `lined` page needs a composite under either design.

The argument that actually decides it is **which file the value lives in**:

- Layers live in the **page file**. Page files are read lazily, one at a time,
  because reading them all is the whole-document read the format exists to
  prevent (`DocumentIndex.swift:6-26`).
- `EditorSession.warmNeighbourComposites` (`:735-757`) builds composites for the
  prefetch window **from what the index knows**, before those pages' files are
  read. A template in the page file means either warming with the wrong paper
  and re-rendering on arrival, or reading page files ahead of the window.

This is the same argument that put per-page geometry in the index. Two smaller
ones fall out of it: a `LayerEnvelope` carries a `pageSpaceTransform` that a
template would leave meaningless and writable-wrong — the "field a shipped kind
does not read" pattern *Forbidden patterns* bans; and setting a layer clears
`neverWritten`, so choosing paper on an overshoot page would make that page
durable, which is exactly what the withholding rule exists to prevent.

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

**Home: one field on `DocumentIndex`.** Phillip's constraint — the template is
the same across all pages — means there is no per-page value at all. This is
not a "default for new pages" beside a per-page override; it is the only place
the value lives, read by every page of the document.

What it costs, honestly: one index rewrite per template change. That is a new
write trigger and a **contract change** (A16, §e), and it is small — a discrete
user action writing one small file, at a frequency far below the page turns
that already rewrite the index for `currentPageIndex`.

**Unknown name refuses the document**, in `validated()`, beside
`invalidZoomCap`. Revision 2 rejected document-scope refusal because "an unknown
*paper name* would make an entire notebook unopenable when nothing about its ink
is at risk". That objection was correct for a *per-page* value and does not
survive the move: the template now describes the whole document, so refusing the
whole document is the honest scope rather than an over-reaction. It costs one
error case and no new mechanism, and with no users in the field it can never
fire on anything but a fixture.

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

A consequence worth stating: because the lens **re-strokes** the ruling rather
than resampling a raster of it, ruled paper is genuinely resolution-independent
at any zoom. That is a property a pre-rendered paper image could not have, and
it is the second reason (after per-page geometry, §f4) that the template is
procedural.

### c1. Delivery: the runtime holds it, exactly as it holds the shape tool

Revision 2 put a `template(forPage:)` question on `PagedCanvasSession`. With one
value per document that is the wrong shape: it is not a per-page fact to be
asked for, it is one setting to be told.

`PagedCanvasController` already does this for the active shape tool
(`:217` stores it, `:416` fans it out to live pages, `:848` applies it to every
page built afterwards). Templates use that mechanism verbatim:

- `PagedCanvasController.setTemplate(_:)` — sibling of `setShapeTool`. Stores,
  fans out to live pages, and `makeCanvas` applies the stored value to a page
  entering the window.
- `PageCanvasController.setTemplate(_:)` — sibling of `setStaticLayers`
  (`:641-672`) — is a no-op when unchanged; otherwise it nils `renderedRequest`,
  bumps `compositeGeneration`, cancels `compositeTask`, calls
  `invalidateLens()`, installs or removes the backdrop per the new emptiness
  rule, and calls `requestCompositeIfNeeded()`.
- `EditorSession.performStart` pushes the loaded value once, beside
  `pages.setPages(...)`.
- **`PagedCanvasSession` is unchanged**, and so is `PageProjection` — nothing
  about a template is a construction-time fact.

### c2. Owner-table rows

| State | Sole writer | Frequency | Lifetime |
|---|---|---|---|
| The document's paper template | `EditorSession` (in the index) | user action | app session → saved |
| The template the runtime applies to new pages | `PagedCanvasController` (told) | user action | app session |
| The rendered template pixels | `StaticLayerRenderer` (inside the composite/lens texture) | layout / layer edit / template change / settle | render-cache entry |

`EditorSession` (`@MainActor`) owns the durable value and puts it in the
request; `StaticLayerRenderer` (actor) owns cache admission and dedup; `render`
and `renderLens` are `nonisolated` → global executor, and that is where template
paths are stroked; `PageBackdrop` on main does one `contents` assignment and is
**otherwise unchanged**. Nothing about templates touches disk.

### c3. The cache: page-scoped eviction, and why the template stays out of the key

**The eviction bug is real and independent of everything else here.**
`retain(layerIDs:)` drops entries where `entry.layerIDs.isDisjoint(with: live)`
(`StaticLayerRenderer.swift:671`), and **the empty set is disjoint with every
set**, so a layer-less page's composite is evicted on every turn — including
while it is the page on screen. The trim's protection has the same hole
(`:758`). Today nothing can trigger it, because today every cached composite has
at least one layer. A templated blank page ends that.

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
}

package func retain(pageIDs live: Set<UUID>, protecting visible: Set<UUID>)
```

This is strictly a simplification, and it pays for itself three ways: eviction
becomes a single-UUID test instead of a set-disjointness test over layer IDs;
`Entry.layerIDs` is replaced by one `pageID`;
and `EditorSession.retainRenderedLayers` (`:704-717`) stops building a union of
every live page's layer IDs each turn.

It costs one claim in the renderer's own doc comment (`:166-168`): "Layer IDs
are unique within a page … so this needs no page identity". That claim was
**only true while every cached composite had at least one layer**, which
templates end. `PageCanvasController` is told its page ID at construction — it
remains blind to page *numbers* and *turns*, which is what golden rule 7
actually says; being told a UUID is telling, not asking.

**The template is deliberately not in the key.** With one value per document
there is never an adjacent page on different paper, so two composites of one
page differing only in template can never both be wanted. Leaving it out means a
template change **overwrites** the superseded entry in place — `remember`
already does `cachedBytes -= existing.byteCount; cache[key] = …` — while the
existing full-request equality check on hit (`:221`) guarantees the stale one is
never served, and the in-flight join's whole-request check (`:228`) guarantees a
render issued before the change is never joined by one issued after. Revision 2
had to key on it because adjacent pages could differ, and logged the orphaned
entry as edge case 9. **That edge case does not exist here.**

The 96 MB byte bound and the LRU backstop are unchanged: a template adds vector
strokes to a context that already exists, so byte cost per entry is unchanged.

### c4. A page is a PDF or it is paper — enforced at the render, not on disk

Phillip's rule. Three candidate homes; the second is proposed.

- **A durable invariant.** `DocumentIndex.validated()` cannot check it: the
  template is in the index and layers are in page files, read lazily and much
  later. The check would have to live in `EditorSession` after a page's file
  lands, and its only available punishment is the existing per-page refusal path
  (`:618`) — an **uneditable page**. That converts a cosmetic disagreement into
  lost access to that page's ink. Refused.
- **Proposed: a render rule.** `StaticLayerRequest.effectiveTemplate` returns
  `.blank` when any layer in the request is `pdf`, and the two draw sites read
  it. Never both, by construction; no durable invariant to enforce; no state
  that can make a page unopenable. The picker disables on a PDF page. If a `pdf`
  layer is ever deleted, the document's paper is underneath it — which is the
  behaviour Phillip chose, and which follows for free because nothing ever
  overwrote the durable value.
- **An import rule** (revision 2's, which forced `.blank` at import). Weakest:
  a convention guaranteed by nothing, and it would have made a deleted PDF leave
  a blank page in a lined notebook.

**Revision 2's argument for beneath-everything was defending an impossible
picture.** It claimed a template shows in the letterbox bands of a partially
covering `pdf` layer. There are no bands: `fittingSource` is
`scale = min(pageWidth / width, pageHeight / height)`
(`LayerEnvelope.swift:168`), and `importPDF` sets the page's geometry to exactly
the source's size (`EditorSession.swift:2036`), so `scale` is exactly 1, `tx`
and `ty` are 0, and an imported PDF covers its page edge to edge **always**. No
code path in this build produces a partially covering `pdf` layer.

**The suppression is local, and provably so.** It bites only when a `pdf` layer
exists — that is, only when the layer list is non-empty. So every "does this
page need a backdrop / a lens / a warm" guard may read the raw template and be
correct either way, because `!layers.isEmpty || template != .blank` is already
true by its first disjunct in exactly the case suppression applies. Only two
sites need the resolved value: the draw call in `render`, and the draw call in
`renderLens`.

### c5. Every empty short-circuit that must change (complete inventory)

A templated blank page has **no layers and is not empty**. Revision 1 named two
of these; there are seven, plus two opacity sites.

| Site | Today | Becomes |
|---|---|---|
| `StaticLayerRenderer.composite` `:214` | `guard !request.layers.isEmpty else { return .empty }` | `layers.isEmpty && template == .blank` |
| `StaticLayerRenderer.warm` `:344` | same guard | same change |
| `StaticLayerRenderer.renderLens` `:408` | same guard | same change — **without it, a templated blank page returns `.empty` from every lens** |
| `StaticLayerRender.empty`'s doc `:1092-1094` | "it is every page in a blank notebook" | every page with no layers **and** blank paper |
| `EditorSession.warmNeighbourComposites` `:746` | `!pageStates[pageIndex].staticLayers.isEmpty` | `|| template != .blank` |
| `PageCanvasController.setStaticLayers` `:652` | `guard !layers.isEmpty` → removes backdrop, `isOpaque = true` | the tear-down path must be conditioned on the template too, or setting layers to empty rips the paper off a templated page |
| `PageCanvasController.requestLensIfNeeded` `:963` | `!staticLayers.isEmpty` | `|| template != .blank` |

Plus the two opacity sites (`:663`, `:816`): the canvas goes transparent when
`!staticLayers.isEmpty || template != .blank`. A genuinely blank page keeps its
opaque canvas and pays nothing — the property `Unproven.md:151-157` cares about,
preserved deliberately.

### c6. Softness under zoom, and the dark-mode hook

Identical to `pdf`, and already shipped: base at `compositeDetail`;
compositor-scaled during the gesture (`magnificationFilter = .linear`); at
settle, if `lensScale > base × 1.25`, a viewport-sized lens re-**strokes** the
rules at the settled scale. No new mechanism.

**Dark mode: structural hook only, no field now.** Template colours are renderer
constants. When dark mode arrives it is one `appearance` term in
`StaticLayerRequest` and one more field in `CompositeKey`, invalidated on a
trait change. **Do not add the field now** — an unread `appearance` field is the
placeholder *Forbidden patterns* bans. What this proposal guarantees is that the
shape admits it: the template is a *name*, resolved to pixels by code at render
time, never a stored colour.

---

## (d) The shims, and their deletion

Phillip's third constraint — no live users, any schema may change — makes every
backward-compatibility path in this codebase **unreachable except from its own
test fixtures**. There are five. They are well written and were correct when
written; what they now cost is that every future change to the durable format
must keep a form nobody can produce still working.

This is the project's own standard applied to itself. `EditorSession.swift:944`,
on deleting a serializing task chain: *"code whose absence nothing can detect
does not ship."* Nothing can detect the absence of any of these.

**The pattern is not deleted with the instances.** Read-both-forms /
write-forward-on-next-save / never-migrate-eagerly is how this project will
handle its first real migration, and it stays stated in `Contract.md` — as a
rule for the future rather than as a description of five live code paths. The
doc comments that cite "phase 1's precedent" are reworded, not removed.

Landing them **before** the template work is deliberate: C1 rewrites
`DocumentIndex.init(from:)`, and the template's new field should land in a
decoder that has one form to read rather than two.

### C1. `DocumentIndex` — the version-2 read path

`Modules/TuberModel/DocumentIndex.swift`. Delete:

- `supersededFormatVersion` (`:110`)
- `CodingKeys.pageIDs`, `.pageWidth`, `.pageHeight` (`:157-163`)
- the whole `if onDisk == Self.supersededFormatVersion { … }` branch (`:172-195`)
- `wasReadInSupersededForm` — field, doc comment, `init` parameter
  (`:96-104`, `:141`, `:148`)
- the "Two forms are read; exactly one is written" table (`:53-74`), replaced by
  one sentence

`currentFormatVersion` becomes **1**. Not 4: with one form read and one form
written and no file in the field, the version number's only remaining job is to
refuse a *newer* file loudly, and starting that count at 1 says what is true.

**`formatVersion` itself stays, and so does `unsupportedFormatVersion`.** That
is forward compatibility — a file from a future build refusing to open with the
right diction — and it is not a shim. Nothing in this section touches it.

Tests deleted: `DocumentIndexTests.legacyIndexReadsForward` (`:41`),
`legacyGeometryIsCarriedNotCorrected` (`:76`), the `!decoded.wasReadInSupersededForm`
assertion (`:34`); `DocumentStoreTests`'s write-forward pair (`:208-233`,
`:243-244`) and its `writeLegacyIndex` fixture (`:328`).

### C2. `DocumentStore` — the index write-forward machinery

`Modules/TuberStore/DocumentStore.swift`. Delete `indexOnDiskIsSupersededForm`
entire: the field and its doc (`:33-44`), the assignment and log at load
(`:340-347`), the `|| indexOnDiskIsSupersededForm` term in `indexNeedsWriting`
(`:725`), and the clear at `:740`. Nothing else reads it.

### C3. `PageFile` — the pre-split and pre-layer forms

`Modules/TuberStore/PageFile.swift`. Two superseded forms are read: envelopes
inline (phases 1–2) and bare `drawingData` (before phase 1). Delete:

- `inlineLayers` and its doc (`:45-53`)
- `private init(pageID:inlineLayers:)` (`:62-66`)
- `CodingKeys` (`:68-78`), the hand-written `init(from:)` (`:80-116`), and
  `encode(to:)` (`:118-122`)

With both branches gone, `layerIDs` is a required decode and **both halves of
`Codable` synthesize**. `PageFile` becomes two stored properties and one
initializer.

Cascade in `DocumentStore`:

- `deleteAssetIfUnreferenced` — delete the pre-split page-file scan (`:172-181`);
  the `layers/` scan below it is the whole sweep
- `layers(of:)` — delete `if let inline = page.inlineLayers { return inline }`
  (`:425`)
- `plan` — delete `isAlreadySplit` (`:790-793`). Delete the
  `$0.inlineLayers != nil ||` term from `pageFileNeedsWriting` (`:811`).
  **Correction, found in implementation:** this section first said
  `layersToWrite` "becomes unconditionally the caller's changed set". That is
  not a semantics-preserving deletion and would have shipped a durability bug.
  `isAlreadySplit` was `existing.map { $0.inlineLayers == nil } ?? false`, and
  the `?? false` carried a live, non-shim case — **a page with no file on disk
  yet**, which must write all of its layers because none of them has a file to
  be unchanged. Written as this section originally described it, 16 tests fail
  with `danglingLayerRef` on the first save of an imported page. The correct
  reading is `existing == nil ? write.layers : filter(changed)`
- `refuseIfThisWriteWouldDropAnUnrewritableLayer` — delete the
  `if let inline = existing.inlineLayers` branch (`:864-869`)

Tests: `LayerEnvelopeTests`'s legacy suite is deleted —
`legacyPageFileDecodesAsAOneInkLayerPage` (`:43`), the inline-envelope
assertions (`:52-77`), the write-forward pair (`:95-108`), 
`legacyPageFileLoadsThroughTheStore` (`:113`), `:133-153`, and the
`LegacyPageFile` fixture with `writeLegacyPageFile` (`:421-447`).
`DocumentIndexTests:141`'s `decoded.inlineLayers == nil` goes with it.

**Two of them are kept and retargeted, not deleted.**
`corruptLegacyPageFileThrows` (`:168`) and `corruptLegacyPageRefusesInk`
(`:190`) put a page file on disk that carries neither `layers` nor
`drawingData`. After C3 such a file carries no `layerIDs` either, so it still
throws and the page still refuses ink — the behaviour survives the shim, and so
should its test. The fixture (`writeCorruptLegacyPageFile`, `:452`) is renamed
to say what it now writes: a page file with no layer list.

### C4. `LayerEnvelope` — `locked` absent decodes unlocked

`Modules/TuberModel/LayerEnvelope.swift:300` is
`decodeIfPresent(Bool.self, forKey: .locked) ?? false`, for envelopes written
before `locked` existed. Make it a required `decode`.

The envelope has exactly five stored properties (`:212-231`) and exactly five
`CodingKeys`, and the hand-written `init(from:)` (`:292-301`) is field-for-field
the synthesized one once that default is gone. So delete `init(from:)` **and**
the explicit `CodingKeys` (`:266-285`) — whose own doc comment says it is
spelled out only *because* the initializer is hand-written. Nothing outside the
type names either.

`kind` stays a raw `String`. That is not a shim: it is how an unknown layer kind
from a newer build refuses its layer instead of failing the whole page's decode.

### C5. `LibraryStore` — adopting the pre-library document

`Modules/TuberStore/LibraryStore.swift:651-668`,
`adoptLegacyDocumentIfPresent`, moves a single `JustACanvas.tubernotes` from
beside the library root into `Documents/` on the first root listing. Its own
comment ends: *"Deletable the day it stops mattering."* With no users, that day
is today. Delete the function and its call site (`:170`).

Tests: `LibraryStoreTests.adoptionIsIdempotent` (`:552-561`), the planted source
in the suite's setup (`:53`), and the suite doc's adoption sentence (`:12`).
`TestScratch`'s use of the name `JustACanvas.tubernotes` for its own document
directory (`:34`, `:61`) is incidental and stays.

### What is deliberately **not** deleted

- **`DocumentIndexError.unsupportedFormatVersion` and the `formatVersion` field**
  — forward compatibility, not backward. A newer file must refuse loudly.
- **`LayerEnvelope.kind` as a raw string, and `recognizedKind` returning `nil`**
  — the same, one level down, and the mechanism an unknown *layer kind* uses.
- **`DocumentStore`'s refusal to overwrite a page file it cannot decode** — that
  is a durability guard, not a compatibility path.
- **The write-forward *rule* in `Contract.md`** — reworded to be about the next
  migration rather than about five current ones, but kept. Deleting the rule
  because its instances are gone would be deleting the reason they were right.

---

## (e) Required `CONTRACT:` amendments — exact proposed edits

Stage as **A16–A19** in `Docs/Contract.proposed.md` (next free numbers; L1–L5
are the library lane). Do not write them into `Contract.md` — no agent authors
a rule.

**Prerequisite, not new:** adopt A5 and A13 first, or `Contract.md`'s "The only
kind is `ink`" contradicts three shipped kinds.

---

**A16. *Durable form* — a document carries a paper template — AHEAD**

Replace, in *Durable form*:

> `document.plist` holds the format version, `documentID`, page geometry, an
> ordered list of page IDs, and the current page index.

with:

> `document.plist` holds the format version, `documentID`, an ordered list of
> page records — each a page ID and that page's geometry — the current page
> index, the document's zoom cap, and the document's paper template.

Replace:

> - **A save writes only what changed.** One changed page writes one page file,
>   and the index is rewritten only if page order or the current index changed.

with:

> - **A save writes only what changed.** One changed page writes one page file,
>   and the index is rewritten only if page order, the current index, or the
>   document's paper template changed.

Add to the bulleted rules:

> - **A document's paper template is a name from a closed set** — `blank`,
>   `lined`, `grid`, `dotted` — stored once in the index and applying to every
>   page of that document. It is a name and nothing more: no spacing, colour,
>   margin, or measurement is durable, because a template is drawn procedurally
>   from constants the build owns, and a stored measurement would be a second
>   authority for one picture. Adding a member is a `CONTRACT:` amendment,
>   exactly as adding a layer kind is.
> - **A template is not a layer.** It has no envelope, no payload, no asset, and
>   no position in any page's layer list; it cannot be selected, transformed,
>   locked, or reclaimed. It is drawn beneath every layer of every page, and it
>   is the document's, never a page's.
> - **A page is a PDF or it is paper, never both.** A page carrying a `pdf`
>   layer draws no template. This is a rule about the picture and not about the
>   file: the document's template stays exactly as written, so removing the
>   `pdf` layer reveals the paper the document already said it had. There is no
>   durable state in which a page is both, because a page's paper was never
>   durable in the first place.
> - **An index naming a template this build does not know refuses the
>   document**, exactly as an unhonourable zoom cap does. The scope is the
>   document because the value is the document's; a page is never refused for
>   paper.

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

**A19. *Durable form* — one form is read, one form is written — FORCED by §d**

Delete, from *Durable form*:

> - The pre-layer page form (bare drawing bytes) is read as a one-ink-layer page
>   and written forward on the page's next save, never migrated eagerly.

and replace it with the rule stated forward rather than as a description of a
live path:

> - **This build reads exactly the form it writes.** No superseded on-disk form
>   is read by any code path, and the format version starts at 1. That is a
>   statement about today and not a policy: the first durable format change made
>   after a document exists outside this repository must follow the
>   read-both-forms rule — read the old form, write the new one on the next save
>   that would have written anyway, never migrate eagerly — and must say in
>   `Contract.md` which two forms are live and when the older one may be
>   dropped. A compatibility path with no file in the world to read is dead
>   code, and dead code on the durability path is a maintenance cost paid
>   forever against a risk that does not exist.

*Also relevant and not this proposal's job:* `Contract.md`'s "Geometry fields
are finite page points greater than zero, with `pageWidth < pageHeight`" is
already false in code (landscape imports). That is A8.

---

## (f) Swift API surface sketches (signatures, not implementations)

```swift
// Modules/TuberModel/PageTemplate.swift  (new; Foundation only)

/// The closed set of paper templates. A name and nothing more: spacing and
/// colour are rendering constants, never durable.
package enum PageTemplate: String, Codable, Sendable, Equatable, CaseIterable {
    case blank, lined, grid, dotted
}

// Modules/TuberModel/DocumentIndex.swift  (edited)
// PageRecord is UNCHANGED. A design claim, not an omission.

package struct DocumentIndex: Codable, Sendable, Equatable {
    // …existing, minus `wasReadInSupersededForm` (C1)…
    /// The paper every page of this document is ruled with.
    package let template: PageTemplate
    package static let currentFormatVersion: UInt32 = 1        // was 3 (C1)
    package static func newDocument(documentID: UUID, pageID: UUID,
                                    template: PageTemplate = .blank) -> DocumentIndex
    package func withTemplate(_ template: PageTemplate) -> DocumentIndex
}

package enum DocumentIndexError: Error, Equatable {
    // …existing…
    /// The index names a paper template this build does not know. Refuses the
    /// document, for the reason an unhonourable zoom cap does — see §b3.
    case unknownTemplate(String)
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

// Modules/TuberRender/StaticLayerRenderer.swift  (edited — see §c3, §c4, §c5)

package struct StaticLayerRequest: Sendable, Equatable {
    let pageID: UUID
    let layers: [LayerEnvelope]
    let geometry: PageGeometry
    /// The document's template, as written. Never resolved here — see below.
    let template: PageTemplate
    package let pixelsPerPagePoint: Double

    /// What actually gets drawn: `.blank` whenever a `pdf` layer is present,
    /// because a page is a PDF or it is paper (A16). The one place that rule
    /// lives, read by `render` and `renderLens` and by nothing else.
    var effectiveTemplate: PageTemplate {
        layers.contains { $0.recognizedKind == .pdf } ? .blank : template
    }

    package init(pageID: UUID, layers: [LayerEnvelope], geometry: PageGeometry,
                 template: PageTemplate, pixelsPerPagePoint: Double)
}
package func retain(pageIDs: Set<UUID>, protecting visible: Set<UUID>)

// Modules/TuberCanvas/PagedCanvasController.swift  (edited — the delivery seam)

/// Sibling of `setShapeTool`: stored, fanned out to live pages, and applied by
/// `makeCanvas` to every page built afterwards. `PagedCanvasSession` gains
/// nothing — one document-wide setting is told, never asked.
package func setTemplate(_ template: PageTemplate)

// Modules/TuberCanvas/PageCanvasController.swift  (edited)
func setTemplate(_ template: PageTemplate)

// Modules/TuberCanvas/PagedCanvasSession.swift — UNCHANGED.
// Modules/TuberCanvas/PageBackdrop.swift — UNCHANGED. The template arrives as
// pixels inside the composite and the lens.

// TuberNotesApp/EditorSession.swift  (edited)
var template: PageTemplate                                 // read by the picker
func setTemplate(_ template: PageTemplate) async throws
// One writer (the index). Rewrites the index only — no page file, and so no
// interaction with the withheld trailing run.
// `appendPage`, `insertPage`, and `importPDF` are UNCHANGED.

// Modules/TuberStore/DocumentStore.swift  (optional, §b2 + A18)
package func loadAsset(assetID: UUID, format: AssetFormat) throws -> Data
// body: try Data(contentsOf: assetURL(assetID, format), options: .mappedIfSafe)
```

---

## (g) Edge cases

### PDF (existing behaviour, verified by reading; each already decided)

| Case | Handling | Where |
|---|---|---|
| CropBox smaller than MediaBox | CropBox wins; MediaBox only on null/empty | `PDFSource.swift:137-138` |
| CropBox with non-zero origin | Cancelled by the final `translateBy(-box.minX, -box.minY)` in y-up space | `:326` |
| `/Rotate` 90/180/270 | Applied to the extent and the CTM; import fits the *displayed* extent | `:123-128`, `:313-325` |
| `/Rotate` not a multiple of 90 | `displayGeometry` → `nil` → `unreadableSourcePage` → the **whole** import refuses | `:141` |
| `sourcePageIndex` out of range | Not checked at load (that means opening every asset); refused at render as `pageOutOfRange` | `:214-216` |
| Sub-rect past the page edge | `rasterOutsidePage`, with 0.001 float-dust tolerance; the caller clamps first | `:266-271`, `PageCanvasController:988` |
| Zero-pixel target / context failure | `rasterUnavailable` → composite refused whole | `:275-291` |
| A raster fails mid-composite | **The entire composite is refused** — refusal tint, logged reason, never a blank page | `StaticLayerRenderer.swift:900-904` |
| Non-axis-aligned pdf transform in the lens | Refused rather than approximated; the soft base stays and stays correct | `StaticLayerRenderer.swift:500-505` |
| Missing asset | `RefusedLayer.Reason.missingAsset`, `isReconstructable == true`, so deleting the layer remains the repair | `LayerEnvelope.swift:403, 415-420` |
| Mixed geometry in one document | Per-page geometry, per-page zoom floor, one shared cap; the key carries width/height | `:173-189` |
| Source page too small for the zoom cap | Refused **at import**, before a byte is written | `EditorSession.swift:2011-2017` |

### Templates (new; each decided here)

1. **A page carrying a `pdf` layer** — draws no template (§c4). The durable
   value is untouched, so deleting the layer reveals the document's paper. This
   is Phillip's rule and the reason revision 2's edge cases 1 and 2 are gone.
2. **A page shorter than one rule spacing** — draws zero or one rule. Not
   clamped and not special-cased; absolute spacing means a small page has few
   rules. (`smallestDisplayablePagePoints` is ~103 pt at the canonical cap, so
   at 24 pt ruling the floor is ~4 rules.)
3. **Non-integral page size** — the last rule lands where it lands; the template
   is never stretched to fit, which would make spacing depend on page size
   (A17 forbids it).
4. **Mixed geometry in one document** — one template, absolute spacing, so a
   landscape page gets more columns and fewer rows at *the same* spacing as the
   portrait page beside it. This is the case A17 exists for, and it is reachable
   today: an imported worksheet sits next to a canonical appended page.
5. **Template changed on a document with ink** — permitted; ink is untouched.
   One index write, one composite invalidation per live page, no page-file
   write. **Not undoable**: like turning and appending, it is not a PencilKit
   stroke edit (*Undo*: "There is no interception and no semantic undo domain").
   Flagged as a judgment call worth Phillip's verdict — GoodNotes does make it
   undoable.
6. **Template changed while a layer is selected** — the lift machinery owns the
   picture, and `setTemplate` calls `invalidateLens()` and re-requests exactly
   as `setStaticLayers` does. The minus-one composite gains the new paper on the
   same swap; no frame shows old paper under a lifted layer.
7. **An unknown template name** — refuses the document, in `validated()` (§b3).
8. **A withheld trailing page** — unaffected, and this is the point. The
   template is in the index, not on a page record, so choosing paper while
   standing on a page that will not persist neither persists that page nor loses
   the choice. Revision 2 had to argue this at length (§e7) and accept a
   surprising behaviour; here there is nothing to argue.
9. **Library thumbnails ignore templates** — `LibraryThumbnailStore` renders ink
   over paper and excludes static composites by design (`:18-27`, `:268-277`),
   so a templated page thumbnails as blank paper, exactly as a PDF-backed page
   already does. **Out of scope**, and named here so it is a decision rather
   than a surprise: fixing it means giving the thumbnail path a static
   composite, which is the per-cell decode that path was explicitly built to
   avoid.

---

## (h) Test plan

Per `CONTRIBUTING.md`, every new check must be able to fail for the reason it
names, and each is verified **by reverting the fix** — this repo's standing
practice (the EXIF swap, the refused-save guard).

**PDF**

- `PDFPageRasterizerTests` extension — `OpenPDFDocument` parses **once** for a
  `displaySize` + `rasterize` pair (count opens via an injected provider or an
  instrumented `Data`); the pixels are byte-identical to the current two-open
  path against the existing byte-exact fixtures. This is defect P1 proven, and
  the byte-identity half is what keeps the refactor honest.
- `PDFLayerRenderTests` extension — a `sourcePageIndex` past the end refuses the
  whole composite with `pageOutOfRange`. The load path deliberately does not
  check this, so the render path is the only place it can be proven.
- Rotation, CropBox origin, y-flip: **already covered**; do not duplicate.
- If `.mappedIfSafe` is taken: `DocumentStoreTests` — bytes are identical, and a
  render **after the asset is deleted** still completes.

**The shim deletion (§d)**

The tests here are mostly *deletions*, and a deletion proves nothing by itself.
What must be positively asserted is that the surviving path is total:

- `DocumentStoreTests` — a document saved and reopened round-trips at
  `formatVersion == 1`; an index carrying **any** other version refuses with
  `unsupportedFormatVersion` naming the number found. The second half is what
  keeps C1 from being read as "version checking was deleted".
- `LayerEnvelopeTests` — a page file with no `layerIDs` throws, and its page
  refuses ink (the two retargeted tests, §C3). An envelope with no `locked` key
  now **fails to decode**, asserted rather than assumed, because that is exactly
  the behaviour C4 changes.
- `LibraryStoreTests` — the first root listing of a container holding a stray
  `JustACanvas.tubernotes` **leaves it alone**. The inverse of the deleted
  adoption test, and it is what says the deletion was intended rather than
  dropped.
- Nothing asserts golden bytes over `document.plist` — checked, and it is why
  C1's key changes break no fixture.

**Templates**

- `PageTemplateDurableTests` — round-trip through `DocumentIndex`; an index
  written without a template decodes `blank`; an **unknown** name refuses the
  document with `unknownTemplate` naming it; `setTemplate` writes the index and
  **no page file**, asserted by mtime *and* bytes, as the phase-3a exit test
  does; and a template chosen while the last page is a withheld trailing page
  survives a close and reopen (edge case 8, pinned rather than merely stated).
- `PaperTemplateRenderTests` — pixel assertions on a small synthetic page for
  each member: `blank` leaves the context byte-identical to today's composite,
  `lined` marks exactly the expected rows and nothing between, `grid` rows and
  columns, `dotted` intersections only. Absolute spacing proven by rendering the
  same template into 612×792 and 842×595 and asserting the **same** spacing in
  points.
- `StaticLayerRenderTests` extension — a template draws **beneath** an image (a
  pixel where the image covers a rule shows image); a `.blank` template with no
  layers still returns `.empty` and allocates no context; **a page carrying a
  `pdf` layer renders byte-identically under `.lined` and under `.blank`**,
  which is §c4's rule in the only form a test can hold, and which fails the
  moment `effectiveTemplate` stops being consulted.
- **`StaticLayerRendererCacheTests` — the eviction fix.** A templated layer-less
  page's composite **survives** a `retain` naming it live, and is dropped when
  it is not. Written against the pre-fix code it fails on the first assertion,
  which is precisely the bug at `:671`. Plus: a template change **replaces** the
  cached entry rather than adding one, which is §c3's reason for keeping the
  template out of the key and fails if it is put back in.
- `LensTests` extension — a templated blank page at `base × 2` returns a
  composited lens rather than `.empty` (the `:408` guard), and its rules are one
  pixel wide at the settled scale rather than two — the existing stripe-fixture
  technique.
- `PageCanvasControllerTests` extension — a `.blank`, layer-less page builds no
  backdrop and keeps `isOpaque == true`; a templated layer-less page builds one
  and goes transparent; `setTemplate` on a live page bumps the composite
  generation, hides the lens, and re-requests; no composite or lens is requested
  from any gesture frame.
- `PagedCanvasControllerTests` extension — a page entering the live window
  **after** a template change is built with the new template, not the one the
  runtime started with. That is the `makeCanvas` half of §c1, and it has no
  other observable.
- `EditorSessionTests` extension — `appendPage` and `insertPage` produce pages
  that render at the document's template with **no diff to either function**,
  and `warmNeighbourComposites` warms a templated layer-less neighbour.
- `ContractStructureTests` — `PageTemplate` lives in a Foundation-only module;
  `PaperTemplateRenderer` imports CoreGraphics and not UIKit.

**Owed to a device, not obtainable from CI** — record in `Unproven.md`, do not
claim: whether the ruling reads as paper rather than as a screenshot of paper;
rule contrast under live ink; whether the soft-base→sharp-lens swap on a ruled
page is visible as a flash; lens latency on a dense textbook (spike 2 is still
scaffolded-but-unthreaded and owes a number).

---

## (i) Ordered implementation sequence

Each step is one commit, green on its own; none is a shim for the next.

**Truth-in-docs first, because everything downstream reasons from these files**

1. Rewrite `Unproven.md:173-192` (rasterization landed; the unit-square payload
   is decided **by evidence**, keeping the genuinely unproven half),
   `PDFSource.swift:179-183`'s "Neither integration exists yet", and
   `EditorSession.swift:1985-1986`'s "No UI calls this yet". *No behaviour
   change.*
2. **[Phillip]** Adopt A5 + A13 into `Contract.md`, tagged `CONTRACT:` — so the
   contract stops saying `ink` is the only kind.

**PDF: kill the double parse**

3. `OpenPDFDocument`; `render` and `renderLens` open once per call; the free
   `PDFPageRasterizer` functions are replaced, not kept alongside. Byte-identity
   tests against the existing fixtures.
4. *(Optional, gated on Phillip)* `.mappedIfSafe` + A18 staged + the
   delete-under-mapping test. Skippable without blocking anything.

**The shims, before the durable work that would otherwise have to preserve them**

5. C1 + C2 — the index's version-2 read path and its write-forward machinery;
   `currentFormatVersion` to 1.
6. C3 — `PageFile`'s two superseded forms and the four `DocumentStore` sites
   that read them; two corrupt-file tests retargeted.
7. C4 + C5 — `locked` becomes a required key and `LayerEnvelope`'s `Codable`
   synthesizes; the pre-library document adoption goes.
8. Stage A16, A17, and A19 in `Contract.proposed.md`. *No `Contract.md` edit.*

**Templates: durable first, as every feature here was sequenced**

9. `PageTemplate`; `DocumentIndex.template`; `newDocument(…template:)`;
   `withTemplate`; the unknown-name refusal; `EditorSession.setTemplate` and its
   `template` getter. `PageTemplateDurableTests`. Nothing renders yet.

**The cache fix, before anything depends on it**

10. `StaticLayerRequest.pageID`, `CompositeKey.pageID`,
    `retain(pageIDs:protecting:)`, and the session's simplified
    `retainRenderedLayers`. `StaticLayerRendererCacheTests`. Independently
    valuable and correct with or without templates.

**Templates: rendering half**

11. `PaperTemplateRenderer` as a pure function plus its pixel tests, wired to
    nothing. Testable in complete isolation.
12. `StaticLayerRequest.template` + `effectiveTemplate` + the call in `render`;
    the `composite`/`warm` empty short-circuits and `StaticLayerRender.empty`'s
    doc comment (§c5).
13. The same call in `renderLens`, **including its own `:408` guard**, and the
    lens-worthwhile guard at `PageCanvasController:963`.
14. Delivery: `PagedCanvasController.setTemplate` and its `makeCanvas`
    application, `PageCanvasController.setTemplate`, the backdrop install/remove
    condition, both opacity sites, `EditorSession.warmNeighbourComposites`'s
    guard, and the push from `performStart` — the rest of §c5. Blank pages
    provably still pay nothing.

**Last**

15. Minimal UI: one template picker for the document, in the editor chrome,
    disabled on a page carrying a `pdf` layer. One control, no custom spacing,
    no per-page override, no marketplace.
16. `ImplementationStatus.md` gains a row; `Unproven.md` gains the device
    verdicts owed for templates.

Fourteen commits of agent work; steps 2 and 4 are Phillip's.

**The boring cost, stated so it is not a surprise in review:** 46 sites
construct a `StaticLayerRequest`, across `EditorSession`, `PageCanvasController`,
and five test files. Every one gains two arguments at step 10 and step 12. None
becomes harder to read; the diff is simply larger than the idea.

**Explicitly out of scope**, each a sentence rather than a stub: custom spacing,
colour, or margins; per-page template overrides (Phillip's constraint, and the
thing that made revision 2 twice this size); template thumbnails (a durable one
violates *Forbidden patterns*); templated library thumbnails (§g9); dark-mode
inversion; undoable template changes (§g5); and making `pdf` layers selectable,
which is what today's axis-aligned lens assumption rests on.
