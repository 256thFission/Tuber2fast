# Plan: page size and paper at creation

Queue item: "Choosing page size and paper when creating a page"
(`Docs/Queue.md`, Parity gaps). This adds a notebook-creation sheet in the
library and an add-page sheet in the editor. No file in the package changes
and no JSON key is added.

**In short.** A catalogue of named sizes in `TNEditor`, one new notebook
intention `appendPage(after:geometry:paper:)` that measures asset paper
before it builds the record, and the old `appendPage` delegating to it.
Size is chosen at creation and never changed after. Runs in parallel with
`tool-picker.md` and `page-navigator.md`; `README.md` in this directory
has the order and the shared files.

## 1. Data shape

### The catalogue

A value type in `Modules/TNEditor/PageSize.swift`. Not `TNModel`: nothing
durable and no notebook intention takes a `PageSize`; `appendPage` and
`createNotebook` take a `PageGeometry`. The catalogue is a creation aid for
sheets, like `EditorViewModel.defaultRect`, and `TNEditor` is hostless too
(`TNTests`). The library's sheet reaches it through the app, which imports
`TNEditor`.

```swift
package enum PageOrientation: Sendable, Hashable, CaseIterable { case portrait, landscape }

/// Named sizes, stated portrait, in points (PDF convention).
package enum PageSize: Sendable, Hashable {
    case letter      // 612 x 792, already `PageGeometry.letter`
    case a4          // 595 x 842
    case a5          // 420 x 595
    case iPadPro13   // 1032 x 1376 points, the 13-inch iPad Pro's screen; `ZoomCap` is derived from its long edge
    case square      // 612 x 612
    case custom(width: Double, height: Double)

    package static let named: [PageSize] = [.letter, .a4, .a5, .iPadPro13, .square]
    /// nil when a custom edge is outside `PageBounds`. Named sizes never are.
    package func geometry(_ orientation: PageOrientation) -> PageGeometry?
}
```

`geometry(_:)` swaps the edges for `.landscape` on the named sizes only. A
`.custom` size is taken as typed: the person who wrote 800 by 600 has
already stated the orientation, and the sheet hides the orientation control
while custom is selected. `geometry(_:)` checks the result with
`PageGeometry.isWithinBounds` (`PageGeometry.swift:18`). Every named edge
sits between `minEdge` 137.6 (`PageGeometry.swift:28`) and `maxEdge` 4096.
`iPadPro13` is two constants, not a screen read: a size read from the
device would make the catalogue differ per device and untestable without a
host. The long edge is `ZoomCap.widestSupportedViewportPoints`; the short
edge, 1032, is that screen's other side and is stated beside it with the
device named.

### What is durable

Nothing new. A page's size is already `width` and `height` in `PageRecord`
(`Modules/TNModel/NotebookIndex.swift:6`), with the key set pinned by
`DurableKeys.pageRecord` (`Modules/TNFormat/Codecs.swift:78`). The catalogue
name is derivable from the two numbers, and the contract forbids "a file in
the package that restates what other files already say" (Forbidden). A page
made from `.a4` and one imported from an A4 PDF (`Notebook.importPDF`,
`Notebook.swift:498`) are the same kind of page.

No notebook default size. `appendPage` already copies the current page's
geometry (`Notebook.swift:347-352`), which is the default a user sees; a
stored default would be a second writer of the same fact. A new index key
means a version bump, a migrator, and a fixture package (Contract, Durable
form) for a value the first page already carries. The sheet offers other
sizes; the catalogue is code.

### Creation-only, and why

Size is chosen when the page is created. The only later change is the one
the contract already allows: asset paper on an empty page takes the asset's
aspect (`Notebook.setPaper`, `Notebook.swift:405-413`). A drawn page is not
resized, for the reason asset paper refuses one: the page rectangle is what
every layer rect and transform is stated in (Contract, Transforms) and what
the composite is rendered for. Shrinking would keep the ink (ink outside the
page is kept) but would leave text and link rects off the page and layer
translations near the "ten page edges" limit invalid, and the app would have
to scale or clamp, which the contract forbids. Resizing an empty page would
be harmless and would follow the asset-paper rule, but no sheet needs it, so
it is not built. The comments saying geometry is "immutable after creation"
(`PageGeometry.swift:4`, `NotebookIndex.swift:3`) are already false because
of asset paper and are corrected here; `page-navigator.md` defers to this
plan for that comment.

## 2. Notebook intentions

```swift
/// A new page's paper.
package enum NewPagePaper: Sendable, Equatable {
    /// The existing rule: the current page's drawn paper, `none` -> `blank`, asset -> `blank`.
    /// Named for what it does, not for which page: `after:` may not be the current page.
    case inheritTemplate
    case drawn(DrawnPaper)
    /// An asset already in the package. The page keeps the chosen width and
    /// takes the asset's aspect, the rule `setPaper` applies to an empty page.
    case asset(Paper)
}

package enum NewPageRefusal: Error, Sendable, Equatable {
    case geometryOutOfBounds(width: Double, height: Double)
    case assetUnreadable(AssetRef)
}

@discardableResult
package func appendPage(after: PageID?, geometry: PageGeometry, paper: NewPagePaper) async throws(NewPageRefusal) -> PageID
```

One intention, one index mutation, one `emitStructure`, one refusal point.
The alternative, append then `setPaper` from the view model, was two
emissions for one action, a visible intermediate page with drawn paper, a
committed intermediate if the process died between them, and a page left
behind when the asset leg failed. `setPaper`'s empty-page check is
satisfied by construction on a page that does not exist yet, so the
aspect measurement (`Renderer.aspect`, the same call `setPaper` makes)
runs before the record is built and the refusal leaves nothing behind.
The measurement is why the intention is `async`. The seam and the format
are untouched either way; that argument never justified two notebook
calls.

The existing `appendPage(after:answering:)` (`Notebook.swift:346`) stays for
the end-boundary pull (`EditorBinding.swift:217`) and `EditorViewModel.addPage`.
It calls the new one with the template's geometry and `.inheritTemplate`; that
geometry came from a validated index, so the throw cannot happen and the
catch calls `TNPrecondition.fail`. The body from line 352 on is shared.

"Paper from page N" passes `.asset(paper)` with the `Paper` read from
`notebook.paper(of:)` (`Notebook.swift:428`). "Photo" is
`importImageAsPaper`'s decode-and-store half (`Notebook.swift:530`) factored
so that `appendPage(after:geometry:paper: .asset(.image(ref)))` follows the
store; the existing `importImageAsPaper(_:on:)` keeps its shape for the
paper menu. The page keeps the chosen width and takes the asset's aspect
(`Notebook.swift:410`), so the sheet disables orientation when an asset
paper is chosen and says why. `lastContentError` is a `FormatFault?`
(`EditorViewModel.swift:44`), so the view model maps `NewPageRefusal` into
`.invalidWrite(...)`, the way `importImageAsPaper` already wraps
`PaperRefusal` (`Notebook.swift:531`, `538`). One channel. A refused
append creates nothing.

Seam: no change. `PageDescriptor` carries geometry (`Seam.swift:29`) and `setPages` restates a survivor's (`PagedCanvasController.swift:160-163`).

Notebook creation: `NotebookIndex.new(notebookID:firstPage:createdAt:)`
(`NotebookIndex.swift:70`) gains `geometry: PageGeometry = .letter, paper:
DrawnPaper = .blank`; `LibraryStore.createNotebook(named:in:)`
(`LibraryStore.swift:218`) and `Notebook.create` (`Notebook.swift:103`) gain
and pass the same two. An out-of-bounds geometry is refused by `save` through
`validated()` (`PackageStore.swift:284`) as `.format(.indexInvalid(...))`; the
sheet refuses earlier by getting `nil` from `PageSize.geometry(_:)`.

## 3. File-by-file

- TNModel `PageGeometry.swift`: fix the comment.
  `NotebookIndex.swift`: `new(...)` takes geometry and paper; fix line 3.
- TNEditor `PageSize.swift`: `PageOrientation`, `PageSize`.
- TNNotebook `Notebook.swift`: the two enums, the new `appendPage`, the old one delegating; `create` takes geometry and paper.
- TNLibrary `LibraryStore.swift`: `createNotebook(named:in:geometry:paper:)`. TNEditor `EditorViewModel.swift`: `addPage(size:orientation:paper:)`, run
  inside `binding.intention` and scrolled to like `addPage()` (line 80);
  `addPage(size:orientation:paperFrom: PageID)` and `addPage(size:orientation:photo: Data)`
  build the `NewPagePaper` and call the one intention, `do`/`catch` at
  method scope as the comment at line 108 requires; `pagesWithAssetPaper: [(PageID, Paper)]` for
  the sheet, from `pageIDs` and `paper(of:)`, omitting pages whose state is
  `.unreadable`: `paper(of:)` reads the index, so such a row would offer an
  asset that can only fail. `EditorBinding.swift`: nothing.
- App `LibraryView.swift`: the "New notebook" alert (line 43) becomes a
  sheet with name, size, orientation, drawn paper. `EditorView.swift`: the
  "Add page" button (line 134) opens size and orientation plus paper: "Same
  as this page", the five drawn kinds, "Photo" (the existing picker routed to
  the new intention), and one row per page with asset paper. `paperMenu`
  stays. New `PageSetupSheet.swift`: the shared size and orientation
  controls; the custom field shows `PageBounds.minEdge` and `maxEdge` and
  disables Create when `geometry(_:)` is nil.
- TNCanvas: no change. `PageFit.scale` is the smaller ratio
  (`SlotLayout.swift:100`), so a landscape page in a portrait slot fits by
  width and `PageFit.rect` and `centerPageInViewport`
  (`PageCanvasController.swift:348`) centre it. The slot is one viewport,
  never the page (`SlotLayout.swift:6-11`). The zoom-floor precondition
  (`PageCanvasController.swift:319`) holds for every catalogue size because
  `minEdge` is derived from the widest viewport; a 4096 edge fits at 0.25.
- TNRender: no change; `composite` is capped at 2800 pixels on the long edge.
## 4. Tests

Hostless, in `TNTests` (Swift Testing):
- `PageSizeTests` (new, hostless): each named size in both orientations is within bounds and
  landscape is the transpose; `.custom` at 137.6 passes, 137.5 and 4097 are
  nil; `.square` is the same both ways.
- `NotebookTests`: A4 landscape with `.drawn(.grid)` lands that record after
  `flush()` and `PackageStore.load()`; `.inheritTemplate` after a `.none` page
  is `.blank`; the boundary path still copies the template (extend
  `endBoundaryAnswersWithSetPages`, `EditorBindingTests.swift:141`);
  `.asset(.image(existing))` keeps the width and takes the aspect in one
  structure change (the shape of line 365); a missing asset throws
  `.assetUnreadable` and creates no page; out-of-bounds throws
  `.geometryOutOfBounds` and emits no structure change.
- `LibraryTests`: `createNotebook` with A5 `.lined`, reopened through
  `PackageStore.load()`, has that first page.
- `FormatTests`: the key-set test at line 8 is unchanged and green, which is
  the proof nothing durable was added.
- `TuberNotesTests/TNCanvasTests` value tests (lines 20 and 41 need no
  host): `PageFit.rect` for 842x595 in 1032x1376 is slot-wide and centred
  vertically; 595x842 in 1376x1032 is slot-tall and centred horizontally.

Hosted: none new. Device evidence, required: the PR template's file list does not name `EditorViewModel.swift`, but `AGENTS.md`'s rule covers any change to `TNEditor`, and a new page size is what could break the zoom floor on hardware. Turn between a landscape and a portrait page; pinch to the floor and the cap on each.

Cross-plan (`README.md`, conflict 5): this plan owns the `PageGeometry.swift` and `NotebookIndex.swift` comment corrections; `page-navigator.md` defers to it. The navigator's "add page after" presents this plan's sheet once both have landed; until then it inherits the current page's paper. The navigator's `contentVersion` bump at creation sits in the `appendPage` body both plans share, so it survives this plan's restructuring in either order. Nothing here touches `tool-picker.md` or `text-editing.md`.

## 5. Contract sentences

Durable form, Paper. Now: "a new page copies the current page's drawn paper
(`none` becomes `blank`); after asset paper a new page is `blank`."
Proposed: "a new page copies the current page's drawn paper (`none` becomes
`blank`) unless its creation specified a paper; after asset paper
a new page is `blank`."

Durable form, Geometry. Now: "**Geometry** is per page, finite, and within
`PageBounds`: `maxEdge` is 4096 points; `minEdge` is derived from
`ZoomCap` ..." (`Contract.md:186-188`). Proposed, an insertion that keeps
the bounds' derivation intact: "**Geometry** is per page, chosen when the
page is created from a catalogue of named sizes or a custom size, finite,
and within `PageBounds`: `maxEdge` is 4096 points; `minEdge` is derived
from `ZoomCap` ... [unchanged to the end of the sentence]. After creation
it changes only when asset paper is applied to an empty page; a page with
ink or layers is never resized."

Custody and Navigation need no change: geometry stays with `Notebook`, and
"A page is scaled to fit its slot and centered" already covers landscape.

## 6. Out of scope

- Resizing an existing page, empty or drawn.
- A notebook default size or paper, and any new index key.
- A library-level paper collection (`Docs/Queue.md`, Custom paper).
- Asset paper at notebook creation; open the notebook and use the sheet.
- Remembering the last chosen size across launches, and thumbnails for
  the "paper from page N" rows; the rows are page numbers.

## 7. Open questions for Phillip

- Should a drawn page ever be resizable, with content scaled, as GoodNotes
  allows? A product verdict; the contract as proposed says no.
- Should the add-page sheet default to "same as this page" (the boundary
  pull's rule) or to the last size chosen in the sheet? One rule in one
  place, or what a second tap usually expects.

## 8. Review disposition

An adversarial review was answered on 2026-09-10. Adopted, and folded in
above: the `lastContentError` mapping through `.invalidWrite` is stated;
custom sizes are taken as typed and have no orientation control; the
Geometry contract change is an insertion, not a replacement, so `minEdge`'s
derivation survives; residue after a failed asset leg is stated as
intended; "paper from page N" omits unreadable pages; five citations
corrected; device evidence is required, with the reason; comment
ownership and the navigator's "add page after" are settled here.
Nothing was rejected.

A second review, same day, was answered as follows. Adopted: `PageSize`
moves to `TNEditor`, a creation aid beside `defaultRect`, since nothing
durable takes it; append and asset paper become one intention with one
emission and one refusal point, and the plan now says why composition
lost; `.sameAsCurrent` is `.inheritTemplate`; `ipadScreen` is `iPadPro13`
with both edges stated; the contract sentence speaks of what creation
specified, not of a sheet. Already done before that review: custom sizes
do not transpose, and the comment fix has one owner. Rejected: merging
`Notebook.create` and `LibraryStore.createNotebook`; the duplication is
pre-existing and consolidating it is not this queue item.
