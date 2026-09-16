import PhotosUI
import SwiftUI
import TNEditor
import TNFormat
import TNModel
import TNNotebook
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// One open notebook: the intentions across the top, the canvas below, and
/// the save refusal in between. Nothing here reads the notebook; the view
/// model is the only thing that does.
struct EditorView: View {
    @Environment(Workspace.self) private var workspace
    let editor: EditorViewModel

    @State private var isPickingPhoto = false
    @State private var isTakingPhoto = false
    @State private var isScanning = false
    @State private var photoDestination = PhotoDestination.layerOnCurrentPage
    @State private var photoItem: PhotosPickerItem?
    @State private var isPickingPDF = false
    @State private var isPickingLinkTarget = false
    @State private var isPickingSticker = false
    @State private var isConfirmingPageDelete = false
    @State private var isAddingPage = false
    @State private var pendingPage: (choice: NewPagePaperChoice, size: PageSize, orientation: PageOrientation)?

    /// What the picked photo is for. The picker serves two destinations, and
    /// a second Bool beside `isPickingPhoto` could claim both at once.
    private enum PhotoDestination {
        case layerOnCurrentPage
        case paperForCurrentPage
        case paperForNewPage(PageSize, PageOrientation)
    }
    @State private var isShowingNavigator = false
    @State private var isExporting = false
    @State private var bookmarkTarget: NavigatorPage?
    @State private var bookmarkTitle = ""
    @State private var isInserting = false

    var body: some View {
        CanvasHost(controller: editor.canvasHost)
            // The bar parks inside the slack the band leaves, not under it.
            .overlay { WritingBar(editor: editor).padding(.top, MacaronBand.slack) }
            .coordinateSpace(.named("editor"))
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    MacaronBand(editor: editor, action: take)
                    if let failure = editor.lastSaveError {
                        RefusalBar(message: Self.message(for: failure))
                    } else if let fault = editor.lastContentError {
                        // An import or a layer that the page refused: without
                        // this it would be a tap that quietly did nothing.
                        RefusalBar(message: "That couldn't be added: \(fault.description)")
                    }
                }
            }
            .confirmationDialog("Insert", isPresented: $isInserting, titleVisibility: .visible) {
                Button("Photo") {
                    photoDestination = .layerOnCurrentPage
                    isPickingPhoto = true
                }
                if VNDocumentCameraViewController.isSupported {
                    Button("Scan Document") { isScanning = true }
                }
                Button("PDF") { isPickingPDF = true }
                Button("Sticker") { isPickingSticker = true }
                Button("Link") { isPickingLinkTarget = true }
                Button("Add page") { isAddingPage = true }
                Button("Pages") { isShowingNavigator = true }
                Button("Delete page", role: .destructive) { isConfirmingPageDelete = true }
                Button("Cancel", role: .cancel) {}
            }
        // The choice is acted on after the sheet is gone: the photo leg
        // presents a second sheet, and two presentations in one frame do not
        // both survive.
        .sheet(isPresented: $isAddingPage, onDismiss: addPendingPage) {
            AddPageSheet(editor: editor) { choice, size, orientation in
                pendingPage = (choice, size, orientation)
            }
        }
        .photosPicker(isPresented: $isPickingPhoto, selection: $photoItem, matching: .images)
        // A cover, not a sheet: on iPad a sheet is a centred card, and a camera
        // preview letterboxed inside one is wrong. Opening it from a `Menu` is
        // not the chained-presentation hazard the comment above warns about —
        // a menu is not a presentation, so nothing is dismissed in the frame
        // the cover appears in.
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraCapture(onFinish: capture)
                .ignoresSafeArea()
        }
        // A cover for the same reason, and one more: the scanner expects to
        // own the screen, and its corner-drag affordances are cramped inside a
        // card.
        .fullScreenCover(isPresented: $isScanning) {
            DocumentScanner(onFinish: scanned, onFailure: scanFailed)
                .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .fileImporter(isPresented: $isPickingPDF, allowedContentTypes: [.pdf]) { result in
            Task { await importPDF(result) }
        }
        .sheet(isPresented: $isPickingLinkTarget) {
            LinkTargetPicker(workspace: workspace, editor: editor)
        }
        .sheet(isPresented: $isPickingSticker) {
            StickerSheet(editor: editor)
        }
        // A sheet, not a full-screen cover: the canvas stays laid out under
        // it, so a tap in the grid can scroll to the page.
        .sheet(isPresented: $isShowingNavigator) {
            PageNavigatorSheet(editor: editor)
        }
        .sheet(isPresented: $isExporting) {
            ExportSheet(editor: editor, name: workspace.activeTab?.name ?? "Notebook") {
                // iPad print has no unanchored presentation; the canvas is
                // what is underneath the sheet.
                guard let view = editor.canvasHost.viewIfLoaded else { return nil }
                return (view.bounds, view)
            }
        }
        .confirmationDialog(
            "Delete this page?",
            isPresented: $isConfirmingPageDelete,
            titleVisibility: .visible
        ) {
            Button("Delete page", role: .destructive) { editor.deleteCurrentPage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The page and everything on it are removed.")
        }
        .bookmarkAlert(editor: editor, page: $bookmarkTarget, title: $bookmarkTitle)
    }

    private func take(_ action: BandAction) {
        switch action {
        case .lasso: editor.selectLasso()
        case .text: editor.selectText()
        case .insert: isInserting = true
        case .export: isExporting = true
        case .seat: workspace.isSeatOpen.toggle()
        }
    }

    /// The page the reader is on, as the navigator sees it. Nil only if the
    /// mirrors have not caught up with an empty notebook, which cannot
    /// happen: a notebook always has a page.
    private var currentPage: NavigatorPage? {
        let pages = editor.navigatorPages
        guard editor.currentPageIndex >= 0, editor.currentPageIndex < pages.count else { return nil }
        return pages[editor.currentPageIndex]
    }

    // MARK: Pages

    private func addPendingPage() {
        guard let pending = pendingPage else { return }
        pendingPage = nil
        switch pending.choice {
        case .sameAsThisPage:
            Task { await editor.addPage(size: pending.size, orientation: pending.orientation) }
        case .drawn(let paper):
            Task { await editor.addPage(size: pending.size, orientation: pending.orientation, paper: paper) }
        case .from(let page):
            Task { await editor.addPage(size: pending.size, orientation: pending.orientation, paperFrom: page) }
        case .photo:
            photoDestination = .paperForNewPage(pending.size, pending.orientation)
            isPickingPhoto = true
        case .flattened:
            Task { await editor.addPageFlatteningCurrentPage(size: pending.size, orientation: pending.orientation) }
        }
    }

    // MARK: Imports

    private func importPhoto(_ item: PhotosPickerItem) async {
        photoItem = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                workspace.banner = "That photo couldn't be read."
                return
            }
            switch photoDestination {
            case .layerOnCurrentPage:
                await editor.importImage(data)
            case .paperForCurrentPage:
                await editor.setPaper(photo: data)
            case .paperForNewPage(let size, let orientation):
                await editor.addPage(size: size, orientation: orientation, photo: data)
            }
        } catch {
            workspace.banner = "That photo couldn't be read: \(error.localizedDescription)"
        }
    }

    /// A camera photo, onto the current page as a layer: the same bytes the
    /// picker hands `importImage`, from a different controller.
    ///
    /// The JPEG is at quality 1 and is immediately decoded and re-encoded as
    /// HEIC by `ImageImport.normalize`. Quality 1 is chosen against `pngData()`
    /// — several hundred milliseconds of Deflate over twelve million pixels,
    /// for eight to fourteen megabytes — and its near-flat quantization sits
    /// far below the HEIC-at-0.9 generation every photo import already takes.
    private func capture(_ image: UIImage?) {
        isTakingPhoto = false
        guard let image else { return }
        guard let data = image.jpegData(compressionQuality: 1) else {
            workspace.banner = "That photo couldn't be read."
            return
        }
        Task { await editor.importImage(data) }
    }

    /// A scan, as pages. An empty array is a cancel, which `importScan`
    /// answers by doing nothing, so there is no second test of it here.
    private func scanned(_ pages: [Data]) {
        isScanning = false
        Task { await editor.importScan(pages) }
    }

    /// Both ways a scan can fail arrive here: the scanner's own error, and a
    /// page that would not encode. The cover closes either way, because the
    /// scanner will not close itself.
    private func scanFailed(_ error: any Error) {
        isScanning = false
        workspace.banner = "That scan couldn't be read: \(error.localizedDescription)"
    }

    private func importPDF(_ result: Result<URL, any Error>) async {
        switch result {
        case .success(let url):
            do {
                await editor.importPDF(try ImportReader.read(url: url))
            } catch {
                workspace.banner = "That PDF couldn't be read: \(error.localizedDescription)"
            }
        case .failure(let error):
            workspace.banner = "That PDF couldn't be read: \(error.localizedDescription)"
        }
    }
}

/// The canvas runtime's own view controller, handed to SwiftUI and never
/// reconfigured by it: the app cannot name `TNCanvas`, and a SwiftUI update
/// has no business inside a frame path.
struct CanvasHost: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController { controller }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// A save that did not fully land, or content the page refused, in the words
/// Part 7 gives each reason.
private struct RefusalBar: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.red)
    }
}

extension EditorView {
    fileprivate static func message(for failure: SaveFailure) -> String {
        switch failure {
        case .insufficientSpace:
            "Not enough space to save. Your pages are still here; free some space and they'll save."
        case .io(let fault):
            "Couldn't save: \(fault.description). Retrying."
        case .pagesRefused(let pages):
            "\(pages.count) page\(pages.count == 1 ? "" : "s") couldn't be saved. Retrying."
        case .indexWithheld:
            "Saving isn't finished yet. Retrying."
        }
    }
}
