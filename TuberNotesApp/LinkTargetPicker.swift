import SwiftUI
import TNEditor
import TNModel

/// Where a new link goes: a page of a notebook that is open.
///
/// Open notebooks only, read from `Workspace.tabs`. A closed notebook would
/// mean reading its index behind a folder picker, and a link this build
/// cannot follow back is not worth minting: following is already built for
/// both scopes, and a notebook the reader is holding is the one they can
/// point at.
struct LinkTargetPicker: View {
    @Environment(\.dismiss) private var dismiss

    let workspace: Workspace
    let editor: EditorViewModel

    @Environment(\.macaron) private var theme

    var body: some View {
        MacaronPanel(title: "Link to", onClose: { dismiss() }) {
            ForEach(tabs) { tab in
                MacaronHeading(text: tab.name)
                ForEach(Array(tab.editor.navigatorPages.enumerated()), id: \.element.id) { position, page in
                    Keycap(
                        fill: theme.chrome,
                        size: CGSize(width: 0, height: Macaron.chip + 6),
                        action: { choose(tab, page) }
                    ) {
                        HStack(spacing: 8) {
                            Text(verbatim: "Page \(position + 1)").font(Macaron.title(.button))
                            if page.isCurrent {
                                Text("current").font(Macaron.body(.caption))
                            }
                        }
                        .padding(.horizontal, 14)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }

    /// This notebook first: most links point into the one the reader is
    /// already in. A `sorted` would not be stable, so the two halves are
    /// filtered and joined instead.
    private var tabs: [Workspace.Tab] {
        let mine = editor.notebook.notebookID
        return workspace.tabs.filter { $0.id == mine } + workspace.tabs.filter { $0.id != mine }
    }

    /// The scope is decided by identity, not by which tab is active: a link
    /// into this notebook must stay internal even when it is minted from a
    /// tab that is not the front one.
    private func choose(_ tab: Workspace.Tab, _ page: NavigatorPage) {
        let target: LinkTarget = tab.id == editor.notebook.notebookID
            ? .internalPage(page.id)
            : .externalPage(notebook: tab.id, page: page.id)
        dismiss()
        Task { await editor.addLink(to: target) }
    }
}
