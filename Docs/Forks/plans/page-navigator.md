# Page navigator with thumbnails

A plan, not code. Branch `v2-rewrite`. Every claim below cites the file it was read from.

**In short.** A sheet with a grid of page thumbnails; tap to go, drag to
reorder, delete, add after. Thumbnails are rendered by the `Renderer`
into a 32 MB in-memory cache keyed by page and a per-page content version
the notebook keeps; nothing is written to disk. Three pre-existing
defects come first as their own commits: the delete successor, reports
from a retiring canvas, and `movePage`'s self-drop. Runs in parallel with
`tool-picker.md` and `page-size-and-paper.md`; `README.md` in this
directory has the order and the shared files.

## 1. Data shape

```swift
// Modules/TNRender/Renderer.swift
/// What one thumbnail was rendered from. `version` is the notebook's per-page
/// content version (section 3), so paper, geometry, layers, and ink are all
/// folded into one number and the key never names them.
package struct ThumbnailKey: Hashable, Sendable {
    package let page: PageID
    package let version: UInt64
}
// The long edge is one constant, below, so the key does not carry it: a
// field with one value is a field reserved for a future feature.

/// One shape for both caches. The asset cache is `decoded`, `order`,
/// `cachedBytes`, and `trimCache` today; a second copy of those four for
/// thumbnails, and a third for the disk tier, is the same code three
/// times. Each instance still declares owner, bound, and evictor where it
/// is declared, as the contract requires; the type is the mechanism, not
/// the declaration.
struct BoundedCache<Key: Hashable, Value> {
    let bound: Int
    let cost: (Value) -> Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    private(set) var bytes = 0
    subscript(key: Key) -> Value? { get }
    mutating func insert(_ value: Value, for key: Key)   // evicts oldest until under bound
    mutating func removeAll()
}

/// Cache: page thumbnails by key. Owner: the `Renderer` actor, one per
/// notebook (`Notebook.init` makes it, Modules/TNNotebook/Notebook.swift).
/// Bound: `thumbnailCacheBound` bytes (32 MB), evicting oldest first.
/// Evictor: `BoundedCache.insert`, on insert, and `purge()` on memory pressure.
package static let thumbnailLongEdgePixels = 480
package static let thumbnailCacheBound = 32 * 1024 * 1024
private var thumbnails = BoundedCache<ThumbnailKey, CGImage>(bound: thumbnailCacheBound, cost: bytesOf)

package func thumbnail(_ key: ThumbnailKey, geometry: PageGeometry, paper: Paper?,
                       layers: [Layer], ink: PKDrawing) async -> CGImage?
package func cachedThumbnail(_ key: ThumbnailKey) -> CGImage?
```

The cache lives on the Renderer because the contract's Rendering section already puts the one cache we have there and requires owner, limit, and evictor at the declaration. The Custody table has no row for rendered pixels; section 7 adds one. A US Letter thumbnail at 480 px long edge is 371 by 480 by 4 bytes, about 710 KB, so 32 MB holds about 45, more than an iPad grid shows at once.

```swift
// Modules/TNNotebook/Notebook.swift
/// Bumped by every change that alters what a page looks like: ink, layers,
/// paper. Never reset by unload, because content is only dropped when clean
/// (`prune()`), so the version on reload still describes the page.
@ObservationIgnored private var contentVersions: [PageID: UInt64] = [:]
package func contentVersion(of page: PageID) -> UInt64
/// nil for a page that is unreadable, whether or not it has been loaded.
package func thumbnail(of page: PageID) async -> CGImage?

// Modules/TNEditor/EditorViewModel.swift
package struct NavigatorPage: Identifiable, Sendable, Equatable {
    package let id: PageID
    package let geometry: PageGeometry
    package let version: UInt64
    package let isCurrent: Bool
    package let isDeletable: Bool     // false when pageCount == 1
    /// True while the notebook is loading the page. Part of the cell's
    /// `.task(id:)` so the cell asks again when the load settles, instead of
    /// the notebook polling its own state.
    package let isLoading: Bool
}
package private(set) var navigatorPages: [NavigatorPage]   // rebuilt on every drain, like the other mirrors

// TuberNotesApp/PageNavigatorSheet.swift
/// The drag payload. A retroactive `Transferable` on `PageID` would be a
/// warning, and warnings are errors (project.yml); a local wrapper is not.
private struct DraggedPage: Transferable, Codable { let id: PageID }
```

## 2. Where thumbnails live

Two candidates were named in `Docs/Queue.md`. A sidecar in the package is refused twice by `Docs/Contract.md`. Forbidden: "A file in the package that restates what other files already say." One save: "Only `compact()` deletes." A stale sidecar needs deleting, so either `compact()` learns about a derived file or a second deleter appears. `compact()` in `Modules/TNFormat/PackageStore.swift` walks `layout.directories`, which includes the root (`PackageLayout.swift`), and its `default: continue` arm never descends into a directory it does not name; a sidecar directory would sit untouched, so the second deleter is the only mechanism, and that is the horn refused.

Decision: this slice keeps thumbnails in memory only. The disk tier, when wanted, is the system caches directory (`Library/Caches/TuberNotes/thumbnails/<NotebookID>/<PageID>.heic`), outside the package, keyed on the four-mtime staleness rule in `Docs/Forks/fundamental-rewrite.md`, Part 6. It is a second pull request, and it is what the library listing needs (section 5).

## 3. Rendering and staleness

Rendering. `Renderer.flattened` (`Modules/TNRender/Renderer.swift`) composes paper, layers, and ink into one bitmap. `thumbnail` reuses the compose-into-context step, without the HEIC step. Pixel size is chosen first: the long edge is exactly `thumbnailLongEdgePixels` and the short edge is the rounded proportion; the scale is derived from those pixels, so the bound is exact and not "480 or 481 after `rounded(.up)`" as `composite` computes. The heavy work is off the main actor; the notebook's state reads are on it, because `Notebook` is `@MainActor`.

Cancellation. `flattened` rasterizes ink in a detached task, and `startLoad` decodes in one. The thumbnail path must not copy that: `CONTRIBUTING.md`, Cancellation, says detached work "detaches cancellation" and is for protected work only, and a thumbnail is the opposite of protected. A cell's `.task(id:)` is cancelled when the cell scrolls away or the version moves; so `thumbnail(of:)` decodes and rasterizes in `nonisolated static async` helpers that run in the caller's task, and checks `Task.isCancelled` before the archive decode, before the composite, and before the ink raster. The version key is the compare half; this is the cancel half.

Inputs. A `.ready` page has `PageContent.ink` and `.layers` and the index record. An `.unloaded` page has no ink; the contract says the notebook "never fetches ink from a canvas", so `thumbnail(of:)` calls `store.loadPage(page)` and decodes, installing nothing: `states[page]` stays `.unloaded`, no `emitContent`, no `markDirty`. The decode is not a second reading of `PageBytes`: `startLoad`'s bytes-to-ink-layers-or-faults judgment moves into one `nonisolated static func decode(_ bytes: PageBytes) async -> LoadResult`, which `startLoad` calls inside its detached task and `thumbnail(of:)` calls in the caller's task. Faults reach the same verdict because they are the same code; a corrupt page never caches a blank under a valid version. A `.loading` page is not waited for: `thumbnail(of:)` returns nil at once, the cell keeps its placeholder, and `NavigatorPage.isLoading` is part of the cell's `.task(id:)`, so the next drain after `installLoaded` (or the drop-back to `.unloaded` in `windowChanged`) re-fires the fetch. No sleep, no loop, no unbounded wait on a wedged load. The `.unloaded` branch is reachable after a drop-back: `windowChanged` resets a `.loading` page to `.unloaded` when it leaves the window, and `pendingRestores[page]` survives that. So the `.unloaded` branch prefers `pendingRestores[page]` over the ink on disk when one is present; the restore is the ink the page will have, already in memory. Without this a scroll during the load thumbnails the pre-undo file and caches it under the bumped version. `.unreadable` returns nil and the cell shows a placeholder.

Each `loadPage` runs on the store actor, and so does every save: a grid's worth of reads during a scroll queues the next save pass behind them, and that is a cost to durability latency, not only to the grid. Milliseconds at this scale; accepted for this slice, named because the disk tier or a read-only second handle is the real answer. Thumbnails also decode assets through the renderer's 48 MB asset cache, so a grid scroll over asset-papered pages can evict what the live composites want next; the same acceptance.

Staleness in session: `contentVersion(of:)`. There is no choke point: `PageContent.setInk` and `edited()` do not see index-level changes (paper, geometry), the pending-restore stash lands on a page with no content, and the counter must outlive unload. So the invariant is maintained by enumeration, and the `NotebookTests` list in section 6 is its enforcement; a mutation that forgets to bump is a failing test to write, not a runtime check. Bump at the point the notebook's picture of the page actually changes, which is not always the intention's entry:
- `inkChanged`, after the echo short-circuit returns, not before it.
- `restore`, in both branches: the `.ready` branch where `setInk` runs, and the early-return branch that stashes `pendingRestores`. The stash is a promise that the page will differ when it loads, and `installLoaded` applies it; bumping on the stash means the cell's `.task(id:)` re-fires and its loop waits for the load. Without this a page thumbnailed while unloaded, then undone into, keeps its pre-undo image forever.
- `retired` when the final ink differs (it calls `inkChanged`, so no separate bump).
- `addLayer`, `transformLayer`, `deleteLayer`.
- `setPaper`, after the post-await mutation, not before the measurement.
- `appendPage` and `importPDF` at creation.
- `endTextEditing`, and `insertLayer` once `text-editing.md` splits it out of `addLayer`, and `.layersRestored` if that plan's step two lands. `text-editing.md` lands second (`README.md`, conflict 3), so it adds those bumps and extends the test list in section 6.
Not in `pageBecameCurrent`, `movePage`, or `windowChanged`. `PageContent.editSeq` cannot serve: `PageContent.init` (`Modules/TNNotebook/PageState.swift`) starts it at 0 on every load. `PageGeometry.swift`'s doc says geometry is "immutable after the page is created"; `setPaper` mutates it. `page-size-and-paper.md` owns that correction; this plan relies on the `setPaper` bump, not on immutability, and does not touch the comment.

The page being drawn on. Custody says the canvas sends the whole drawing when a stroke ends, and `inkChanged` bumps the version. The tap that presents the sheet lifts the Pencil first. A stroke that spans the presentation is covered by the bump on its report.

## 4. The navigator UI

`PageNavigatorSheet` in `TuberNotesApp/`, presented from a new toolbar button in `TuberNotesApp/EditorView.swift`. SwiftUI reads `editor.navigatorPages` and sends intentions.

- Grid: `LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))])`. Each cell: the image over a page-shaped placeholder from `geometry`, a page number from position, an accent border when `isCurrent`.
- Fetch: `.task(id: page.version) { image = await editor.thumbnail(of: page.id) }`. The image is cell state; pixels, not ink.
- Tap: dismiss, then `editor.scroll(toPageIndex:)`. `PagedCanvasController.scroll(to:)` returns early while `currentLayout.isEmpty`; the canvas stays laid out under a sheet. Keep it a sheet, not a full-screen cover.
- Reorder: `.draggable(DraggedPage(id:))` and `.dropDestination(for: DraggedPage.self)` on each cell and on the trailing "+" tile, which is the past-the-end target. The mapping to `Notebook.movePage(_:before:)`: dropping on cell `i` passes `before: navigatorPages[i].id`; dropping on the "+" tile passes `nil`. Two guards in the intention, because `movePage` has no production caller today and has two surprises: `movePage(A, before: A)` removes A, fails to find A, and appends it (a self-drop sends the page to the end), and dropping on the immediate right neighbour lands the page where it was. So `EditorViewModel.movePage` returns without calling the notebook when the dragged page is the target, when the target is its next page, or when the target is nil and the page is already last; each would otherwise rewrite and save an unchanged index. A `movePage` test pins all three.
- Delete: context menu and a trash button, disabled when `!isDeletable`. The sheet gets its own confirmation dialog, a small `@State` holding the page to delete; today's dialog in `EditorView` is bound to `deleteCurrentPage`, cannot take a page argument, and stays where it is for the toolbar. `EditorViewModel.deletePage(_:)` is new and both dialogs call it.
- Add: a trailing "+" tile and a per-cell "Add page after". `EditorViewModel.addPage(after:)` calls `appendPage(after:)` then scrolls. If the page-size plan (`page-size-and-paper.md`) has landed, both present its setup sheet, defaulting to the page tapped; until then `appendPage` copies paper and geometry from `currentPageID`, not from `after`, and the label says so.

Deleting a page mid-stroke. When a page leaves the list during a stroke, `PagedCanvasController.retireDepartedPage` parks its canvas in `retiring` and waits for the stroke to end (`PagedCanvasController.swift`). Until then `pageDidChangeInk` forwards that canvas's reports unconditionally, and `Notebook.inkChanged` traps for a page it no longer has (`TNPrecondition.fail`, `Notebook.swift`). `retired()` is guarded; `inkChanged` deliberately is not. Reachable today through the toolbar's delete, and the grid makes every page deletable. The fix is in the runtime, not at the call sites: a report from a canvas in `retiring` is a dead letter by construction, since the notebook has already dropped the page, so `pageDidChangeInk` does not forward for a page in `retiring`, and `pageDidRetire`'s final report goes through `retired()`, which is guarded. Deleting mid-stroke then simply works on every path, the ink goes with the page it belonged to, and there is no guard, no refusal, and no banner. The contract's rule that a canvas sending ink for a page the notebook has not loaded is a bug stays intact because the report is never sent. `deleteCurrentPage` becomes `deletePage(currentPageID)` anyway, so there is one delete path; the toolbar's confirmation dialog stays as it is. This is a `TNCanvas` change, already on this PR's device-evidence list, and its test is hosted (`TNCanvasTests`). `deletePage` also leaves `pendingRestores` and history entries for the deleted page, so an undo into it is swallowed; a `KNOWN DEFECT` block at `deletePage` records that until undo of layer and page operations is designed.

## 5. File-by-file

- `Modules/TNRender/Renderer.swift`: `BoundedCache`, the asset cache moved onto it (no behaviour change; the existing eviction tests pin it), `ThumbnailKey`, the thumbnail cache with its three declarations, `thumbnail`, `cachedThumbnail`; `purge()` clears both. Factor the compose-into-context step out of `flattened` into a helper both use, with the ink raster passed in: `flattened` rasterizes detached, the thumbnail in the caller's task, so the raster cannot be shared, only the compose. `composite()` stays actor-isolated because it owns the asset cache.
- `Modules/TNNotebook/Notebook.swift`: `contentVersions`, `contentVersion(of:)`, the bumps in section 3, the shared `decode`, `thumbnail(of:)`. `deletePage` removes the version, and picks the successor the runtime picks: `order[min(previousIndex, order.count - 1)]` (`PagedCanvasController.setPages`), which clamps when the last page goes. Today it jumps to the first page; this changes the toolbar's delete too, and a test pins it. The `KNOWN DEFECT` for stranded history. The successor fix, the departed-canvas fix, and the `movePage` guards are three pre-existing defects; each is its own commit ahead of the feature commits, so the reviewable unit stays honest.
- `Modules/TNCanvas/PagedCanvasController.swift`: `pageDidChangeInk` drops reports for a page in `retiring`.
- `Modules/TNEditor/EditorViewModel.swift`: `NavigatorPage`, `navigatorPages` (rebuilt in `refreshMirrors()` with the other mirrors; a map over five-field structs per drain is not worth a flag that can be stale), `thumbnail(of:)`, `movePage(_:before:)` with the three guards, `deletePage(_:)`, `addPage(after:)`.
- `Modules/TNEditor/EditorBinding.swift`: unchanged.
- `TuberNotesApp/EditorView.swift`: the button and `.sheet`. `TuberNotesApp/PageNavigatorSheet.swift`: the grid, `DraggedPage`, the dialog. `TuberNotesApp/Workspace.swift`: subscribe to `UIApplication.didReceiveMemoryWarningNotification` and call `renderer.purge()` on every open notebook. `purge()` has no caller today, so the asset cache's declared evictor "on memory pressure" is a promise; this wires it. `Workspace.swift` is on `CONTRIBUTING.md`'s device-evidence list, so this PR requires device evidence, not optionally.
- `Modules/TNModel/Seam.swift` and `Modules/TNModel/PageGeometry.swift`: unchanged.
- `Modules/TNLibrary`: unchanged. `LibraryItemCell` says "Thumbnails are not drawn yet". The listing has no `Notebook` and no `Renderer`; a first-page thumbnail there is the disk tier keyed by mtimes (`fundamental-rewrite.md`, Part 6), rendered for the `LibraryStore` actor off main. Second pull request.

## 6. Tests

All in `TNTests` unless said.

- `RendererTests` (new): a thumbnail's long edge is exactly `thumbnailLongEdgePixels` for portrait and landscape; a one-stroke drawing yields a non-white pixel at the stroke and white away from it; eviction is oldest first and the asset cache's existing eviction tests still pass on `BoundedCache`; `purge()` empties both caches; `cachedThumbnail` hits after `thumbnail` and misses on another version; a cancelled task produces no cache entry.
- `NotebookTests`: `contentVersion` rises on `inkChanged` (and not on an echo), `undo` into a loaded page, `undo` into an unloaded page (bumped at the stash; a thumbnail taken while the page is still `.unloaded` shows the restored ink, and so does one after the load), `setPaper`, `addTextLayer`, `deleteLayer`; unchanged by `pageBecameCurrent`, `movePage`, `windowChanged`; survives unload and reload. `thumbnail(of:)` on an `.unloaded` page returns an image and leaves the state `.unloaded` and `dirtyPageCount` 0; on an unloaded page with a bad ink container returns nil, and `startLoad` on the same page reaches `.unreadable` with the same faults; on a `.loading` page returns nil at once. `deletePage` of the current page makes the clamped successor current.
- `EditorBindingTests` with `RecordingSurface`: `movePage` produces one `setPages` in the new order; a self-drop, a next-neighbour drop, and the last page onto the end produce none; `addPage(after:)` produces `setPages` then `.scroll(new)`; `deletePage` of the last page produces no `setPages`; `navigatorPages[i].isLoading` follows the page's state across a `windowChanged`.
- `TuberNotesTests/TNCanvasTests` (hosted): a canvas mid-stroke whose page leaves `setPages` delivers no `inkChanged` to the reporter until the stroke ends, and then one `retired` with the final ink.
- Device evidence, required: drag to reorder, delete the current page, and a thumbnail of the page just drawn on.

## 7. Contract sentences

Proposals for Phillip; the commit that adopts them carries a `CONTRACT:` subject and is his.

Vocabulary, after the composite sentence, add: "A **thumbnail** is a page's composite and ink rendered small. It is derived, never saved in the package."

Custody table, add: "| Page thumbnails | `Renderer` | in memory, keyed by `ThumbnailKey`; rebuilt from the page |".

Rendering, quoted: "The renderer's asset cache declares its owner, its limit (48 MB), and what evicts from it, at the point it is declared. A cache that cannot state all three is forbidden."
Replace with: "The renderer's asset cache (48 MB) and thumbnail cache (32 MB) each declare their owner, their limit, and what evicts from them, at the point they are declared. A cache that cannot state all three is forbidden. A thumbnail is 480 pixels on the long side and is rendered by the `Renderer` actor from the notebook's ink, or from the page's files when the page is not loaded; rendering one loads nothing into the notebook, marks nothing dirty, and is cancelled when nothing wants it."

Forbidden, quoted: "A second copy of ink anywhere other than the notebook and the live canvas."
Replace with: "A second copy of ink anywhere other than the notebook and the live canvas. A drawing decoded for a render and discarded when the render ends is not a copy."

Undo, quoted: "Turning and adding pages are navigation, not edits, and cannot be undone."
Replace with: "Turning, adding, reordering, and deleting pages are navigation, not edits, and cannot be undone."

`Docs/Queue.md`, in the same PR: remove "A page navigator with thumbnails" from Parity gaps, and rewrite the thumbnails open decision to "the system caches directory; a sidecar is refused", since this plan decides that half.

## 8. Out of scope

The disk tier. The library listing thumbnail. Multi-select, duplicate page, copy between notebooks. Page size and paper on creation. Undo of delete or reorder. Any change to the seam or the format.

## 9. Open questions for Phillip

1. Superseded by `page-size-and-paper.md`: "add page after X" presents the setup sheet. If that plan does not land, the grid inherits the current page's paper and geometry as `appendPage` does now, and the label says so.
2. Is a deleted page gone at once, or should the navigator offer a page trash? A page trash is a format change.
3. Does the library listing thumbnail justify the disk tier, or is a first-page render on listing, cached per launch, enough?

## 10. Review disposition

Two adversarial reviews were answered on 2026-09-10. What stands after
both is the body above. Two items the first review adopted were then
deleted by the second and are not in the plan: a refusal through
`lastContentError` for a mid-stroke delete, and a `do`/`catch` around a
polling sleep. The second review replaced the refusal with the runtime
fix (no forwarding from a retiring canvas) and the poll with
`NavigatorPage.isLoading` in the cell's task id.

Adopted across the two reviews: the `.unloaded` branch prefers a pending
restore; `deleteCurrentPage` routes through `deletePage`; the
last-page-onto-end no-op guard; the long edge is exactly 480; `ThumbnailKey`
carries no one-valued field; the shared factor is the compose step only;
`contentVersions` is an enumerated invariant enforced by its test list;
the mirror rebuilds on every drain with no `isNavigatorShown` flag; one
`BoundedCache` for both caches; one `decode` shared by `startLoad` and the
thumbnail path; store contention and asset-cache eviction are named as
costs; the three pre-existing defects are their own commits; the
`PageGeometry` comment belongs to the page-size plan.

Rejected: a separate refusal channel (`lastRefusal`), moot once the
refusal itself went.

## 11. Cross-plan

`README.md` in this directory. This plan is in wave 1 and depends on
nothing. `text-editing.md` lands after it and owes it the bumps in
section 3 (conflict 3) and the retiring-canvas policy for text reports
(conflict 4). `page-size-and-paper.md` owns the `PageGeometry` comment
and the add-page sheet (conflict 5). `contentVersion` and text editing's
`renderGeneration` are different counters and both stay (conflict 6).
