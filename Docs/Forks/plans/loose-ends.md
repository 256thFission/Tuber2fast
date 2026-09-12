# Loose ends: nine small items over an engine that already works

A plan, not code. Branch `v2-mvp` (b84af06). Every claim below cites the
file it was read from.

**In short.** Nine items, each a day or less, on one branch with one
commit per item so each is reviewable alone. Four are a menu row over a
notebook intention that exists, is tested, and has no app caller: a photo
as the current page's paper, a page flattened into a new page's paper, a
link to a page of an open notebook, and a page duplicated after itself
(the last is new, one function beside `insertPage`). Two are library work
with no device evidence: search over the whole tree, and the new-notebook
sheet opening on the last size and paper chosen. One deletes
`Notebook.detailNeeded` and the `Composite.scale` field only it read. One
gives a link a way to move, for `selection.md`'s overlay to call. Deleting
an object is not planned here: it needs a selected layer, which
`selection.md` builds. First, as its own commit, a defect wider than any
item: every notebook opens on its first page, because the saved current
page is read into the notebook and never sent to the runtime. No format,
seam, or Contract change.

## 0. Where it stands today

Each item's engine half is cited in its step in section 3. Two facts
belong here.

**Commit 0.** `Notebook.init` reads `view.json` into `currentPageID`
(`Modules/TNNotebook/Notebook.swift:85-89`). The runtime learns the order
from `setPages`, whose descriptors carry no current flag
(`Modules/TNModel/Seam.swift:27-36`), and when its own `currentPageID` is
nil it takes `order[0]` (`Modules/TNCanvas/PagedCanvasController.swift:
146, 173-178`). The opening push is `setPages` then a drain
(`Modules/TNEditor/EditorBinding.swift:125-127`); the only `scroll(to:)`
callers are undo, redo, the add-page paths, and `scroll(toPageIndex:)`
(`EditorBinding.swift:274, 284`; `EditorViewModel.swift:251, 282, 350`).
So every open shows page 1 while the toolbar's "Page N of M", read from
the notebook (`EditorViewModel.swift:114`), says otherwise. A call at open
would also be dropped: `scroll(to:)` returns while the layout is empty
(`PagedCanvasController.swift:296-301`), and the first layout is built in
`viewDidLayoutSubviews` (115-127). Following a link into a closed
notebook (`TuberNotesApp/Workspace.swift:198-201`) hits both holes.

**Dead code.** A scan of every `package` member of `Notebook` against
`Modules`, `TuberNotesApp`, `TNTests`, and `TuberNotesTests` finds one with
zero callers: `detailNeeded(for:scale:)` (`Notebook.swift:631-634`). It is
the only caller passing `rerenderComposite`'s `scale:` (606, 633) and the
only production reader of `Composite.scale` (632; `Seam.swift:45`), which
the renderer sets (`Modules/TNRender/Renderer.swift:120, 250`) and one test
reads (`TuberNotesTests/TextFidelityTests.swift:52`). The contract's
Rendering section (`Docs/Contract.md:305-313`) requires a composite
rendered once at no more than 2800 pixels and scaled by the scroll view,
and nothing about a sharper render at zoom; there is no Performance
section.

## 1. What GoodNotes does here, and what this plan matches

| GoodNotes | This plan |
|---|---|
| Change Template applies a paper, imported images included | a photo becomes an empty page's paper; no template library |
| no flatten; export a page as an image, re-import as a template | a new page whose paper is the source's picture, source untouched |
| a link to a page in this or another document, or a URL | a page of an open notebook; no URL, which is not a `LinkTarget` case |
| Search over titles, handwriting, PDFs, typed text | titles across the library; the rest is deferred by Phillip |
| the new-notebook sheet opens on the last cover and paper | the last size and paper |
| thumbnails offer Duplicate, inserted after the source | the same, from the navigator's context menu |

## 2. The data shape

Nothing durable changes: no package file, no JSON key, no seam command.

```swift
// Modules/TNCanvas/PagedCanvasController.swift (commit 0)
/// A scroll asked for before the first layout existed; consumed by the
/// first `viewDidLayoutSubviews`, dropped by a `setPages` that no longer
/// lists the page. Owner: this runtime, like its other scroll state.
private var pendingScroll: PageID?

// TuberNotesApp/PageSetupSheet.swift (commit 2)
// `NewPagePaperChoice` gains `case flattened`, no payload.

// Modules/TNLibrary/LibraryStore.swift (commit 5)
/// Every item under `folder`, depth first, with full paths. Its own walk.
package func listTree(under folder: String) throws(LibraryError) -> [LibraryItem]

// Modules/TNLibrary/LibraryViewOptions.swift (commit 6)
/// What the New notebook sheet opens on. `PageGeometry`, not a catalogue
/// name: `PageSize` is in `TNEditor`, and `PageSize.matching(_:)` recovers
/// the name at the sheet.
package struct NotebookSetup: Codable, Equatable, Sendable {
    package let geometry: PageGeometry
    package let paper: DrawnPaper
}
/// On `LibraryViewOptions`: nil until a notebook has been created here.
package var newNotebook: NotebookSetup? = nil

// Modules/TNNotebook/Notebook.swift (commit 7)
/// A new page after `source`: same geometry, paper, ink, and layers; new
/// `PageID` and `LayerID`s; the same assets by name. Navigation, records
/// nothing. Refused under an open text box and for an unreadable page.
package func duplicatePage(_ source: PageID) async throws(FormatFault) -> PageID
/// A page not in custody, decoded from its files with any pending restore
/// adopted, installed nowhere. `thumbnail(of:)`'s `.unloaded` arm, shared.
private func unloadedContent(of page: PageID) async -> PageContent?
/// `insertPage` takes the content it installs; today's callers pass empty.
private func insertPage(after: PageID?, geometry: PageGeometry, paper: Paper,
                        content: PageContent, answering: ReportSeq?) -> PageID

// Modules/TNNotebook/Notebook.swift (commit 9)
/// A link's placement is its rect, not its transform (Contract,
/// Transforms), so a move is a rect edit: `transformLayer`'s shape with a
/// rect in place of a transform, recorded through the revision.
package func moveLinkLayer(on page: PageID, layer: LayerID, to rect: PageRect) -> TransformOutcome
```

Owner of `newNotebook`: `LibraryBrowser`, through `options`, whose
`didSet` is the one writer (`Modules/TNLibrary/LibraryBrowser.swift:42-44`).
Deleted: `detailNeeded`, `rerenderComposite`'s `scale:`, `Composite.scale`.

## 3. The steps

One branch, `loose-ends`, off `v2-mvp`; one commit per item, in this
order, each green alone. Commits 0, 1, 2, 3, 7, and 9 change `TNCanvas`
or `TNEditor` and need device evidence (`AGENTS.md`, Definition of done).
Commits 5, 6, and 8 need none.

**Commit 0, the saved page is the page shown.** The hosted test comes
first, against b84af06, in `TuberNotesTests/TNCanvasTests.swift` beside
`openSession`: a runtime given three pages, `scroll(to:)` the third before
any layout, then laid out, sits at the third slot's offset and reports
`pageBecameCurrent` for it once; with a `setPages` dropping the page in
between, nothing. And in `TNTests/EditorBindingTests.swift` over
`RecordingSurface`: a notebook reopened with `view.json` naming page 3
(the `reopened` helper, 96-104, after a `pageBecameCurrent(third)`) pushes
`scroll(third)` after its opening `setPages`. The test decides; if it
passes unchanged the commit is a note. The fix: `scroll(to:)` stores the
page in `pendingScroll` instead of returning at `:300-301`;
`viewDidLayoutSubviews` (115-127) consumes it after `refreshWindow()`;
`setPages` (131) clears it when the page left the order; `EditorBinding.
init` adds `surface.scroll(to: notebook.currentPageID)` after the opening
push (125). Device evidence: open a notebook last viewed on page 3; canvas
and toolbar agree.

**Commit 1, photo as this page's paper.** Engine:
`Notebook.importImageAsPaper(_:on:)` (`Notebook.swift:733-737`) refuses a
page with ink or layers before storing anything (564-567), stores the HEIC
(722-730), and applies it through `setPaper` (542-560), which takes the
asset's aspect at the page's width; pinned by `flattenAndPhotoPaper`
(`TNTests/NotebookTests.swift:917-951`). Added: `EditorViewModel.setPaper
(photo: Data) async` in the shape of `importImage` (`EditorViewModel.swift:
361-367`); `EditorView.PhotoDestination` (`TuberNotesApp/EditorView.swift:
27-30`) gains `.paperForCurrentPage`, `paperMenu` (149-167) a "Photo" row,
`importPhoto`'s switch (214-219) the case. A page with ink is refused by
the notebook and the bar says so (734); the row is not greyed, which would
need a per-drain "page is empty" mirror. Test, `TNTests/
EditorViewModelTests.swift`: on an empty loaded page the record's paper
becomes `.image` at width 612 with the photo's aspect and the surface saw
`setPages` and `updateComposite`; on a page with a stroke,
`lastContentError` is set and `assets/` is empty. Device evidence: the
photo fills the page and ink lands over it.

**Commit 2, flatten this page into a new page's paper.** Engine:
`Notebook.flatten(_:)` (`Notebook.swift:742-751`) renders composite and
ink to one HEIC at 2800 pixels (`Renderer.swift:242-254`), returns the
asset, and changes nothing (`NotebookTests.swift:929-932`). Added: a "This
page, flattened" row in the add-page sheet's paper picker
(`PageSetupSheet.swift:251-263`), `takesAssetAspect` true for it (282-287);
`addPendingPage` (`EditorView.swift:189-203`) routes it to
`EditorViewModel.addPage(size:orientation:flatteningCurrentPage:) async`,
the shape of `addPage(photo:)` (224-232): text-session refusal, `try await
notebook.flatten(page)`, then `append(size, orientation, .asset(.image
(asset)))`. `flatten` records nothing and an append is navigation
(`Contract.md:277-278`); the stack is untouched. Test,
`EditorViewModelTests`: a page with a stroke and an image layer;
afterwards `pageCount` is 2, the new record's paper is `.image(asset)`
with a readable asset, the source and `canUndo` are unchanged, and the
surface saw `setPages` then `scroll(new)`. Device evidence: the flattened
page beside its source at fit zoom.

**Commit 3, mint a link.** Engine: `Notebook.addLinkLayer(on:rect:target:)`
(`Notebook.swift:753-756`) through `insertLayer` (642-655), which records
and rerenders; `EditorViewModel.addLink(to:)` (378-385) places it at a
default rect and refuses under a text session. Following is built end to
end: hit rects (`PageCanvasController.swift:73-76, 281-292`), the tap
(555-572, 586-588), `linkActivated` (`PagedCanvasController.swift:
680-681`), the binding (`EditorBinding.swift:236-250`), and
`Workspace.activate` (`Workspace.swift:187-217`) with the contract's three
refusals (`Contract.md:341-345`). Added: `TuberNotesApp/LinkTargetPicker.
swift`, one `List` with a section per open tab from `Workspace.tabs`
(`Workspace.swift:35`; `EditorView` holds the workspace, `EditorView.swift:
14`), active tab first, rows from each tab's `editor.navigatorPages` with
`isCurrent` marked (`EditorViewModel.swift:11-23, 65`); a row calls
`addLink(to: .internalPage(page))` when `tab.id == editor.notebook.
notebookID`, else `.externalPage(notebook: tab.id, page:)`. A "Link" row
in `insertMenu` (`EditorView.swift:169-185`) presents it. A closed notebook
is not offered. Every link lands at the default rect until commit 9 and
`selection.md` move it. Test, `EditorViewModelTests`: `addLink(to:)`
inserts one `.link` layer with that target, records one entry, and
`layersSeen` carries it. Device evidence, covering commit 0: a link to
page 3 turns to page 3 under the pen; a link into a second open tab
focuses it on the page; close that tab, follow again, the reopened tab
lands on the page; trash the target, the bar says so.

**Item 4, delete an object.** Not planned here. `Notebook.deleteLayer`
(`Notebook.swift:877-889`) records and rerenders, but a menu needs a layer
under the finger, and image and PDF layers have no hit rect
(`PageCanvasController.swift:288-290`). `selection.md` builds that and owns
the item.

**Commit 5, search the whole library.** Today `displayed` filters one
folder's `listing` by name (`LibraryBrowser.swift:72-83, 95`) and the store
holds no tree (`LibraryStore.swift:242-253`). Added: `listTree(under:)`. In
`reload()` under `.documents`, `listing` is `list(folder:)` when
`searchText` is empty and `listTree(under: "")` otherwise; `LibraryView`'s
reload task id (`TuberNotesApp/LibraryView.swift:41`) gains `|\(browser.
searchText.isEmpty)`, so the tree is read once per search; `displayed` is
unchanged; favorites already list the whole tree (410-422). `LibraryItem`
gains `parentPath`, shown under the name while searching (`TuberNotesApp/
LibraryCells.swift:36-47, 90-103`). Enter, open, select, move, and trash
already take full paths (108-113; `LibraryView.swift:348`;
`LibraryBrowser.swift:139-142, 179-191`). Cost: one directory read per
folder and one index read per notebook (`item(at:)`, 227-238), once per
search. Test, `TNTests/LibraryTests.swift`: `listTree(under: "")` over
Term/Week 1/Deep lists all three with full paths, depth first;
`listTree(under: "Term")` omits the root's other items.
`LibraryBrowserTests.searching` (33-55) extended: from the root and from
another folder, "deep" shows Deep with `parentPath` "Term/Week 1";
clearing returns the folder listing.

**Commit 6, remember the new-notebook choice.** `NewNotebookSheet` opens
on Letter, portrait, blank every time (`PageSetupSheet.swift:168-171`) and
hands geometry and paper to `LibraryBrowser.createNotebook`
(`LibraryBrowser.swift:213-215`). Added: `newNotebook` as in section 2;
`createNotebook` sets it after `perform` leaves `refusal` nil, and the
`didSet` saves it under the key `LibraryViewDefaults` owns (`TuberNotesApp/
LibraryViewDefaults.swift:16`); the sheet takes `opensOn: NotebookSetup?`
and opens through `PageSize.matching` (`Modules/TNEditor/PageSize.swift:
42-49`); `LibraryView` passes `browser.options.newNotebook` (52-56). No new
store, key, or allowlist entry. The add-page sheet keeps opening on the
current page's size (`page-size-and-paper.md`, open question 2). Test,
`TNTests/LibraryViewOptionsTests.swift`: the round-trip case (77) carries
`newNotebook`; `LibraryBrowserTests`: creating an A5 lined notebook sets
it, a refused create leaves it.

**Commit 7, duplicate a page.** No page-level engine;
`LibraryStore.duplicateNotebook` (516-551) is the notebook copy. Added:
`duplicatePage`, `unloadedContent(of:)`, and `insertPage(content:)` as in
section 2. The source: `.ready` gives `content` after requiring no open
text session; `.unloaded` and `.loading` give `unloadedContent(of:)`,
`thumbnail(of:)`'s arm (`Notebook.swift:587-593`) with the pending
revision applied through `PageContent.adopt` (`PageState.swift:100-116`),
and `thumbnail` rewritten onto it; `.unreadable` throws. The copy: the
source record's geometry and paper under a new `PageID`, layers rebuilt
under new ids with the same transform and payload, all pending, `setInk`
when `hasInk` so the first save writes the container (`PageState.swift:
81-86`), else `edited()`; `insertPage` does the rest (477-497). Layer ids
are new because a layer file is one per id (`PackageLayout.swift:25-27`)
and a transform on either page would rewrite it for both. Assets are
shared by name: immutable (`Contract.md:198-200`; `PackageStore.swift:
425-430`), and `compact()` keeps any a reachable layer or record names
(493-508). Entry: `EditorViewModel.duplicatePage(_:) async`, drain, then
`scroll(to: copy)` as `addPage(after:)` does (279-283); "Duplicate page"
in the navigator's context menu (`PageNavigatorSheet.swift:103-115`).
Test, `NotebookTests`: a ready A4 landscape grid page with a stroke, an
image layer, and a text layer; the copy follows the source, equals it in
ink, `inkIndex`, `hasInk`, geometry, and paper, matches its layers with no
id in common, leaves `canUndo` unchanged, and after `flush` and reload
both pages are fault-free with one file under `assets/`; an unloaded
source copies the disk ink and stays `.unloaded`; a pending restore is
what the copy takes; an open text session throws. `EditorBindingTests`:
one `setPages` with the copy after the source, an `installContent`, then
`scroll(copy)`. Device evidence: duplicate the page just drawn on; the copy
shows the ink and takes new ink.

**Commit 8, delete the dead detail path.** Delete `detailNeeded`
(631-634), `rerenderComposite`'s `scale:` (606, 614), and `Composite.scale`
(`Seam.swift:45`, and the equality at 52-54): with no reader it is the
field the contract forbids (`Contract.md:392`). `Renderer.composite` and
`flattened` build `Composite(image:)` (120, 250), `rasterize` returns
`CGImage?` (189-191), `TNCanvasTests.swift:295, 332-333` drop the argument,
and `TextFidelityTests.swift:52` asserts `composite.image.width ==
Int((612 * 2).rounded(.up))`. The proof is the build.

**Commit 9, a link can be moved.** A link carries a rect and an identity
transform, `validated()` refuses any other (`Layer.swift:271`), so
`transformLayer` refuses every move of a link (`Notebook.swift:864`), and
nothing on this branch edits a rect except a text session's commit (829).
A move is a rect edit, not a transform: `moveLinkLayer(on:layer:to:)` is
the body of `transformLayer` (860-875) with `LinkLayer(rect: rect, style:,
target:)` in place of `withTransform`, `validated()` deciding, the file
pended, `recordEdit`, and a rerender so the hit rects follow. It answers
`TransformOutcome` so the overlay's report can be answered the way
`layerTransformed` is. No caller in this plan. Test, `NotebookTests`: move
a link, the rect is new and the file pending, undo restores it, redo
returns; a zero-width rect is `.refused` and records nothing; a text
layer's id is `.refused`.

## 4. Contract

No Contract change. Adding a page is already navigation (Undo,
`Contract.md:277-278`) and `duplicatePage` is an `insertPage`; assets are
already immutable (Durable form, 198-200); a link's rect is already its
placement (Transforms, 193-196); commit 6's preference lands under a key
an allowlisted file already owns.

## 5. Out of scope

A URL link target, a title on a link, and any gesture that moves one.
Links into closed notebooks. Selecting, moving, or deleting an image or
PDF layer. Search over handwriting, PDF text, or typed text, and a search
index kept between sessions. A template library. Flatten in place.
Remembering the add-page sheet's choice. A page trash, and undo of any
page operation. A sharper composite at zoom. `Docs/Unproven.md`'s
paragraph about an old `duplicatePage` (418-436), which is Phillip's to
strike.

## 6. Decisions

1. Flatten is a new page's paper, never in place: the contract says
   flattening does not change the source (`Contract.md:178`). Smallest
   alternative: none; in place is refused by the rule.
2. The link picker offers open notebooks only, from `Workspace.tabs`.
   Smallest alternative: closed notebooks too, through
   `LibraryStore.indexFacts(ofPackageAt:)` (`LibraryStore.swift:216-221`)
   returning the page list, behind a folder picker shaped like
   `LibraryMovePicker`.
3. Search reads the whole tree from the root wherever the person is.
   Smallest alternative: `listTree(under: folder)`, one word.
4. `duplicatePage` reads an unloaded source from its files so every cell
   in the navigator can be duplicated. Smallest alternative: refuse a
   source that is not `.ready`; the menu then works on loaded pages only.

## 7. Cross-plan

Everything in `README.md` has landed. Commits 1 and 2 build on
`page-size-and-paper.md`'s `appendPage(after:geometry:paper:)`
(`Notebook.swift:441-473`) and change no paper rule; commit 7's entry is
`page-navigator.md`'s context menu; every mutation here records through
`undo.md`'s `recordEdit` or is navigation.

Item 4 belongs to `selection.md`, which builds the hit test and the
selected object a delete needs; this plan adds no hook. Commit 9 is the
notebook half of moving a link; `selection.md`'s overlay is what calls
`moveLinkLayer`, through whatever report that plan gives a rect edit.
Following a link is built and needs nothing from any plan.

`export.md` and `selection.md` also edit `EditorView.swift`'s toolbar
`HStack` (80-103), where commit 1 adds a `paperMenu` row and commit 3 an
`insertMenu` row, and `EditorViewModel.swift`'s Content section
(353-406), where commits 1, 2, 3, and 7 add methods. Distinct rows,
distinct methods: the merge is textual. `selection.md` may edit
`PageCanvasController.setLayers` (281-292); commit 0 edits
`PagedCanvasController`, a different file. The `TNLibrary` and library
view files are touched by commits 5 and 6 and by no other open plan.

## 8. Review disposition

A simplicity review was answered on 2026-09-11. Adopted, all nine: commit
0 is the wider defect (every open shows page 1; verified at
`PagedCanvasController.swift:146, 178` and by the absence of any
`scroll(to: notebook.currentPageID)` caller), hosted test first, one-line
push in `EditorBinding.init`; no Contract hunks; the link picker is one
`List` over `Workspace.tabs` with no library reader; search is two lines
in `reload()` and the task id, `listTree` with its own walk; one shared
`unloadedContent(of:)`; `Composite.scale` deleted; links do not stack;
`case flattened` carries no payload; section 0 is the scan and the commit
0 note, section 3 one paragraph per item. Also adopted, from
`selection.md`'s revision: commit 9, a link can be moved, verified at
`Layer.swift:271` and `Notebook.swift:864`. Rejected: nothing. One
citation in the review was off by two lines (`Workspace.tabs` is at
`Workspace.swift:35`, not 33); the finding stands.
