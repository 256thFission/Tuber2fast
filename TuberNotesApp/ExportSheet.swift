import SwiftUI
import TNEditor
import TNModel
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

    @Environment(\.macaron) private var theme

    var body: some View {
        MacaronPanel(title: "Export", onClose: { dismiss() }) {
            if let file = editor.exportedFile {
                result(file)
            } else if let progress = editor.exportProgress {
                walk(progress)
            } else {
                choices
            }
        }
        // A sheet dismissed mid-walk stops it; a result the sheet is done
        // with is not kept for the next opening.
        .onDisappear {
            editor.cancelExport()
            editor.clearExport()
        }
    }

    @ViewBuilder private var choices: some View {
        MacaronHeading(text: "Pages")
        HStack(spacing: Macaron.rowGap) {
            scopeCap("This page", .thisPage)
            scopeCap("All pages", .allPages)
            scopeCap("Pages", .range)
        }
        if scope == .range {
            counter("From", value: $first)
            counter("To", value: $last)
        }

        MacaronHeading(text: "Export")
        MacaronButton(title: "Export PDF", fill: theme.accent) { editor.exportPDF(pages: pages) }
        MacaronButton(title: "Export image of this page", fill: theme.secondary) {
            editor.exportCurrentPageImage()
        }
        footer("Handwriting is exported as pixels; paper, text, and imported PDF pages stay sharp at any size.")
    }

    /// The chosen scope is sunk and takes the accent, as a held tool and an
    /// active tab do. There is no other mark on it.
    private func scopeCap(_ title: String, _ candidate: ExportScope) -> some View {
        MacaronButton(
            title: title,
            fill: scope == candidate ? theme.accent : theme.chrome,
            isHeld: scope == candidate
        ) {
            scope = candidate
        }
    }

    /// A stepper is two caps with a flat readout between them.
    private func counter(_ label: String, value: Binding<Int>) -> some View {
        let bounds = 1...max(1, editor.pageCount)
        return HStack(spacing: Macaron.rowGap) {
            Text(label)
                .font(Macaron.body(13))
                .foregroundStyle(theme.outline(of: theme.chrome).color)
            Keycap(fill: theme.chrome, isEnabled: value.wrappedValue > bounds.lowerBound) {
                value.wrappedValue = max(bounds.lowerBound, value.wrappedValue - 1)
            } label: {
                Image(systemName: "minus").font(Macaron.body(14))
            }
            .accessibilityLabel(Text(verbatim: "\(label): one fewer"))
            Text(verbatim: "\(value.wrappedValue)")
                .font(Macaron.title(15))
                .foregroundStyle(theme.outline(of: theme.chrome).color)
                .frame(minWidth: 28)
            Keycap(fill: theme.chrome, isEnabled: value.wrappedValue < bounds.upperBound) {
                value.wrappedValue = min(bounds.upperBound, value.wrappedValue + 1)
            } label: {
                Image(systemName: "plus").font(Macaron.body(14))
            }
            .accessibilityLabel(Text(verbatim: "\(label): one more"))
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(Macaron.body(12))
            .foregroundStyle(theme.outline(of: theme.chrome).color)
            .fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder private func walk(_ progress: EditorViewModel.ExportProgress) -> some View {
        MacaronHeading(text: "Exporting")
        Text(verbatim: "Page \(min(progress.done + 1, progress.total)) of \(progress.total)")
            .font(Macaron.body(13))
            .foregroundStyle(theme.outline(of: theme.chrome).color)
        // A readout, so it is flat: a track in the chrome's outline with the
        // accent filling it, and no wall under either.
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Macaron.swatchRadius, style: .continuous)
                    .strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
                RoundedRectangle(cornerRadius: Macaron.swatchRadius, style: .continuous)
                    .fill(theme.accent.color)
                    .frame(width: proxy.size.width * walked(progress))
            }
        }
        .frame(height: Macaron.swatch)
        MacaronButton(title: "Cancel") { editor.cancelExport() }
    }

    private func walked(_ progress: EditorViewModel.ExportProgress) -> Double {
        progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
    }

    @ViewBuilder private func result(_ file: EditorViewModel.ExportedFile) -> some View {
        MacaronHeading(text: "Ready")
        switch file.kind {
        case .pdf:
            ShareLink(
                item: ExportedPDF(data: file.data, name: "\(name).pdf"),
                preview: SharePreview("\(name).pdf", image: Image(systemName: "doc.richtext"))
            ) {
                cap("Share PDF", icon: "square.and.arrow.up", fill: theme.accent)
            }
            .accessibilityLabel("Share PDF")
            MacaronButton(title: "Print", icon: "printer") { presentPrintPanel(file.data) }
        case .png:
            ShareLink(
                item: ExportedImage(data: file.data, name: "\(name).png"),
                preview: SharePreview("\(name).png", image: Image(systemName: "photo"))
            ) {
                cap("Share image", icon: "square.and.arrow.up", fill: theme.accent)
            }
            .accessibilityLabel("Share image")
        }
        MacaronButton(title: "Export something else", fill: theme.ground) { editor.clearExport() }
        footer("\(file.data.count / 1024) KB, kept in memory until this sheet closes.")
    }

    /// A `ShareLink` owns its own tap, so its label is drawn as the cap a
    /// `MacaronButton` would be rather than built from one, which would take
    /// the tap away from it.
    private func cap(_ title: String, icon: String, fill: RGBA8) -> some View {
        let outline = theme.outline(of: fill)
        let shape = RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
        return HStack(spacing: 6) {
            Image(systemName: icon).font(Macaron.body(14))
            Text(title).font(Macaron.title(15))
        }
        .foregroundStyle(outline.color)
        .padding(.horizontal, 14)
        .frame(height: Macaron.chip + 6)
        .background { shape.fill(fill.color) }
        .overlay { shape.strokeBorder(outline.color, lineWidth: Macaron.line) }
        .background { shape.fill(outline.color).offset(y: Macaron.chipWall) }
        .padding(.bottom, Macaron.chipWall)
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
