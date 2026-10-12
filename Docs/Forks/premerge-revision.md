# Proposal: the pre-merge revision of the pdf-templates stack

Status: proposal, unreviewed by Phillip. Written by an agent from the
2026-08-12 twelve-reviewer parallel review of `main...4035bf7`
(`library-lane-f` → `library-overnight` → `pdf-templates`; consolidated
findings at https://claude.ai/code/artifact/1af0cfda-f41c-4846-8af4-b90303c0374c).
Every claim below was anchored to code by a reviewer and the load-bearing
anchors were re-verified; line numbers are at `4035bf7`. Nothing here is a
rule.

**Verdicts, Phillip, 2026-08-13.** The open decisions are closed: R4 —
implement a real document identity (keep the field, make it true). R9 —
remove `locked`. R10 — deferred; the contract pass is Phillip's alone, on
his own schedule, and is not part of this revision's work queue. R11 —
deferred for now; the gaps stand as recorded. The sections below carry the
verdicts in place of the former decision blocks.

## What gates the merge, and what does not

The merge is the moment this stack becomes the base every later lane builds
on, so three classes gate it:

1. **Ink** — any path where a user's strokes are lost or a save lies about
   having happened.
2. **Bytes** — durable-format decisions. After merge, code piles onto the
   format immediately (thumbnail keys, the page navigator, export), and the
   contract forbids migrations, so a format edit is free now and forbidden
   later.
3. **Rules and proof** — the contract adoption pass, and the tests whose
   absence lets 1 and 2 regress silently. *(Both deferred out of the gate by
   the 2026-08-13 verdicts — R10 runs on Phillip's own schedule, R11 waits —
   so the merge now rests on classes 1 and 2 alone.)*

Explicitly **not** gating: UX nits, GoodNotes parity gaps, the page
navigator, export, recursive search, haptics, keyboard shortcuts. Those are
post-merge lanes and the review artifact holds them, ordered. Performance
findings gate only where the arithmetic is already wrong on the primary
device (R12).

Fixes land on this stack (or a fix branch off it), not on `main`. R1–R3
touch `EditorSession`, so per `AGENTS.md` — *Definition of done* they need
evidence from a physical iPad, not only green CI.

---

## R1 — A draining session's package is inviolate

**Defect.** After a dirty close the session is retained and still writing,
but `DrainingSession` carries no item path (`LibraryCoordinator.swift:33-37`)
and `canOpenDocuments` (`:68`) gates opening only. Eight mutations are
ungated — rename, move, trash, duplicate, batch trash, batch move,
`deletePermanently`, `emptyTrash` (`LibraryBrowserModel.swift:331, :351,
:363, :391, :248, :304`; `LibraryToolbarMenu.swift:301, :310`) — and
`FolderListingModel` holds `LibraryStore` directly, never passing the
coordinator. When a mutation moves the package, the next retry calls
`createDirectoriesIfNeeded()` (`DocumentStore.swift:663, :690 → :855-858`),
which recreates the package at the old path; `indexNeedsWriting`
(`:678-679`) then writes the **full** index beside only the dirty page
files — dangling page refs, which *Durable form* calls fatal. The save
succeeds, the banner clears, the close reports `.clean`, and the user is
told nothing. Four reviewers reached this independently.

**Change.** Two independent edits, then one structural one:

- `DrainingSession` gains `itemPath`. Every library mutation refuses —
  throwing a typed `LibraryError` the banner already renders — when its
  target is the draining path or a folder that prefixes it. Refusal is loud,
  per *Invalid states fail loud*.
- `DocumentStore.save` never recreates its package root. Directories are
  created on the first save of a document only; thereafter a vanished
  `directoryURL` throws. A package that disappeared under a live store is an
  invalid state, not something to correct.
- Structurally (may follow the two edits in the same revision):
  `LibraryStore` becomes the sole vendor of package access — a package is
  checked out to one `DocumentStore` at a time, and tree mutations refuse on
  a checked-out package. This is the serialization point every future writer
  (scenes, export, sync) plugs into, and it makes the comment at
  `LibraryCoordinator.swift:9-11` true instead of aspirational.

**Done when** a test holds a drain open, issues each of the eight mutations,
and observes the typed refusal; and a test deletes the package under a live
store and observes `save` throw rather than recreate.

## R2 — The close window must not eat a stroke

**Defect.** Between the Back tap and `close()` returning, the canvas is
still editable (`.disabled(coordinator.isClosing)` sits on the back button
only, `EditorContainerView.swift:41`) while `drawingChanged` drops every
report (`EditorSession.swift:1515-1529`). A stroke finished in that window —
which spans a full save pass, measured at 126 ms cold at 20k strokes — is
never marked dirty, so `performClose` reports `.clean` and the canvas is
released with the stroke in it. A false `.clean` also releases the package
to R1's library mutations.

**Change.** Delete the `isClosing` early return and let the report mark the
page dirty. The drain machinery already handles the rest: `markDirty`
refuses to arm a debounce while closing (`:1597`), `performOneSave`'s exit
owns the re-arm (`:1982`), so the close returns `.dirty` and the coordinator
retains the session to drain — which is what retain-if-dirty exists for.
(The stronger form — retire the live window through the ordinary handover at
`close()` entry — is acceptable instead; either way the canvas must not be
both editable and unheard.)

**Done when** a test draws during a held drain and observes `.dirty` and the
stroke on disk after the drain completes.

## R3 — `.clean` means no outstanding writes

**Defect.** `performClose` awaits `startTask` and the save — nothing else.
`reclaimPage`'s three store deletions (`EditorSession.swift:1385, :1398,
:1403`), `deleteLayer`'s reclaim, and `writeAsset` can all still be running
after `close()` returns `.clean` (`:2513-2552`), inside a package the
library has just been told it may mutate. R1's gate is only sound if
`.clean` is honest.

**Change.** One handle for post-save store work — the shape `currentSave`
already has — set before any reclaim/asset write suspends, awaited by
`performClose` alongside `currentSave`.

**Done when** a close issued mid-reclaim returns only after the last unlink,
under a store decorator that holds deletions open.

## R4 — A real document identity, and an honest Duplicate

**Defect.** `documentID` is minted (`EditorSession.swift:300, :519`),
encoded, decoded — and read by nothing; `duplicateDocument` clones it
byte-for-byte under a `KNOWN DEFECT:` block (`LibraryStore.swift:383-387`)
whose justification — "nothing library-level keys on it tonight" — is true
only because nothing reads it at all. The de facto identity is the mutable
relative path, and favorites, trash origins, the thumbnail key, and the open
seam all key on it. The project currently has no stable document identity.

**Verdict: keep the field and make it true.** Duplicate routes through a
new `DocumentStore.rewriteDocumentID(_:)` — the rewrite happens through the
store because `LibraryStore` must not open a package, and the natural moment
is the staged copy, before the atomic landing move, so the copy is born with
its own identity rather than acquiring one after it exists. In the same
commit, `documentID` gains one shipped reader so it cannot rot again:
`LibraryThumbnailStore.Key` becomes `{documentID, modifiedAt}`
(`LibraryThumbnailStore.swift:40-43`), which also deletes the accepted
rename-re-renders cost recorded at `:34-36`.

**Done when** duplicating a document yields two packages with two IDs, the
thumbnail cache is keyed on the identity, and the `KNOWN DEFECT:` block is
gone.

## R5 — The trash gives back what it took

**Defect.** `Trash/` is flat, so `trashItem` resolves collisions by really
renaming the user's package (`freeName`, `LibraryStore.swift:449-453`), and
the origin sidecar records the folder but not the name (`:874-880`), so
`recoverItem` (`:529-565`) restores under the suffixed trash name. A trash →
recover round-trip through a feature whose whole promise is reversibility
**permanently renames the notebook**, and `LibraryStoreTests.swift:373-395`
currently blesses the rename as correct.

**Change.** Per-entry containers: `Trash/<uuid>/<original name>` with the
sidecar inside as `.origin.plist`, and `TrashOrigin` gaining `originName`.
Nothing collides in the trash, so `freeName` leaves `trashItem` entirely;
recover suffixes only when the destination actually collides, which is the
one place suffixing was ever meant to happen. The two reserved-substring
hacks (`.origin.plist` skips at `:486` and `:690-692`) die with it.

**Done when** the round-trip test asserts the original name, not the suffix.

## R6 — Paper is a page's fact, named `paper`

**Defect.** `DocumentIndex.template` is document-wide, and its stated
justification — that `warmNeighbourComposites` needs paper "before those
pages' files have been read" (`DocumentIndex.swift:77-94`) — is contradicted
by the function it cites: its header says it runs *after* `fetchPageData`,
and its body reads `pageStates[…].staticLayers` (`EditorSession.swift:
757-762, :783, :792`). The claim was false at the base commit, and it is the
load-bearing argument in the proposal and in the staged contract text
(`Contract.proposed.md:1243-1249`), so adopting the amendment as written
enshrines it. Meanwhile per-page paper is already leaking in as a hard-coded
special case (`effectiveTemplate` forcing `.blank` for PDF pages,
`StaticLayerRenderer.swift:1172-1174`), and `importPDF` makes mixed
documents the normal case. The prefetch argument is fully satisfied by
`PageRecord` — the identical argument that already put geometry per page.

**Change.** `PageRecord` gains the field; `DocumentIndex.template` is
deleted. `setTemplate` maps over `index.pages` and still writes exactly one
file, so "one writer, and it writes one file" survives verbatim, as does the
whole warm path. The UI stays one document-wide control — per-page becomes a
later UI change with no format change behind it. The durable key is named
**`paper`** (freeing `template` for the GoodNotes catalog sense that is on
the parity path); renaming `PageTemplate` → `Paper` and
`PaperTemplateRenderer` → `PaperRenderer` is recommended in the same commit,
while the rename is one commit and not an archaeology. Strike the false
prefetch claim from the staged amendment text before R10 adopts it.

**Done when** the index carries no document-level paper, every
`PageRecord` round-trips its own, and a document created lined then appended
to yields lined pages throughout.

## R7 — A `pdf` layer records which rectangle it placed

**Defect.** A `pdf` layer persists `{assetID, sourcePageIndex}` plus a
transform whose domain is the source page's unit square
(`AssetRef.swift:180-233`) — and nothing durable says what that unit square
is. It is re-derived on every render from the asset's bytes
(`PDFSource.swift:136-149`: CropBox falling back to MediaBox, `/Rotate`
applied). The math today is verified correct; the defect is that the durable
value's meaning is a function of this build's box policy. Change the policy —
a box preference, a `/Rotate` edge case, a Quartz difference across an OS
version — and the worksheet moves under strokes already committed to disk,
undetectably, because no durable value records what the rectangle was when
the ink was drawn. Same class as the moving zoom cap that
`zoomCapPagePointsPerPixel` exists to fix.

**Change.** `PDFLayerRef` gains the displayed source extent — post-`/Rotate`
box origin, size, and normalized rotation — written once at import from the
same `displayGeometry` call. The render path compares its fresh derivation
against the stored value and **refuses the layer** on disagreement
(`RefusedLayer.Reason` gains a case); refusal, not preference, per *Invalid
states fail loud*. The amendment adopting this must cite *Forbidden
patterns* explicitly: the value derives from the asset, not from the ink the
rule protects, and that distinction should be stepped through, not over.

**Done when** a fixture whose stored rectangle disagrees with the derivation
loads as a refused layer, and import round-trips the recorded extent.

## R8 — A current-version file missing a key refuses; key sets are pinned

**Defect.** `template` and `zoomCapPagePointsPerPixel` are
`decodeIfPresent` with defaults that survive `validated()`
(`DocumentIndex.swift:210-221`). The stated reason — a newer build's file
should decode far enough to be refused by number — applies only when
`formatVersion != 1`, and the comment says so itself. For a version-1 file
the leniency inverts: a lined notebook whose index loses one key opens
blank and the next save writes `blank` over the user's choice. The code's
own reasoning twelve lines away (`:313-315`) refutes the exemption, and
`PageTemplateDurableTests.swift:55-64` certifies the wrong behaviour.
Separately, `PageFile` and `LayerEnvelope` carry no version and synthesized
`Codable` drops unknown keys on read and re-encodes without them on save —
so the only protection for a layer-file change is an index bump that nothing
states or tests.

**Change.** Gate the leniency on the version, which is decoded first:
require the keys when `formatVersion == currentFormatVersion`, keep
`decodeIfPresent` otherwise; invert the test to assert refusal naming the
key. Pin the coupling: one test asserting the exact encoded key sets of
`LayerEnvelope`, `PageFile`, `PageRecord`, `ImageLayerRef`, and
`PDFLayerRef` alongside `currentFormatVersion`, so changing either without
the other fails (`DocumentIndexTests.pageRoundTrip:74-82` is the model).

**Done when** a v1 index missing `paper` or the zoom cap refuses to open,
and the key-set pin exists.

## R9 — `locked` is removed

**Defect.** `locked` is a required durable key on every envelope whose only
writer is test-only (`EditorSession.swift:2295-2312` — "No UI calls this
yet"), so every envelope this build writes carries `false`, and only one of
three kinds reads it (`LayerEnvelope.swift:279-282`) — the literal wording
of "no field a shipped kind does not read" and of the placeholder ban. It
also makes the envelope five fields where the contract defines four.

**Verdict: delete it** — `locked`, `withLocked`, `setLayerLocked`,
`LayerEditError.layerIsLocked`, and `isTransformable`'s second conjunct
(after which `isTransformable` and `isSelectable` coincide and one of the
two goes) — along with the dashed-chrome branch at
`LayerSelectionRuntime.swift:555` and the locked test suites that pin the
behaviour. Phase 4 reintroduces the key with its UI, which is the "smallest
change" rule applied to a durable byte.

**Done when** the envelope is the contract's four fields, no `locked` symbol
survives in `Modules/`, `TuberNotesApp/`, or `TuberNotesTests/`, and the
required-key decode test goes with the key it pinned.

## R10 — The adoption pass

**Deferred (Phillip, 2026-08-13): this is Phillip's alone, on his own
schedule. Nothing in this section is agent work, and no other item in this
revision waits on it.** The record below stands so the pass has its map when
it runs.

Not a defect in code — the one piece of this revision only Phillip can do.
`Docs/Contract.md` is byte-identical to `main` across all 56 commits while
26 amendments sit staged; the drift is tracked, not neglected (`121c5df`
deliberately un-adopted an agent's `CONTRACT:` edit), and 18 of the 22
audited violations close in this single pass. The order matters — the pass
runs **after** R4–R9, so the contract is written once, against the revised
format, not twice.

- Reconcile the staged text's three self-contradictions first: the
  superseded version-2/3 read paragraph (`Contract.proposed.md:808-817`),
  the `locked` read-forward shim that `3c4337e` deleted (`:423-433`), and
  the asset extensions given as `.png/.jpeg` where the code writes and
  refuses by name anything but `heic`/`pdf` (`:124-127`, `:462`). Strike
  the false prefetch claim (R6) at `:1243-1249`.
- Adopt `Docs/Contract.draft.md` (791 lines, amendments already merged,
  verdicts marked `[DECIDE]`) into `Docs/Contract.md` in one
  `CONTRACT:`-tagged commit, in Phillip's own words. Hold **A10** (undo
  registrations) out until its device check runs — the code itself marks
  the premise "UNVERIFIED, and load-bearing"
  (`PageCanvasController.swift:1246-1253`).
- Two rulings the draft needs that no amendment states: golden rule 4's
  transitive read (the canvas holds a renderer that reads assets — carve it
  out or invert the seam), and `ImageIO`/`CoreGraphics` in TuberRender
  (A15, the amendment its author flagged for personal ratification).
- Vocabulary verdicts while the pen is out: `paper` (R6), notebook vs.
  document, `Notebooks/` vs. `Documents/` as the library root, `pageID`
  spelling.

After adoption (agent work): repoint the 19 shipping-code citations of
`Contract.proposed.md` at `Contract.md`; add the structural guard that
`Contract.proposed.md` may never contain the string `FORCED`; fix the stale
seam comment at `DocumentStoring.swift:28-30`; delete the dead
`defaultDirectoryURL()` and `deleteOrphanedPages()`.

## R11 — The proof the format is owed

**Deferred for now (Phillip, 2026-08-13). The gaps stand as recorded below —
in particular, the write-order rule remains untested, so a refactor that
reorders the save's blocks still goes green.** Tests that arrive as part of
implementing R1–R9 (a changed behaviour's own coverage) are not deferred;
this section's standalone proof suite is.

- **Write order.** "Page files first, then the index" is called load-bearing
  and has no test: every interruption test hand-writes the end state, so
  reordering the blocks at `DocumentStore.swift:648-694` breaks nothing.
  Add a `DocumentStoring` decorator that fails the Nth write of a save,
  sweep N, and assert after each: `load()` succeeds or reports a missing
  page file **the index does not name** — never a dangling ref.
  `HeldSaveStore` proves the seam decorates.
- **The two overstated commit-record claims.** `e1adb12` ("three tests that
  fail if superseded work keeps running") — one does; amend the two
  assertion messages that claim the cancellation half
  (`PageCanvasControllerTests.swift:612`,
  `StaticLayerRenderTests.swift:757-760`) or add a decode-progress probe so
  they can earn it. `3e07d45` — `LibraryViewOptionsModel.load()` has no
  assertion that can fail; add the test that writes non-default prefs, loads
  through a second model, and asserts them; pin `.type`'s direction to a
  literal.
- **Suite hygiene.** Bound the five unbounded spin loops
  (`StaticLayerRenderTests.swift:695-755`); replace the two aborting
  timeout paths (`LibraryBrowserTests.swift:290-294`,
  `PrefetchWarmTests.swift:95-97`) with `#require`; one shared `waitUntil`
  at the save suites' 10 s deadline; a `.timeLimit` trait on the renderer
  suites.

## R12 — The memory arithmetic

The cache's own bound argument is stale twice over: the live window has been
five pages since `windowRadius = 2`, and this stack put every page of any
non-blank-paper document on the composite path — 5 × 22 MB against a 96 MB
bound on the 13" iPad the bound was sized for, with `trimToByteBound`
protecting only the single visible page. The warm this stack added is
defeated by the trim it also triggered.

- Correct the BOUND paragraph (`StaticLayerRenderer.swift:56-74`); size
  `defaultByteBound` from the invariants (or lower
  `maximumCompositeLongEdge` so five capped composites fit), stating the
  device it was computed for.
- `protecting:` receives the live window, not `[current]`
  (`EditorSession.swift:747-749`).
- `windowRadius` becomes `package static`; `prefetchRadius` is defined as
  `windowRadius + 1` so the relationship stops being a comment.
- `render` draws each layer as it decodes and releases the raster, exactly
  as `renderLens` twenty lines up already does
  (`StaticLayerRenderer.swift:870-1049`) — peak becomes one raster plus the
  context instead of N × 24 MB.
- Thumbnail fan-out gets a small fixed token gate (suspend before work, so
  per-cell cancellation inheritance survives); the thumbnail store purges on
  memory warning and when `openDocument` becomes non-nil; the render cache
  gains a memory-pressure eviction stated in its declaration.

## R13 — Small correctness, one line each

- `duplicatePage`: move the fetch into the `.loading` case and delete the
  unreachable `.clean`-with-nil-`durable` arm — today it refuses every page
  more than three from the visible one, and the navigator will be wired
  straight to it (`EditorSession.swift:1163-1205`; `Page.swift:366-379`).
  Correct the `Unproven.md` entry: the branch was unreachable, not untested.
- `createAndOpenNotebook` claims the open slot synchronously before its
  first suspension, as its synchronous sibling already does
  (`LibraryCoordinator.swift:88-105`).
- `setDecoration` sends field intentions (`setFolderColor`,
  `setFolderIcon`); the store merges under its actor
  (`LibraryPopovers.swift:135-179`).
- `movePage` adopts the `onMove` before-removal convention now, while no UI
  exists to freeze the wrong one (`EditorSession.swift:1281-1286`).
- The reclaim guard re-evaluates `layersUnsaved` after each of its three
  suspensions (`EditorSession.swift:1374-1403`).
- `duplicatePage`'s pruned path re-checks `source.ink` after the drain, as
  its other arms already do (`:1245-1249`).
- Rename's `committed` flag is set before the task spawns
  (`LibraryPopovers.swift:183-209`).
- `appendPage` and `importPDF` route through `restatePageList()`, and
  `pruneDurableBytes()` joins it, making one place a list mutation re-scopes
  both caches (`EditorSession.swift:902-917, :2048-2064, :1048-1051`).
- The thumbnail negative cache splits "decoded and invalid" (cache the
  refusal) from "read or allocation failed" (install nothing, retry on next
  appearance) (`LibraryThumbnailStore.swift:236-264`).
- A `resourceValues` failure surfaces as a degradation instead of coercing
  to not-a-directory; unreadable timestamps stop rendering as `.distantPast`
  facts (`LibraryStore.swift:201-203, :487-489, :505, :715, :742`).
- `EditorSession.swift:1711`'s `min(...)` becomes an explicit successor
  choice plus a `precondition`, so the validator built to catch the state
  can reach it.
- The rename collision surfaces its suffix like move and duplicate already
  do (`LibraryBrowserModel` rename discards it).
- Four lines of path-component validation at `LibraryStore`'s entry points
  (reject empty, `.`, `..`, `\0`) — the invariant becomes the store's, not
  its callers'.
- Split `DocumentReading` out of `DocumentStoring`; the thumbnail render
  accepts a reader it is handed instead of constructing a writer
  (`LibraryThumbnailStore.swift:232`), keeping the seam's own sentence true.
- Every cache-shaped declaration states owner, bound, and evictor — six of
  seven in the thumbnail layer currently fail, and `pendingDecodes`
  (`PagedCanvasController.swift:718`) has no comment at all.
- `lastKnownIndex` gains an mtime check: a mismatch means the file changed
  underneath, and the save refuses loudly instead of skipping the index
  write (`DocumentStore.swift:31, :678-679`).
- Memoize `displayed(under:)` — it filters, collates, and fully re-sorts on
  every render pass, three times per pass in select mode
  (`LibraryBrowserModel.swift:118-138`).

## Deferred, with named triggers

Stated so the scope is a decision rather than an accident:

- **Favorites re-keyed to IDs** (with `folderID` in `.folder.plist`) —
  trigger: before drag-and-drop ships, or before any second path-keyed
  sidecar. Drag multiplies move frequency and re-prices the accepted
  crash-prunes-a-star cost.
- **`LibraryPrefs` shape edit** (persistent `filter`; per-folder sort
  override) — trigger: batched with the next change touching
  `library.plist`.
- **Sidecar `formatVersion`s** (`favorites.plist` rewrapped,
  `FolderDecoration` split into swatch/custom-hex/namespaced symbol) —
  trigger: before the first build that leaves the dev machine; today a
  newer sidecar reads as corrupt and gets silently replaced.
- **`Documents/` → `Notebooks/` root rename** — trigger: R10's vocabulary
  verdict; it also removes the collision with iOS's own `Documents`.
- **Page navigator, export, composite thumbnails, undo-on-trash, 44 pt
  targets, context menus** — the UX lanes, ordered in the review artifact.

## Order of work

1. ~~Verdicts~~ — recorded 2026-08-13: R4 keep-and-fix, R9 delete, R10
   deferred to Phillip's own schedule, R11 deferred. R10's remaining
   `[DECIDE]` register (vocabulary, the two import rulings, A10's device
   gate) travels with R10.
2. **R1–R3** — the ink. Device evidence per `AGENTS.md`.
3. **R4–R9** — the format edits (R4/R9 as decided), each with its own
   changed-behaviour tests.
4. **R12–R13** — the batches.
5. Merge. R10 and R11 follow on their own schedules and do not hold it.
