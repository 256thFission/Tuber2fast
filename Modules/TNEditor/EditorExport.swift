import Foundation
import PencilKit
import TNFormat
import TNModel
import TNNotebook
import UniformTypeIdentifiers

/// Export: one intention over one list of requests. A new target is a case
/// of `ExportRequest` and of `ExportedFile.Kind`, and the sheet draws its
/// button and its result from them; what the sheet still switches on is
/// which `Transferable` carries the bytes, because a representation's
/// content type is fixed per type.
extension EditorViewModel {
    /// How far a walk has got. `done` counts pages finished, so a walk that
    /// has finished reads `done == total` and stays visible under the
    /// result until the sheet is closed.
    package struct ExportProgress: Equatable, Sendable {
        package let done: Int
        package let total: Int

        package init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    /// What an export produced: bytes and what kind of bytes they are. No
    /// file is written; the share sheet and the print panel take the data.
    package struct ExportedFile: Equatable, Sendable {
        package enum Kind: Sendable {
            case pdf, png

            /// What the bytes are. A raster kind is encoded as this.
            package var contentType: UTType {
                switch self {
                case .pdf: .pdf
                case .png: .png
                }
            }

            package var fileExtension: String {
                switch self {
                case .pdf: "pdf"
                case .png: "png"
                }
            }

            /// What the sheet calls the file it hands over.
            package var title: String {
                switch self {
                case .pdf: "PDF"
                case .png: "image"
                }
            }

            /// Print takes a document; a picture goes out through the share
            /// sheet, whose own Print row takes it there.
            package var isPrintable: Bool { self == .pdf }
        }

        package let kind: Kind
        package let data: Data

        package init(kind: Kind, data: Data) {
            self.kind = kind
            self.data = data
        }
    }

    /// What the sheet can ask for.
    package enum ExportRequest: Hashable, Sendable {
        /// 1-based positions in the page list, the way the sheet counts them.
        case pdf(pages: ClosedRange<Int>)
        /// The page on screen as one PNG at asset resolution.
        case currentPageImage

        /// Every export the sheet offers, in the order it draws them, for
        /// the pages its scope names.
        package static func offered(pages: ClosedRange<Int>) -> [ExportRequest] {
            [.pdf(pages: pages), .currentPageImage]
        }

        package var title: String {
            switch self {
            case .pdf: "Export PDF"
            case .currentPageImage: "Export image of this page"
            }
        }

        package var kind: ExportedFile.Kind {
            switch self {
            case .pdf: .pdf
            case .currentPageImage: .png
            }
        }
    }

    /// An open text box commits first, so the export has what was typed. A
    /// range outside `1...pageCount` is a refusal and nothing is asked of
    /// the renderer. A second export cancels the one in flight.
    package func export(_ request: ExportRequest) {
        lastContentError = nil
        commitTextEditing()
        let ids = notebook.pageIDs
        let pages: ClosedRange<Int>
        switch request {
        case .pdf(let range): pages = range
        case .currentPageImage: pages = (currentPageIndex + 1)...(currentPageIndex + 1)
        }
        guard pages.lowerBound >= 1, pages.upperBound <= ids.count else {
            lastContentError = .invalidWrite("pages \(pages.lowerBound)-\(pages.upperBound) are outside 1-\(ids.count)")
            return
        }
        let selected = Array(ids[(pages.lowerBound - 1)...(pages.upperBound - 1)])
        let kind = request.kind
        beginExport(total: selected.count)
        let renderer = notebook.renderer
        exportTask = Task { [weak self] in
            let data: Data?
            switch kind {
            case .pdf:
                data = await renderer.pdf(pageCount: selected.count) { index in
                    await self?.exportedPage(index, of: selected, from: pages.lowerBound)
                }
            case .png:
                if let page = await self?.exportedPage(0, of: selected, from: pages.lowerBound) {
                    data = await renderer.flattened(
                        geometry: page.geometry, paper: page.paper, layers: page.layers, ink: page.ink,
                        as: kind.contentType.identifier as CFString)
                } else {
                    data = nil
                }
            }
            self?.finishExport(data.map { ExportedFile(kind: kind, data: $0) }, total: selected.count)
        }
    }

    /// Page `index` of a walk, as the renderer draws it; `first + index` is
    /// its place in the notebook, which a refusal names.
    private func exportedPage(_ index: Int, of selected: [PageID], from first: Int) async -> (geometry: PageGeometry, paper: Paper, layers: [Layer], ink: PKDrawing)? {
        // A walk cancelled before this page is reached shows no progress
        // after the cancel cleared it.
        guard !Task.isCancelled else { return nil }
        exportProgress = ExportProgress(done: index, total: selected.count)
        let page = selected[index]
        guard let record = notebook.index.record(of: page), let revision = await notebook.revision(of: page) else {
            // Nothing is dropped: a page that cannot be read refuses the
            // export rather than leaving a hole in it. A read the cancel cut
            // short is no refusal, because the person asked it to stop.
            if !Task.isCancelled { lastContentError = .invalidWrite("page \(first + index) couldn't be read") }
            return nil
        }
        return (record.geometry, record.paper, revision.layers, revision.ink)
    }

    /// Stops the walk. A cancelled export leaves no file and no refusal:
    /// the person asked for it to stop.
    package func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportProgress = nil
    }

    /// The sheet is done with the result.
    package func clearExport() {
        exportedFile = nil
        exportProgress = nil
    }

    private func beginExport(total: Int) {
        exportTask?.cancel()
        exportedFile = nil
        exportProgress = ExportProgress(done: 0, total: total)
    }

    private func finishExport(_ file: ExportedFile?, total: Int) {
        guard !Task.isCancelled else { return }
        exportTask = nil
        guard let file else {
            // A refusal already named its page; anything else is the
            // renderer refusing the whole document.
            if lastContentError == nil { lastContentError = .invalidWrite("the export couldn't be built") }
            exportProgress = nil
            return
        }
        exportProgress = ExportProgress(done: total, total: total)
        exportedFile = file
    }
}
