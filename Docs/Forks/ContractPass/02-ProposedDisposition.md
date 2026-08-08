# Disposition of `Contract.proposed.md`

Stage 1 item 4 of `Docs/Forks/CanvasCompleteTodo.md`. Every piece of
`Docs/Contract.proposed.md` — A1–A15 including A6b, the A8/A9 correction
sections, the two record-only sections, the file's own "Open questions for
Phillip", and the *Silent drift* list from `Docs/Forks/ReviewFindings.md` — gets
one disposition here, with paste-ready wording where the disposition is adopt or
amend.

**This file authors nothing.** It is an agent's proposal, exactly as
`Contract.proposed.md` is. Adopting an entry means Phillip moving its wording
into `Contract.md` in a commit tagged `CONTRACT:`. Nothing here is in force.

**Every claim an entry makes was checked against the source at
`d09b27f`,** not against the staged text's own account of itself. Line
references in `Contract.proposed.md` and `ReviewFindings.md` have drifted; the
citations below are current. Where the staged text says something the code does
not do, the entry says so and the wording is rewritten.

Read top to bottom. Each entry is: **staged text** (where it is), **disposition**,
**final wording** (paste-ready), **evidence** (what was checked, and where).
The decisions that are still yours are collected in a checklist at the end;
each of those carries a recommendation and a one-paragraph case, plus the
alternative in brief, so the checklist is a yes/no pass rather than a re-think.

---

## Summary

| # | Piece | Disposition |
|---|---|---|
| A1 | golden rule 5, generalized | **adopt** — already in force, no action |
| A2 | the layer envelope | **adopt** — in force; its page-file line is superseded by A14 |
| A3 | the state table's layer rows | **amend** — two of five rows are false as written |
| A4 | two lifecycles, not one | **amend** — the three-state machine does not exist in code |
| A5 | the kind set opens to `image` | **amend** — fold into A13; one kind line, not two edits |
| A6 | assets | **amend** — extension list; write-order bullet ceded to A14 |
| A6b | the unit-square consequence | **adopt** — the code does A6b, confirmed twice |
| A7 | the derived-artifact ban, narrowed | **refuse** — nothing on disk waits on it |
| A8 | per-page geometry | **amend** — adopt two of three replacements; the third conflicts with A6b |
| A9 | the absolute zoom cap | **amend** — fold both corrections and the unstated coarse-cap refusal into one block |
| A10 | one manager per page, two clients | **yours** — recommended: adopt amended, outcome claim to `Unproven.md` |
| A11 | selection as the third drag claimant | **amend** — rewritten to the code, per your 2026-08-07 decision |
| A12 | the live-canvas bound survives layers | **adopt** — verbatim |
| A13 | the kind set opens to `pdf` | **amend** — merged kind line; the five payload bullets adopt verbatim |
| A14 | `layers/` splits out of the page file | **adopt** — five edits, all matching code |
| A15 | the `CoreGraphics` ban | **yours** — recommended: ratify, and add `ImageIO`, which is free |
| C1 | A8 correction — where geometry lives | **adopt** |
| C2 | A8 correction — mixed slots | **amend** — one sentence, into *Navigation*, not *Durable form* |
| C3 | A8 correction — conflicts with A6b | **adopt as instruction** — no text of its own |
| C4 | A9 correction — units and value | **adopt** — folded into A9 |
| C5 | A9 correction — where a bad cap is refused | **adopt** — folded into A9 |
| C6 | the index format version is bumped | **amend** — one durable sentence survives; the rest is a log entry |
| R1 | "Amendments this milestone does NOT need" | **refuse** — record only, no contract text |
| R2 | "What A8 did *not* need" | **refuse** — record only, no contract text |
| D1 | drift: immediate saves bypass the debounce | **amend in** — new prose, *Saving* |
| D2 | drift: the composite LOD policy | **amend in** — new prose, *Performance* |
| D3 | drift: the kind/format cross-check | **amend in** — new prose, *Durable form* |
| D4 | drift: append without navigate | **amend in** — new prose, *Navigation* |
| D5 | drift: `RootCanvasView.shapeKind` | **code, not prose** — note only |

Counts: **7 adopt**, **11 amend**, **4 refuse**, **2 yours** (A10, A15), plus
**5 drift items** (4 prose, 1 code) and **7 open questions** answered below.

**One sequencing note before you start.** Two sibling proposals in this
directory edit `Contract.md` in the same sitting: `01-Saving.md` (stage 1
item 3 — partial acknowledgement under a thrown save, and the two dirty axes)
writes into *Saving*, where **D1 below also inserts**; and `03-Failure.md`
(stage 1 item 5) adds a whole `## Failure` section, which is additive and
collides with nothing here. Take `01-Saving.md` first and D1's paragraph goes
after its text cleanly; take D1 first and item 3's replacement has to find a
home around it. Either order works — do not do them in two sittings and forget
the other exists.

---

# Part 1 — the amendments

## A1. *Owners* — golden rule 5, generalized

**Staged:** `Contract.proposed.md:32-41`, marked LANDED.

**Disposition: adopt — already in force. No action.**

**Evidence.** `Contract.md:58` carries the text byte for byte. `EditorSession`
is the sole writer of `staticLayers` (EditorSession.swift:73, `private(set)`,
mutated only through `layerListChanged`), and the custody framing is real:
`savedStaticLayers` (EditorSession.swift:92) is a record of what reached disk,
not a second authority. Nothing to do.

## A2. *Durable form* — the layer envelope

**Staged:** `Contract.proposed.md:43-48`, marked LANDED.

**Disposition: adopt — in force. One consequence: A14 supersedes half of it.**

`Contract.md:76` still reads `pages/<pageID>.plist    one file per page: its
own pageID and its ordered layer envelopes, inline`, and `Contract.md:81` still
says envelopes are inlined. **Both are now false** — phase 3a split them out.
A14 is the edit that fixes it; A2 needs nothing of its own.

**One thing A2's envelope-shape sentence does need, and no amendment in the
file touches it:** the envelope has five fields, not four. That is the
envelope's fifth field, answered under **Open question 8** below.

**Evidence.** `PageFile.swift:39-52` — a page file is `{ pageID, layerIDs }`
and encodes only that form. `LayerEnvelope.swift:216-220` — five stored
properties.

## A3. *Owners* — the state table gains its layer rows

**Staged:** `Contract.proposed.md:51-76`. Five rows across two tables.

**Disposition: amend.** Three rows are true and adopt as written. The
transform/selection row is true but its *rationale* claims a structural test
that does not exist. The decoded-images row is false in both its owner and its
lifetime, and describes a design the code did not build.

**Final wording** — one table, five rows, appended to the table at
`Contract.md:40-50`:

> | A page's layer list (order, membership) | `EditorSession` | user action | app session → saved |
> | Committed layer envelopes in custody | `EditorSession` | edit/save | app session |
> | Asset files | `DocumentStore` | import | across launches |
> | A layer's selection and transform-in-progress | `PageCanvasController` | frame/input | canvas session |
> | Decoded and composited layer images | `StaticLayerRenderer` | render | byte-bounded cache, pruned to the retain window |

*Why:* the table is where this project settles ownership disputes; a state that
lives only in prose is the one that grows a second writer.

**What changed from the staged rows, and why.**

- "Committed layer values, **held layer bytes**" → "Committed layer envelopes
  in custody". There are no held layer bytes. A layer envelope is refs, a few
  dozen bytes (EditorSession.swift:71-80); the only bytes the session holds are
  *page* bytes, which the table already has a row for. Saying "held layer bytes"
  invents a cache that does not exist and would need a bound under *Performance*.
- "`DocumentStore` **(import path)**" → "`DocumentStore`". The parenthetical
  names a caller, and the table's other rows name owners. `DocumentStore` writes
  assets and deletes them (`deleteAssetIfUnreferenced`); the import path is one
  of its callers, not a second writer.
- "Decoded tiles / downsampled images | **canvas runtime cache** | render |
  **live window**" → the row above. Three corrections: nothing tiles; the cache
  is **not in the canvas runtime** — `StaticLayerRenderer` is an actor
  constructed by `EditorSession` (EditorSession.swift:502), importing
  CoreGraphics and ImageIO and deliberately no UIKit; and its lifetime is not
  the live window — it is a 96 MB byte bound with an LRU backstop, pruned by
  `retain(layerIDs:)` to the live window **plus the prefetch radius**
  (StaticLayerRenderer.swift:36-65). Adopting the staged row would put a rule
  in the table that the structural checker's own allowlist comment contradicts.

**On the staged rationale for the selection row.** The staged text says
selection "is checked by a structural test that fails if any of it appears in
`EditorSession`". **No such test exists.** `ContractStructureTests` has four
rules — UI-framework imports, file I/O, one `PKCanvasView` site, no stale
allowlist entry — and none of them mentions selection. What *does* hold the
line is the import allowlist: `LayerSelectionRuntime.swift` is on it
(ContractStructureTests.swift:569) and `EditorSession.swift` is not, so
selection code cannot move into the session without failing the build. That is
a weaker and different claim, and the row's justification should not assert
more than the machine checks. The row itself stands; the sentence claiming a
bespoke test does not go into `Contract.md` (it was never proposed to).

**Evidence.** EditorSession.swift:73, :92, :502; StaticLayerRenderer.swift:33-65
(owner/bound/eviction declared as *Performance* requires);
ContractStructureTests.swift:219, :524-604, :615-671.

## A4. *Owners* — two lifecycles, not one

**Staged:** `Contract.proposed.md:78-99`.

**Disposition: amend.** The two-machines idea is right and the editability
sentence is load-bearing. The static machine as drafted —
`loading | refused(reason) | ready(assetRef)` — **exists nowhere in the code**,
and one of its three states cannot occur: a static layer never loads. Its
envelope arrives with the page file, already decoded or already refused. What
loads is the layer's *render*, which is a cache under *Performance*, not durable
state, and a page whose render has not landed is still fully editable.

**Final wording** — appended after the paragraph beginning "Each page has
exactly one ink state" (`Contract.md:63`):

> That machine is **ink's** lifecycle, not every kind's. A static layer is
> never `live`, `held`, or `saving` — its payload is immutable and only its
> envelope changes. A static layer is in exactly one of two states from the
> moment its page file is read: `ready`, this build understands its kind and
> its payload; or `refused(reason)`, it does not, and the layer is a typed
> refused state rather than a dropped one. There is no third state and no
> loading state: a static layer's envelope arrives with its page, and what
> arrives later is its *render*, which is a cache and never an authority — a
> page whose image has not finished decoding is a page that is fully editable
> and briefly plain.

*Why:* forcing a static asset through an ink-shaped machine invents states that
cannot occur and hides the one that can.

**On the duplicated editability sentence (the file's open question 1).** Cut it
from A4. "A page is editable exactly when its ink layer is editable and no layer
is refused or unreadable" already stands in *Durable form* (`Contract.md:87`),
which is where the refused state is defined, and this contract's own opening
says it "carries no history and keeps nothing for reference". Two homes for one
aggregation function is exactly the second-copy failure the *Owners* section
exists to forbid, one level up from the code. The staged text offers both;
**take *Durable form*.**

**Evidence.** EditorSession.swift:63-70 (`refusedLayers`, typed, never dropped),
:73 (`staticLayers` — recognized, in order); there is no `loading` or `ready`
case for a static layer anywhere in the target — the render path returns a
refusal *render*, not a layer state (StaticLayerRenderer.swift:314, :335). The
editability aggregation does hold: `requireLayerListIsEditable` and the ink
state together (EditorSession.swift:1565-1567 region).

## A5. *Durable form* — the kind set opens to `image`

**Staged:** `Contract.proposed.md:101-114`.

**Disposition: amend — fold into A13.** Do not make this edit and then make
A13's edit over the top of it in the same sitting.

The mechanism A5 defends is right: a new kind costs an explicit amendment. But
the mechanism is a *toll on the code*, not a toll on the number of times one
line of Markdown is retyped. Both kinds are written, green, and shipped on this
branch; paying the toll twice tonight is theatre, and it leaves an intermediate
state in the file's history that was never true of any build. The single kind
line is in A13.

Its friction is preserved a better way — see the final wording under A13, which
states the toll as a rule so the next kind cannot arrive quietly.

**This answers the file's open question 2:** keep the per-kind friction, spend
it on the *next* kind, and write the two kinds that already exist in one line.

## A6. *Durable form* — assets

**Staged:** `Contract.proposed.md:116-177`.

**Disposition: amend.** The three inserted bullets, the dangling-asset bullet
and the reclamation bullet all adopt **verbatim** — every one of them is
implemented and tested. Two things change: the directory diagram's extension
list, and the write-order bullet, which A14 replaces with a four-level version
(adopt A14's, not this one, or you will write the same bullet twice).

**Final wording — the directory diagram** (replacing `Contract.md:73-77`, and
already including A14's page and layer lines so the diagram is written once):

> ```text
> JustACanvas.tubernotes/
>   document.plist          the index
>   pages/<pageID>.plist    one file per page: its own pageID and its ordered layer IDs
>   layers/<layerID>.plist  one layer envelope per file
>   assets/<assetID>.<ext>  imported originals, byte for byte: .png, .jpeg, .pdf
> ```

**Final wording — the three bullets**, inserted after the ink-transform bullet
(`Contract.md:86`), verbatim from the staged text:

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

**Final wording — the two refusal bullets**, after "A dangling page ref is
fatal; an orphan is not" (`Contract.md:92`), verbatim from the staged text:

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
>   reference anything — it reclaims nothing, and **while any page holds a
>   layer list no save has yet written, it reclaims nothing at all**: disk can
>   only answer for lists that reached it, and a reference living in memory is
>   one the scan is blind to. Crash orphans accumulate until a sweep-on-open
>   lands; an orphan is inert and merely heavy.

**What changed, and why.**

- `.png, .jpeg` → `.png, .jpeg, .pdf` in the diagram. `AssetFormat` has three
  cases (AssetRef.swift:17-24) and phase 3 writes PDFs into `assets/`. A6's
  two-format line was true the night A6 was written and is not true now;
  adopting it would put a false line in `Contract.md` for however long it takes
  A13 to be adopted, and the whole point of this pass is that no stated rule is
  false when you stand up.
- **The clause about unsaved layer lists is new** and it is not cosmetic. It is
  `ReviewFindings` #1 — the failure that permanently destroyed a write-once PDF
  asset — and its fix is code, at EditorSession.swift:1667-1684. Without this
  clause the contract's reclamation rule reads as an unconditional "answered
  from disk", which is the exact reasoning that produced the bug. State the
  guard next to the rule it guards.
- A6's write-order bullet is **not** adopted; A14's four-level version replaces
  it. Same for A6's "Replace the write-order bullet with" instruction: skip it.

**Also flagged, not amended here: HEIC.** `Docs/Queue.md:210-256` records your
2026-08-07 decision that image assets consolidate on HEIC, and stage 1 item 6
carries it. The code has not moved (AssetRef.swift:17-19 is still `png`/`jpeg`),
so the diagram line above states today's truth. **When item 6 lands its code,
that one line becomes `.heic, .pdf`** — one line, one amendment, and it should
ride in item 6's own `CONTRACT:` commit rather than being pre-written here
against code that does not exist.

**Evidence.** AssetRef.swift:17-30, :49-83; DocumentStore.swift:12-14, :223,
:913; EditorSession.swift:1297 (`importImage` leaf-to-root),
:1667-1684 (the reclamation guard), :1694-1735 (`reclaim`, root-to-leaf, one
step at a time, each answered from disk).

## A6b. *Geometry and coordinates* — the unit-square consequence

**Staged:** `Contract.proposed.md:179-204`.

**Disposition: adopt, verbatim.**

**Final wording**, replacing `Contract.md:158`:

> Crop, PDF source coordinates, and annotation anchors do not exist. An
> asset-backed layer's transform maps its source's unit square into page
> space, and may rotate; nothing else is authored in normalized coordinates,
> and no other space is normalized.

**Evidence.** This is the sentence the branch's code has been contradicting the
longest, and two independent lanes reached the same verdict: the phase 3b
correction section says outright "**The code does A6b**"
(`Contract.proposed.md:761`), and I confirmed it directly. `ImageLayerRef`
stores `{ assetID, format }` and no size, with the reason stated at
AssetRef.swift:37-43. `PDFLayerRef` stores `{ assetID, sourcePageIndex }` and no
size. Nothing durable anywhere states a source's extent — the renderer
re-derives the CropBox from the asset (PDFSource.swift:11-12, :62-65, :102-105).
Rotation is real and reachable: `Grab.rotate` and the rotation handle
(LayerSelectionRuntime.swift:242-266, :488), so dropping "Rotation" from the
does-not-exist list is required, not stylistic.

**Note the one loss, so it is a decision and not an accident:** this sentence is
the contract admitting a normalized coordinate space, which the pre-A6b text
denied outright. The staged rationale is honest about it and correct about the
alternative's cost (placement unanswerable without opening a 50 MB file). A13's
per-kind bullet repeats the convention for `pdf`, and the two must not drift.

## A7. *Forbidden patterns* — the derived-artifact ban, narrowed

**Staged:** `Contract.proposed.md:206-253`.

**Disposition: refuse.** Leave `Contract.md:212-213` exactly as it is.

**Reason.** By the amendment's own updated note, **nothing on this branch writes
a render to disk** — phase 2's cache, phase 3c's composite, the lens texture and
the prefetch warm are all in memory, all under the byte bound *Performance*
already permits (StaticLayerRenderer.swift:33-65; the lens is
viewport-sized and dropped on view movement, PageCanvasController.swift:839-841).
So A7 grants a permission no code has asked for, which is what
`AGENTS.md`'s "smallest change that proves the queue item" and the contract's
own ban on placeholders for future features both forbid, one level up from the
code. A permission granted early is a permission granted without the case that
would have shaped it: the exception's bounds — outside the package, keyed by
`documentID`, unreferenced from `pages/` — are good bounds *guessed* at, and the
first real on-disk cache will have opinions about them.

**Refusing costs nothing and loses nothing.** The argument is preserved here and
in `Contract.proposed.md`'s history; when a cache actually needs disk, this text
is the first draft of its amendment, and by then it can be checked against a
thing that exists rather than a thing imagined. The one sentence worth keeping
in mind while refusing: the reason a render of an immutable asset is safe —
missing but never stale — is a genuinely good argument, and it will still be
good in a month.

## A8. *Geometry and coordinates* — per-page geometry

**Staged:** `Contract.proposed.md:255-299`, plus corrections C1–C3.

**Disposition: amend.** Two of A8's three replacements adopt; the third is
withdrawn (C3), because A6b's sentence is the one the code implements.

**Final wording — replacement 1**, replacing `Contract.md:144`'s first two
sentences ("The page does not grow. `pageWidth` and `pageHeight` are fixed at
creation."):

> The page does not grow. **Geometry is per page**, set at page creation and
> immutable afterward: a blank page gets the canonical size, an imported page
> gets its source's size in page points. No owner mutates geometry after
> creation, and the zoom floor derives from the page it belongs to.

**Final wording — replacement 2**, replacing `Contract.md:98`:

> Geometry fields are finite page points greater than zero, per page.
> `pageWidth < pageHeight` is **dropped** — landscape sources exist — and so is
> equality with the canonical geometry: an imported page's geometry is its
> source's, and refusing it is how a landscape worksheet came to be letterboxed
> into a portrait page.

**Replacement 3: withdrawn.** Do not adopt A8's "PDF and image source
coordinates do exist" sentence. Adopt A6b's in its place — see C3.

**What changed.** Replacement 2 gains "per page" and the dropped-equality
clause. The staged version deletes `pageWidth < pageHeight` but is silent about
"and equal the application's canonical geometry", which is the *other* half of
the same deleted sentence and is equally dead — `validated()` checks
`page.geometry.isValid` per page and nothing else (DocumentIndex.swift:254-265).
Adopting the staged text verbatim would leave the canonical-equality clause
either half-deleted or ambiguous.

**Evidence.** DocumentIndex.swift:87 (`pages` of `{ id, geometry }`), :254-265
(per-page validation, with the letterboxing history in the comment);
PageGeometry.swift; the mixed-geometry paging tests survived adversarial review
(`ReviewFindings.md:255`).

## A9. *Geometry and coordinates* — the absolute zoom cap

**Staged:** `Contract.proposed.md:301-318`, plus corrections C4 and C5, plus the
unstated coarse-cap refusal from *Silent drift*.

**Disposition: amend — fold all four into one block.** A9 as drafted is true
but incomplete in three ways, and the three fixes are one paragraph.

**Final wording**, added to *Geometry and coordinates*:

> **The absolute zoom cap is a durable document constant**, in page points per
> pixel. It is not derived from the viewport: a fit-width multiple changes with
> device, rotation, and Split View, so nothing durable may rest on it. Anything
> that must reason about a maximum reachable detail level reads the durable cap.
>
> Its value is pinned by the framework, not by taste. **`PKCanvasView` silently
> refuses a `maximumZoomScale` above 10** — measured, undocumented, and
> invisible unless the value is read back, where a plain `UIScrollView` keeps
> whatever it is given. The cap is therefore **a twentieth of a page point per
> pixel**: twenty device pixels per page point, exactly what the framework
> delivers at the 2× grid every supported iPad has. Deeper zoom than that is a
> different ink surface, not a different constant.
>
> A cap is refused at both ends when the index is validated, rather than
> clamped. **Finer than the runtime will deliver** is a durable promise nothing
> can keep, and it must surface as a document that will not open rather than as
> a canvas that quietly gives less. **Coarser than one page point per pixel** is
> not a document anyone can write in. The canvas reads its accepted
> `maximumZoomScale` back and fails loud if it was clamped, which is the belt to
> that braces.

**What changed from the staged text, and why.**

- "Today's cap is `fitWidth × 8`" is deleted. It describes what the cap *was*
  before phase 3b and reads, in the contract, as a statement of what it is.
- The value and the framework clamp (C4) are folded in; without them the rule
  states a durable constant and refuses to say what it is, which invites the
  next author to pick one.
- The refusal (C5) is folded in, and **extended with the coarse end**, which is
  the *Silent drift* item: `validated()` enforces
  `zoomCapPagePointsPerPixel <= 1` (DocumentIndex.swift:275-280) and no document
  states it. An enforced-and-unstated rule is the drift class this whole stage
  exists to close.
- C4's two "consequences worth stating plainly" — that `fitWidth × 8` was
  already over the clamp on most devices, and that pinning gains no detail —
  are **not** adopted into `Contract.md`. They are true and they are reasoning
  about a superseded design; the contract "carries no history".

**Evidence.** DocumentIndex.swift:87, :126 (`1.0 / 20.0`), :275-280 (both ends
refused, with the reasoning in the comment); PageGeometry.swift:102
(`runtimeMaximumZoomScale = 10`), :109 (`minimumSupportedDisplayScale = 2`),
:118 (`finestReachable = 1 / (10 × 2)`); PageCanvasController.swift:446-468 (the
read-back and its precondition). Note `ReviewFindings` #9 — the read-back traps
rather than refuses at displayScale 1 — is a live code defect against this rule,
not an argument against the rule.

## A10. *Undo* — one manager per page, two clients

**Staged:** `Contract.proposed.md:320-367`.

**Disposition: yours.** See the checklist. **Recommended: adopt, amended** —
wording below — with the *outcome* claim moved to `Docs/Unproven.md` until
spike 3 runs. The alternative (hold the whole section for the spike) is set out
after the wording.

**Recommended final wording**, replacing `Contract.md:189-191`:

> Undo is **one manager per page** — the responder chain's, PencilKit's own —
> with **two clients**. PencilKit registers stroke undo exactly as today. A
> committed layer edit registers its inverse — the layer's prior transform —
> with the *same* manager, in one group, exactly once per commit, and only
> after the session has accepted the edit. There is no interception: nothing
> wraps or filters PencilKit's registrations. There is **no second manager**,
> which is what "no semantic undo domain" protects. Undoing a layer edit
> re-emits the prior value through the ordinary save path, and registers the
> opposite move as it goes, so a layer edit stays undoable and redoable
> indefinitely without a stack of its own. Saving never clears undo. Turning
> and appending remain navigation, not editing.
>
> Layer-edit undo has the same per-page lifetime stroke undo has: the manager
> dies with the page controller. A canvas with no manager in its responder
> chain registers nothing — the edit still lands and is simply not undoable,
> and nothing fabricates a manager to hold an action nobody can reach. An undo
> whose layer has been locked since the commit is refused by the session like
> any other edit to a locked layer: the undo does nothing, loudly in the log
> and silently on screen.

**What changed from the staged text, and why — four corrections, all verified.**

- "registers its inverse, **the prior envelope value**" → "the layer's prior
  transform". `commitLayerTransform(_:from:to:)` takes two
  `PageSpaceTransform`s (PageCanvasController.swift:1052-1056). An envelope
  carries a payload and a `locked` bit that undo does not restore; saying
  "envelope value" promises a restoration the code does not perform.
- "**through the session**" → the registration is in the controller. The
  session is *asked* first (`onLayerTransformed`, :1062) and the registration
  happens after it accepts, on `undoManager` with target `self`
  (:1072-1075). "Through the session" describes the opposite wiring.
- The **no-manager path** is stated. It exists (:1068-1072), it is deliberate,
  and it is exactly the kind of silent branch a contributor would otherwise
  "fix" by fabricating a manager.
- The **locked-between-commit-and-undo** no-op is stated. `transformLayer`
  throws `layerIsLocked` (EditorSession.swift:1517-1519), which the session's
  closure turns into `false` (EditorSession.swift:380-382), which
  `commitLayerTransform` logs and returns from (:1063-1066). Cmd-Z doing nothing
  is a surprising outcome; unstated, it reads as a bug.

**The case for adopting now (recommended).** The spike tests whether PencilKit
*tolerates* a foreign registration, and the answer changes what the user
experiences — not what the code should be trying to do. The contract states the
design a change must conform to, and every sentence above is a true description
of a shipped code path; leaving it out means a contributor touching
`commitLayerTransform` has no rule to check against, which is worse than a rule
whose user-visible payoff is unconfirmed. The failure mode if the spike fails is
established and benign — the registration is ignored, the durable value is
still correct, nothing crashes (`Contract.proposed.md:363-367`) — so a wrong
adoption costs one deleted paragraph, not a data-loss window. What must **not**
be adopted anywhere is the claim that Cmd-Z undoes a layer move on a device:
that belongs in `Docs/Unproven.md`, next to the other things the simulator
cannot say, until spike 3 reports.

**The alternative, in brief.** Hold the whole section until spike 3. Cost:
stage 1's exit condition ("nothing in `Contract.proposed.md` is load-bearing")
is not met — one section still is — and shipped code in the hottest file on the
branch keeps running under a contract sentence that forbids what it does
("There is no interception and no semantic undo domain" is *survivable* but
plainly not written with a second client in mind). Benefit: the contract never
carries a rule whose premise a device has not confirmed, which is a defensible
line and this project's stated instinct.

## A11. *Navigation* — selection is the third drag claimant

**Staged:** `Contract.proposed.md:369-433`.

**Disposition: amend — rewritten to the code, per your decision of 2026-08-07.**
The code side wins on selectability: image-only stands. Both of A11's falsities
are fixed below, and the escape-hatch and pinch paragraphs are cut.

**Final wording**, added after the paragraph settling the paging-vs-canvas drag
contention (`Contract.md:164-166`):

> Layer manipulation is a **third claimant** on the same drag, and **selection
> is the mode switch** that arbitrates it. With no selection, every touch
> behaves exactly as it does today, and a page with nothing selectable on it
> carries no selection machinery at all — no recognizer of ours is installed,
> so the blank-page path pays nothing as a property of the object graph rather
> than of a delegate's judgement.
>
> A tap selects the topmost selectable layer under it, and a tap that lands on
> none deselects. While a selection exists, a drag beginning on the selected
> layer — inside it, or on one of its handles — is a transform, owned by the
> canvas runtime. **A drag beginning anywhere else is simply not ours**: the
> recognizer fails, the touch reaches the scroll system unchanged, and the
> selection survives it. Only a tap deselects. Arbitration is by hit test and
> nothing else, decided once at touch-down; no recognizer delegate arbitrates.
>
> **An `image` layer is selectable; a `pdf` layer is not.** Selection is a
> transform UI, and a page-sized imported worksheet is the page — dragging it
> around inside itself is not an operation this application offers. What a
> static kind refuses is *drawing* input; addressability is per kind, and it is
> stated here rather than left to be inferred from what happens to be
> draggable.
>
> Because selection is the only producer of a layer's identity for the user, a
> kind that is not selectable needs its own way to be removed, or a mis-import
> is permanent. **A `pdf` layer is deleted through the page it occupies, not
> through selection** — deleting the page deletes its layers, and the asset is
> reclaimed with the last of them.
>
> A layer may additionally be **locked** against transforms, and locked is a
> bit on the envelope, not a property of the kind. A locked layer is still
> selectable — locked refuses transforms, not addressability — and a drag on it
> pans and turns the page exactly like bare paper. Its chrome is dashed and
> carries no handles, so the refusal is visible before the user discovers it.
>
> **Scale and rotate are handle drags, not a pinch.** A pinch recognizer would
> contend directly with `PKCanvasView`'s own pinch-zoom — the one gesture this
> section hands to the framework outright — and winning that contention means
> either stealing zoom while a layer is selected or losing the scale. Handles
> need no arbitration: they are a different *place*, and place is what the hit
> test already answers.

**Every change from the staged text, with its evidence.**

1. **"A `pdf` or `image` layer is selectable" → image only.**
   `LayerEnvelope.isSelectable` is `recognizedKind == .image`
   (LayerEnvelope.swift:297), and `LayerSelectionRuntime.select` *preconditions*
   on it (LayerSelectionRuntime.swift:236-239) — a pdf layer reaching selection
   is a trap, not a refusal. The staged rationale ("selection is how 'replace
   the worksheet' has a UI path at all") is the sentence the code contradicts,
   so it is replaced by a reason that is true of the code: a page-sized
   worksheet is the page.
2. **The delete path for `pdf` layers is stated as intent.**
   ⚠️ **Flagged for reconciliation.** This paragraph describes work being
   implemented in a parallel worktree as this is written; **check it against the
   landed code before you paste it.** If the delete path lands as
   page-deletion, the wording above is right as written. If it lands as
   something else — a layers list, a per-page menu, an import-time undo — the
   paragraph must be rewritten to name what shipped, and the surrounding rule
   ("a kind that is not selectable needs its own way to be removed") is the part
   that must survive intact either way. Do not adopt this paragraph blind:
   it is the one place in this document describing code I could not read.
3. **"a drag beginning anywhere else deselects and falls through" → the
   recognizer fails and the selection survives.** `grab(atPagePoint:)` returns
   `nil` for a touch that is not on the selected layer or its handles
   (LayerSelectionRuntime.swift:291-296), and `LayerDragRecognizer` fails
   immediately when `shouldBegin` says no; nothing in that path clears
   selection. Deselection happens only in `tapped(atPagePoint:)` → `select(nil)`
   (LayerSelectionRuntime.swift:222-227, :231-234). Selection chrome therefore
   rides through a scroll, which is the behaviour, and it is better than the
   drafted one: a drag that pans the page should not silently destroy a
   selection the user made deliberately.
4. **The blank-page sentence is narrowed** to the staged suggestion, which is
   what the code does: `installSelectionIfNeeded` builds nothing unless
   `staticLayers.contains(where: \.isSelectable)`
   (PageCanvasController.swift:591-593). **Note the consequence this narrowing
   now has, given change 1:** a page carrying only a `pdf` layer has nothing
   selectable, so an imported worksheet page also grows no selection machinery.
   That is consistent and cheap, and it is the mechanism behind change 2's
   necessity.
5. **`locked` adopts as a rule** — it is read in two owners
   (LayerSelectionRuntime.swift:296 and :551-554 for the dashed handleless
   chrome; EditorSession.swift:1517-1519 for the durable refusal) and written by
   exactly one (`setLayerLocked`, EditorSession.swift:1540). It passes the
   "no field a shipped kind does not read" test. Its *durable* half — the
   envelope's fifth field and absent-decodes-as-false — is **open question 8**,
   below, and A11's wording above does not depend on how you answer it.
6. **The escape-hatch paragraph is cut.** It argues against a design nobody
   proposed to build and reasons about the fork doc; `Contract.md` "carries no
   history". The finding it records is worth keeping — it lives in the code, at
   LayerSelectionRuntime.swift:36-50, which is where `AGENTS.md` says a rule's
   reason lives.
7. **The pinch paragraph is kept**, trimmed of its fork-doc reference. Unlike
   the escape hatch, it states a live constraint about a gesture the contract
   itself hands to the framework, and the next person to want a pinch will
   reach for this section.

## A12. *Performance* — the live-canvas bound survives layers

**Staged:** `Contract.proposed.md:435-445`.

**Disposition: adopt, verbatim.**

**Final wording**, added to the hard invariants at `Contract.md:196-203`:

> - A page has exactly one `ink` layer. The live canvas count is bounded per
>   page in the live window; ink layers multiplying per page would multiply
>   canvases inside that bound.

**Evidence.** `Contract.md:85` already carries the one-ink-layer rule as a
format rule; the deliberate duplication is argued in the staged text and the
argument is right — the two homes state the same constraint for two different
reasons, and someone lifting it will read one or the other. One `PKCanvasView`
construction site is machine-checked (ContractStructureTests.swift:652).

## A13. *Durable form* — the kind set opens to `pdf`

**Staged:** `Contract.proposed.md:447-514`.

**Disposition: amend** — one merged kind line in place of A5's and A13's two;
the five payload bullets adopt **verbatim**; the diagram line is already folded
into A6 above.

**Final wording — the kind line**, replacing `Contract.md:83`:

> - **The set of kinds is closed.** The kinds are `ink`, `image`, and `pdf`.
>   Adding a kind is a new case plus a `CONTRACT:` amendment, one amendment per
>   kind and no bundling — there is no metadata bag, no extension payload, and
>   no field a shipped kind does not read.

**Final wording — the five bullets**, after A6's `image`-payload bullets,
verbatim from the staged text:

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

**What changed.** Only the kind line: it names three kinds instead of stepping
through two, and it absorbs the per-kind friction A5 was defending into the rule
itself, where the next author will actually read it. The staged kind line's
existing tail ("there is no metadata bag…") is preserved from `Contract.md:83`
verbatim.

**Evidence.** `LayerKind` has three cases (LayerEnvelope.swift:~170-182);
`PDFLayerRef` is `{ assetID, sourcePageIndex }` with no format and no size;
PDFSource.swift:11-12, :62-65, :102-117 for the CropBox → MediaBox → `/Rotate`
derivation, made in one place exactly as the bullet claims; the out-of-range
index refuses at render (StaticLayerRenderer.swift:~629). The staged
"why the size decision went this way" argument is reasoning, not rule, and is
correctly absent from the wording above.

## A14. *Durable form* — `layers/` splits out of the page file

**Staged:** `Contract.proposed.md:516-597`.

**Disposition: adopt.** Five edits, all matching code. The diagram edit is
already folded into A6's diagram above; the other four follow.

**Final wording — replacing the inlining sentence** (`Contract.md:81`, second
sentence):

> A layer envelope is one file, named by its `layerID`, and a page file is the
> ordered list of layer IDs that make up the page. Order is z-order. A layer
> file carries its own `layerID` and is checked against the name it is filed
> under, exactly as a page file's repeated `pageID` is.

**Final wording — replacing the "save writes only what changed" bullet**
(`Contract.md:90`):

> - **A save writes only what changed, at the finest granularity the form
>   has** — which is one layer. Ink on page 4 of a fifty-page import writes
>   page 4's ink layer file and nothing else: not the `pdf` envelope beneath
>   it, not page 4's own page file, whose layer list did not change, not the
>   other pages, not the asset, not the index. Rewriting an unchanged file at
>   any level is a defect rather than an inefficiency: it is the whole-document
>   rewrite this format exists to prevent, one level down.

**Final wording — replacing the write-order bullet** (`Contract.md:93`; this is
the one write-order bullet, superseding A6's):

> - **Write order is leaf-to-root: assets, then layer files, then page files,
>   then the index**, so an interrupted save leaves an orphan at some level and
>   never a dangling ref at any. A save that names an asset or a layer which is
>   neither already durable nor being written now is refused before any write.
>   **Deletion is the mirror, root-to-leaf**: the page file drops the ref
>   first, the layer file dies second, the asset dies third.

**Final wording — two bullets after the dangling-asset bullet:**

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

**Final wording — replacing the migration sentence** (`Contract.md:88`):

> The pre-layer page form (bare drawing bytes) and the pre-split form
> (envelopes inline in the page file) are both read, and written forward on the
> page's next save, never migrated eagerly. **A page not yet in the split form
> writes all of its layer files forward on that save**, because none of them
> has a file to be unchanged. Three forms are read; exactly one is written.

**Evidence.** PageFile.swift:13-52 — the three-forms table is in the code's own
doc comment, `encode(to:)` writes only the third form, and `inlineLayers` is
non-encoded and read by exactly the two paths the amendment describes.
DocumentStore.swift:12-14 for the directory shape; the write order (layers →
pages → index, index unconditionally last) survived adversarial review
(`ReviewFindings.md:250-251`). The staged sections *Why here and not at phase 1*
and *The cost, stated honestly* are reasoning and correctly absent from the
wording above — though the cost paragraph's last line is worth remembering: "a
save landed" is no longer observable by watching `pages/`.

## A15. *Owners* — the import rule and `CoreGraphics`

**Staged:** `Contract.proposed.md:601-632`.

**Disposition: yours.** See the checklist. **Recommended: ratify — and add
`ImageIO` at the same time, which costs zero new allowlist entries.**

**Recommended final wording**, replacing `Contract.md:67`'s first sentence:

> Durable value types import Foundation only — not UIKit, not PencilKit, not
> CoreGraphics, and not ImageIO. The two graphics frameworks are named
> explicitly because each arrives as a whole vocabulary: admitting
> `CGPDFDocument` admits `CGContext`, `CGImage`, and every drawing call
> attached to them, and a durable value that can hold a `CGAffineTransform` will
> eventually hold one. `PageSpaceTransform` is six `Double`s for exactly this
> reason.

**The case (recommended side).** The widening is already enforced and the only
unacceptable state is the current one — a machine-checked rule stricter than the
document it claims to enforce. Between ratifying and reverting, ratify: the
rule's *purpose* is that a durable value type cannot acquire a graphics
vocabulary, and CoreGraphics is the most likely source of one on this branch —
`PageSpaceTransform` exists as six bare `Double`s precisely because
`CGAffineTransform` must not reach the durable form, and until the widening
nothing mechanical stopped the next author from reaching for it. The two
allowlist entries it costs (`PDFSource.swift`, `StaticLayerRenderer.swift`) are
manifestly not durable value types and each carries a paragraph saying why, so
the allowlist is documenting a real boundary rather than papering over one.
**`ImageIO` should join in the same edit**: its rationale is identical — pixel
decoding vocabulary — and the two files that import it,
`StaticLayerRenderer.swift` and `ImportPickers.swift`, are *already* on the
allowlist for other reasons, so the addition costs one array element and zero
new entries. Leaving it out is the half-enforcement `ReviewFindings` names, and
it is free to close.

**The alternative, in brief.** Revert: delete `"CoreGraphics"` from
`uiFrameworkModules` (ContractStructureTests.swift:219) and both allowlist
entries become unnecessary. This is the position with the cleanest principle —
an agent widened a machine-checked rule overnight, and this contract says no
agent authors a rule, so the default answer to "an agent did this" is undo it
and let a human redo it deliberately. Cost: nothing mechanical prevents the next
durable type from importing CoreGraphics, and `PageSpaceTransform`'s six
`Double`s become a convention rather than a constraint.

**One naming consequence either way.** The checker's constant is called
`uiFrameworkModules` and neither CoreGraphics nor ImageIO is a UI framework. If
you ratify, rename it — `frameworksDurableTypesMayNotImport`, or similar — so
the code and the rule use one word for one idea. If you revert, the name becomes
accurate again on its own.

**Evidence.** ContractStructureTests.swift:219 (the widened set), :524-604 (the
allowlist and its per-file reasons); `PDFSource.swift` imports CoreGraphics and
Foundation only; `StaticLayerRenderer.swift` imports CoreGraphics, Foundation,
ImageIO and no UIKit; `ImportPickers.swift` imports ImageIO and is allowlisted
for UIKit already; the seven `import ImageIO` sites are two app files and five
test files, and tests are not policed.

---

# Part 2 — the correction sections

## C1. A8 correction — where geometry lives

**Staged:** `Contract.proposed.md:691-721`.

**Disposition: adopt, verbatim.**

**Final wording**, replacing `Contract.md:79`:

> `document.plist` holds the format version, `documentID`, an ordered list of
> pages — each its ID and **its own geometry** — the current page index, and the
> document's absolute zoom cap. A page file holds no geometry: the index is the
> one file read whole at open, and page files are read lazily, so geometry in a
> page file would either make opening a notebook scale with its total size or
> make a page's position depend on what had finished loading.

**Evidence.** DocumentIndex.swift:87 and :133-140 — the index carries
`pages: [{ id, geometry }]`, `currentPageIndex`, `formatVersion`, `documentID`,
and `zoomCapPagePointsPerPixel`. `PageFile` carries `{ pageID, layerIDs }` and
no geometry (PageFile.swift:39-41). The paging argument holds:
`PagedCanvasController` sizes content and places slots before any page outside
the live window is read (PagedCanvasController.swift:319-330).

## C2. A8 correction — mixed slots, decided

**Staged:** `Contract.proposed.md:723-742`.

**Disposition: amend — one sentence, and it belongs in *Navigation*, not
*Geometry and coordinates*.**

**Final wording**, added to *Navigation* after the paging-contention paragraph
(and before A11's block):

> A slot in the paging scroll view is **one viewport wide, always, whatever the
> page in it measures**. The page varies inside its slot, not the slot: a page
> canvas fills its slot and fits its own page inside itself — its zoom floor and
> its opening scale come from its own geometry — and the room left over is
> centred. This is what keeps one page per swipe true across mixed geometry
> without hand-written snap arithmetic.

**What changed.** The staged block's second half — the pricing of the
filmstrip alternative, the prefix sums, `settle` becoming a search — is
reasoning about a road not taken and does not go into `Contract.md`. It is
already recorded where it belongs, in the code
(PagedCanvasController.swift:345-351). The last clause of the adopted sentence
is added so the rule states what it buys, per the contract's habit of putting
the reason next to the rule.

**Placement.** *Navigation* owns "one page per swipe, snapping to a page
boundary" and the drag-contention settlement; a slot's width is that section's
business. *Geometry and coordinates* owns spaces and durable extents, and a slot
is neither.

**Evidence.** PagedCanvasController.swift:319-330 (the slot is one viewport
wide, and the composite detail derivation depends on it), :345-351 (the decision
and its reasoning in the code).

## C3. A8 correction — its third replacement conflicts with A6b

**Staged:** `Contract.proposed.md:744-768`.

**Disposition: adopt as an instruction. It contributes no text of its own.**

**The instruction:** do not adopt A8's replacement for the "Rotation, crop, PDF
source coordinates, normalized coordinates, and annotation anchors do not exist"
sentence. Adopt **A6b's** replacement instead (see A6b above). A8's version says
PDF and image *source coordinates* exist and that each layer maps source space
to page space; the code maps the source's **unit square**, and no durable value
anywhere states a source's extent.

**Evidence.** Independently confirmed: AssetRef.swift:37-43 (no pixel size,
stated as a decision), `PDFLayerRef` (no size), PDFSource.swift:102-105 (the
renderer re-derives the box from the asset). This is the one place two staged
amendments contradict each other, and the correction section already picked the
right one; this entry exists so the conflict cannot be re-introduced by adopting
A8 top to bottom.

## C4. A9 correction — the units stand, the value is not free

**Staged:** `Contract.proposed.md:770-796`.

**Disposition: adopt — folded into A9's block above.** The value, the framework
clamp, and the "different ink surface, not a different constant" line are in
A9's final wording. The two "consequences worth stating plainly" are history
and stay out of `Contract.md` (argued under A9).

## C5. A9 correction — where an unhonourable cap is refused

**Staged:** `Contract.proposed.md:798-806`.

**Disposition: adopt — folded into A9's block above,** and extended with the
coarse end of the same guard, which was enforced and unstated.

## C6. The index format version is bumped; the page file's was not

**Staged:** `Contract.proposed.md:808-817`.

**Disposition: amend.** Most of this section is a log entry — which phase bumped
what, and why phase 3a did not — and belongs in `OvernightLog.md`, where it
already is. **One durable rule inside it is stated nowhere in `Contract.md` and
should be**, because it is the rule that decides what happens when a future
build meets a file it does not understand.

**Final wording**, added to *Durable form* after the `document.plist` sentence
(C1's replacement):

> The index carries a format version and the page and layer files do not. That
> is what the version is for: a build meeting an index newer than it knows
> **refuses the document**, saying so, rather than failing to find a key and
> reporting that the index will not decode. A superseded version it *does* know
> is read, and written forward on the first save that follows — never migrated
> eagerly, exactly as a page file's older form is.

**Evidence.** DocumentIndex.swift:54 (the version table in the code's own doc
comment), :195-215 (v2 and v3 read, v3 written), :250-253 (a version this build
does not know throws `unsupportedFormatVersion`); the v2→v3 migration and the
version-4 refusal survived adversarial review (`ReviewFindings.md:251`).

## R1. "Amendments this milestone does NOT need"

**Staged:** `Contract.proposed.md:634-645`.

**Disposition: refuse — no contract text.** Four deliberate absences (no `shape`
kind, no SVG interchange rule, no export rule, no collaboration/sync/AI). All
four are correct and all four are *absences*; `Contract.md` states what is in
force and does not enumerate what it declined. The record survives in
`Contract.proposed.md`'s history and in `Docs/Queue.md`. Nothing to paste.

One of them is worth carrying forward as knowledge rather than as text: the
`shape` tool commits snapped strokes into the ink layer and so changes no
durable form. If a future change makes shapes their own kind, that is a
`CONTRACT:` amendment under A13's per-kind rule, and this is why.

## R2. "What A8 did *not* need"

**Staged:** `Contract.proposed.md:819-827`.

**Disposition: refuse — no contract text.** Both entries are consequences of
adopted rules rather than rules: the appended page taking canonical geometry
follows from A8, and `PageSpaceTransform` needing no reconciliation follows from
A13's unit-square payload. Verified true — `appendPage` builds a page at the
canonical geometry (EditorSession.swift:851) and an imported page's `pdf` layer
maps the unit square edge to edge — and stating a consequence as a rule is how a
contract grows text that cannot be violated.

---

# Part 3 — the silent drift

Rules the code enforces that **neither** contract file states. Four are prose,
below, each with paste-ready wording. The fifth is code.

## D1. Structural edits save immediately, bypassing the ink debounce

**Disposition: amend in — new prose in *Saving*.**

**Final wording**, added to *Saving* after the paragraph "Work arriving during a
save receives a fresh debounce after that save returns" (`Contract.md:130`):

> The debounce is **ink's**. An edit that is not interaction-frequency does not
> wait for it: an import and a layer deletion each save immediately, once, when
> they complete. The distinction is the reason the debounce exists — it
> coalesces a stream of strokes into one write, and a one-shot structural edit
> is not a stream. A layer *transform* is the exception that proves it: a drag
> produces a value per frame, so a commit dirties the page and takes the
> ordinary debounce like ink.

**Evidence.** `importImage` awaits `saveIfNeeded()` directly
(EditorSession.swift:1360), as do `importPDF` (:1456) and `deleteLayer` (:1653).
`transformLayer` (:1508-1530) does **not** — it marks the list unsaved and
leaves the debounce to it, and says so in its doc comment at :1500-1502. The
`ReviewFindings` line numbers for these three sites have drifted; the behaviour
is unchanged.

## D2. The composite level-of-detail policy

**Disposition: amend in — new prose in *Performance*.**

**Final wording**, added to *Performance* after the in-memory-caching paragraph:

> A composited static backdrop is rendered at **one derived level of detail**:
> fit-width times the display scale, never below one pixel per page point, and
> capped so the composite's long edge does not exceed 2,800 pixels — the page's
> own long edge, so a landscape page is capped by its width where a portrait one
> is capped by its height. The cap is a texture budget, not a quality choice.
> The consequence is user-visible and is the design: zoomed past fit-width, the
> backdrop is soft until a sharp patch at the settled zoom replaces it. **One
> derivation, in one place** — a second copy of this arithmetic is two numbers
> that drift, and a drifted number is a prefetched render that can never be the
> render the page asks for.

**Evidence.** `PageCanvasController.compositeDetail` (PageCanvasController.swift:
812-828) — `min(max(fitWidth × displayScale, 1), 2800 / max(width, height))`,
rounded to two places, `static` so the prefetch warm reproduces it exactly, with
the drift argument in the code at :806-811. `maximumCompositeLongEdge = 2800` at
:189. The lens is the sharp patch (:830-841). Today this policy lives only in
those comments.

## D3. An `image` layer may not name a PDF asset

**Disposition: amend in — new prose in *Durable form*.**

**Final wording**, appended to A6's `image`-payload bullet (the first of the
three), so the cross-check sits with the field it constrains:

> The check is on the pair, not on the format alone: a format outside the closed
> set refuses the layer, and so does a format that is in the set but is not an
> image. An `image` layer naming a `pdf` asset is the same invalid state as one
> naming an encoding this build has no decoder for, and takes the same refusal.

**Evidence.** `ImageLayerRef.recognizedFormat` switches exhaustively over
`AssetFormat` and returns `nil` for `.pdf` (AssetRef.swift:66-83), with the
reasoning in the doc comment. Its four call sites all treat `nil` as a refusal
(EditorSession.swift:1718; StaticLayerRenderer.swift:314, :478, :629;
DocumentStore.swift:534). Exhaustiveness is deliberate — a new encoding cannot
be added without deciding this — and that is a rule, not an implementation
detail.

## D4. Importing a PDF appends at the end and does not navigate

**Disposition: amend in — new prose in *Navigation*.**

**Final wording**, added to *Navigation* after the swipe-past-the-last-page
paragraph (`Contract.md:168`):

> Importing pages appends them **at the end of the document and does not
> navigate to them**. Import is not a turn: moving the user somewhere they did
> not swipe would be the editor taking a navigation decision, and the current
> page is theirs.

**Evidence.** `importPDF` rebuilds the index with
`currentPageIndex: index.currentPageIndex` (EditorSession.swift:1440) and then
`pages.setPages(count:currentPageIndex:)` with the same value (:1444). This is
deliberate and unstated; whether it is *right* is a product judgement — if you
would rather an import land the user on the first imported page, this is the
sentence to invert, and it is a two-line code change. Recommended as written:
it matches the code, and the rule is defensible on its own terms.

## D5. `RootCanvasView.@State shapeKind`

**Disposition: code, not prose. Note only — no contract text.**

`RootCanvasView.swift:15` holds `@State private var shapeKind: ShapeKind?`, a
copy of the active tool whose sole writer is `PagedCanvasController`
(`Contract.md:44`). It is written at :180 and read at :187 to tint the selected
button. This is the exact copy `EditorSession.setShapeTool` refuses to hold —
and says so, at EditorSession.swift:390-394 — held one level up instead. It is a
golden-rule-1 and golden-rule-2 violation, and no rule needs writing: the
contract already forbids it in two places.

**Fix it, do not document it.** Stage 1 item 4 names this as its code half. The
shape is small: the SwiftUI root sends an intention and renders a snapshot, so
the selected tool must be readable *from* the owner rather than mirrored beside
it. Out of scope for this document, which authors no code.

---

# Part 4 — the file's own open questions

Answers to `Contract.proposed.md:647-680`, plus one the file does not ask.

**1. A4's duplicated editability sentence — pick a home.**
***Durable form.*** Cut it from A4's block. Argued under A4 above.

**2. A5 versus a general rule.**
Keep the per-kind friction; spend it on the *next* kind. Write today's three
kinds in one line, and state the toll as part of the rule so it cannot be
bundled away quietly. Wording under A13.

**3. A10 is written as if the spike passed.**
Yours. Recommended: adopt the amended wording (which is a true description of
shipped code) and put the *outcome* claim — that Cmd-Z undoes a layer move on a
device — in `Docs/Unproven.md` until spike 3. Full case under A10.

**4. A8's two calls worth your eye.**
Both ratified above. Geometry in the index: **yes** (C1) — the paging arithmetic
needs it before any page file is read, and the alternatives are opening every
file or re-laying pages under the user's finger. A slot one viewport wide:
**yes** (C2), with the alternative priced in the code and nothing durable
depending on the choice.

**5. A13's unit-square-versus-point-size call.**
Ratified: unit square, no stored size. The strongest argument for storing it —
a PDF page has an intrinsic size in points, unlike a bitmap — is real and still
loses. Under A8 an imported page's *geometry* already is its source's size in
points, so a durable size in the payload is a third copy of one number; and
"the page's size" is a choice among five boxes plus a rotation, which
PDFSource.swift:62-65 and :102-105 make in exactly one place. Freezing that
choice into every payload ever written is the drift that has no detector.

**6. The zoom cap's value was decided by a framework limit, not by taste.**
Acknowledged, and now stated in the contract rather than only known — see A9's
second paragraph. The operative consequence for planning: deeper than 20 device
pixels per page point is a different ink surface, not a different constant.
Price any future lens work with that in hand.

**7. `CoreGraphics` joined the checker's banned list.**
Yours. Recommended: ratify, add `ImageIO` (free — both importing files are
already allowlisted), and rename `uiFrameworkModules`, which describes neither.
Full case under A15. Note the file's own count is right here and stale
elsewhere: there are **two** allowlist entries attributable to the widening,
`PDFSource.swift` and `StaticLayerRenderer.swift`.

**8. The question the file does not ask: the envelope's fifth field.**
`ReviewFindings` #5. **Yours.** Recommended: **bless absent-as-false, and amend
the envelope-shape sentence** — no amendment in the staged file touches it, so
adopting every amendment above still leaves `Contract.md:81` describing four
fields while five are on disk.

**Recommended final wording**, replacing the envelope sentence at
`Contract.md:81`:

> A page is an ordered list of layers. A layer is one durable envelope, uniform
> across kinds: `{ layerID, kind, payload, pageSpaceTransform, locked }`.
> `locked` is the one field a reader may find absent: an envelope written before
> it existed decodes as unlocked. That is the read-forward rule this section
> already states for the pre-layer page form, one level down — a bit nobody
> could have set, in a file written by a build that had no way to set it — and
> not a defaulted invalid state, which nothing here is permitted to be.

**The case.** *Invalid states fail loud* forbids clamping, adapting, correcting,
or defaulting — and the test that separates this from a violation is whether the
absent value is *ambiguous*. It is not. Every build that could write a file
without the key was a build in which no layer could be locked, so the absent key
has exactly one meaning and the decode is a translation rather than a guess.
Refusing instead would make every page file on disk unreadable, for a bit that
changes no other rule — a cost with nothing bought, and this project has no
users to protect from it, which is precisely why the choice should be made on
the principle rather than on the blast radius. The reason the wording says it
out loud, rather than leaving it in a code comment, is that today it *is*
justified only by an agent's analogy; putting the analogy in the contract is
what converts it into a rule a human made. Note the one live inconsistency this
does not cover, and that you may want closed the other way:
`DocumentIndex.zoomCapPagePointsPerPixel` also decodes-if-present with a
canonical fallback (DocumentIndex.swift:199-202). Same pattern, same argument,
one sentence away from also being stated — or from being the second reason to
strike the pattern entirely.

**The alternative, in brief.** Strike it: make `locked` required, let old files
fail to decode, and delete the `decodeIfPresent` (LayerEnvelope.swift:285). The
contract's "never implement legacy support or backwards shims unless I say to"
points here, and there is nothing on disk anywhere that matters. Cost: the
pre-layer and pre-split read-forward rules in *Durable form* stay, so the format
would then read forward at two levels and refuse at a third, which is a harder
rule to hold in your head than "we read what we understand and write forward".

**Evidence.** LayerEnvelope.swift:216-220 (five stored properties), :285
(`decodeIfPresent … ?? false`), :262-278 (the read-forward argument as the code
states it); `Contract.md:7` (*Invalid states fail loud*), `Contract.md:88` (the
pre-layer read-forward precedent this leans on).

---

# The checklist — what is still yours

Everything above is either a paste or a decision already made. These are the
open ones. Each has a recommendation and a full case at the reference.

- [ ] **A10 — undo, one manager, two clients.** Adopt the amended wording now
      with the outcome claim moved to `Unproven.md`, or hold the section for
      spike 3. *Recommended: adopt amended.* → **A10**
- [ ] **A15 — the `CoreGraphics` ban.** Ratify (and add `ImageIO`, free), or
      revert the widening and delete two allowlist entries. Either way, rename
      `uiFrameworkModules`. *Recommended: ratify + `ImageIO`.* → **A15**
- [ ] **The envelope's fifth field.** Bless absent-as-false and amend the
      envelope-shape sentence, or strike the pattern and let old files fail.
      *Recommended: bless, with the reasoning written into the rule.* →
      **open question 8**
- [ ] **A11's pdf-delete paragraph.** Read the parallel worktree's landed code
      before pasting; the surrounding rule survives either way. → **A11**,
      change 2
- [ ] **D4 — import does not navigate.** A product judgement, not a defect.
      Confirm the code's behaviour is the one you want before writing it down.
      → **D4**
- [ ] **A6's asset extensions and HEIC.** Adopt `.png, .jpeg, .pdf` today;
      confirm that the HEIC amendment rides in stage 1 item 6's own commit
      rather than being pre-written. → **A6**
- [ ] **Sequencing with `01-Saving.md`.** It also writes into *Saving*.
      Decide the order once, do both. → the note at the top

Two things this pass does **not** clear, flagged so their absence is deliberate:
stage 1 item 3 (*Saving* is false in two places) is dispositioned in
`01-Saving.md`, not here; and D5 (`RootCanvasView.shapeKind`) is a code fix with
no prose. Both must land for stage 1's exit — "a new contributor can read
`Contract.md` and nothing in `Contract.proposed.md` is load-bearing" — to be
true.
