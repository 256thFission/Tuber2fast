# Canvas feature complete

Status: proposal, revision 2 — supersedes the first draft after adversarial
review. Not an active contract.  
Scope: an extensible page layer model carrying efficiently placed images and
PDF/image background layers for annotation, plus tool-drawn shapes as snapped
ink. Design direction and sequencing only — no implementation, no prescribed
types.

## Purpose

`Just a Canvas` proves blank pages. [`PDFAndImages.md`](PDFAndImages.md)
records the full first-class vision — semantic highlights, OCR, search,
annotation export. This proposal names the deliberately smaller milestone
between them: the point at which the *canvas itself* is feature complete. A
page can carry a background you annotate, objects you place and move, and
shapes you draw. Everything semantic stays in the fork doc — but the layer
model built here is the one that vision will inherit, so it is extensible
from the first commit.

What changed in revision 2, so the deltas are auditable: shapes are snapped
ink, not a layer kind, and SVG leaves the milestone with them; the mirrored
sibling is the presumed rendering answer and the inside-`PKCanvasView` branch
must overcome a recorded crash; render caches hold only immutable asset
renders and live outside the document package; unknown kinds refuse the
layer, not the document; layer-edit undo and gesture arbitration are named
as first-class problems with their own spike and amendment; the launch
snapshot and whole-document cache warming are cut; the normalization flag is
gated on a zoom-cap amendment; and layer files split from the page file at
phase 3, not phase 1.

## The page is an ordered list of layers

The document model already contains the shape to copy. A document is an
ordered list of page IDs, one authority per page's content. Feature complete
applies the same rule one level down:

**A page is to its layers what a document is to its pages.**

A layer is one durable envelope, uniform across kinds:

```text
{ layerID, kind, payload, pageSpaceTransform }
```

Kinds at this milestone: `ink`, `image`, `pdf`. Layer order *is* z-order,
with one pin: **the page's single `ink` layer is always last** — ink renders
above every static layer. That pin is what keeps "everything below the ink
is static" true by construction rather than by luck (see *Rendering*), and
it is what a note-taking app means anyway: your notes are never buried under
a sticker. Lifting the pin is a future amendment, priced when a kind that
belongs above ink (a text comment, a signature) actually exists. There is no
separate "background" concept: a worksheet is a `pdf` layer that happens to
sit first.

Two uniformity rules stated now so the envelope does not lie:

- **The `ink` layer's `pageSpaceTransform` is identity, always.** Ink is
  authored in page space (*Geometry and coordinates*); a transform on the
  ink layer would be a second way to position ink and would have to
  transform the live `PKCanvasView` itself, colliding with its scroll and
  zoom ownership. The field is present because the envelope is uniform and
  constrained because ink is special; an ink layer loaded with a
  non-identity transform is an invalid state.
- **A `pdf` or `image` layer is selectable; selection is how "replace the
  worksheet" has a UI path at all.** What a kind refuses is *drawing*
  input, not addressability. A layer may additionally be locked against
  transforms — a worksheet you annotate should not drift under a stray
  drag — and locked is a bit on the envelope, not a property of the kind.

### Extensible is not speculative

The contract forbids undefined placeholder fields for future features, and
this design must not smuggle them in through the back door:

- The envelope is uniform; the set of kinds is **closed**. Adding a kind
  is a new case plus a `CONTRACT:` amendment — cheap by construction, but
  explicit, every time.
- No generic metadata bag, no opaque extension payload, no plugin
  registry. The extensibility is the *shape* of the model, not a slot.
- **An unknown kind on load refuses the layer, not the document.** The
  first draft failed the whole document loud; the failure taxonomy's own
  classifier overrules that — correct code produces this state, because
  the ad hoc fleet runs mixed builds by design, so it is a typed error,
  not a trap. The layer renders as a refusal with a sentence, the page
  refuses input while it carries one, and the other two hundred pages of
  ink open normally. Loud, at the scope that is actually invalid. The
  exact wording belongs to `failure-has-a-taxonomy`; the *scope* is
  decided here. There is still no preserve-and-ignore path: a refused
  layer is never silently dropped, rewritten, or carried blind through a
  save.

## One value, one writer — generalized, not multiplied

Golden rule 5 today: a page with a live canvas has exactly one authority,
that canvas; without one, the session may hold an immutable value, which
is custody rather than a second copy. The layer model restates that rule
once, about layers, and every kind inherits it:

**A layer's content has exactly one authority: its live controller, if one
exists; otherwise the immutable value in the session's custody. The layer
*list* — order, membership — has one writer, `EditorSession`, exactly as
page order does today.**

| State | Sole writer | Frequency | Lifetime |
|---|---|---|---|
| A page's layer list (order, membership) | `EditorSession` | user action | app session → saved |
| Live ink layer (`PKDrawing`) | `PKCanvasView` in `PageCanvasController` | Pencil/input | canvas session |
| A layer's transform-in-progress, selection | `PageCanvasController` | frame/input | canvas session |
| Committed layer values, held layer bytes | `EditorSession` (custody) | edit/save | app session |
| Asset files | `DocumentStore` (import path) | import | across launches |
| Decoded tiles / downsampled images | canvas runtime cache | render | live window |

The ink pattern repeats without modification: a transform gesture is
frame-frequency state owned by the canvas controller; at gesture end the
controller hands the session one immutable committed layer value, which
follows the ordinary save path. SwiftUI never mirrors a layer list, an
in-progress transform, or a decoded image, for the same reasons it never
mirrors a `PKDrawing`. Most kinds never have a live controller at all — a
`pdf` layer is born static and stays static; only `ink` (always) and a
layer under manipulation (briefly) are ever live.

### Lifecycles are per shape of kind, not one machine for all

`page-ink-has-one-state`'s machine — `loading | unreadable | clean | live |
held | saving` — is ink's lifecycle, and this milestone still depends on it
landing first, because ink-as-a-layer inherits it unchanged. But it is
**not** every kind's lifecycle: a static asset layer is never `live`,
`held`, or `saving` — its payload is immutable and only its envelope
changes. Forcing static kinds through an ink-shaped machine is the same
uniformity trap the envelope rules above refuse. Two machines, each fitting
its problem:

```text
mutable kind  (ink):          loading | unreadable | clean | live | held | saving
static kind   (pdf, image):   loading | refused(reason) | ready(assetRef)
```

**A page is editable exactly when its ink layer is editable and no layer is
`refused` or `unreadable`.** That sentence is the aggregation function the
first draft left undefined, stated so the next
`unloaded-page-is-not-a-canvas`-class hole has nowhere to live: a page with
a refused layer takes no input, and says why, in the placeholder style that
item establishes.

One deliberate bound survives generalization: **a page has exactly one
`ink` layer.** The live-canvas count is bounded per page in the live
window; ink layers multiplying per page would multiply canvases inside
that bound. Lifting this is a future amendment, not a today cost.

## Undo crosses the layer boundary, and the contract must say how

The first draft never said the word "undo," and the contract as written
forbids the obvious implementation: *Undo* gives PencilKit's live manager
sole ownership and bans a semantic undo domain. A moved image that cannot
be un-moved is not feature complete — a mis-drag destroys layout with no
recourse — so phase 4 cannot land without an amendment, and the shape of
that amendment is a design decision, not a detail:

**One undo manager per page, the responder chain's, with two clients.**
PencilKit registers stroke undo with the canvas's `undoManager` exactly as
today. A committed layer edit registers its inverse (the prior envelope
value) with the *same* manager, through the session, exactly once per
commit. One manager means one Cmd-Z stream and correct interleaving for
free; "no interception" survives — nothing wraps or filters PencilKit's
registrations; "no semantic undo domain" is amended to "no *second*
manager." Undoing a layer edit re-emits the prior committed value through
the ordinary save path. Saving never clears undo, as today. Turning and
appending stay navigation, not editing.

The risk to spike, named honestly: PencilKit's manager is the responder
chain's and dies with the page controller, so layer-edit undo has the same
per-page lifetime stroke undo has today — acceptable, because it is the
*existing* behavior, but it must be verified that PencilKit tolerates
foreign registrations in its manager rather than assuming it. That check
is part of the phase 4 device spike below.

## Durable form — the same rules, recursive

```text
Notebook.tubernotes/
  document.plist                    ordered page IDs, current index
  pages/<pageID>.plist              ordered layer IDs, geometry, inline envelopes (phases 1–2)
  layers/<layerID>.plist            one envelope per file (from phase 3)
  assets/<assetID>.<ext>            original imported bytes: .pdf, .png, .jpeg
```

Every existing durable-form rule restates one level down, stated once and
applied at both levels:

- **A save writes only what changed**, at the finest granularity the form
  currently has. Phases 1–2 fold layer envelopes into the page file: one
  mutable kind exists, so per-layer files would add a directory level to
  prove a property nothing can yet observe. **Phase 3 splits envelopes
  into `layers/`** — the moment a 50 MB import makes "ink on page 4
  writes one small file, never the pdf envelope, never the asset"
  a testable claim rather than a slogan. The split is when the property
  becomes observable, and its exit test is the observation.
- **Write order is leaf-to-root, load-bearing as before:** assets, then
  layer files, then page files, then the index. An interrupted save
  leaves orphans at some level and never a dangling ref at any. Deletion
  is the mirror, root-to-leaf: the page file drops the ref first, the
  layer file dies second, so an interruption leaves an inert orphan,
  never a dangling ref.
- **A dangling ref is fatal; an orphan is inert** — page→layer and
  layer→asset, same as document→page today.
- **Assets are sources, write-once, immutable.** "Replace the worksheet"
  is a new asset and a layer edit, never mutation.
- **Asset reclamation:** when the last layer referencing an asset is
  deleted, the asset is deleted with it — three lines at the one site
  that deletes layers. Crash orphans (an import whose layer file never
  landed) accumulate until a sweep-on-open lands, gated behind
  `failure-has-a-taxonomy`, because a sweep that deletes the wrong file
  is a durability failure and needs the taxonomy to say what it does
  when unsure. Until then an orphan is inert and merely heavy.
- Heavy bytes live behind refs (`assetID` + source page index + invertible
  source-to-page transform for `pdf`/`image`); `ink` payloads are inline,
  as ink is today.

### Render caches — a deliberate amendment, narrowed to what cannot lie

The contract bans durable derived artifacts to prevent a second source of
truth. This milestone amends the ban rather than tiptoeing around it, and
revision 2 narrows the amendment to make the safety argument airtight:
**a derived artifact that anything reads for truth is still banned; a
disposable render derived from an immutable asset is allowed — and only
from an immutable asset.** Because assets are write-once, an asset-derived
render can be missing but can never be *stale*: there is no edit that
could invalidate it. The class of cache that shows plausible wrong pixels
is excluded by construction, not by an invalidation scheme.

Two consequences of the narrowing:

- **The per-page composite launch snapshot is cut.** It compiled ink into
  a durable raster, which either restates the ink (rewritten every
  autosave, stale the moment it isn't) or omits it (a cold open shows the
  worksheet *without your notes* — for an ink app, the worst possible
  first frame). Cold open shows the placeholder tint until ink and base
  hydrate, exactly as blank pages do today. If launch feel demands more,
  a snapshot keyed by ink content hash is the future flag, priced then.
- **The cache lives in the app's Caches container, keyed by
  `documentID`, not inside the document package.** The `.tubernotes`
  package is what gets copied, AirDropped, and backed up; shipping
  disposable renders inside it inflates every copy, and the OS purges
  the Caches container under pressure for free — a stronger version of
  "deletable at will" than any directory we manage. Nothing in `pages/`
  or `layers/` may reference it; a document is complete without it.

Entries are keyed by `(assetID, sourcePage, levelOfDetail)`, write-once.
Corruption or absence is a cache miss, never a failure. **Import warms the
prefetch radius, not the document** — the first draft's whole-document
warm loses to its own LRU on any import larger than the byte budget, so
the warming rule and the prefetch rule are now the same rule. A miss
renders on demand, off the import path, never blocking anything.

The disk cache carries the same three declarations every cache does —
owner (`DocumentStore`), bound (a byte budget), eviction (LRU on the
budget, beneath the OS's own purge) — because a disk cache that grows
forever is the same failure as a memory cache that does.

## Geometry amendment

Per-page geometry, set at page creation, immutable afterward. A blank page
gets the canonical size; an imported page gets its source's size in page
points. `pageWidth < pageHeight` is dropped — landscape sources exist.
Everything else stands: the page does not grow, the zoom floor derives
from the fixed page, no owner mutates geometry after creation. Ink and
layer transforms are authored in page space; each asset-backed layer owns
the one invertible mapping from its source space.

Priced honestly, because the first draft waved past it: `PageGeometry` is
a global static today, consumed at canvas construction, and the paging
arithmetic assumes uniform screen-width slots. Per-page geometry threads a
geometry value through page construction and makes slot layout per-page.
And it is not an edge case: **swiping past the last page of an imported
PDF appends a blank canonical-geometry page** (decided), so a portrait
canonical page after a landscape worksheet is the *normal* state of any
annotated import. The plumbing lands in phase 3 with the first source
that needs it, not "later."

**One new durable constant this milestone must pin: the absolute zoom
cap**, in page points per pixel, as a document property. Today's cap is
`fitWidth × 8`, a function of the viewport — it changes with device,
rotation, and Split View, so nothing durable may be derived from it. The
normalization flag below is unsound without this pin, and the lens
arithmetic wants it anyway. Its own `CONTRACT:` amendment, listed below.

## Rendering, without breaking the frame path

`PKCanvasView` is a `UIScrollView` and already owns pan and zoom. The
layer stack renders beneath the ink inside the same scroll geometry, so
one transform drives the whole stack. `PageCanvasController` — the canvas
runtime — owns the compositing and the mirroring; frame-frequency work
living exactly where the contract says it must.

**The presumed structure is the mirrored sibling, and the burden of proof
is on the alternative.** The first draft presumed layer views could sit
inside `PKCanvasView` beneath its ink; this project's own code records why
that is the branch to distrust — adding a subview to `PKCanvasView` put it
into the scroll view's touch bookkeeping and crashed UIKit in
`_delayTouchesForEvent:` on the first Pencil stroke (the page boundary is
a `CALayer` for exactly this reason), and "beneath its ink" means
inserting into a private subview order that any iOS point release may
reshuffle. So: the stack is a sibling view under a transparent
`PKCanvasView`, mirrored by one transform assignment per scroll tick from
the canvas runtime's existing delegate callbacks — a single property set,
no allocation, no publication. The inside-`PKCanvasView` branch may still
be spiked, but it must survive a first stroke on device *and* explain the
recorded crash before it is allowed to win.

- **The static stack flattens to one texture.** The ink-last pin makes
  this true by construction: everything below the ink is static between
  edits, so `pdf + image` composite into one texture per page at the
  current level of detail. A ten-layer page costs the GPU what a
  one-layer page costs, and the layer list is a durable and editing
  structure, never a compositing structure. Re-compositing happens only
  on a layer edit, off-main.
- **Overdraw is ≥ 2×, said plainly.** For the stack to show through, the
  ink surface goes transparent, and a full-screen blend under the ink is
  the floor cost everywhere, forever — the first draft's "~1×" was
  arithmetic that ignored its own transparency requirement. The estimate:
  one blended full-screen layer at 120 Hz is routine for M-series iPads,
  and marking the composite opaque holds the total at 2×. It is an
  estimate; the zoom spike measures it, and the measurement is the claim.
- **Gesture start must not ghost.** A layer under manipulation is baked
  into the composite it is being lifted from; the "stack minus this
  layer" texture does not exist at grab time. The rule: selection —
  which precedes any drag — kicks off the minus-one recomposite off-main;
  until it lands, the moving layer renders live *over* the stale
  composite, an over-draw of one layer for a fraction of a second, never
  a double image in motion and never a wait. Fold-back on commit as
  before.
- **Sharpness comes from base + lens, on plain `CALayer.contents`.** The
  base is the page's composite at fit-width (from the cache when warm);
  when zoom settles deeper, the visible rect renders off-main into a
  second lens layer. At most two textures per page ever exist — the lens
  is viewport-sized at any zoom, and the pinned zoom cap bounds its
  detail. A late lens shows the scaled base — soft, never blank; a page
  with no base yet shows a placeholder tint, loudly distinguishable from
  blank.
- **The budget, in numbers, so the spike has something to contradict:** a
  fit-width base on a 13" iPad is roughly 2048 × 2700 × 4 ≈ 22 MB; three
  live pages of base plus one lens is ~90 MB of working set, *outside*
  the evictable cache budget, before ink. That is affordable and not
  free, and it is the number the device spike confirms or corrects — a
  project that wrote "no numbers exist" does not get to propose a
  renderer without one.

Two mechanisms are refused by name — and the refusals are honest about
their evidence grade. Both rest on field reports, not on a reproduction of
ours; by this project's own epistemics that is *asserted*, and a spike
that contradicts either reopens it:

- **`CATiledLayer`.** Invalidating one tile flashes the whole layer, a
  zoom level's cache cannot be invalidated, its background drawing races
  UIKit's, and the fixes on record are private API. Functionally frozen
  since ~2010 and disqualified at 120 Hz — on the record's word.
- **`PDFView` + `PDFPageOverlayViewProvider`.** Apple's sanctioned
  ink-over-PDF path, and an ownership inversion here: `PDFView` owns
  scrolling, zooming, and page layout — the exact seats
  `PagedCanvasController` and `PKCanvasView` hold in *Owners* — and the
  field reports (overlay touches eaten as scrolls, low-resolution
  overlays under zoom) are the symptoms of PencilKit living as a guest
  in someone else's scroll hierarchy. Right tool for a reader with light
  ink; wrong for an ink app with PDFs underneath. Cheap to spike if
  doubted; the inversion argument stands even if the reports don't.

If a device spike shows lens renders of dense vector pages arriving too
slowly, the named escape hatch is a pooled tile grid in the
PSPDFKit/Nutrient style — the lens split into N pooled rects on plain
layers. An evolution of this design, not a rewrite, and not built until
the spike demands it.

### Zoom and pan

This milestone has **no raster editing** — that is a future milestone —
and the resource story leans on it: every layer except ink is static
content during a gesture, and static content is what the compositor
moves for free. The main thread does no more per frame than it does
today on a blank page, plus one transform assignment for the mirror. The
costs land in three distinct moments:

- **During the gesture: compositor only.** A pan or pinch transforms
  already-rendered textures on the GPU. **No decode is ever triggered by
  a gesture frame.** A pinch shows the current texture scaled, slightly
  soft, exactly as every PDF viewer on iOS does.
- **At settle: background decode, then swap.** Sharper content renders
  off-main at the new scale — a lens render of the visible rect over the
  composite base — and the main thread commits a contents swap. Ink
  needs nothing; PencilKit re-renders at scale today.
- **At turn: prefetch.** The prefetch radius that holds neighbor pages'
  ink bytes extends to their background decodes, so a swipe lands on a
  rendered worksheet, not a placeholder. **After `turn-settles-once`
  lands, explicitly** — today "turn" fires at the midpoint of a drag,
  and extending prefetch to decodes before that fix means decode work
  triggered twice by an abandoned half-drag. That queue item is a direct
  dependency of this bullet, not just of the milestone in general.

Memory rules: **decode for the viewport, never for the source** — an
image past a size threshold renders through the same base-and-lens path
as a PDF, so deep zoom never materializes the full bitmap — and the
cache bound is stated **in bytes**, not pages. The
live-window-plus-prefetch rule is the eviction policy; the byte budget
is the bound; three pages of high-resolution decodes is not a bound in
the only unit that matters.

### The gesture problem, named as what it is

The first draft claimed "no second gesture system exists" and then shipped
select/move/scale/rotate inside the same milestone. Said honestly: **layer
manipulation is a third claimant in the drag arbitration that *Navigation*
spent a contract section settling for two.** Today `drawingPolicy =
.pencilOnly` means a finger drag pans or turns; phase 4 needs a finger
drag on a selected layer to move the layer instead — without stealing the
pan when nothing is selected, without breaking the turn at fit-width, and
without a recognizer forest of ours competing with two `UIScrollView`s.

The rule this proposal commits to, for the spike to break: **selection is
the mode switch.** With no selection, every touch behaves exactly as
today — zero new gesture cost on the blank-page path. A tap on a layer
(finger, on a selectable kind) selects it; while a selection exists, a
drag beginning on the selected layer is a transform, owned by the canvas
runtime, and a drag beginning elsewhere deselects and falls through to
the scroll system. Escape hatch if the fall-through fights UIKit: a
selection chrome view that owns its own recognizers, so arbitration is
by view hit-testing — UIKit's native competence — rather than by
recognizer delegates.

### Device spikes, now three

The verdicts are Phillip's, on device:

1. **Mirror fidelity:** does the sibling mirror hold registration with
   ink at 120 Hz through pinch, fling, and rubber-band — and does the
   inside-`PKCanvasView` branch survive a first stroke at all?
2. **Lens latency:** do lens renders of dense vector pages arrive fast
   enough during zoom over a textbook — the spike that decides whether
   the pooled tile grid gets built. This spike also produces the first
   real numbers against the memory budget above.
3. **Manipulation feel and undo:** does selection-as-mode-switch
   arbitrate cleanly against pan and turn, and does PencilKit's undo
   manager tolerate the session's layer-edit registrations. Runs at
   phase 4, not before.

### Experimental flag: import-time image normalization

Off by default, behind a build-time flag, and **gated on the zoom-cap
amendment** — without a durable, device-independent cap, "pixels beyond
the ceiling are unreachable forever" is false, and normalization would
destroy data against a limit that changes with the viewport. With the cap
pinned, the ceiling is `zoomCap × page-space size`, a document constant.
With the flag on, import downsamples to that ceiling and transcodes to
HEIC (hardware-decoded), so a 48-megapixel photo becomes a few megabytes
that decode in milliseconds. **PNG sources are exempt** — screenshots and
line art are the common case in a note app, and lossy transcode rings at
exactly their edges; they downsample but stay lossless.

The spend: import becomes lossy for photographs, and export can no longer
embed the pristine original — which is why it is a flag and not the rule
while this milestone's export story is still deferred. `pdf` assets are
**never** normalized under any flag: original PDF bytes are the entire
small-export story. If device evidence shows the un-normalized path
already meets the memory budget through viewport decoding alone, the
flag dies; if the flag wins decisively, promoting it to default is a
`CONTRACT:` amendment weakening the byte-for-byte asset rule for images,
authored then, not now.

## Shapes are snapped ink, and SVG leaves the milestone

Decided: shapes are drawn with a tool. That answer, followed to its end,
deletes the `shape` kind. A shape that lands as its own layer forfeits
every tool the user already has — the eraser cannot touch it, the lasso
cannot select it with the ink around it, undo needs the layer-edit path —
a seam GoodNotes does not have, bought for nothing this milestone ships.
**The shape tool commits snapped, idealized strokes into the page's ink
layer** — a rect is four clean `PKStroke`s — and inherits eraser, lasso,
stroke undo, the save path, and the renderer for free. The recognizer
question (tool-drawn today, post-hoc recognition via the Gestures fork
later) stays open and stays cheap: both produce strokes.

With the typed vector model gone, **SVG import/export leaves the
milestone** — its only consumer was the `shape` payload, and a declared
subset that fails loud on groups, transforms, and styles refuses
virtually every SVG in the wild anyway; it was a feature that mostly
emitted error messages. When a semantic shape kind earns its way in (the
fork doc's vision still names one), it arrives as a new kind plus its
`CONTRACT:` amendment — which is exactly what the closed-kind rule is
for — and SVG interchange arrives with a consumer attached.

## Sequencing — smallest change that proves each step

1. **Ink becomes a layer.** No new kinds, no visible change: today's
   page becomes a one-layer page whose envelope folds into the page
   file. What phase 1 proves — stated honestly, since fold-in means the
   *bytes on disk* barely change: the envelope round-trips, the ink
   machine from `page-ink-has-one-state` drops one level to layer scope
   unchanged, and the save path is layer-shaped even while page-granular.
2. **One `image` layer under the ink.** Import a single image as page
   background. Proves: the asset store, leaf-to-root write order,
   behind-ink rendering via the sibling mirror (spike 1), off-main
   decode, transparent-canvas overdraw on device.
3. **`pdf` layers, and the format earns its split.** Import a PDF; each
   source page becomes a page. `layers/` splits out of the page files
   here — the moment "annotating page 4 of a 50 MB import writes one
   small file" becomes testable, and its exit test is exactly that
   observation. Proves: base-and-lens (spike 2), prefetch decode
   warming, per-page geometry and mixed-geometry paging (the appended
   canonical blank after a landscape worksheet), source-space mapping.
4. **Transformable `image` layers.** Select, move, scale, rotate.
   Proves: selection-as-mode-switch (spike 3), the gesture→committed-
   value handoff, layer-edit undo through the shared manager, minus-one
   recompositing, layer order as z-order beneath the ink pin.
5. **The shape tool**, committing snapped strokes. No format change at
   all — which is the point of having decided it that way.

## Contract amendments this requires

Each lands as an exact edit for Phillip to author, tagged `CONTRACT:`:

- *Owners*: the layer-authority rule as the generalized golden rule 5,
  and the table rows above.
- *Undo*: one manager per page, two clients; layer edits register their
  inverse with the responder chain's manager through the session; "no
  semantic undo domain" becomes "no second manager."
- *Durable form*: `layers/` (from phase 3) and `assets/`, leaf-to-root
  writes and root-to-leaf deletes, dangling/orphan rules at both new
  levels, inline-then-split envelope granularity, the closed-kind rule
  with per-layer refusal of unknown kinds, the one-ink-layer and
  ink-last rules, the identity-transform rule for ink, delete-inline
  asset reclamation.
- *Geometry and coordinates*: per-page geometry at creation; the
  absolute zoom cap as a durable document constant; delete the sentence
  declaring PDF source coordinates and rotation nonexistent; admit layer
  transforms as durable page-space values.
- *Navigation*: selection as the third drag claimant and the
  selection-is-the-mode-switch rule.
- *Forbidden patterns*: the derived-artifact ban is amended, not
  skirted — an artifact anything reads for truth stays banned; a
  disposable render **derived from an immutable asset**, held outside
  the document package with a declared owner, byte bound, and eviction,
  is allowed. Imported originals are sources; no generic layer metadata
  bag. The normalization flag, if promoted, carries its own amendment
  weakening byte-for-byte assets for images only.

## Sequencing against the queue

Not before the durability queue drains. `page-ink-has-one-state` is the
direct dependency — its machine is the ink layer's lifecycle, built first
at page scope; phase 1 is its natural successor, touching the same code
with the machine fresh. `failure-has-a-taxonomy` decides the words a
refused layer and an unreadable asset say (their *scope* is decided
here). `turn-settles-once` specifically gates the prefetch-decode bullet:
extending prefetch to background decodes before turns settle once means
paying the decode twice per abandoned half-drag.

## What this milestone still refuses

Held for the full [`PDFAndImages.md`](PDFAndImages.md) vision, on
purpose: text-anchored highlights, text comments, OCR, search, PDF export
with real annotations, crop, a layer-reordering UI, signatures, a
semantic shape kind and SVG interchange, the launch composite snapshot,
and **raster editing** — painting on an image's pixels is its own
milestone, and its absence is what makes this one's zoom, pan, and save
guarantees clean. Each arrives later as a new kind or a new tool over the
same stack — that is what the extensibility bought — but none rides in on
this milestone. And as ever: no collaboration, sync, or AI abstractions
in the file format.

## Decisions taken (were open questions)

- **Mixed documents:** swiping past the last page of an imported PDF
  appends a blank canonical-geometry page. Consequence accepted: mixed
  geometry is the normal case, and its plumbing lands in phase 3.
- **Layer file granularity:** inline in the page file for phases 1–2,
  split to per-layer files at phase 3, where the property the split buys
  first becomes observable. The trade each way is recorded above.
- **Asset garbage collection:** delete-inline now (last ref deletes the
  asset); sweep-on-open later, gated behind `failure-has-a-taxonomy`;
  growth from crash orphans accepted until then. (No Swift memory
  concern exists here — this is file refcounting, not ARC.)
- **Shape authoring:** drawn with a tool, committed as snapped ink
  strokes; no `shape` kind this milestone; recognizer-vs-tool stays an
  open UX question that no longer touches the durable form.
