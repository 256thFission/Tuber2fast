import SwiftUI
import TNLibrary

/// Where a move lands: the folder tree, one level at a time, with "Move
/// here" confirming whichever level is showing. The root is a destination
/// like any other.
struct LibraryMovePicker: View {
    let browser: LibraryBrowser
    let paths: Set<String>
    let confirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stack: [String] = []

    /// The level being shown is the top of the stack; the root is what is
    /// under an empty one.
    private var folder: String { stack.last ?? "" }

    var body: some View {
        MacaronPanel(
            title: folder.isEmpty ? "Documents" : Workspace.displayName(ofPath: folder),
            onClose: { dismiss() }
        ) {
            LibraryMoveLevel(
                browser: browser,
                paths: paths,
                folder: folder,
                canGoBack: !stack.isEmpty,
                enter: { stack.append($0) },
                back: { stack.removeLast() },
                confirm: { destination in
                    confirm(destination)
                    dismiss()
                }
            )
        }
    }
}

private struct LibraryMoveLevel: View {
    let browser: LibraryBrowser
    let paths: Set<String>
    let folder: String
    let canGoBack: Bool
    let enter: (String) -> Void
    let back: () -> Void
    let confirm: (String) -> Void

    @Environment(\.macaron) private var theme
    @State private var folders = Listing.loading

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The ground's fill, as the band's overflow chip takes: a way
            // back out is not a peer of the destinations it sits over.
            if canGoBack {
                MacaronButton(title: "Back", icon: "chevron.left", fill: theme.ground) { back() }
            }

            MacaronHeading(text: "Folders")
            switch folders {
            case .loading:
                EmptyView()
            case .refused(let message):
                readout("These folders could not be shown: \(message)")
            case .loaded(let items) where items.isEmpty:
                readout("No folders here")
            case .loaded(let items):
                ForEach(items) { item in
                    MacaronButton(title: item.name, icon: "folder") { enter(item.relativePath) }
                }
            }

            MacaronButton(
                title: folder.isEmpty ? "Move to Documents" : "Move here",
                fill: theme.accent
            ) {
                confirm(folder)
            }
        }
        .task(id: folder) {
            folders = await browser.destinations(in: folder, excluding: paths)
        }
    }

    private func readout(_ text: String) -> some View {
        Text(text)
            .font(Macaron.body(13))
            .foregroundStyle(theme.outline(of: theme.chrome).color)
    }
}
