# The contract — proposed amendments

**This is not the contract.** `Contract.md` is. No agent authors a rule; this
file is a staging area written by an agent so Phillip can edit, cut, and adopt
in the morning. Nothing here is in force. Adopting an amendment means moving
its text into `Contract.md` in a commit tagged `CONTRACT:`.

Each amendment states: the section it edits, what is there now, the proposed
replacement, why, and **which phase forces it** — so anything whose phase has
not landed can be deferred without stalling the rest.

Status key: **LANDED** — already adopted by Phillip and in `Contract.md`.
**FORCED** — code implementing it is written and green tonight; the contract
now lags the code, which is the state this file exists to fix. **AHEAD** — no
code yet; adopt when its phase arrives.

> **One thing was un-adopted overnight, deliberately.** The phase 3b agent
> wrote A8 and A9 straight into `Contract.md` and tagged its commit
> `CONTRACT:`. Its code is kept; **its contract edit was reverted** and its
> text lives here with the rest. Two reasons: `Contract.md` says "no agent
> authors a rule, and no agent's output becomes a rule by having been
> committed," and the standing instruction for the night was to stage a
> parallel contract to adopt on waking. Every other lane staged; that one
> self-adopted, and consistency is worth more than one section being early.
> The consequence to know: `Contract.md` currently still says
> `pageWidth < pageHeight` while the code accepts landscape pages and has
> tests for them. **The contract lags the code in exactly the places this
> file lists**, which is the gap this file exists to close in one pass.

---

## A1. *Owners* — golden rule 5, generalized — **LANDED**

Adopted in `f6522bd`. Recorded here only so this file reads as the complete
amendment set:

> 5. A value's content has exactly one authority: its live controller, if one
> exists; otherwise the immutable value in the session's custody, which is
> custody rather than a second copy. A page with a live canvas has exactly one
> authority, that canvas. A page's layer *list* — order, membership — has one
> writer, `EditorSession`, exactly as page order does.

## A2. *Durable form* — the layer envelope — **LANDED**

Adopted in `f6522bd`: the page-file line in the directory diagram, and the
layer-envelope block replacing "A page file holds its own `pageID` and its
opaque drawing bytes". Phase 1's code implements exactly this text.

---

## A3. *Owners* — the state table gains its layer rows — **FORCED (phase 1, phase 2; one row below still AHEAD, per-row status inline)**

The table in *Owners* lists nine states and no layer state, so the layer list
and layer values are governed only by prose. Add these rows, which restate
existing rules one level down rather than introducing new owners:

| State | Sole writer | Frequency | Lifetime |
|---|---|---|---|
| A page's layer list (order, membership) | `EditorSession` | user action | app session → saved |
| Committed layer values, held layer bytes | `EditorSession` (custody) | edit/save | app session |
| Asset files | `DocumentStore` (import path) | import | across launches |

The first of the two rows below is now **FORCED (phase 4)** — selection and a
transform in progress live in `PageCanvasController`'s own
`LayerSelectionRuntime` and are checked by a structural test that fails if any
of it appears in `EditorSession`. The second is still **AHEAD**: nothing
decodes tiles, and the one decoded image phase 4 holds (the lifted layer) is
owned by `PageBackdrop` for the length of a selection rather than cached.

| State | Sole writer | Frequency | Lifetime |
|---|---|---|---|
| A layer's transform-in-progress, selection | `PageCanvasController` | frame/input | canvas session |
| Decoded tiles / downsampled images | canvas runtime cache | render | live window |

*Why:* the table is where this project settles ownership disputes; a state
that lives only in prose is the one that grows a second writer.

## A4. *Owners* — two lifecycles, not one — **FORCED (phase 2)**

Append after the paragraph beginning "Each page has exactly one ink state":

> That machine is **ink's** lifecycle, not every kind's. A static layer is
> never `live`, `held`, or `saving` — its payload is immutable and only its
> envelope changes. Two machines, each fitting its problem:
>
> ```text
> mutable kind  (ink):          loading | unreadable | clean | live | held | saving
> static kind   (image, pdf):   loading | refused(reason) | ready(assetRef)
> ```
>
> A page is editable exactly when its ink layer is editable and no layer is
> `refused` or `unreadable`.

*Why:* forcing a static asset through an ink-shaped machine invents states
that cannot occur and hides the one that can (refused). The editability
sentence is the aggregation function; without it, "which page takes input" is
undefined the moment a page holds more than ink. The last line already appears
in the adopted *Durable form* block — repeating it here in *Owners* is
deliberate, or cut one; Phillip's call which home is right.

## A5. *Durable form* — the kind set opens to `image` — **FORCED (phase 2)**

In the adopted block, replace:

> - **The set of kinds is closed.** The only kind is `ink`.

with:

> - **The set of kinds is closed.** The kinds are `ink` and `image`.

*Why:* the closed-kind rule's whole mechanism is that each new kind costs one
explicit amendment. This is that amendment being paid. `pdf` is **AHEAD** —
phase 3 pays for it separately, in its own commit, or the mechanism is a
formality.

## A6. *Durable form* — assets — **FORCED (phase 2, code is written and green)**

This is the implementing agent's exact text, not my earlier paraphrase — the
code implements *this*, so adopting anything else leaves the contract lying.

Extend the directory diagram:

```text
JustACanvas.tubernotes/
  document.plist          the index
  pages/<pageID>.plist    one file per page: its own pageID and its ordered layer envelopes, inline
  assets/<assetID>.<ext>  imported originals, byte for byte: .png, .jpeg
```

After the ink-transform bullet, insert:

> - **An `image` layer's payload is a ref, never bytes**: the `assetID` of an
>   asset in `assets/`, and that asset's format, which completes its file
>   name. Heavy bytes live behind refs; `ink` payloads stay inline. A format
>   outside the closed set refuses the layer, exactly as an unknown kind does.
> - **An `image` layer's `pageSpaceTransform` is a real durable value**: the
>   one invertible mapping from the image's own extent, taken as the unit
>   square with its origin at top-left, into page space. It is where the layer
>   is. The image's pixel size is **not** durable — the asset's own bytes state
>   it, and a second copy in the page file is a value that can disagree with
>   itself. A singular transform is an invalid state and fails loud.
> - **Assets are sources: write-once and immutable.** There is no update and
>   no overwrite. "Replace the worksheet" is a new asset and a layer edit,
>   never a mutation. Writing an `assetID` that exists is refused rather than
>   verified: verifying identity means reading the whole asset back to
>   authorize a write no correct caller makes, and write-once is what makes an
>   asset-derived render impossible to be stale rather than merely unlikely.

Replace the write-order bullet with:

> - **Write order is leaf-to-root: assets, then page files, then the index**,
>   so an interrupted save leaves an orphan at some level and never a dangling
>   ref at any. A save that names an asset which is not already durable is
>   refused before any write. **Deletion is the mirror, root-to-leaf**: the
>   page file drops the ref first, the asset dies second.

After "A dangling page ref is fatal; an orphan is not", insert:

> - **A dangling asset ref is fatal; an orphan asset is inert.** The failure is
>   the *layer's*: it is a typed refused state, the page refuses input while
>   carrying it, and every other page opens normally. Unlike a layer this build
>   cannot re-encode, such a page may still be written — deleting the broken
>   layer is the one repair, and deleting it is a save.
> - **Asset reclamation is delete-inline**: when the last layer referencing an
>   asset is deleted, the asset is deleted with it, at the one site that
>   deletes layers. Whether anything still references it is answered from the
>   page files on disk, so a failed page write cannot orphan a live asset. When
>   it cannot tell — a layer whose kind or payload this build cannot open might
>   reference anything — it reclaims nothing. Crash orphans accumulate until a
>   sweep-on-open lands; an orphan is inert and merely heavy.

*Why the two refusal classes differ, since this is the subtle part:* an
unknown **kind** blocks overwriting its page, because this build cannot
re-encode what it cannot read. A missing **asset** does not, because the
envelope is fully understood and only the file is gone — and deleting the
broken layer is the one available repair, which is itself a save. Refusing
that write would make such a page permanently unrepairable.

## A6b. *Geometry and coordinates* — the unit-square consequence — **FORCED (phase 2)**

**The fork doc's own amendment list misses this**, and the code needs it.
Replace:

> Rotation, crop, PDF source coordinates, normalized coordinates, and
> annotation anchors do not exist.

with:

> Crop, PDF source coordinates, and annotation anchors do not exist. An
> asset-backed layer's transform maps its source's unit square into page
> space, and may rotate; nothing else is authored in normalized coordinates,
> and no other space is normalized.

*Why, and the decision to overrule if you disagree:* the implementing agent
chose **not** to store the source's pixel size in the payload, mapping the
image's extent-as-unit-square into page space instead. Its reasoning: a
durable pixel size restates what the asset's bytes already say, would be
invalidated by the milestone's own downsample flag, and makes placement
resolution-dependent. The cost is precisely this sentence — it *is* a
normalized coordinate space, which the contract currently says does not exist.
The alternative (transform from source pixel space, size in the payload) means
the durable form cannot answer "where is this image on the page" without
opening a possibly-50 MB file, which hurts phase 4 hit-testing. **This is the
single most reversible-but-annoying-later call made overnight.**

## A7. *Forbidden patterns* — the derived-artifact ban, narrowed — **AHEAD (phase 3)**

**Not needed by phase 2's rendering half, which has landed without it.** The
render cache built there is in memory only: it states its owner, a bound in
bytes, and its eviction at its declaration, which the *Performance* section
already permits, and it writes nothing to disk. This amendment is required only
by the **on-disk** render cache, which is deliberately not built. Adopt it with
phase 3 or not at all.


Replace:

> - a durable derived artifact — a thumbnail, a checksum table, an asset
>   manifest. Nothing written to disk restates what the ink already says.

with:

> - a durable derived artifact **that anything reads for truth** — a checksum
>   table, an asset manifest, a thumbnail standing in for the page. Nothing
>   written to disk restates what the ink already says.
>
>   One exception, and its bounds are the whole safety argument: **a
>   disposable render derived from an immutable asset** is allowed. Because
>   assets are write-once, such a render can be missing but can never be
>   stale — there is no edit that could invalidate it — so the class of cache
>   that shows plausible wrong pixels is excluded by construction rather than
>   by an invalidation scheme. It must live **outside the document package**,
>   in the app's Caches container keyed by `documentID`, so that copying,
>   AirDropping, or backing up a document never carries it; nothing in
>   `pages/` may reference it; a document is complete without it; and it
>   states an owner, a byte bound, and an eviction rule like any other cache.
>   A render derived from anything mutable — ink, a composite including ink —
>   is still banned.

*Why:* the ban exists to prevent a second source of truth, and a render of an
immutable source cannot become one. Stated as a narrowing rather than a
loophole so that the next cache proposal has to meet the same test. **This is
what kills the launch-snapshot idea**: a composite containing ink either
restates the ink or omits it, and both are failures.

## A8. *Geometry and coordinates* — per-page geometry — **FORCED (phase 3b, code is written and green)**

*Adopt with the corrections at the end of this file: where geometry lives, and
how mixed slots lay out.*

Replace:

> The page does not grow. `pageWidth` and `pageHeight` are fixed at creation.

with:

> The page does not grow. **Geometry is per page**, set at page creation and
> immutable afterward: a blank page gets the canonical size, an imported page
> gets its source's size in page points. No owner mutates geometry after
> creation, and the zoom floor derives from the page it belongs to.

Delete from the same section:

> Geometry fields are finite page points greater than zero, with
> `pageWidth < pageHeight`, and equal the application's canonical geometry.

replacing with:

> Geometry fields are finite page points greater than zero. `pageWidth <
> pageHeight` is **dropped** — landscape sources exist.

Delete this sentence entirely:

> Rotation, crop, PDF source coordinates, normalized coordinates, and
> annotation anchors do not exist.

replacing with:

> Crop, normalized coordinates, and annotation anchors do not exist. **PDF and
> image source coordinates do exist**: each asset-backed layer owns exactly
> one invertible mapping from its source space to page space. Ink and layer
> transforms are authored in page space, and a layer's `pageSpaceTransform` is
> a durable value.

*Why:* mixed geometry is not an edge case — swiping past the last page of an
imported PDF appends a blank canonical page, so a portrait page after a
landscape worksheet is the *normal* state of any annotated import. Note the
real cost: `PageGeometry` is a global static consumed at canvas construction,
and paging arithmetic assumes uniform screen-width slots; this amendment is
the expensive one to implement, not the expensive one to write.

## A9. *Geometry and coordinates* — the absolute zoom cap — **FORCED (phase 3b, code is written and green)**

*Adopt with the corrections at the end of this file: the value is bounded by a
measured `PKCanvasView` clamp, and an unhonourable cap is refused at load.*

Add:

> **The absolute zoom cap is a durable document constant**, in page points per
> pixel. Today's cap is `fitWidth × 8`, a function of the viewport — it
> changes with device, rotation, and Split View, so nothing durable may be
> derived from it. Anything that must reason about a maximum reachable detail
> level reads the durable cap, never the viewport-derived one.

*Why:* the import-normalization flag is unsound without it — "pixels beyond
the ceiling are unreachable forever" is false if the ceiling moves with the
device — and lens rendering wants a bounded detail level anyway. Cheap to
adopt, and it gates a flag that would otherwise destroy image data against a
moving limit.

## A10. *Undo* — one manager per page, two clients — **FORCED (code landed; adoption gated on spike 3 — the undo premise is untested)**

Replace:

> PencilKit and its live undo manager own stroke undo and redo, and
> system-owned UI may invoke that manager directly. There is no interception
> and no semantic undo domain.

with:

> Undo is **one manager per page** — the responder chain's, PencilKit's own —
> with **two clients**. PencilKit registers stroke undo exactly as today. A
> committed layer edit registers its inverse, the prior envelope value,
> with the *same* manager, through the session, exactly once per commit.
> There is no interception: nothing wraps or filters PencilKit's
> registrations. There is **no second manager**, which is what "no semantic
> undo domain" protects. Undoing a layer edit re-emits the prior committed
> value through the ordinary save path. Saving never clears undo. Turning and
> appending remain navigation, not editing.
>
> Layer-edit undo therefore has the same per-page lifetime stroke undo has:
> the manager dies with the page controller.

*Why:* a moved image that cannot be un-moved is not feature complete — a
mis-drag destroys layout with no recourse. One manager buys one Cmd-Z stream
and correct interleaving for free. **Unverified:** that PencilKit tolerates
foreign registrations in its manager. Phase 4's device spike checks this
before the amendment is adopted; if it does not tolerate them, this amendment
is wrong and phase 4 needs a different design, not a workaround.

**Status after phase 4's code.** `PageCanvasController.commitLayerTransform`
implements exactly this text — the responder chain's manager, the prior
transform as the inverse, one explicit group per commit, target `self` so the
existing `willRetire` cleanup covers it, and the undo re-emitting through
`EditorSession` like any other edit. **The spike still has not run**, and it
cannot run anywhere but on a device. Two things narrow the risk without
removing it:

- The registration happens **after** the session accepted, not before, which
  is the opposite of the shape tool's order and deliberately so: a layer
  transform mutates no `PKDrawing`, so there is no PencilKit registration to
  interleave with, and the only real hazard is an undo entry restoring a value
  that was refused.
- If PencilKit ignores foreign registrations, the failure is **silent and
  benign**: the layer edit is not undoable, the durable value is still correct,
  and nothing crashes. So the spike is a yes/no on one Cmd-Z, not a
  crash-hunt — but a silent failure is one nobody stumbles on, which is why it
  has to be checked deliberately.

## A11. *Navigation* — selection is the third drag claimant — **FORCED (phase 4, code is written and green)**

Add after the paragraph settling the paging-vs-canvas drag contention:

> Layer manipulation is a **third claimant** on the same drag, and
> **selection is the mode switch** that arbitrates it. With no selection,
> every touch behaves exactly as it does today — the blank-page path pays
> nothing. A tap on a selectable layer selects it. While a selection exists, a
> drag beginning on the selected layer is a transform, owned by the canvas
> runtime; a drag beginning anywhere else deselects and falls through to the
> scroll system unchanged.
>
> A `pdf` or `image` layer is selectable — selection is how "replace the
> worksheet" has a UI path at all. What a static kind refuses is *drawing*
> input, not addressability. A layer may additionally be **locked** against
> transforms, and locked is a bit on the envelope, not a property of the kind.

*Why:* *Navigation* spent a section settling this contention for two
claimants; adding a third silently is how that settlement rots. The
fall-through rule is the part most likely to fight UIKit — if it does, the
escape hatch is a selection chrome view owning its own recognizers, so
arbitration happens by hit-testing rather than by recognizer delegates.

**One sentence needs amending before adoption, because the code does something
narrower and better.** "With no selection, every touch behaves exactly as it
does today — the blank-page path pays nothing" is implemented as *a page with
no selectable layer builds no selection runtime at all*, so a blank page grows
neither a tap recognizer nor a drag recognizer. That is the same narrowing
`PageBackdrop` makes for transparency (paid per page that has a stack, not once
for the app), and it makes the claim a property of the object graph rather than
of a delegate's judgement. Suggested replacement for the first sentence:

> With no selection, every touch behaves exactly as it does today, and a page
> with nothing selectable on it carries no selection machinery at all.

**The escape hatch as written cannot be built, and the reason belongs in the
record.** A selection chrome *view* has nowhere to live: under the transparent
`PKCanvasView` it receives no touches, because the canvas is above it and takes
them; above the canvas it receives them and therefore eats every Pencil touch
over the selected image, so you could no longer draw on top of a picture you
had selected. Arbitration is still by hit test — `LayerDragRecognizer` asks the
same unit-square question a view's `hitTest` would — it simply asks it inside a
recognizer that declines instead of inside a view that must exist somewhere in
the z-order. If this fights UIKit on device, the finding is that neither
structure works, not that the hatch was skipped.

**Scale and rotate are handle drags, not a pinch**, and that is a design
decision this amendment should record. A `UIPinchGestureRecognizer` would
contend directly with `PKCanvasView`'s own pinch-zoom — the one gesture
*Navigation* hands to the framework outright — and winning that fight means
either stealing zoom while an image is selected or losing the scale. Handles
need no arbitration: they are a different *place*, and place is what the hit
test already answers.

~~**Do not adopt the `locked` bit until code reads it**~~ — **code now reads
it**, in two owners: `LayerSelectionRuntime` refuses to begin a drag on a
locked layer (so a locked image pans the page like bare paper, and its chrome
is dashed and handleless to say so before the user finds out), and
`EditorSession.transformLayer` refuses the durable edit outright. Its one
writer is `EditorSession.setLayerLocked`, which no UI calls yet — exactly as no
UI called `importImage` when phase 2 landed. An envelope written before
`locked` existed decodes as unlocked; that read-forward is the same rule
*Durable form* already states for the pre-layer page form, one level down, and
it is the single most reversible call in phase 4 if Phillip would rather the
old files simply fail.

## A12. *Performance* — the live-canvas bound survives layers — **FORCED (phase 1)**

Add to the hard invariants:

> - A page has exactly one `ink` layer. The live canvas count is bounded per
>   page in the live window; ink layers multiplying per page would multiply
>   canvases inside that bound.

*Why:* the one-ink-layer rule is already adopted in *Durable form* as a format
rule, but its actual justification is a performance bound. Stating it in both
places is intentional: someone lifting it will read one or the other.

## A13. *Durable form* — the kind set opens to `pdf` — **FORCED (phase 3)**

This is A5's mechanism being paid a second time, deliberately and separately,
because paying once per kind is the entire point of a closed set. In the
adopted block, replace:

> - **The set of kinds is closed.** The kinds are `ink` and `image`.

with:

> - **The set of kinds is closed.** The kinds are `ink`, `image`, and `pdf`.

Extend the directory diagram's asset line:

```text
  assets/<assetID>.<ext>  imported originals, byte for byte: .png, .jpeg, .pdf
```

After the `image`-payload bullets, insert:

> - **A `pdf` layer's payload is a ref and a source page**: the `assetID` of a
>   PDF in `assets/`, and the zero-based index of the source page this layer
>   shows. One import is one asset however many pages it has, so a fifty-page
>   worksheet costs one copy of the worksheet and fifty refs into it.
> - **A `pdf` asset is never normalized and never rewritten.** The original
>   bytes are the whole of the small-export story: what a later export hands
>   back is the file the user imported. This is stronger than the write-once
>   rule assets already carry, and it is stated separately because the
>   import-time normalization flag that images may one day take is closed to
>   `pdf` by this sentence.
> - **A `pdf` layer's `pageSpaceTransform` follows the same unit-square
>   convention an `image` layer's does**: it maps the source page's rectangle,
>   taken as the unit square with its origin at top-left, into page space. The
>   source page's size in points is **not** durable, for the reason the image's
>   pixel size is not: the asset states it, nothing can use it without opening
>   the asset anyway, and a second copy is a value that can disagree with
>   itself. **The source rectangle is the page's CropBox, falling back to its
>   MediaBox, with `/Rotate` applied** — a PDF page carries five boxes and a
>   rotation, so "the page's size" is a choice, and the choice is made in one
>   place rather than frozen into every layer that was ever written.
> - A `pdf` layer carries **no format field**. An `image` layer needs one
>   because `png` and `jpeg` are both images; a `pdf` layer's asset is a PDF by
>   definition of the kind, so a stored format could only repeat the kind. The
>   consequence, stated so it is not discovered later: a `pdf` layer has no
>   unsupported-format refusal, because it has no format to be unsupported. Its
>   refusals are an unreadable payload and a missing asset.
> - A `pdf` layer's `sourcePageIndex` is a non-negative integer. That it is
>   *within* the source is **not** checked on load: answering it means opening
>   the asset, and opening every asset on load is the whole-document read this
>   format exists to avoid. An out-of-range index is the render path's refusal.

*Why the size decision went this way, since it is the one genuinely open call
of the phase and the argument for the other side is real:* a PDF page has an
intrinsic size in points, a resolution-independent physical fact, where a
bitmap has only pixels — so "the source states its size, unlike an image"
is true and is the strongest case for storing it. It still loses, on four
counts. It restates the asset, which is the failure A6b refused. No consumer
needs the number without also needing the bytes — every use is a render, and
`CGPDFPage` states its own box when opened — whereas the question the durable
form *must* answer without opening a 50 MB file is "where is this layer on the
page", which the transform already answers. "The page's size" is a choice among
five boxes plus a rotation, and freezing that choice into every payload lets it
drift from the renderer's with no way to detect the drift. And under A8 an
imported page's *geometry* is its source's size in points, so a durable size in
the payload would be a third copy of one number. **The unit-square payload
needs no reconciliation when A8 lands; a stored point size would.** If Phillip
disagrees, the change is one field and one migration, and it is easier to add
later than to remove.

## A14. *Durable form* — `layers/` splits out of the page file — **FORCED (phase 3)**

The adopted block says envelopes are inlined and that "per-layer files arrive
with the first heavy kind, not before". `pdf` is that kind. Replace the
directory diagram's page line, and add a layer line:

```text
  pages/<pageID>.plist    one file per page: its own pageID and its ordered layer IDs
  layers/<layerID>.plist  one layer envelope per file
```

Replace:

> Envelopes are inlined in the page file; per-layer files arrive with the first
> heavy kind, not before.

with:

> A layer envelope is one file, named by its `layerID`, and a page file is the
> ordered list of layer IDs that make up the page. Order is z-order. A layer
> file carries its own `layerID` and is checked against the name it is filed
> under, exactly as a page file's repeated `pageID` is.

Replace the "save writes only what changed" bullet with:

> - **A save writes only what changed, at the finest granularity the form
>   has** — which is one layer. Ink on page 4 of a fifty-page import writes
>   page 4's ink layer file and nothing else: not the `pdf` envelope beneath
>   it, not page 4's own page file, whose layer list did not change, not the
>   other pages, not the asset, not the index. Rewriting an unchanged file at
>   any level is a defect rather than an inefficiency: it is the whole-document
>   rewrite this format exists to prevent, one level down.

Replace A6's write-order bullet with:

> - **Write order is leaf-to-root: assets, then layer files, then page files,
>   then the index**, so an interrupted save leaves an orphan at some level and
>   never a dangling ref at any. A save that names an asset or a layer which is
>   neither already durable nor being written now is refused before any write.
>   **Deletion is the mirror, root-to-leaf**: the page file drops the ref
>   first, the layer file dies second, the asset dies third.

After the dangling-asset bullet, insert:

> - **A dangling layer ref is fatal; an orphan layer file is inert.** The same
>   rule as a dangling page ref, one level down, and *unlike* a dangling asset
>   ref: a missing layer file may be the page's ink, and no other copy of it
>   exists, so the page is refused rather than repaired. A layer file no page
>   names is never read.
> - **Layer reclamation is delete-inline, like assets**: when a page drops a
>   layer, that layer's file is deleted once no page file names it, and only
>   then is its asset considered. Both questions are answered from the files on
>   disk one level up, so a page write that failed leaves the layer file alive
>   and a layer file that outlives its deletion keeps its asset alive.

Extend the migration sentence:

> The pre-layer page form (bare drawing bytes) and the pre-split form
> (envelopes inline in the page file) are both read, and written forward on the
> page's next save, never migrated eagerly. **A page not yet in the split form
> writes all of its layer files forward on that save**, because none of them
> has a file to be unchanged. Three forms are read; exactly one is written.

*Why here and not at phase 1:* the split's whole benefit is that annotating a
page does not rewrite what is heavy on it, and before a heavy kind existed
there was nothing heavy to not rewrite — a directory level proving nothing is
a directory level that only costs. Phase 3 is where the claim becomes
observable, and its exit test is exactly that observation: a five-page import
with a 794 KB asset, one page's ink dirtied once, and the whole document
package compared file by file, by modification date and by bytes. One file is
rewritten. That test fails if the granularity regresses — verified by
deliberately coarsening the save path and watching it name the `pdf` envelope
as the second rewrite.

*The cost, stated honestly:* a document now has one file per layer rather than
one per page, roughly doubling the file count for blank pages, and reads on
load go from one file per page to one plus one per layer. Load is unchanged in
practice — a blank page is one page file plus one ink file where it used to be
one page file carrying the same ink — and the save side is where the win is.
The other cost is that "a save landed" is no longer observable by watching
`pages/`, which broke a timing test and would break any future tooling that
watched page files.

---

## A15. *Owners* — the import rule now bans `CoreGraphics` — **FORCED, and it needs your ratification specifically**

**Read this one even if you skim the rest.** An agent *widened a
machine-checked rule* overnight. That is adjacent to authoring a rule, which
this contract forbids, so it is called out rather than left in a diff.

`ContractStructureTests.uiFrameworkModules` was `["UIKit", "PencilKit"]` and is
now `["UIKit", "PencilKit", "CoreGraphics"]`. The contract sentence it enforces
is *Owners*: "Durable value types import Foundation only."

*The argument for it:* `CGPDFDocument` arrives with `CGContext`, `CGImage`, and
every drawing call attached, so admitting CoreGraphics anywhere admits the
whole graphics vocabulary into files that should hold values. This milestone
makes that risk concrete — `PageSpaceTransform` is six `Double`s precisely so
that `CGAffineTransform` never reaches the durable form, and nothing mechanical
was stopping the next author from reaching for it.

*The argument against it:* the contract names UIKit and PencilKit and does not
name CoreGraphics. The widened rule is stricter than the text it cites, and
two files now carry allowlist entries that exist only because of the widening
(`PDFSource.swift`, `StaticLayerRenderer.swift`) — both manifestly not durable
value types.

If you adopt it, *Owners* should say so out loud:

> Durable value types import Foundation only — not UIKit, not PencilKit, and
> not CoreGraphics, whose vocabulary is a graphics framework's whole surface.

If you reject it, delete `"CoreGraphics"` from `uiFrameworkModules` and both
allowlist entries become unnecessary. **It is one line either way**; what is
not acceptable is leaving a machine-checked rule stricter than the document it
claims to enforce.

## Amendments this milestone does NOT need

Recorded so the absence is deliberate rather than forgotten:

- **No `shape` kind.** Shapes commit snapped strokes into the ink layer, so
  they change no durable form and require no amendment. This is the entire
  benefit of that decision.
- **No SVG interchange rule.** It left the milestone with the `shape` kind.
- **No export rule.** Export is deferred; the normalization flag stays a flag
  precisely because promoting it would weaken the byte-for-byte asset rule for
  images, and that amendment gets authored when the evidence exists, not now.
- **No collaboration, sync, or AI anything** in the file format.

## Open questions for Phillip

1. **A4's duplicated editability sentence** — it now appears in both *Owners*
   and *Durable form*. Pick a home.
2. **A5 versus a general rule.** Paying one amendment per kind is the
   mechanism working as designed, but it means `pdf` costs another. Confirm
   you want that friction; the alternative — amending once to admit
   `image` and `pdf` together — is cheaper and weaker. **A13 pays it**, as a
   separate section in its own commit, on the assumption the friction is
   wanted. Merging A5 and A13 into one bullet is a two-line edit if not.
3. **A10 is written as if the spike passed.** It has not run. Adopt it only
   after phase 4's device spike confirms PencilKit tolerates foreign undo
   registrations.
4. **A8 is the expensive one, and it has now landed.** The letterboxing is
   gone: an imported PDF page carries its source's size in page points, and
   A13's unit-square payload needed no reconciliation, as predicted. Two calls
   inside it are worth your eye rather than your assent — geometry lives in
   `document.plist` per page rather than in the page file, and a paging slot
   stayed one viewport wide. Both are argued at the end of this file.
5. **A13's unit-square-versus-point-size call.** Recorded in full in A13
   because the case for storing the source page's point size is genuinely
   stronger for PDF than it was for images, and this is the call most worth
   overruling if the reasoning does not convince. One field and one migration
   either way.
6. **The zoom cap's value was decided by a framework limit, not by taste.**
   `PKCanvasView` silently clamps `maximumZoomScale` to 10, so 20 device pixels
   per page point is the deepest zoom that exists at all, and the cap is pinned
   there. If you want deeper zoom than that, it is a different ink surface, not
   a different constant — worth knowing before any lens work is priced.
7. **`CoreGraphics` joined the contract checker's banned-import list**, with
   two allowlist entries, `PDFSource.swift` and `StaticLayerRenderer.swift`.
   It is not a UI framework, so it stretches the rule's name to serve the
   rule's purpose; deleting the entries is one line each, and doing so makes
   any file able to import it unnoticed.

---

# Corrections after phase 3b (per-page geometry and the durable zoom cap)

A8 and A9 are now **FORCED**: the code implementing them is written and green.
Both are adopted as drafted except where this section says otherwise. The
corrections below are what the implementation forced, and each says which
sentence of the draft it replaces.

## A8 correction — the sentence about where geometry lives

A8 says nothing about the durable home, and the fork doc says "the page file is
the obvious home". **It went in the index instead**, one `{ id, geometry }`
record per page in `document.plist`, and that is a decision worth ratifying
rather than a detail.

The reason is the paging arithmetic, not tidiness. `PagedCanvasController`
sizes its scroll content and places every slot before any page outside the live
window has been read, and page files are read lazily precisely because reading
them all is the whole-document read *Durable form* exists to prevent. Geometry
in the page file leaves two options and both are worse: read every page file at
open, so opening a notebook scales with its total size; or lay pages out at a
guessed size and re-lay them as their files arrive, which moves the content
offset of every later page under the user's finger, mid-scroll.

It costs nothing in writes — geometry is immutable after page creation, and
creating a page already rewrites the index because page order changed — and it
keeps the no-duplication rule true, because a page file still holds only its own
ID and its layer list.

Add to *Durable form*, replacing "`document.plist` holds the format version,
`documentID`, page geometry, an ordered list of page IDs, and the current page
index":

> `document.plist` holds the format version, `documentID`, an ordered list of
> pages — each its ID and **its own geometry** — the current page index, and the
> document's absolute zoom cap. A page file holds no geometry: the index is the
> one file read whole at open, and page files are read lazily, so geometry in a
> page file would either make opening a notebook scale with its total size or
> make a page's position depend on what had finished loading.

## A8 correction — mixed slots, decided

A8 and the fork doc both say paging "makes slot layout per-page" and leave the
layout undecided. It is decided now, and in the other direction:

> A slot in the paging scroll view is **one viewport wide, always, whatever the
> page in it measures**. The page varies inside its slot, not the slot. A page
> canvas fills its slot and fits its own page inside itself — its zoom floor and
> its opening scale come from its own geometry — and the room left over is
> centred.

Priced, because the alternative is real: a filmstrip of true relative widths
means turning off `isPagingEnabled` and re-deriving the snap in
`scrollViewWillEndDragging(targetContentOffset:)`, which is a hand-written
gesture arbitration replacing one *Navigation* deliberately takes from
`UIScrollView`; it turns three offset computations into prefix sums and `settle`
from a rounding into a search; and it forces a document-wide points-per-page-point
choice that is a rendering decision, not a durable fact. Nothing durable and
nothing in `PageCanvasController` assumes a uniform slot — three lines in
`PagedCanvasController` do — so it is reversible when something needs it.

## A8 correction — its third replacement conflicts with A6b, and A6b is right

**Do not adopt A8's replacement for the "Rotation, crop, PDF source
coordinates, normalized coordinates, and annotation anchors do not exist"
sentence.** A8 proposes:

> Crop, normalized coordinates, and annotation anchors do not exist. **PDF and
> image source coordinates do exist**: each asset-backed layer owns exactly one
> invertible mapping from its source space to page space.

A6b proposes the opposite of both halves:

> Crop, PDF source coordinates, and annotation anchors do not exist. An
> asset-backed layer's transform maps its source's unit square into page space,
> and may rotate; nothing else is authored in normalized coordinates, and no
> other space is normalized.

**The code does A6b.** An asset-backed layer's `pageSpaceTransform` maps the
source's *unit square* — a normalized space — into page space; it does not map
source points, and no durable value anywhere states a source's extent. A8 was
drafted before A13 settled the unit-square payload and its sentence describes
the design A13 rejected. Phase 3b therefore landed A8's geometry paragraphs and
left that sentence alone, so `Contract.md` still carries the pre-A6b wording and
still lags the code by exactly A6b's edit — which is A6b's to close, not this
lane's.

## A9 correction — the units stand, the value is not free

A9's text stands as drafted. The value does not follow from taste:

> **`PKCanvasView` silently refuses a `maximumZoomScale` above 10.** Measured,
> undocumented, and invisible unless the value is read back — a plain
> `UIScrollView` keeps whatever it is given. The cap is therefore pinned at **a
> twentieth of a page point per pixel**: twenty device pixels per page point,
> which is exactly what the framework will deliver at the 2× grid every iPad
> has. A document may not pin a cap finer than the runtime can honour, and one
> that does is refused at load rather than opened and quietly given less.

Two consequences worth stating plainly, because both correct the draft's own
reasoning:

- The old cap was **less viewport-dependent than A9 claims**. `fitWidth × 8`
  exceeds 10 whenever fit-width exceeds 1.25, which is every iPad in portrait,
  so most devices were already sitting on the framework's clamp rather than on
  the arithmetic. The complaint is still right — the smallest iPad in portrait
  fell short of the clamp at ≈ 9.7, and Split View moved it further — but the
  spread was narrower than "it changes with device, rotation, and Split View"
  suggests.
- **Nothing gains detail by pinning the cap**, because the clamp was already
  the effective ceiling. What is gained is that the ceiling is now a *stated*
  number a durable claim can rest on, which is exactly what A9 was for. Any
  future design that wants deeper zoom than 20 px per page point needs a
  different ink surface, not a different constant.

## A9 correction — where an unhonourable cap is refused

Add, after A9's paragraph:

> A cap finer than the canvas runtime will deliver is an invalid durable state
> and is refused when the index is validated, so it surfaces as a document that
> will not open rather than as a canvas that quietly gives less. The canvas
> reads its accepted `maximumZoomScale` back and fails loud if it was clamped,
> which is the belt to that braces.

## The index format version is bumped; the page file's was not

Phase 3a split `layers/` out of the page file without bumping anything, because
a page file carries no version field. The index does, and this is what it is
for: a build predating per-page geometry must refuse a version 3 index saying
"this document was written by a newer version", not fail to find a `pageIDs` key
and report that the index will not decode. `DocumentIndex` reads version 2 and
version 3, writes only version 3, and `DocumentStore` remembers that the index it
loaded was superseded and writes it forward on the first save that follows —
phase 1's precedent, unchanged, at one level up.

## What A8 did *not* need

- **No amendment for the appended page.** *Navigation* already says swiping past
  the last page yields a blank writable page; that page takes the canonical
  geometry, which is a consequence of A8 rather than a new rule.
- **No amendment for `PageSpaceTransform`.** An imported page's `pdf` layer now
  carries `{ a: pageWidth, d: pageHeight, tx: 0, ty: 0 }` — the unit square edge
  to edge — where under one document-wide geometry it was a letterbox. A13's
  unit-square decision needed no reconciliation, exactly as A13 predicted.
