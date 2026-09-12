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
        NavigationStack {
            Form {
                if let file = editor.exportedFile {
                    result(file)
                } else if let progress = editor.exportProgress {
                    walk(progress)
                } else {
                    choices
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // A sheet dismissed mid-walk stops it; a result the sheet is done
        // with is not kept for the next opening.
        .onDisappear {
            editor.cancelExport()
            editor.clearExport()
        }
    }

    private var choices: some View {
        Group {
            Section("Pages") {
                Picker("Pages", selection: $scope) {
                    Text("This page").tag(ExportScope.thisPage)
                    Text("All pages").tag(ExportScope.allPages)
                    Text("Pages").tag(ExportScope.range)
                }
                .pickerStyle(.segmented)
                if scope == .range {
                    Stepper("From \(first)", value: $first, in: 1...max(1, editor.pageCount))
                    Stepper("To \(last)", value: $last, in: 1...max(1, editor.pageCount))
                }
            }
            Section {
                Button("Export PDF") { editor.exportPDF(pages: pages) }
                Button("Export image of this page") { editor.exportCurrentPageImage() }
            } footer: {
                Text("Handwriting is exported as pixels; paper, text, and imported PDF pages stay sharp at any size.")
            }
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
        Section {
            ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                Text("Page \(min(progress.done + 1, progress.total)) of \(progress.total)")
            }
            Button("Cancel", role: .cancel) { editor.cancelExport() }
        }
    }

    private func result(_ file: EditorViewModel.ExportedFile) -> some View {
        Section {
            switch file.kind {
            case .pdf:
                ShareLink(
                    item: ExportedPDF(data: file.data, name: "\(name).pdf"),
                    preview: SharePreview("\(name).pdf", image: Image(systemName: "doc.richtext"))
                ) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                }
                Button {
                    presentPrintPanel(file.data)
                } label: {
                    Label("Print", systemImage: "printer")
                }
            case .png:
                ShareLink(
                    item: ExportedImage(data: file.data, name: "\(name).png"),
                    preview: SharePreview("\(name).png", image: Image(systemName: "photo"))
                ) {
                    Label("Share image", systemImage: "square.and.arrow.up")
                }
            }
            Button("Export something else") { editor.clearExport() }
        } footer: {
            Text("\(file.data.count / 1024) KB, kept in memory until this sheet closes.")
        }
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
