# Proposal: identity-keyed canvas runtime and page management

Status: proposal, unreviewed by Phillip. Revision 2, incorporating an
adversarial review against the code; the review's findings were re-verified
against the code before being adopted. Written by an agent from a full read of
the contract, Queue, Unproven, the runtime, the session, the model types, and
the store/test surfaces. Nothing here is a rule; contract amendments are
proposed as exact edits for Phillip to author.

## Summary of recommendation

Make **page identity the only key that crosses any boundary**. There is no token-translation layer and no "opaque page token" indirection (Unproven.md's S8 idea): the codebase already has a stable, durable, unique identity — `PageRecord.id` — and the session is *already* identity-keyed internally (`Page.id`, `stateIndex(of:)`, captures by `pageID`, held bytes "keyed by page ID because an index means a different page once the list changes" — Contract, Owners). The only structure that is genuinely index-keyed is the seam (`PagedCanvasSession`) and the runtime's slot machinery. Re-key both by identity; derive positions locally wherever UIKit arithmetic demands them (`contentOffset = width × position`). This is the smallest structural change that makes delete/reorder/insert/duplicate correct by construction, and the code supports it directly.

Page-list mutations are serialized behind one **structural gate** in the session (see (d)): the gate drains the save machinery to quiescence, re-validates after every suspension, and performs the mutation itself synchronously. "A capture and a list mutation never overlap" is a property the gate *enforces*, not one a single awaited check hopes for.

---

## (a) Inventory of index-keyed sites, and what breaks

### The seam (`Modules/TuberCanvas/PagedCanvasSession.swift`)
All nine methods are index-keyed: `canvasContent(forPageAt:)`, `staticLayers(forPageAt:)`, `projection(forPageAt:)`, `drawingChanged(onPageAt:)`, `layerTransformed(onPageAt:…)`, `pageIsRetiring(at:handingOver:)`, `currentPageChanged(to:)`, plus session→runtime calls `reloadPage(at:)`, `reloadStaticLayers(at:)`, `livePage(at:)`, `snapshot(at:)`, `compositeDetail(forPageAt:)`, `setPages(count:currentPageIndex:)` — note `setPages` doesn't even carry identity; the runtime knows only a *count*.

### Runtime (`PagedCanvasController.swift`) — the breakers

1. **`SlotHost.pageIndex` (lines 88–108)** — captured at slot construction "for the slot's life," on the stated assumption "a slot's index does not change while the slot exists." A delete or reorder falsifies that assumption for every surviving slot. A live canvas keeps reporting `drawingChanged`/`layerTransformed` under its stale index → **wrong page marked dirty; wrong page's layer transformed**. This is the central wrong-page write.
2. **`slots: [Int: Slot]` (line 130)** — after a delete, every slot at or past the deleted position shows the wrong page at its position, and `refreshWindow` will happily keep it there.
3. **`pageIsRetiring(at:)` in `refreshWindow` (line 487)** — a retirement under a stale index hands page A's drawing into page B's custody (`Page.retired(handingOver:)`) → **silent ink corruption**, the worst class of failure the contract names.
4. **`settle()` (line 804)** — reports a *position*; if the session's list changed between `setPages` calls, position→identity resolves to the wrong page and `EditorSession.currentPageChanged` durably writes a current index the user never chose.
5. **`pendingDecodes: [Int: PendingDecode]` (line 586)** — a decode started for the old occupant of position *n* installs into the new occupant's slot. The token guard protects rebuilds that funnel through `makeSlot`/`cancelDecode`; a list mutation does not funnel through either.
6. **Positional-by-nature, and fine**: `contentSize`, `slotFrame(for:)`, `scrollTo`, `windowedIndices`, `appendPreviewFrame` — pure geometry over *whatever the current order is*. These stay positional; positions just become locally derived.

### Session (`TuberNotesApp/EditorSession.swift`) — the breakers

7. **`drawingChanged(atPageIndex:)` (line 843)**, **`pageIsRetiring(atPageIndex:)` (line 879)**, **`layerTransformed(atPageIndex:…)` (line 1546)** — all index into `pageStates[pageIndex]`; they inherit breaker 1's stale index and commit the wrong-page write.
8. **`beginSave`, `.live` case (line 1113)** — `liveRuntime?.snapshot(at: pageIndex)` reads *whichever canvas now sits at that position* and saves its ink under a different page's ID. A delete during live editing corrupts the *durable* form.
9. **`content/staticLayers/projection(forPageAt:)` (545/598/612)** — answered from `pageStates[pageIndex]`; correct only while runtime and session agree on order at every instant.
10. **`fetchPageData(forPagesAround:)` (line 722)** — computes bounds before awaiting and indexes `index.pageIDs[candidate]` after (the exact latent defect Unproven.md records). The body resolves by identity (`stateIndex(of: pageID)`), which is the right key — but that resolution happens *after* `await store.loadPage(pageID)`, and page loads are deliberately never cancelled ("dedup, not staleness," lines 285–294). Once pages can be deleted, a load returning for a vanished page reaches `stateIndex`'s trap. See (d): the load-return path becomes tolerant.
11. **`stateIndex(of:)` precondition "pages are never removed" (line 522)**, and `deleteLayer`'s own comment (line 1736) acknowledging the stale-index-across-await class. `deleteLayer`'s post-await re-resolution (line 1737) calls `stateIndex(of:)` again, which under a concurrent page delete is a trap on a state any user can reach.
12. **Fine as-is (positional over current order, recomputed synchronously)**: `pruneDurableBytes`, `retainRenderedLayers`, `warmNeighbourComposites`, `durableIndex`'s trailing trim, `DocumentIndex.currentPageIndex` (positional durably, per Durable form), and the session→runtime `firstIndex(of:)`-then-call sites (already resolve identity→position at call time).

### Tests pinning current behavior
`PagedCanvasControllerTests` (window bound, handover-before-release, placeholder discipline, decode cancel/token, settle-once, append preview/trigger, mixed geometry), `PageCanvasControllerTests`, `EditorSessionTests`/`EditorSessionCloseTests` (save capture, retirement custody, withheld trailing pages), `PrefetchWarmTests`, `StaticLayerRenderTests`. All use the index-keyed seam through `TestCanvasHosts.swift` and will be rewritten mechanically to the identity seam.

---

## (b) Ownership and data flow (owner-table diction)

No owner changes. One row's *meaning* sharpens and one new sub-value gets named:

| State | Sole writer | Frequency | Lifetime |
|---|---|---|---|
| Page order, page identity, current page | `EditorSession` | user action | app session |
| The rendered order — the runtime's snapshot of `[UUID]` and the current page | `PagedCanvasController` (told by `setPages`, never inferred) | user action | app session |

The flow keeps the contract's one direction: **the session tells the runtime the order as a snapshot (`setPages(order:current:)`); the runtime renders that snapshot and sends every report — dirty, retirement, transform, turn — by identity.** A position exists in exactly two places, both local derivations: the runtime's scroll arithmetic (`position(of:)` over its order snapshot) and the durable `document.plist` (`currentPageIndex`, unchanged per Durable form). Golden rule 7 is strengthened: `PageCanvasController` stays blind even to identity; the runtime's `SlotHost` captures the **page ID** instead of the index — an identity is stable for the page's life where an index was stable only for the slot's, which is the whole fix.

### The trap policy, restated precisely

Two worlds cross the session's boundary, and they earn different policies:

- **Reports from the runtime** (`drawingChanged`, `pageIsRetiring`, `layerTransformed`, `currentPageChanged`) are synchronous with respect to list mutations: every mutation reconciles the runtime **before the mutating call returns**, and a mutation retires a deleted page's canvas inside that reconcile. So a runtime report bearing an ID the session no longer holds is a defect and **traps** — `stateIndex(of:)` keeps its precondition, reworded.
- **Returns from the store** (`loadPage`, asset writes) are asynchronous and deliberately uncancelled; they can legitimately outlive the page that asked. A load result for a vanished ID is **dropped, loudly logged, never trapped** — the bytes are a cache entry for a page that no longer exists, so dropping them loses nothing. This is finding-of-fact, not leniency: it is the same distinction `installDecoded`'s token check already draws inside the runtime ("cancel so the work stops; compare so what finished cannot install stale").

`fetchPageData` additionally snapshots its candidate *IDs* before its first await (closing Unproven's latent bounds item), and its post-await writes go through an optional lookup rather than `stateIndex`.

### The identity type: plain `UUID`, deliberately

A `struct PageID { let raw: UUID }` wrapper was considered and is **not recommended**. The cost, confronted:

- Synthesized `Codable` encodes `{"raw": "…"}`, not a UUID string. If `PageID` reached `PageRecord.id` it would break every existing `document.plist`; avoiding that needs a custom `singleValueContainer` `Codable` — ceremony for a type whose whole point was to be free.
- If instead the wrapper stays seam-only, every crossing wraps and unwraps against `index.pageIDs: [UUID]`, `store.loadPage(UUID)`, and the `[UUID: Data]` save batches — a translation layer, which is exactly what this proposal exists to not build.

The codebase already keys `layerID: UUID` and `assetID: UUID` bare, disambiguated by parameter labels, and no cross-keying bug has come from it. The seam does the same: `page pageID: UUID`, labels load-bearing. If a cross-keying bug ever ships, the wrapper with a custom single-value `Codable` (adopted all the way down to `PageRecord.id`, one mechanical pass) is the recorded fallback.

---

## (c) API surface

**Seam** (`PagedCanvasSession`, full replacement — no compatibility shim, per "burn things down"):

```swift
@MainActor package protocol PagedCanvasSession: AnyObject {
    func canvasContent(forPage pageID: UUID) -> PagedCanvasController.PageContent
    func staticLayers(forPage pageID: UUID) -> [LayerEnvelope]
    func projection(forPage pageID: UUID) -> PageProjection
    func drawingChanged(onPage pageID: UUID)
    func layerTransformed(onPage pageID: UUID, layerID: UUID, to transform: PageSpaceTransform) -> Bool
    func pageIsRetiring(_ pageID: UUID, handingOver snapshot: DrawingSnapshot)
    func currentPageChanged(to pageID: UUID)
    func reachedEndBoundary()
}
```

**Runtime**:

```swift
package func setPages(_ order: [UUID], current pageID: UUID)   // replaces setPages(count:currentPageIndex:)
package func reloadPage(_ pageID: UUID)
package func reloadStaticLayers(onPage pageID: UUID)
package func livePage(_ pageID: UUID) -> PageCanvasController?
package func snapshot(ofPage pageID: UUID) -> DrawingSnapshot?
package func compositeDetail(forPage pageID: UUID) -> Double?
// internals: order: [UUID]; slots: [UUID: Slot]; pendingDecodes: [UUID: PendingDecode];
// private func position(of pageID: UUID) -> Int?  — the one place identity becomes geometry
```

### The `setPages` reconciler, fully specified

`setPages` keeps every load-bearing property of today's implementation (lines 280–296) and adds identity reconciliation. In order:

1. **Precondition**: `order` non-empty ("a document always has at least one page"), `current` ∈ `order`, no duplicate IDs.
2. **Retire departed IDs.** For every slot whose ID is absent from the new order: `cancelDecode` for that ID (a decode nobody will install must not compete with the Pencil); if the slot is a canvas, **no handover** — the only way an ID disappears is a deletion the session already decided, and handing a deleted page's ink into custody would resurrect it as undying dirty state — but `page.willRetire()` **still runs** before `willMove(toParent: nil)`/release, exactly as in `refreshWindow`: it is the teardown that drops the page's undo actions and detaches the canvas cleanly, and it is orthogonal to the handover. Placeholders are removed from the view hierarchy.
3. **Adopt the snapshot**: store the new `order` and derive `currentPageIndex = position(of: current)`; update `contentSize` if the count changed.
4. **Re-frame survivors**: `layoutSlots()` derives each surviving slot's frame from `position(of: id)` — live canvases *move*, they are never rebuilt, so no ink and no zoom state is touched.
5. **Restate the offset** for the current page with `animated: false` — no delegate callback fires, so no settle and no phantom turn, the same guarantee the width-change path relies on.
6. **Settle synchronously**: `refreshWindow()` (whose retirements of still-present pages hand over exactly as today), then `livePage(current)?.becomeActivePage()` — first responder and tool picker move to the surviving current page; without this, deleting the current page leaves dead Pencil input.

All of this completes **synchronously inside the call**, preserving the property `scrollViewDidEndDragging`'s append correction (lines 833–877) depends on: "the page count, contentSize, the blank slot, and the offset all describe the new page by the time the callback below returns."

**Session** (page management, all `EditorSession`, the sole writer of order):

```swift
enum PageEditError: Error, Equatable {
    case sessionNotReady
    case pageNotFound(UUID)
    case lastPage                        // "a document always has at least one page"
    case positionOutOfRange(Int)
    case pageCarriesRefusedLayer(UUID)   // duplicate refuses it; see (d)
    case pageNotReady(UUID)              // duplicate of a .loading/.unreadable page
}

func insertPage(after pageID: UUID) async throws -> UUID
func insertPage(before pageID: UUID) async throws -> UUID
func deletePage(_ pageID: UUID) async throws
func movePage(_ pageID: UUID, toPosition position: Int) async throws
func duplicatePage(_ pageID: UUID) async throws -> UUID
```

**`Page`** grows one initializer for duplication (today it has only `init(loading:)`, `init(clean:durable:)`, `init(appended:)`):

```swift
/// A duplicate of an existing page: fresh page identity, fresh inkLayerID,
/// a copied layer list flagged unsaved, and the source's captured ink in
/// custody — dirty by construction, so the next pass writes it whole.
init(duplicating source: Page, id: UUID, capturedInk: UnsavedInk)
// sets: staticLayers = source's layers re-identified, layersUnsaved = true,
//        ink = .held(capturedInk), durable = source.durable (as cache), neverWritten = false
```

**Store**: one addition, `deletePageFileIfUnreferenced(pageID:)`, mirroring the existing reclamation shape — it answers "does the index on disk still name this page?" from the *files*, deletes `pages/<pageID>.plist` only if not, and a failure costs an orphan, never data (orphans are already contract-ignored).

---

## (d) End-to-end flows and edge cases

### The structural gate

The first revision's prologue — one `await currentSave?.value` — was a one-shot check, and a one-shot check is not a critical section: two structural ops could both await the same save and interleave; `flushForBackground` could begin a capture after the prologue resumed; the debounce (which the prologue never cancelled) could fire during duplicate's own byte-fetch await; and a suspended op could resume after `performClose`'s final pass and mutate a session about to be pronounced clean. All five interleavings are closed the same way: structural ops run inside **one serialized gate** with re-validation after every suspension.

```swift
/// Chains structural page-list mutations one behind another. The gate is the
/// only place the page list mutates, and each link re-establishes its
/// preconditions from scratch — nothing observed before a suspension survives one.
private var structuralOp: Task<Void, Never>?
```

Each operation appends itself to the chain (`let previous = structuralOp; structuralOp = Task { await previous?.value; … }` and awaits its own link), so ops never interleave with each other. Inside its link, every op follows the same skeleton:

1. **Validate**: `phase == .ready`, `!isClosing`, the target page exists — else typed refusal.
2. **Quiesce the save machinery**: cancel `debounceTask` (so no autosave pass can *begin* during a later suspension), then `while let save = currentSave { await save.value }` — a loop, not a single await, because a save that began between checks must also be drained.
3. **Re-validate after the drain** — `isClosing` may have been set (a Back landing mid-op; the same re-check `importImage` performs after its asset write at line 1365), the page may have been deleted by an earlier link, phase may have failed. Every `await` inside an op is followed by this re-validation, without exception.
4. **Mutate synchronously**: index + `pageStates` + `alignedWithIndex()` + `setPages` reconcile, with **no suspension between the last validation and the end of the mutation**. This is what makes "a capture and a list mutation never overlap" true: captures begin only in `beginSave`, `beginSave` runs only on the main actor, and between validation and mutation this op never yields it.
5. **Persist**: arm the immediate save (`await saveIfNeeded()`), then any reclamation.

Consequences elsewhere, both required:

- **`performOneSave`'s acknowledgement paths stay trap-free without tolerance code**: the gate guarantees no capture is in flight when the list mutates, so `stateIndex(of:)` in the acknowledgement loop never meets a missing page. (The gate makes this an invariant; the trap is the enforcement.)
- **`deleteLayer`'s post-await re-resolution (line 1737) becomes tolerant**: it already re-resolves by ID out of caution; under page deletion that caution must complete — a vanished page after `await saveIfNeeded()` means a concurrent delete won, the layer is gone with its page, and `deleteLayer` returns rather than trapping. Its reclamation guard (below) already re-reads global state.
- **`fetchPageData`'s load-return becomes tolerant** (the store-return world of the trap policy in (b)): `store.loadPage` is deliberately never cancelled, so a delete during an in-flight load *will* see the load return for a vanished ID. The result is dropped with a `CanvasLog` event; `pageLoadsInFlight` clears through the existing `defer`. Delete does not cancel or absorb loads — cancellation would reintroduce exactly the "dedup, not staleness" machinery the current design rejected, to save a bounded disk read whose result is a droppable cache entry.

### Insert (before/after)

Gate → mint `PageRecord(id: UUID(), geometry: .canonical)` → insert into `index.pages` and `pageStates` at the position (`Page(appended:)` state: clean over empty bytes, `neverWritten`) → `indexDirty = true`, `alignedWithIndex()` → `setPages(order, current: insertedID)` (turning to the inserted page is this UI's choice; defensible either way) → immediate save.

Durability follows the existing withheld-trailing-run rule, stated honestly:

- **Insert with a written page anywhere after it**: durable at once — `durableIndex` withholds only the *trailing* never-written run, and `beginSave`'s existing `clean + firstWrite` branch (line 1095) writes the blank page file in the same pass as the index, so the index never dangles.
- **Insert at the end, or before/among the trailing never-written run**: the inserted page *joins* that run and is withheld — on screen, not in the file — until its first ink or layer, exactly as an appended page is. This is the same rule, not an exception to it; nothing about insert position may create a page file nobody has written on when append would not.

### Delete

Refuse if it is the only page (`lastPage`; `setPages`'s non-empty precondition stays as the loud backstop). Then, inside the gate:

1. Decide the successor current page when the deleted page is current: same position clamped (`min(deletedPosition, newCount − 1)`) — the page that visually slides under the finger; deleting the last-position page steps back.
2. Remove from `index.pages` and `pageStates`; `indexDirty = true`; `alignedWithIndex()`.
3. `setPages(order, current:)` — the reconciler retires the deleted page's canvas *without handover* (its `willRetire()` teardown still runs; see (c)). **Deleting a live page with unsaved ink discards that ink, deliberately and by the user's confirmed act**; the discard happens at the reconciler, so no custody entry survives to keep the session dirty. A page in `.saving` cannot occur here — the gate drained the save.
4. Immediate save: the index write is what makes the deletion durable (pre-delete disk state is consistent, merely stale; a crash before this write reopens with the page present, which is a stale document, never a torn one).
5. **Reclaim, root to leaf, in reference order — page file first**: the reclamation scans answer referenced-ness from *disk*, so the order must follow who references whom on disk. The just-rewritten index no longer names the page, so `deletePageFileIfUnreferenced(pageID:)` deletes `pages/<pageID>.plist` **first**. Only with the page file gone do its layers become unreferenced — `deleteLayerFileIfUnreferenced` (DocumentStore.swift:207) scans page files for the layerID — so the page's layer files go **second**, via the existing per-layer `reclaim(_:)` path. Only with the layer files gone do their assets become unreferenced — `deleteAssetIfUnreferenced` (:169) scans layer files — so assets go **last**, inside that same path. (Revision 1 ordered layer files before the page file; against the actual scans that pass reclaims nothing and permanently pins shared assets. The corrected order is: index → page file → layer files → assets.)
6. **The reclamation honors `deleteLayer`'s existing guard**: while any page holds an unsaved layer list (`pageStates.contains(where: \.layersUnsaved)`, line 1753), the on-disk reference scan is blind to in-memory references and reclamation is **skipped entirely**, logged, leaving inert orphans — otherwise a delete could destroy an asset a surviving page's unsaved import still needs. Orphans are reclaimable by a later delete once every list is durable, exactly as today.

An interruption between any two steps leaves an orphan, never a dangling ref — the mirror of the write order.

**Deleting a trailing never-written page** touches no disk at all: drop state + index entry, `setPages`, done — `durableIndex` never named it and no file exists.

### Reorder

Gate → `index.withPages(reorderedPages, currentPageIndex: newPositionOfCurrentID)` — the current *identity* is preserved and its position recomputed; reorder never changes which page the user is on → remap `pageStates` to match, `alignedWithIndex()` → `setPages` (canvases move, nothing rebuilt, nothing handed over) → immediate save (index-only write; page files untouched, per "a save writes only what changed"). Moving the trailing never-written page into the middle ends its withholding via the existing `firstWrite` machinery; moving a written page behind the trailing run ends the run's withholding the same way — both already handled by `durableIndex` + `beginSave`.

### Duplicate

Gate → validate the source: a page carrying a **refused layer is refused** with `pageCarriesRefusedLayer` — `Page.refusedLayers` holds typed refusals *outside* `staticLayers` (Page.swift:38), so a copy would save cleanly without them, which is precisely the "carried blind / silently dropped" outcome Contract — Durable form forbids; a `.loading`/`.unreadable` source is refused with `pageNotReady`. Then capture the source's ink:

- `.clean` → its `durable` bytes; if evicted, `await fetchPageData` for it, then **re-validate** (gate rule 3) — the source may have been deleted during the fetch;
- `.held(…)` → that value;
- `.live` → `liveRuntime?.snapshot(ofPage:)` taken **synchronously, before any suspension** — the live canvas is the authority and the snapshot is the same shape a retirement hands over;
- `.saving` → unreachable; the gate drained the save.

Build the copy with `Page.init(duplicating:id:capturedInk:)`: fresh `pageID`, fresh `inkLayerID`, `staticLayers` copied with **fresh `layerID`s** referencing the **same `assetID`s** — layer files are per-layer so two pages must not contend for one file, while assets are reference-counted by the on-disk scan, which handles sharing by construction (deleting one copy leaves the asset; deleting both reclaims it). `layersUnsaved = true` and ink in custody make the copy dirty, so the immediate save writes its page file, its layer files, and the index in one pass. Geometry copies the source's: `PageRecord(id: new, geometry: source.geometry)`. Insert after the source.

**Unchanged**: append (`reachedEndBoundary` — not routed through the gate; it is the one synchronous mutation, called from inside a scroll callback that depends on synchronous settle, and it remains safe under an in-flight save for the reason its comment states: the appended page is withheld from every capture until it takes ink), the append preview, backgrounding, close.

### Undo: page mutations are **not undoable** — argued

The contract's Undo section commits to "no interception and no semantic undo domain," and stroke undo lives in PencilKit's per-page manager, which `willRetire()` already discards when a canvas leaves the window — a manager that cannot survive a page turn certainly cannot host a cross-page structural inverse. An undoable delete would require the session to retain the deleted page's ink, layers, and position (a second custody, violating golden rule 5's one-authority discipline) and to insert into a manager owned by a canvas that may not exist. Navigation is already not undoable; insertion and reorder are trivially re-performable by hand; duplication is deletable. The one destructive op, **delete, gets a confirmation in the UI instead of an undo** — prevention where restoration is unaffordable. This should be stated in the contract (below) so it is a decision, not an omission. If a document-level undo domain is ever wanted, it is a `CONTRACT:` amendment of its own, not a rider on this work.

---

## (e) `CONTRACT:` amendments

1. **Owners** — golden rule 7 extended: "…It is blind to page numbers *and page identity*: the runtime addresses pages by identity; positions exist only as the runtime's local scroll arithmetic and as the durable current-page index." Add the rendered-order row (or a sentence under the existing runtime row). State: "A page-list mutation reconciles the runtime synchronously before the mutating call returns."
2. **Owners / held bytes** — the "pages are never removed" era ends: removing a page removes its state, its held bytes, and its custody. A *runtime report* bearing an unknown page identity is a defect and fails loud; a *store return* for a page that no longer exists is dropped and logged, because uncancelled asynchronous work may legitimately outlive the page that asked.
3. **Durable form** — add: "Deleting a page rewrites the index first and reclaims the page's files second — in reference order: the page file, then its layer files, then their assets, each step answered from the level above on disk — so an interruption leaves an orphan, never a dangling ref." Note the delete-last-page refusal is the runtime face of "a document always has at least one page."
4. **Navigation / Undo** — add: "Inserting, deleting, reordering, and duplicating pages are document edits with no undo: there is no semantic undo domain, and PencilKit's per-page manager never learns of them. Deletion is confirmed, not undone."
5. **Saving** — add: "Structural page-list mutations are serialized behind one gate. The gate cancels the debounce, drains any save in flight to quiescence, re-validates its preconditions after every suspension, and mutates synchronously — so a capture and a list mutation never overlap, by enforcement rather than by timing."

---

## (f) Test plan — behaviors to pin

*Seam/runtime (rewrite existing suites to identity, then add):*
- Reconcile keeps identity: after delete/reorder, each surviving live canvas still reports `drawingChanged`/`layerTransformed`/retirement under **its own** page ID (the pinned negation of breaker 1).
- Reconcile retires a removed page's canvas **without** handover but **with** `willRetire()` teardown; surviving retirements still hand over before release.
- After deleting the current page, the successor page is first responder and takes Pencil input (`becomeActivePage` ran).
- A decode in flight for a deleted/moved page is cancelled and never installs into another page's slot.
- After reconcile, offset shows the stated current page and **no settle/turn is reported** (parallel to the width-change tests); the reconcile completes synchronously within the `setPages` call (the append-correction property).
- Window bound and held-bytes prune still hold across insert/delete/reorder.

*Session — the gate:*
- Two structural ops issued concurrently execute serially; the second observes the first's result.
- A structural op issued during an in-flight save mutates only after that save's acknowledgement; no capture ever meets a missing page.
- The debounce firing "during" a structural op begins no save before the mutation lands (the gate cancelled it).
- `flushForBackground` racing a structural op never captures across the mutation.
- A structural op suspended when `close()` begins refuses at its re-validation and mutates nothing.
- A page delete during `deleteLayer`'s awaited save: `deleteLayer` returns without trapping.
- A page delete during an in-flight `loadPage`: the load's return is dropped and logged; no trap, no state written.

*Session — the operations:*
- Delete of the only page throws `lastPage`; document still opens with one page.
- Delete current page → current becomes clamped successor; deleting the last-position page steps back.
- Delete a `.live` page → session is clean of it (no undying dirty entry), next save writes an index not naming it, reload reproduces the survivors byte-exactly (durability round-trip).
- Delete of trailing never-written page performs zero store calls.
- Delete reclamation order: after the pass, the page file, its layer files, and its sole-referenced assets are gone, in that dependency order; a shared asset survives; a simulated failure after the index write leaves orphans and a loadable document.
- Delete while another page holds an unsaved layer list: reclamation is skipped entirely, files remain as orphans, and the event is logged (the `layersUnsaved` guard).
- Insert with a written page after it writes the blank page file in the same pass as the index (no dangling ref, via `HeldSaveStore`-style inspection); insert at the end or before the trailing never-written run stays withheld until first ink, exactly as append does.
- Reorder preserves current *identity*; index-only write (unchanged page files are not rewritten — the "defect not inefficiency" rule).
- Duplicate: fresh page/ink/layer IDs, shared assetIDs; deleting the duplicate does **not** reclaim the shared asset; deleting both does; duplicate of a `.live` source captures the live drawing, not stale disk bytes; duplicate of a page carrying a refused layer throws `pageCarriesRefusedLayer`; duplicate of an evicted page fetches, re-validates, and copies the fetched bytes.
- `fetchPageData` snapshot-IDs-before-await (closes the Unproven latent item).

*Device evidence (maintainer verdict, per contract):* delete/reorder feel during live inking; the reconcile's offset restatement under a finger.

---

## (g) Implementation sequence — smallest change that proves each item

1. **Re-key the seam and runtime internals by identity** (`slots`, `pendingDecodes`, `SlotHost`, all `PagedCanvasSession` methods, `setPages(order:current:)` with order semantically identical to today — append-only callers). Mechanical test rewrite. *Proves:* identical behavior, identity-carried. This is the bulk of the diff and changes zero behavior.
2. **`setPages` reconciler** (retire-absent with `willRetire`/`cancelDecode` and without handover, re-frame survivors, restate offset, `becomeActivePage`) + `stateIndex` policy split (runtime reports trap; store returns tolerate) + `fetchPageData` ID snapshot and tolerant return. *Proves:* the runtime survives an order change with live canvases intact — pinned by the reconcile tests, before any UI can trigger one.
3. **The structural gate + `deletePage`** (with `deletePageFileIfUnreferenced`, the corrected reference-order reclamation, the `layersUnsaved` guard, `deleteLayer`'s tolerant re-resolution, and `CONTRACT:` amendments 2–5 in this commit, tagged). Delete is first because it exercises every hard edge (custody discard, current-page motion, reclamation ordering, the gate's interleavings).
4. **`insertPage`** (rides on existing `firstWrite` machinery; pins the trailing-run behavior honestly).
5. **`movePage`** (index-only write; current-identity preservation).
6. **`duplicatePage`** (`Page.init(duplicating:)`, refused-layer refusal, asset sharing + reclamation interplay).
7. **UI intentions** (SwiftUI root → session, per the owners diagram) + delete confirmation — last, thin, and separately reviewable; device evidence collected here.

Each step is independently green, independently revertible, and none carries a legacy shim: step 1 deletes the index-keyed seam outright.

**Key files:** `Modules/TuberCanvas/PagedCanvasSession.swift`, `Modules/TuberCanvas/PagedCanvasController.swift`, `TuberNotesApp/EditorSession.swift`, `TuberNotesApp/Page.swift`, `Modules/TuberModel/DocumentIndex.swift`, `Modules/TuberStore/DocumentStore.swift`, `Docs/Contract.md` (amendments), tests under `TuberNotesTests/`.
