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

## A3. *Owners* — the state table gains its layer rows — **FORCED (phase 1, phase 2)**

The table in *Owners* lists nine states and no layer state, so the layer list
and layer values are governed only by prose. Add these rows, which restate
existing rules one level down rather than introducing new owners:

| State | Sole writer | Frequency | Lifetime |
|---|---|---|---|
| A page's layer list (order, membership) | `EditorSession` | user action | app session → saved |
| Committed layer values, held layer bytes | `EditorSession` (custody) | edit/save | app session |
| Asset files | `DocumentStore` (import path) | import | across launches |

Two rows are **AHEAD**, not forced until phase 4 builds manipulation:

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

## A6. *Durable form* — assets — **FORCED (phase 2)**

Extend the directory diagram:

```text
Notebook.tubernotes/
  document.plist                    the index
  pages/<pageID>.plist              one file per page: its ordered layer envelopes, inline
  assets/<assetID>.<ext>            original imported bytes: .png, .jpeg
```

And add to the durable-form rules:

> - **Assets are sources: write-once, immutable, byte-for-byte.** An import
>   writes a new asset; nothing ever mutates one. "Replace the image" is a new
>   asset and a layer edit, never a rewrite.
> - **Heavy bytes live behind refs.** An `image` layer's payload is an
>   `assetID` plus the invertible source-to-page mapping. `ink` payloads stay
>   inline, as ink is today.
> - **A dangling asset ref refuses the layer; an orphan asset is inert** —
>   layer→asset, exactly as document→page. A layer whose asset is missing is
>   refused with a reason, the page refuses input, and the rest of the
>   document opens.
> - **Write order is leaf-to-root: assets, then page files, then the index.**
>   An interrupted save leaves orphans at some level and never a dangling ref
>   at any. **Deletion is the mirror, root-to-leaf**: the page file drops the
>   ref first, the asset dies second, so an interruption leaves an inert
>   orphan, never a dangling ref.
> - **Asset reclamation is delete-inline**: when the last layer referencing an
>   asset is deleted, the asset is deleted with it, at the one site that
>   deletes layers. Crash orphans — an import whose page file never landed —
>   accumulate until a sweep-on-open lands, which waits on the failure
>   taxonomy, because a sweep that deletes the wrong file is a durability
>   failure. Until then an orphan is inert and merely heavy.

*Why:* every clause restates a rule the document→page level already carries.
The write-order clause is the one that is load-bearing rather than tidy: it is
what makes an interrupted import recoverable.

## A7. *Forbidden patterns* — the derived-artifact ban, narrowed — **AHEAD (phase 2 rendering / phase 3)**

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

## A8. *Geometry and coordinates* — per-page geometry — **AHEAD (phase 3)**

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

## A9. *Geometry and coordinates* — the absolute zoom cap — **AHEAD (phase 3)**

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

## A10. *Undo* — one manager per page, two clients — **AHEAD (phase 4)**

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

## A11. *Navigation* — selection is the third drag claimant — **AHEAD (phase 4)**

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

**Do not adopt the `locked` bit until code reads it** — an unread bit is an
undefined placeholder field, which *Forbidden patterns* bans.

## A12. *Performance* — the live-canvas bound survives layers — **FORCED (phase 1)**

Add to the hard invariants:

> - A page has exactly one `ink` layer. The live canvas count is bounded per
>   page in the live window; ink layers multiplying per page would multiply
>   canvases inside that bound.

*Why:* the one-ink-layer rule is already adopted in *Durable form* as a format
rule, but its actual justification is a performance bound. Stating it in both
places is intentional: someone lifting it will read one or the other.

---

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
   `image` and `pdf` together — is cheaper and weaker.
3. **A10 is written as if the spike passed.** It has not run. Adopt it only
   after phase 4's device spike confirms PencilKit tolerates foreign undo
   registrations.
4. **A8 is the expensive one.** Its text is short and its implementation
   threads geometry through page construction and makes paging slots
   per-page. Worth confirming you want it in phase 3 rather than earlier or
   later.
