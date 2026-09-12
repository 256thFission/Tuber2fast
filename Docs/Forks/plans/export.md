# Export: PDF, image, share, print

A plan, not code. Branch `v2-mvp` (b84af06). Every claim below cites the
file it was read from; paths are relative to that worktree.

**In short.** Nothing a person makes in this app can leave the device.
The renderer already draws paper, every layer, and ink into a `CGContext`,
and the notebook already reads a page it has not loaded without
installing it; export is one renderer function that points that drawing
at a PDF context and asks a closure for each page in turn. Paper, text,
and imported PDF pages stay vector because the same code draws them; ink
is a raster because PencilKit renders to nothing else. The document is
built in memory and shared through `ShareLink`, so no file is written and
the file I/O allowlist is untouched; print is the same `Data` handed to
`UIPrintInteractionController`; one page as PNG is `flattened` with a
different type. Two pull requests. Four census lines close: a notebook or
page range to PDF, a page as an image, the share sheet, and print.

## 0. Where it stands today

Drawing a page into a context is built. `Renderer.compose` makes a bitmap
context, flips it to page space (`Modules/TNRender/Renderer.swift:129-130`),
fills white (`:131-132`), draws the paper (`:133`) and every layer
(`:134-136`), and reads the pixels back (`:137`). None of the draw paths
depends on the context being a bitmap: drawn paper is CG paths
(`Modules/TNRender/PaperRenderer.swift:23-68`), asset paper is a flipped
`CGImage` draw or `PDFSource.draw` (`Renderer.swift:197-219`), which ends
in `context.drawPDFPage(page)` (`Modules/TNRender/PDFSource.swift:52`),
layers are the same two plus a rounded rect for a link and `CTLineDraw`
for text (`Renderer.swift:264-320`) over the lines `TextTypesetting.placedLines`
places (`Modules/TNModel/TextTypesetting.swift:113-139`). Drawn into a PDF
context, all of that is vector for free. The one raster is the ink:
`Renderer.rasterize` is `PKDrawing.image(from:scale:)` in the caller's
task (`Renderer.swift:189-192`). `flattened` is composite, ink raster,
`overlay`, HEIC (`:242-254`); `Notebook.flatten` calls it
(`Modules/TNNotebook/Notebook.swift:745`) and `flatten` itself has no
caller in `Modules/` or `TuberNotesApp/` (grep, this worktree).

Reading a page that is not loaded is built. `Notebook.thumbnail(of:)`
renders a `.ready` page from custody (`Notebook.swift:585-586`) and an
`.unloaded` one by `store.loadPage`, `Self.decode`, and a preference for
the pending restore over the ink on disk, installing nothing (`:587-593`);
`.loading` and `.unreadable` answer nil (`:594-595`). `decode` runs in the
caller's task (`:195-211`), so a cancelled export stops decoding. Three
tests pin that the unloaded path leaves the state `.unloaded` and the
notebook clean (`TNTests/NotebookTests.swift:763-781`), prefers the
pending restore (`:783-822`), and refuses a corrupt page (`:824-836`).

A PDF context without UIKit is available. `TNRender` may import
CoreGraphics, PencilKit, and CoreText and not UIKit
(`TuberNotesTests/ContractStructureTests.swift:736`), so
`UIGraphicsPDFRenderer` is out and `CGContext(consumer:mediaBox:_:)` over a
`CGDataConsumer(data:)` is in; the test support already builds a PDF that
way (`TNTests/FormatSupport.swift:48-60`). The app presents pickers as
SwiftUI modifiers (`TuberNotesApp/EditorView.swift:53-58`), has a
`Transferable` (`TuberNotesApp/PageNavigatorSheet.swift:17-23`), imports
`UniformTypeIdentifiers` (`EditorView.swift:8`), and the tab knows the
notebook's name (`TuberNotesApp/Workspace.swift:18-23`); the notebook does
not. No Info.plist key beyond `project.yml:203-215` is set, and no zip or
archive path exists anywhere in `Modules/` or `TuberNotesApp/`.

## 1. What GoodNotes does here, and what this plan matches

GoodNotes exports from a share sheet: all pages, this page, or a range;
as PDF, as one image per page, or as its own `.goodnotes` file; with
switches for the page template and the annotations; and prints through
the system panel. Its PDF keeps handwriting as vector.

Matched: a notebook or a page range as one PDF; the current page as a
PNG; the system share sheet for both, where AirDrop, Files, Mail, and
Print live; a Print button that is the same PDF handed to the print
panel. Paper, text, links, images, and imported PDF pages export as they
draw on screen.

Not matched, deliberately. Ink is a raster: PencilKit renders a
`PKDrawing` to pixels and to nothing else, and a vector ink renderer of
our own is non-PencilKit ink, which the 2026-09-11 deferral memo lists as
permanently out. The template and annotation switches: an export always
carries paper and ink. Bulk per-page images and a `.goodnotes`-style
archive: section 5. Links export as the blue button the composite draws
(`Renderer.swift:287-297`), not as PDF link annotations.

## 2. The data shape

Nothing durable. No file in the package changes, no index key, no
`view.json` field.

```swift
// Modules/TNRender/Renderer.swift
extension Renderer {
    /// One PDF, `pageCount` pages, each asked for in turn and drawn into a
    /// page-space context by the code `compose` uses: paper and text vector,
    /// the ink a raster at the flatten scale (Renderer.swift:243). The
    /// context and its `NSMutableData` are locals; the actor is reentrant at
    /// each `await page(n)`, so composites for the live canvas are served
    /// between pages. A page the source cannot give, or a cancel between
    /// pages, returns nil. Measured: N KB per Letter page of handwriting.
    package func pdf(
        pageCount: Int,
        page: @MainActor (Int) async -> (geometry: PageGeometry, paper: Paper?, layers: [Layer], ink: PKDrawing)?
    ) async -> Data?

    /// `flattened` gains the encoding type; `heic` becomes `encode(_:as:)`.
    /// `Notebook.flatten` passes `"public.heic"`; the image export passes
    /// `"public.png"`. No new function.
    package func flattened(geometry: PageGeometry, paper: Paper?, layers: [Layer], ink: PKDrawing, as type: CFString) async -> Data?
}
```

Underneath, the body of `compose` between the flip and `makeImage`
(`Renderer.swift:131-136`) becomes `private func drawPage(...in context:)`
with an optional ink image drawn flipped inside the page rectangle the
way asset paper is (`:203-208`); `compose` calls it with no ink, `pdf`
calls it with the raster. The PDF page's media box is the geometry in
points; a page with `.drawn(.none)` paper still gets the white ground
`compose` gives it (`:131-132`), so screen and export agree.

```swift
// Modules/TNNotebook/Notebook.swift
extension Notebook {
    /// The `.unloaded` arm of `thumbnail(of:)` (Notebook.swift:587-593),
    /// factored out, with `.loading` joining it: custody for a ready page;
    /// otherwise the files, decoded in the caller's task and installed
    /// nowhere, a pending restore preferred. Nil for an unreadable page.
    package func revision(of page: PageID) async -> PageRevision?
}
```

`thumbnail(of:)` becomes its cache check, its `.loading` nil (`:594`, a
cell re-asks when the load settles, `PageNavigatorSheet.swift:172-176`),
and `revision(of:)`.

```swift
// Modules/TNEditor/EditorViewModel.swift
package struct ExportProgress: Equatable, Sendable {
    package let done: Int
    package let total: Int
}

package struct ExportedFile: Equatable, Sendable {
    package enum Kind: Sendable { case pdf, png }
    package let kind: Kind
    package let data: Data
}

extension EditorViewModel {
    /// Owner: this view model, like the other mirrors (EditorViewModel.swift:60-66).
    /// Non-nil while a walk runs. Not on the notebook, whose observed
    /// surface is five properties (Contract.md:78-82).
    package private(set) var exportProgress: ExportProgress?
    /// Owner: this view model, until the sheet closes. Pixels and PDF, not ink.
    package private(set) var exportedFile: ExportedFile?
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    /// 1-based positions from the list at the tap; the sheet passes `n...n`
    /// or `1...pageCount` from `currentPageIndex` and `pageCount`
    /// (EditorViewModel.swift:62-63). A range outside `1...pageCount` is
    /// `lastContentError`, and nothing is asked of the renderer.
    package func exportPDF(pages: ClosedRange<Int>)
    package func exportCurrentPageImage()
    package func cancelExport()
    package func clearExport()
}
```

`exportPDF` refuses while a text box is open, exactly as the three imports
do (`EditorViewModel.swift:364, 373, 382`), because custody holds the box
as it was when the session opened and the typing is in the text view. It
runs `notebook.renderer.pdf(pageCount:page:)` (`renderer` is `package let`,
`Notebook.swift:42`) in `exportTask`; the closure calls
`notebook.revision(of:)`, sets `exportProgress`, and returns nil for a page
that cannot be read, on which `lastContentError` becomes
`.invalidWrite("page N couldn't be read")` in the shape of `textBoxOpen`
(`:390-392`): the export refuses rather than exports a hole, because
"Nothing is dropped" (`Docs/Contract.md:202-207`). A cancel is nil with
no error. A second `exportPDF` while one runs cancels the first.

The document stays in memory. A Letter page's ink raster at the flatten
scale is 2163 by 2800 pixels, 24 MB for the moment it is drawn; the PDF
context Flate-compresses the image stream, and a handwriting page is
almost entirely zero alpha, so a page lands well under a megabyte and
two hundred pages under a quarter of a gigabyte in one `Data`, inside an
iPad's foreground budget, with the range picker there anyway. The
measured number goes in `pdf`'s doc comment.

```swift
// TuberNotesApp/ExportSheet.swift
/// What the share sheet receives. Data stays in memory; `suggestedFileName`
/// is what Files and Mail name it, from the tab's name.
struct ExportedPDF: Transferable {
    let data: Data
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { $0.data }.suggestedFileName { $0.name }
    }
}
struct ExportedImage: Transferable   // the same, `.png`
```

The share sheet offers Save Image for a PNG item and the system kills an
app without `NSPhotoLibraryAddUsageDescription` when that row is tapped,
so `project.yml` gains `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription`
beside the other keys (`project.yml:203-215`), a consequence of shipping
a PNG. The string is the app's; proposed: "Saves the exported page to
your photo library."

## 3. The steps

Two pull requests, in order.

**PR 1. The renderer and the notebook.** `Renderer.swift`: `drawPage`
factored out of `compose`; `pdf(pageCount:page:)`; `flattened(...as:)`
and `encode(_:as:)`; `Notebook.flatten` passes `"public.heic"`
(`Notebook.swift:745`). The dead `box` local in `PDFSource.draw`
(`PDFSource.swift:48-51`) goes in the same refactor. `Notebook.swift`:
`revision(of:)`, and `thumbnail(of:)` over it.

Tests, `TNTests/RendererTests.swift`, over `NoAssets` (`RendererTests.swift:10-12`)
and a scratch `PackageStore` where an asset is needed
(`FormatSupport.swift:48-60` makes a PDF, `:64-77` an image): two pages
give a `CGPDFDocument` of two pages whose media boxes are their
geometries; a page carrying `Fixture.textLayer` (`FormatSupport.swift:94`)
yields "Hello, world" from `PDFDocument(data:).page(at: 0).string`, the
proof the text is vector (PDFKit in the test bundle only); the one-stroke
fixture drawn back through `drawPDFPage` into a bitmap is dark at the
stroke and white away, the assertion of `inkLandsWhereDrawn`
(`RendererTests.swift:30-39`); a lined page with no ink and no layers has
no `XObject` in its resources; a page whose paper is `Fixture.pdfData`
has only `Form` XObjects and no `Image`; a source returning nil at page 2
yields nil; a task cancelled before page 2 yields nil;
`flattened(...as: "public.png")` decodes as a PNG with a dark stroke
pixel. And the doc-comment number: the bytes one Letter page of a few
hundred strokes adds.

Tests, `TNTests/NotebookTests.swift`, with `fast`, `waitUntil` (`:148`),
and `HeldLoadStore` (`:37`): `revision(of:)` of a pruned page leaves the
state `.unloaded`, `dirtyPageCount` 0, and `canUndo` unchanged; of a
loading page reads the disk and leaves it `.loading`; of a page with a
stashed undo returns the restored ink (the `thumbnailPrefersPendingRestore`
shape, `:783-822`); of the corrupt fixture (`Fixture.populated`,
`FormatSupport.swift:115`) is nil and the state stays `.unloaded`; the
four thumbnail tests (`:763-851`) pass unchanged.

Verification: simulator. Neither module needs device evidence
(`CONTRIBUTING.md:121-123`).

**PR 2. The editor, the sheet, the print, the key.** `EditorViewModel.swift`:
`ExportProgress`, `ExportedFile`, the three properties, the four
intentions. `EditorView.swift`: one Share button at the end of the
toolbar `HStack` (`:82-97`) and one `.sheet(isPresented:onDismiss:)`
beside the others (`:48-65`), passing `workspace.activeTab?.name`.
`TuberNotesApp/ExportSheet.swift`: a `NavigationStack` over a `Form` like
`AddPageSheet` (`TuberNotesApp/PageSetupSheet.swift:222-244`) with a
picker for This page, All pages, Pages and two number fields; Export PDF
and Export image buttons; while `exportProgress` is non-nil a
`ProgressView(value:total:)` and Cancel; once `exportedFile` is non-nil a
`ShareLink(item:preview:)` over `ExportedPDF` or `ExportedImage`, and for
a PDF a Print button that is `UIPrintInteractionController.shared.printingItem = data`
and `present(animated: true)`, falling back to `present(from:in:)` over
`editor.canvasHost.view.bounds` (`EditorViewModel.swift:38`) if iPadOS
wants an anchor. `.onDisappear` calls `cancelExport()`. `project.yml`
gains the Photos key.

Tests, `TNTests/EditorViewModelTests.swift`, on the `Notebook.create`
pattern there (`:15-18`): `exportPDF(pages: 1...1)` ends with
`exportedFile.kind == .pdf` and progress `1 of 1`; `0...1` and `3...2`
set `lastContentError` and never set `exportProgress`; `cancelExport`
during a held load leaves both nil; an export under an open text session
sets `lastContentError` and leaves `canUndo` unchanged.

Verification: `TNEditor` is on the definition of done's device list
(`AGENTS.md`, Definition of done), and no test taps a share sheet
(`Docs/Unproven.md`, Nothing exercises a touch). On an iPad the PR
records: AirDrop a five-page PDF to a Mac and the text is selectable in
Preview; Save to Files names it after the notebook; Print shows the
panel; the image export offers Save Image, the prompt shows the string,
the photo lands; Cancel at page 2 of 40 returns to the sheet within a
second with the notebook clean. Each line not done goes to
`Docs/Unproven.md`. `EditorBinding.swift` and `Workspace.swift` are not
touched.

## 4. Contract

Every hunk is Phillip's `CONTRACT:` commit; this is the proposal. No
rule blocks the design.

Rendering, quoted (`Docs/Contract.md:316-317`): "Asset paper is decoded
through the same cache as image and PDF layers, and so is a page being
flattened."

Replace with: "Asset paper is decoded through the same cache as image
and PDF layers, and so is a page being flattened or exported."

Rendering, add after that paragraph:

> An export is one or more pages drawn by the `Renderer` into a PDF
> context, or one page into a PNG, by the code that draws a composite.
> Paper, text, and an imported PDF page are vector; ink and image assets
> are pixels, the ink at asset resolution. A ready page is drawn from
> custody, unsaved ink included; any other page from its files, decoded
> and discarded, installing nothing. Exporting marks nothing dirty,
> records nothing, and is cancelled between pages. The document is built
> in memory and handed to the system; no file is written.

Forbidden, quoted (`Docs/Contract.md:390-391`): "A second copy of ink
anywhere other than the notebook and the live canvas."

Replace with: "A second copy of ink anywhere other than the notebook and
the live canvas. A drawing decoded for a render and discarded when the
render ends is not a copy." This is the sentence
`Docs/Forks/plans/page-navigator.md:163-164` proposed for the thumbnail
and that never landed; the thumbnail already does it
(`Notebook.swift:587-593`) and the export does it once per page.

## 5. Out of scope

A folder as an archive needs a zip writer iOS does not ship and a file
on disk; the library menu's export is a second plan. Also out: one image
per page in bulk, PDF link annotations, a temporary file route, export
options for paper or ink alone, vector ink, an export that continues in
the background under the lease (which is for saves,
`Workspace.swift:240-254`), and every one of the ten deferred features.

## 6. Decisions

1. Ink raster scale. Recommendation: the flatten scale
   (`Renderer.swift:243`), the long edge at `maximumLongEdgePixels`, the
   constant the contract already calls asset resolution
   (`Docs/Contract.md:175-178`). Alternative: `Notebook.baseCompositeScale`,
   2x (`Notebook.swift:45`), what the screen shows at fit width, a third
   the pixels and soft ink when the PDF is zoomed.
2. The image is PNG. Recommendation as stated: lossless, and the type
   Photos, Files, and every mail client understand. Alternative: HEIC
   through the same `encode` at 0.9, a third the bytes and a format
   recipients off Apple platforms may not open.
3. Print is a button and a share row. Recommendation: the button, two
   lines, because it is what a person looks for; the share sheet's own
   Print row appears for a PDF item regardless. Alternative: the share
   row only.

## 7. Cross-plan

`README.md` in this directory. This plan assumes undo has landed as
merged at b84af06: `revision(of:)` returns the `PageRevision` of
`Modules/TNNotebook/PageState.swift:131-135` and prefers the
`pendingRestores` slot of `Notebook.swift:59`. It touches `Renderer.swift`,
`PDFSource.swift`, `Notebook.swift`, `EditorViewModel.swift`,
`EditorView.swift`, `project.yml`, the three test files named above, and
adds `ExportSheet.swift`. It does not touch `Seam.swift`,
`EditorBinding.swift`, `PageState.swift`, either canvas controller, or
`Workspace.swift`.

With `selection.md` and `loose-ends.md` it shares the `EditorView`
toolbar `HStack` (`EditorView.swift:82-97`), where this plan adds one
button at the end, and `EditorViewModel.swift`, where it adds one
`MARK: Export` section and changes no existing method. Both merges are
textual. If `selection.md` changes `Renderer.compose` or `draw(_ layer:)`,
the `drawPage` factoring is the seam it lands on, and whichever lands
second rebases inside it. If `loose-ends.md` wires `Notebook.flatten` to
a button, it calls `flattened(...as: "public.heic")` and nothing else
changes. Neither plan is assumed to have landed.

## 8. Review disposition

One simplicity review, answered on 2026-09-11. Every finding was
adopted; none was rejected.

Adopted: the PDF session on the actor, its two preconditions, its trap
test, `exportInkScale`, and the widening of `rasterize` are replaced by
one `Renderer.pdf(pageCount:page:)` with local state, because actors are
reentrant at every `await` and the stated reason for the session (a
stalled composite) was wrong; `Notebook.pdf`, `Notebook.image`,
`ExportOutcome`, and `ExportRefusal` are deleted and the notebook gains
`revision(of:)` alone, with progress, cancel, and the text-session
refusal on the view model where the imports already keep theirs; the
checker-token step is deleted as guarding nothing the plan uses;
`flattenedImage`, `pageImage`, and `png` collapse into `flattened(...as:)`;
five steps become two pull requests; the temp-file alternative is closed
by arithmetic and stated as the design; decisions 3, 5, 8, and 9 are
facts and moved into section 2 as one sentence each; `ExportRange` is a
`ClosedRange<Int>`; the offered custody rows and the list of unchanged
rules are struck; the archive and library-menu paragraphs are one
sentence; section 0's duplicate inventory is gone. Two citations fixed
(`Fixture.textLayer` at `FormatSupport.swift:94`; the permanent exclusion
of non-PencilKit ink is the deferral memo's, not `README.md`'s) and the
`flattened` caller claim made precise.
