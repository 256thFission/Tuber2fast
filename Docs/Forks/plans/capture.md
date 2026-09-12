# Capture: a camera photo and a document scan

A plan, not code. Branch `v2-mvp` (2a8fbf8). Every claim below cites the
file it was read from; paths are relative to that worktree.

**In short.** The back half of this is built, and it is the back half the
photo picker already uses. `Data` goes to `EditorViewModel.importImage`
(`Modules/TNEditor/EditorViewModel.swift:393`), then `Notebook.importImage`
(`Modules/TNNotebook/Notebook.swift:741`), which normalizes to upright HEIC
(`Modules/TNRender/Renderer.swift:431-444`), centres the image, writes the
asset, inserts the layer and records an undo entry. A camera photo is the
same `Data` from a different controller. The scan leg is VisionKit's own
scanner, whose pages become new pages with the scan as paper, through one
`Notebook.importScan` beside `importPDF`. The one thing that will kill the
app on the first tap is the missing `NSCameraUsageDescription`, which no
simulator test can catch, so it is in PR 1. Two pull requests, PR 1 first.

## 0. Where it stands today

**Everything from `Data` inwards is built and needs no change.** The
picker's bytes reach `importImage(_ data: Data)`
(`Modules/TNEditor/EditorViewModel.swift:393-399`), which refuses while a
text box is open, calls the notebook and drains.
`Notebook.importImage(_:on:)` (`Notebook.swift:741-753`) normalizes off the
main actor (`:742`), fits to 60% of the page and centres it (`:746-750`),
builds an `.image` layer (`:751`) and calls `addLayer` (`:729-737`), which
publishes the asset and then `insertLayer` (`:713-726`): insert at
`inkIndex`, mark edited, record the undo entry, bump the content version,
re-render (`:717-725`). Underneath, `ImageImport.normalize`
(`Modules/TNRender/Renderer.swift:431-444`) decodes with
`CGImageSourceCreateWithData` (`:432`), bakes in
`kCGImagePropertyOrientation` (`:436-438`, `upright` at `:446`) and
re-encodes HEIC at lossy quality 0.9 (`:441`). A camera photo gets undo, the
composite, the dirty mark and the layer file for free. So does the
new-page-with-a-photo half: `addPage(size:orientation:photo:)` (`:224-232`)
calls `notebook.storeImageAsset` (`Notebook.swift:793-801`) and appends
`.asset(.image(stored))`, and `appendPage` (`:441-473`) measures it through
`renderer.aspect(of:)` (`Renderer.swift:239`) and keeps the passed width:
"the rectangle is the asset's shape at the chosen width" (`:463-465`). A
scanned page's geometry needs no arithmetic of ours.

**`importPDF` is the shape a multi-page import already takes.**
`Notebook.importPDF` (`Notebook.swift:759-789`) writes the asset once,
threads a local `var after` (`:763`, advanced `:780`), inserts each page
into the index itself, then emits structure once (`:783`), emits content and
re-renders per created page (`:784-787`) and marks dirty once (`:788`).
`appendPage` cannot be looped in its place: every one ends in `insertPage`,
which emits structure, emits content, marks dirty and re-renders for each
page (`:494-498`), so ten pages would restate the whole page list to the
canvas ten times and kick ten composites.

**Nothing is half-built, and the surfaces are ready.** No file in the tree
names VisionKit, `AVCapture`, `NSCameraUsage`, `UIImagePickerController` or
`fullScreenCover` (grep over `Modules/`, `TuberNotesApp/`, both test
directories and `project.yml`); the only capture-adjacent import is
`import PhotosUI` at `TuberNotesApp/EditorView.swift:1`. `insertMenu`
(`:198-219`) already holds Photo, PDF and Link rows, each setting a `@State`
Bool from `:17-24` and each answered by a presentation modifier in `body` at
`:51-89`, so two rows join it and the toolbar (`:94-121`) is not
restructured. `CanvasHost` (`:280-286`) is the only
`UIViewControllerRepresentable` in the tree and has no `Coordinator`.

**No camera usage string.** There is no `Info.plist`; the app generates one
(`project.yml:220`) from the keys at `:203-219`, which declare
`NSPhotoLibraryAddUsageDescription` (`:219`) and nothing about the camera.
iOS terminates an app that presents a camera controller without
`NSCameraUsageDescription`, and no test here presents a view controller, so
CI cannot catch it. No framework entry is needed: "Swift autolinks an
imported system framework and the linker finds it in the SDK"
(`project.yml:70-71`, said there as the reason an absent link forbids
nothing, which is why SwiftUI is aliased away instead).

## 1. What GoodNotes does here, and what this plan matches

GoodNotes puts a camera photo on the current page as a movable object and
turns a multi-page scan into several pages, never a floating image, using
the system scanner whole; this plan matches both. Section 5 says what is
deliberately not matched, and why.

## 2. The data shape

Nothing durable is added. No layer kind, no field in any JSON file, no asset
format, no store method, no model type. A scanned page is an image asset and
a `PageRecord` whose paper is `.image(asset)`, which is what the
library-photo path already produces (`EditorViewModel.swift:224-232`). The
only new state is two `@State` Bools in `EditorView` beside `isPickingPhoto`
(`EditorView.swift:17-24`), owned by the view that presents the cover.

Two representables, one per controller, and not one shared: the delegate
protocols differ, the results differ, and the only shared part is four lines
of boilerplate. They are not symmetric either, and the asymmetry is the one
thing here an implementer cannot recover from alone, so both declarations
are exact and the two paragraphs after them say why.

```swift
// TuberNotesApp/DocumentScanner.swift
/// VisionKit's scanner, presented full screen. Nothing here configures it:
/// the edge detection, the perspective correction, the corner drag, the page
/// buffer and the retake are the system's. `updateUIViewController` is empty.
struct DocumentScanner: UIViewControllerRepresentable {
    /// One JPEG per scanned page, in scan order. Empty on cancel. The
    /// coordinator encodes page by page inside an `autoreleasepool`, so one
    /// 48 MB bitmap is live rather than all of them: handing the app
    /// `[UIImage]` needs every page decoded before the first is encoded.
    let onFinish: ([Data]) -> Void

    /// A scanner failure, or a page that would not encode. Both dismiss and
    /// both banner: the SDK header says twice, on the `delegate` property and
    /// on the protocol, that the app dismisses the document camera in every
    /// delegate callback. Without this a failed scan is a cover with no exit.
    let onFailure: (any Error) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController
    func makeCoordinator() -> Coordinator

    /// Both attributes are load-bearing; neither alone compiles. The failure
    /// selector is `didFailWithError:`. Both paragraphs below.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan)
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController)
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error)
    }
}
```

```swift
// TuberNotesApp/CameraCapture.swift
/// The system camera. `UIImagePickerController` is the only still-camera UI
/// UIKit ships, and building one over `AVCapturePhotoOutput` is a camera app
/// inside a notebook app.
struct CameraCapture: UIViewControllerRepresentable {
    /// The captured photo, or nil on cancel. Synchronous, so the handler
    /// wraps its `await` in `Task { }`, the pattern at `EditorView.swift:59`.
    /// Nobody owns that task's cancellation: a capture whose import is in
    /// flight when the view goes away runs to completion into a notebook that
    /// is still open. True of the existing photo leg, and not made worse.
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController
    func makeCoordinator() -> Coordinator

    /// Bare, and deliberately: the paragraph below.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any])
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController)
    }
}
```

**Why one coordinator is annotated twice and the other not at all.**
`UIImagePickerControllerDelegate` is declared `NS_SWIFT_UI_ACTOR`
(`UIKit.framework/Headers/UIImagePickerController.h:112-113`), so its
witnesses infer `@MainActor` and reach the view model with no annotation.
`VNDocumentCameraViewControllerDelegate` carries no such annotation and no
`SwiftAttributes` in VisionKit's apinotes, so its witnesses are nonisolated.
`UIViewControllerRepresentable` is `@preconcurrency @MainActor`
(`SwiftUI.swiftinterface:10546`) but a nested class does not inherit that.
Checked with `swiftc -typecheck -swift-version 6` against the iOS 26.5 SDK,
the scanner coordinator gives three different failures for three spellings:
bare, "call to main actor-isolated instance method in a synchronous
nonisolated context" where it touches `EditorViewModel`
(`EditorViewModel.swift:31`) or `Workspace` (`Workspace.swift:14`);
`@MainActor` alone, "conformance crosses into main actor-isolated code and
can cause data races"; `@preconcurrency` alone, "has no effect" with the
first error still standing, and that warning is itself a build failure
(`project.yml:22-23`, Swift 6 with warnings as errors). Only both together
compile. On the camera coordinator, `@preconcurrency` is the one that warns.

**The failure selector is `didFailWithError:`, and must not be "corrected".**
VisionKit's apinotes does carry a `documentCameraViewController(_:didFailWith:)`
rename, but under `Classes: - Name: VNDocumentCameraViewController`, so it
renames a method on the class, which declares none, and leaves the protocol
requirement alone. `#selector` resolves
`VNDocumentCameraViewControllerDelegate.documentCameraViewController(_:didFailWithError:)`
and rejects `didFailWith:`. Writing `didFailWith:` buys a method that is
never called plus a "nearly matches optional requirement" warning this build
treats as an error. Every method in the protocol is optional, so a wrong
spelling is otherwise silent.

One method on the notebook and one on the view model. The camera photo needs
neither: it is `editor.importImage(data)`, the call already at
`EditorView.swift:252`.

```swift
// Modules/TNNotebook/Notebook.swift
extension Notebook {
    /// One new page per scanned page, after the current page and in scan
    /// order, each keeping the current page's width and taking the scan's
    /// aspect the way `appendPage` measures asset paper (`:462-465`).
    ///
    /// Here rather than in `TNEditor` because page order is the notebook's
    /// ("Page order, paper, geometry | `Notebook` | `NotebookIndex`",
    /// `Docs/Contract.md:44`), and in `importPDF`'s shape (`:759-789`): one
    /// `emitStructure` and one `markDirty` for the run, not the per-page
    /// storm N calls to `appendPage` would kick (`:494-498`).
    ///
    /// `after` is threaded locally (`:763`) and re-checked against
    /// `index.pageIDs` after every await, which `importPDF` need not do: its
    /// loop body has no await (`:765-781`) and this one suspends twice per
    /// page, at `storeImageAsset` (`:793`) and at `renderer.aspect` (`:462`).
    /// If the page `after` names is deleted across a suspension, `insertPage`
    /// answers with `pages.append` (`:481-485`), a default where
    /// `Docs/Contract.md:9-12` forbids one, so the run stops instead.
    ///
    /// A page that cannot be stored or measured, or an `after` that is gone,
    /// stops the run, and what was made is emitted and marked dirty before
    /// the error is thrown. `importPDF` does not do that: `:768` throws
    /// straight past `:783-788`, leaving pages in the index the canvas was
    /// never told about and no save scheduled. That is its defect, not a
    /// precedent, and fixing it is not this plan's.
    package func importScan(_ images: [Data]) async throws(FormatFault) -> [PageID]
}

// Modules/TNEditor/EditorViewModel.swift
extension EditorViewModel {
    /// The seven lines `importPDF` already is (`:414-420`) over
    /// `notebook.importScan`, plus one `scroll(to:)` of the first page made.
    /// One error type, one method-scope `do`/`catch` for the reason the
    /// comment at `:387-391` gives, one drain.
    package func importScan(_ images: [Data]) async
}
```

The loop threads `after` itself rather than calling
`addPage(size:orientation:photo:)` N times, because `append` passes
`notebook.currentPageID` unconditionally (`EditorViewModel.swift:267`) and
`currentPageID` moves only at open (`Notebook.swift:86-88`), on a canvas
report (`:407`) and on a page delete (`:519`). Every existing caller adds
exactly one page, for which "after the current page" is right, so there is
nothing defective in `append` and nothing to fix there. On a device the
naive loop would not merely land the scan backwards: the canvas can report a
page turn between iterations, so the order would be nondeterministic.

**Undo.** The camera photo records an entry, because `insertLayer` does
(`Notebook.swift:721`). The scan records none, because appending a page
records none: `insertPage` (`:478-500`) never calls `recordEdit`, and
neither Add Page nor Import PDF is undoable today. Making page structure
undoable is a change to the Contract's Undo section and its own work.

## 3. The steps

Two pull requests, PR 1 first and not in either order: it carries
`INFOPLIST_KEY_NSCameraUsageDescription`,
`VNDocumentCameraViewController` opens the camera, and PR 2 alone would
terminate the app on an iPad while CI stayed green.

**PR 1. The camera photo, and the usage description.**

`project.yml`: one key beside the Photos one at `:219`,
`INFOPLIST_KEY_NSCameraUsageDescription`, with the same shape of justifying
comment that key carries at `:216-218`. Proposed string: "Takes a photo or
scans a document straight into your notes." It covers both legs, so PR 2
adds nothing here. Then `xcodegen generate`.

`TuberNotesApp/CameraCapture.swift`: new, the declaration in section 2.

`TuberNotesApp/EditorView.swift`: `@State private var isTakingPhoto` in the
block at `:17-24`; a "Take Photo" row with `systemImage: "camera"` in
`insertMenu` (`:198-219`) above the existing Photo row, present only when
`UIImagePickerController.isSourceTypeAvailable(.camera)`, absent rather than
disabled where there is no camera, because `.camera` traps there and a
disabled row invites the question why; a
`.fullScreenCover(isPresented: $isTakingPhoto)` beside the presentations at
`:51-89`, not a `.sheet`, because on iPad a sheet is a centred card and a
camera preview letterboxed inside one is wrong; and a
`capture(_ image: UIImage?)` beside `importPhoto` (`:243-261`) that clears
the flag, turns the image into `Data` and runs
`Task { await editor.importImage(data) }`. An image that yields no data
reports through `workspace.banner`, the channel `importPhoto` uses at
`:247`. The encode is one line and a real cost, priced in section 6:
`image.jpegData(compressionQuality: 1)`, which `ImageImport.normalize` then
decodes and re-encodes as HEIC at 0.9 (`Renderer.swift:441`).

Tests: none reach any of this, which is a fact about the repo, not a choice.
No file in `TNTests/` or `TuberNotesTests/` imports the app target (grep for
`import TuberNotes` returns nothing), `TNTests` has no app dependency at all
(`project.yml:256-274`), and `TuberNotesTests`, though hosted by the app
(`:229`), imports only modules. What CI covers is the source scanner: both
new app files are enumerated automatically
(`ContractStructureTests.swift:494-505`) and trip nothing, VisionKit and
PhotosUI being outside the scanned set (`:224`), UIKit permitted to the app
(`:722`), and neither file naming a file-I/O token (`:285-312`). No table
changes and no allowlist entry is added. One gate needs no device, run after
`xcodegen generate` and a simulator build, since the same mechanism already
carries `NSPhotoLibraryAddUsageDescription` into the bundle:

```
plutil -p "<DerivedData>/Build/Products/Debug-iphonesimulator/TuberNotes.app/Info.plist" | grep NSCamera
```

Verification: this PR touches no module on the device list, but a camera
does not exist in a simulator either. On an iPad it records: the first tap
on Take Photo shows the permission prompt with the string above and the app
does not terminate; denied, the row still does not crash; allowed, the
camera fills the screen and a photo taken and confirmed lands centred on the
page; undo removes it and redo brings it back; the app backgrounded
mid-capture returns with the page intact; the row is absent in the
simulator. Any line not done goes to `Docs/Unproven.md`
(`CONTRIBUTING.md:124-125`).

**PR 2. The document scan.**

`TuberNotesApp/DocumentScanner.swift`: new, the declaration in section 2.
`Modules/TNNotebook/Notebook.swift`: `importScan(_:)` as declared, beside
`importPDF`. `Modules/TNEditor/EditorViewModel.swift`: `importScan(_:)` as
declared, in a new `// MARK: Capture` section after Content (`:385-441`). No
existing method in either file changes. `TuberNotesApp/EditorView.swift`:
`@State private var isScanning`; a "Scan Document" row with
`systemImage: "doc.viewfinder"` in `insertMenu`, present only when
`VNDocumentCameraViewController.isSupported`; a
`.fullScreenCover(isPresented: $isScanning)` carrying `DocumentScanner`,
which expects to own the screen and whose corner-drag affordances are
cramped inside a card; a `scanned(_ pages: [Data])` that clears the flag and
runs `Task { await editor.importScan(pages) }`, an empty array being a
cancel that does nothing; and a `scanFailed(_ error: any Error)` that clears
the flag and sets `workspace.banner`, where both a scanner failure and a
page that would not encode arrive. This is not the chained-sheet hazard the
comment at `:48-50` warns about: both rows open from a `Menu`, which is not
a presentation, so nothing is dismissed in the frame the cover appears in.

A scan becomes N pages rather than N image layers on one page because that
is what GoodNotes does, because `appendPage` already measures an asset's
aspect (`Notebook.swift:463-465`) and `importPDF` already establishes one
new page per source page, and because a scan is a document, not a picture on
one. Its price, said plainly: a scanned page's image is paper, and paper
cannot be selected, moved, resized, rotated or deleted ("a tap on paper
clears", `selection.md:356`), so removing one means deleting the page. The
reader is left on the first page made, so a scan reads from its beginning,
rather than on the last where Add Page leaves it
(`EditorViewModel.swift:272`).

Tests, `TNTests/EditorViewModelTests.swift`, over `loaded(_:)` (`:230-242`)
and `Fixture.imageData(width:height:)` (`TNTests/FormatSupport.swift:64-76`),
in the shape of `photoBecomesThePaper` (`:244-264`):

- three images of aspects 200x100, 100x200 and 300x300 append three pages
  after the current one and in that order, geometries 612x306, 612x1224 and
  612x612 in sequence.
- each new page's paper is `.image`, its asset reads back non-empty
  (`notebook.store.readAsset`, the assertion at `:284`), and
  `lastContentError` is nil.
- with a two-page notebook on page 1, the order is page 1, the three scans,
  page 2: after the current page, not before it and not at the end.
- one undecodable `Data` in the middle sets `lastContentError`, leaves the
  page made before it and makes nothing after it, and that page reaches
  `setPages` with the notebook dirty, the half `importPDF` drops.
- an empty array makes no page, sets no error, and issues no `scroll`.
- the surface sees `setPages` containing the first created page before
  `scroll(to:)` of it, the ordering assertion at `:293-295`, and `canUndo`
  is unchanged across the run, the stated non-undoability.

No test can reach the usage description, either coordinator, the delegate
selector, the presentation style or the `UIImage` to `Data` map, so the
device list carries them. This PR changes `Notebook.swift` and
`EditorViewModel.swift`, so it is on the definition of done's device list
(`AGENTS.md`, Definition of done), though not on `CONTRIBUTING.md`'s
narrower file list (`:104-113`), which names `EditorBinding.swift` and not
the view model. On an iPad it records: the scanner presents, fills the
screen and detects an edge; a three-page scan makes three pages in the order
scanned, each filling its page with no stretch; the reader lands on the
first; a cancel makes nothing; a scan forced to fail, by covering the lens
mid-capture or revoking camera access while the scanner is open, closes the
cover and shows a banner; a page that yields no encodable data does the
same, with what happened to the pages already made recorded; a one-page scan
of dense text is legible at fit width and at full zoom, with the HEIC's byte
count recorded beside the source image's pixel size, the measurement section
6 turns on; the notebook saves clean and reopens intact.

## 4. Contract

**No rule changes, and nothing here is a `CONTRACT:` commit.** Nothing
touches a file: `VNDocumentCameraScan.imageOfPage(at:)` and
`UIImagePickerController`'s info dictionary both hand back a `UIImage` in
memory, as `PHPickerViewController` hands back `Data`, so "File I/O happens
in `PosixFileSystem`, `LibraryStore`, and `ImportReader`, and nowhere else"
(`Docs/Contract.md:377-378`) is untouched, none of the tokens at
`ContractStructureTests.swift:285-312` appears, and the existing photo leg
is the proof, since `EditorView.swift:243-261` is not in the allowlist at
`:814-830`. "UIKit is imported only by `TNCanvas`, `TNEditor`, and the app"
(`Docs/Contract.md:380-381`): both new files are in the app target
(`project.yml:188-189`), whose row already permits UIKit
(`ContractStructureTests.swift:722`), and VisionKit is not scanned (`:224`).
"Asset paper comes from three places, and each is an asset import followed
by a paper change on an empty page: a photo, a page of a PDF, or a flattened
page" (`Docs/Contract.md:175-178`): a scanned page is a photo, the sentence
naming the kind of asset and not where the bytes came from, and the path is
`storeImageAsset` plus an insert, the two things
`addPage(size:orientation:photo:)` already does
(`EditorViewModel.swift:226-231`). "Layer kinds are `image`, `pdf`, `link`,
`text`, and nothing else" (`:143`) is untouched: a camera photo is an
`image` layer, and ink stays above it because ink is not a layer and sits at
`inkIndex` (`:147-152`). Putting the scan loop in `Notebook` rather than in
the view model is what Custody asks for (`:44`), so this design agrees with
the rules more closely than the first draft did.

## 5. Out of scope

A scan or a photo that becomes a new notebook in the library, which is a
library operation and belongs to whatever surface `organisation.md` builds.
OCR on a scan, which is handwriting recognition and search over it, both on
the 2026-09-11 deferral list, however free VisionKit makes it. Replacing an
existing image layer by retaking it, deferred. Cropping or rotating an image
after a camera photo lands, which is object editing and reachable through
`selection.md`'s frame; before it lands VisionKit already draws the
rectangle, so this plan ships no cropping UI and
`UIImagePickerController.allowsEditing` stays false, its editor being a
square crop that a photo of a page is not. A destination picker before
capture of the kind GoodNotes offers, which puts a second sheet in front of
the scanner for one choice this plan makes for the user. A "Take Photo" row
in the Add Page sheet beside `NewPagePaperChoice.photo`
(`PageSetupSheet.swift:228`, offered at `:272`). Notability's Convert to
Ink, its caption and text-wrap sheet, and GoodNotes' Elements collections.
Filters, reordering pages inside a scan before it commits, and multi-page
capture into layers on one page. And every one of the ten deferred features.

## 6. Decisions

1. **The double encode, and its price.** Both controllers hand back
   `UIImage` and `ImageImport.normalize` takes `Data` (`Renderer.swift:431`),
   so the app encodes and `normalize` immediately decodes and re-encodes to
   HEIC. Recommendation: `jpegData(compressionQuality: 1)`, roughly 5 to
   7 MB and under a tenth of a second for a 12 MP rectified page, against
   `pngData()`'s 8 to 14 MB and several hundred milliseconds of Deflate over
   twelve million pixels; at quality 1 the quantization is near-flat, so the
   loss sits far below the HEIC-at-0.9 generation (`:441`) every photo
   import already takes. The real peak is the bitmap, not the JPEG: 3024x4032
   is 48.8 MB, which is why the coordinator encodes inside a per-page
   `autoreleasepool` and hands back `[Data]`, holding one bitmap rather than
   ten beside the notebook, the canvases and N fresh composites. The store
   side needs nothing: HEIC at 0.9 lands one to two megabytes, far under the
   64 MB guard (`Modules/TNFormat/PackageStore.swift:426`), and `normalize`
   decodes one image at a time with `kCGImageSourceShouldCache: false`
   (`Renderer.swift:433`). If PR 2's iPad check shows fringing on text, a
   `CGImage` entry point into `TNRender` is the answer; not before it.

## 7. Cross-plan

`README.md` in this directory. This plan assumes the merge at 2a8fbf8: undo
landed, so `insertLayer` records (`Notebook.swift:721`); export landed, so
the toolbar carries an Export button (`EditorView.swift:105-108`) and
`ExportSheet.swift:164-176` is the precedent for presenting a UIKit
controller imperatively. It touches `EditorView.swift`,
`EditorViewModel.swift`, `Notebook.swift`, `project.yml` and
`TNTests/EditorViewModelTests.swift`, and adds two app files. It does not
touch `Seam.swift`, `EditorBinding.swift`, `PageState.swift`,
`Renderer.swift`, either canvas controller, `Workspace.swift`, or any table
in `ContractStructureTests.swift`.

With `organisation.md`, the wave-4 sibling, it shares two files and no
function. In `EditorView.swift` this plan adds two rows inside `insertMenu`
(`:198-219`) and two `@State` Bools at `:17-24`; a bookmark control in the
toolbar `HStack` (`:94-121`) or a mode switch in `PageNavigatorSheet` merges
textually against them. In `EditorViewModel.swift` it adds one
`// MARK: Capture` section and changes no existing method, so a bookmark
mirror or an outline list beside `navigatorPages` (`:66`) merges textually
too. The one thing to watch is page order: a scan appends N pages
mid-notebook, so an outline or a bookmark set keyed to page position shifts
under it, and both should key on `PageID`. Neither plan is assumed to have
landed, and neither blocks the other.

## 8. Review disposition

Three reviews were answered on 2026-09-12: two against the simplicity brief
on different models, one adversarial, which read the iOS 26.5 SDK headers
and apinotes. Ten of eleven findings were adopted. The largest is
structural: `EditorViewModel.addPages(scanned:)`, which called `appendPage`
N times, is gone, replaced by `Notebook.importScan(_:)` beside `importPDF`,
the view model reduced to `importPDF`'s seven lines plus a scroll. Two
reviewers reached that independently from different directions, one from
Custody's "page order is the notebook's" and line count, one from the
per-page report storm `insertPage` would kick; it deleted the two error
types, the two `do`/`catch` blocks per image, the `Self.fault` mapping, the
`after:` threading in `TNEditor` and the `currentPageSize` round trip. With
it went the claim that a failed run may cite `importPDF`, whose `:768`
throws straight past the emit and the `markDirty`; the plan now states the
requirement, names that as `importPDF`'s defect, and tests it. Also adopted:
the scanner hands back `[Data]` encoded inside a per-page `autoreleasepool`
instead of `[UIImage]`, which had forced every 48.8 MB bitmap live at once;
`after` is re-checked after each suspension, since `insertPage`'s silent
`pages.append` is a default the Contract forbids; `onFailure` gained the
destination it lacked, a `scanFailed` handler that dismisses and banners,
because the SDK requires the app to dismiss in every callback; both
presentations became `.fullScreenCover`; the synchronous `onFinish` against
an `async` handler is a `Task`, with nobody owning its cancellation said
plainly; `append` is no longer called defective, since all four existing
callers add one page; and the unstated price of pages-not-layers, that a
scanned page is paper and cannot be selected or deleted, is written down.
Some hundred and eighty lines came out under the prose finding: decision 1
was section 2's paragraph said twice, decision 3 lost its four-function
`CGImage` sketch, decisions 2, 4 and 5 became one sentence each inside the
steps, section 1 became two sentences and a pointer, and section 4's three
sub-headings and its temporary-file paragraph became one paragraph.

Rejected: one, the delegate-selector rename. The adversarial pass read
VisionKit's apinotes correctly and drew the wrong conclusion: the
`documentCameraViewController(_:didFailWith:)` entry sits under
`Classes: - Name: VNDocumentCameraViewController`, so it renames a method on
the class, which declares none, and leaves the protocol requirement alone.
Checked with `swiftc -typecheck -swift-version 6` against the iOS 26.5
simulator SDK: `#selector` resolves `didFailWithError:` and rejects
`didFailWith:`, and writing the latter buys a method never called plus a
"nearly matches optional requirement" warning this build turns into an
error. The original spelling stands and section 2 says why, so nobody
corrects it back. The same check amended the fix that was adopted: the
prescribed `@preconcurrency` conformance does not compile without
`@MainActor` in front of the class, and section 2 now carries both
attributes and the three diagnostics the three wrong spellings produce.
Five citations were corrected (`Docs/Contract.md:175-178`, `:380-381`,
`:147-152`, `project.yml:229`, and `PageState.swift:148-152`, which is
`HistoryEntry` and not a recording call, replaced by `Notebook.swift:721`);
five more of the review's citation fixes named things this draft already had
right or never said, and four of the review's own citations were off by a
line and are corrected here (`EditorViewModel.swift:414-420`,
`project.yml:22-23`, `Notebook.swift:759-789`, `FormatSupport.swift:64-76`).
