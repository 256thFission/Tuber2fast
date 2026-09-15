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

    var body: some View {
        GeometryReader { geo in
            clusterLayout(viewport: geo.size)
                .coordinateSpace(name: "editor")
                .onAppear {
                    viewportSize = geo.size
                    publishBandActions()
                    resolvePlacement(viewport: geo.size)
                    if ProcessInfo.processInfo.arguments.contains("-MacaronShowNavigator") { isShowingNavigator = true }
                    if let forced = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-MacaronCluster=") }) {
                        switch forced.dropFirst("-MacaronCluster=".count) {
                        case "leading": placement = .snapped(.leading)
                        case "trailing": placement = .snapped(.trailing)
                        case "top": placement = .snapped(.top)
                        case "bottom": placement = .snapped(.bottom)
                        default: placement = .floating(fx: 0.5, fy: 0.45)
                        }
                    }
                }
                .onChange(of: geo.size) { _, size in
                    let turned = (size.width > size.height) != (viewportSize.width > viewportSize.height)
                    viewportSize = size
                    if turned { resolvePlacement(viewport: size) }
                }
        }
        .overlay(alignment: .top) {
            if let failure = editor.lastSaveError {
                RefusalBar(message: Self.message(for: failure))
            } else if let fault = editor.lastContentError {
                RefusalBar(message: "That couldn't be added: \(fault.description)")
            }
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

    /// The page the reader is on, as the navigator sees it. Nil only if the
    /// mirrors have not caught up with an empty notebook, which cannot
    /// happen: a notebook always has a page.
    private var currentPage: NavigatorPage? {
        let pages = editor.navigatorPages
        guard editor.currentPageIndex >= 0, editor.currentPageIndex < pages.count else { return nil }
        return pages[editor.currentPageIndex]
    }

    // MARK: The cluster

    @State private var placement: ClusterPlacement = .snapped(.leading)
    @State private var dragPoint: CGPoint?
    @State private var viewportSize: CGSize = .zero

    private var currentGeometry: PageGeometry {
        currentPage?.geometry ?? PageGeometry.letter
    }

    private func resolvePlacement(viewport: CGSize) {
        let landscape = viewport.width > viewport.height
        placement = ClusterPlacement.load(landscape: landscape)
            ?? ClusterPlacement.proposed(page: currentGeometry, viewport: viewport)
    }

    @ViewBuilder
    private func clusterLayout(viewport: CGSize) -> some View {
        let canvas = CanvasHost(controller: editor.canvasHost)
        if let dragPoint {
            // Floating while dragged: the viewport never changes under a drag.
            ZStack {
                canvas
                cluster(vertical: true, chip: ClusterMetrics.smallChip, floating: true)
                    .position(x: dragPoint.x, y: dragPoint.y + clusterLength(chip: ClusterMetrics.smallChip) / 2 - 12)
            }
        } else {
            switch placement {
            case .floating(let fx, let fy):
                ZStack {
                    canvas
                    cluster(vertical: true, chip: ClusterMetrics.smallChip, floating: true)
                        .position(x: fx * viewport.width, y: fy * viewport.height)
                }
            case .snapped(let edge):
                let ribbon = ClusterMetrics.slack(on: edge, page: currentGeometry, viewport: viewport) < ClusterMetrics.thickness
                let chip = ribbon ? ClusterMetrics.smallChip : ClusterMetrics.chip
                let snapped = cluster(vertical: edge.isVertical, chip: chip, floating: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                switch edge {
                case .leading: HStack(spacing: 0) { snapped.frame(width: chip + 14); canvas }
                case .trailing: HStack(spacing: 0) { canvas; snapped.frame(width: chip + 14) }
                case .top: VStack(spacing: 0) { snapped.frame(height: chip + 14); canvas }
                case .bottom: VStack(spacing: 0) { canvas; snapped.frame(height: chip + 14) }
                }
            }
        }
    }

    private func clusterLength(chip: CGFloat) -> CGFloat { 24 + 7 * (chip + 8) + 3 + 16 }

    private func cluster(vertical: Bool, chip: CGFloat, floating: Bool) -> some View {
        ClusterView(editor: editor, vertical: vertical, chip: chip, floating: floating) { value in
            dragPoint = value.location
        } onDragEnded: { value in
            dragPoint = nil
            settle(predicted: value.predictedEndLocation, end: value.location)
        }
    }

    /// Within snapDistance of an edge, or flicked toward one, snaps; anywhere
    /// else floats, stored as fractions of the viewport.
    private func settle(predicted: CGPoint, end: CGPoint) {
        let viewport = viewportSize
        guard viewport.width > 0, viewport.height > 0 else { return }
        let distances: [(ClusterEdge, CGFloat)] = [
            (.leading, predicted.x), (.trailing, viewport.width - predicted.x),
            (.top, predicted.y), (.bottom, viewport.height - predicted.y),
        ]
        let nearest = distances.min { $0.1 < $1.1 }!
        if nearest.1 < ClusterMetrics.snapDistance {
            placement = .snapped(nearest.0)
        } else {
            placement = .floating(
                fx: min(max(end.x / viewport.width, 0.05), 0.95),
                fy: min(max((end.y + clusterLength(chip: ClusterMetrics.smallChip) / 2 - 12) / viewport.height, 0.1), 0.9)
            )
        }
        placement.save(landscape: viewport.width > viewport.height)
    }

    /// The whole chip is a menu; "Go to page" heads it and opens the navigator.
    private var pageReadout: some View {
        Menu {
            Button { isShowingNavigator = true } label: { Label("Go to page\u{2026}", systemImage: "rectangle.grid.2x2") }
            Divider()
            Button { isAddingPage = true } label: { Label("Add page", systemImage: "plus.rectangle.portrait") }
            Button {
                guard let page = currentPage else { return }
                bookmarkTitle = page.bookmark ?? ""
                bookmarkTarget = page
            } label: {
                Label(
                    currentPage?.bookmark == nil ? "Bookmark page" : "Edit bookmark",
                    systemImage: currentPage?.bookmark == nil ? "bookmark" : "bookmark.fill"
                )
            }
            paperMenu
            Button(role: .destructive) { isConfirmingPageDelete = true } label: { Label("Delete page", systemImage: "trash") }
        } label: {
            HStack(spacing: 6) {
                Text("Page \(editor.currentPageIndex + 1) of \(editor.pageCount)")
                    .font(Macaron.display(14).monospacedDigit())
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .black))
            }
            .padding(.horizontal, 6)
        }
    }

    /// Insert and Export live in the workspace band; the band reaches the
    /// state here through these closures on the workspace.
    private func publishBandActions() {
        var rows: [MacaronBandActions.Row] = []
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            rows.append(.init(label: "Take Photo", symbol: "camera") { isTakingPhoto = true })
        }
        rows.append(.init(label: "Photo", symbol: "photo") { photoDestination = .layerOnCurrentPage; isPickingPhoto = true })
        if VNDocumentCameraViewController.isSupported {
            rows.append(.init(label: "Scan Document", symbol: "doc.viewfinder") { isScanning = true })
        }
        rows.append(.init(label: "PDF", symbol: "doc") { isPickingPDF = true })
        rows.append(.init(label: "Sticker", symbol: "seal") { isPickingSticker = true })
        rows.append(.init(label: "Link", symbol: "link") { isPickingLinkTarget = true })
        workspace.bandActions = MacaronBandActions(insert: rows, export: { isExporting = true }, readout: { AnyView(pageReadout) })
    }

    private var paperMenu: some View {
        Menu {
            ForEach(DrawnPaper.allCases, id: \.self) { paper in
                Button {
                    Task { await editor.setPaper(paper) }
                } label: {
                    if editor.currentPaper == .drawn(paper) {
                        Label(PageNames.paper(paper), systemImage: "checkmark")
                    } else {
                        Text(PageNames.paper(paper))
                    }
                }
            }
            Divider()
            Button {
                photoDestination = .paperForCurrentPage
                isPickingPhoto = true
            } label: {
                Label("Photo", systemImage: "photo")
            }
        } label: {
            Label("Paper", systemImage: "square.grid.2x2")
        }
        .disabled(editor.currentPaper == nil)
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
            .font(Macaron.display(14))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .macaronCard(fill: Macaron.strawberry, radius: 12, shadow: 5)
            .padding(.top, 24)
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
