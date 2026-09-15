import SwiftUI
import TNEditor
import UIKit
import UniformTypeIdentifiers

/// What the share sheet receives for a PDF. The bytes stay in memory; the
/// suggested name is what Files and Mail write it as, taken from the tab.
struct ExportedPDF: Transferable {
    let data: Data
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { $0.data }
            .suggestedFileName { $0.name }
    }
}

/// The same for one page as a picture. PNG, so Photos, Files, and every
/// mail client understand it and nothing is re-compressed on the way out.
struct ExportedImage: Transferable {
    let data: Data
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
            .suggestedFileName { $0.name }
    }
}

/// Which pages a PDF export covers. Three choices rather than a range and a
/// flag, which could disagree.
private enum ExportScope: Hashable {
    case thisPage
    case allPages
    case range
}

/// Export, share, and print. The sheet asks for a range, shows the walk,
/// and hands the result to the system; nothing here reads the notebook.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let editor: EditorViewModel
    /// The tab's name, which the notebook does not know. It names the file
    /// a person saves or mails.
    let name: String
    /// Where the print panel is anchored from: iPad has no unanchored
    /// presentation.
    let anchor: () -> (rect: CGRect, view: UIView)?

    @State private var scope = ExportScope.thisPage
    @State private var first: Int
    @State private var last: Int

    @MainActor init(editor: EditorViewModel, name: String, anchor: @escaping () -> (rect: CGRect, view: UIView)?) {
        self.editor = editor
        self.name = name
        self.anchor = anchor
        let page = editor.currentPageIndex + 1
        _first = State(initialValue: page)
        _last = State(initialValue: page)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    MacaronHeader("Export")
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(MacaronWordChipStyle())
                }
                if let file = editor.exportedFile {
                    result(file)
                } else if let progress = editor.exportProgress {
                    walk(progress)
                } else {
                    choices
                }
            }
            .padding(20)
        }
        .macaronSheet()
        // A sheet dismissed mid-walk stops it; a result the sheet is done
        // with is not kept for the next opening.
        .onDisappear {
            editor.cancelExport()
            editor.clearExport()
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                MacaronHeader("Pages", size: 16)
                MacaronSegments(
                    options: [
                        (ExportScope.thisPage, "This page"),
                        (ExportScope.allPages, "All pages"),
                        (ExportScope.range, "Pages"),
                    ],
                    selection: $scope
                )
                if scope == .range {
                    Stepper("From \(first)", value: $first, in: 1...max(1, editor.pageCount))
                    Stepper("To \(last)", value: $last, in: 1...max(1, editor.pageCount))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .macaronSection()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("Export PDF") { editor.exportPDF(pages: pages) }
                        .buttonStyle(MacaronWordChipStyle(fill: Macaron.vanilla))
                    Button("Image of this page") { editor.exportCurrentPageImage() }
                        .buttonStyle(MacaronWordChipStyle())
                }
                Text("Handwriting is exported as pixels; paper, text, and imported PDF pages stay sharp at any size.")
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .macaronSection()
        }
    }

    private var pages: ClosedRange<Int> {
        switch scope {
        case .thisPage:
            let page = editor.currentPageIndex + 1
            return page...page
        case .allPages:
            return 1...max(1, editor.pageCount)
        case .range:
            return min(first, last)...max(first, last)
        }
    }

    private func walk(_ progress: EditorViewModel.ExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                Text("Page \(min(progress.done + 1, progress.total)) of \(progress.total)")
            }
            Button("Cancel", role: .cancel) { editor.cancelExport() }
                .buttonStyle(MacaronWordChipStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .macaronSection()
    }

    private func result(_ file: EditorViewModel.ExportedFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch file.kind {
            case .pdf:
                HStack(spacing: 10) {
                    ShareLink(
                        item: ExportedPDF(data: file.data, name: "\(name).pdf"),
                        preview: SharePreview("\(name).pdf", image: Image(systemName: "doc.richtext"))
                    ) {
                        Text("Share PDF")
                    }
                    .buttonStyle(MacaronWordChipStyle(fill: Macaron.vanilla))
                    Button("Print") { presentPrintPanel(file.data) }
                        .buttonStyle(MacaronWordChipStyle())
                }
            case .png:
                ShareLink(
                    item: ExportedImage(data: file.data, name: "\(name).png"),
                    preview: SharePreview("\(name).png", image: Image(systemName: "photo"))
                ) {
                    Text("Share image")
                }
                .buttonStyle(MacaronWordChipStyle(fill: Macaron.vanilla))
            }
            Button("Export something else") { editor.clearExport() }
                .buttonStyle(MacaronWordChipStyle())
            Text("\(file.data.count / 1024) KB, kept in memory until this sheet closes.")
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .macaronSection()
    }

    /// The same bytes the share sheet would carry, handed to the print
    /// panel directly, because Print is what a person looks for and the
    /// share sheet's own Print row is two taps further in.
    private func presentPrintPanel(_ data: Data) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = name
        controller.printInfo = info
        controller.printingItem = data
        guard let anchor = anchor() else { return }
        controller.present(from: anchor.rect, in: anchor.view, animated: true, completionHandler: nil)
    }
}
