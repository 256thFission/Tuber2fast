import SwiftUI
import TNLibrary

/// What the trash holds, and the three things you can do with it. The
/// listing is the browser's; this view draws it and sends intentions.
struct LibraryTrashView: View {
    let browser: LibraryBrowser
    @Environment(Workspace.self) private var workspace

    @State private var deleting: TrashEntry?
    @State private var isEmptying = false

    @Environment(\.macaron) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 14)

            if case .refused(let message) = browser.listing {
                empty("The trash could not be shown: \(message)")
            } else if browser.trash.isEmpty {
                empty("Trash is empty")
            } else if browser.displayedTrash.isEmpty {
                empty("No results for \(browser.searchText)")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Macaron.rowGap) {
                        ForEach(browser.displayedTrash) { entry in
                            row(entry)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                }
            }
        }
        .confirmationDialog(
            "Delete permanently?", isPresented: isDeleting, titleVisibility: .visible, presenting: deleting
        ) { entry in
            Button("Delete \(entry.name)", role: .destructive) {
                workspace.changeLibrary { await browser.deletePermanently(entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This cannot be undone.")
        }
        .confirmationDialog("Empty the trash?", isPresented: $isEmptying, titleVisibility: .visible) {
            Button("Delete \(browser.trash.count) items", role: .destructive) {
                workspace.changeLibrary { await browser.emptyTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    /// A readout, so it is flat and has no wall.
    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Macaron.body(.text))
            .foregroundStyle(theme.outline(of: theme.chrome).color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Trash")
                .font(Macaron.title(.large))
                .foregroundStyle(theme.outline(of: theme.chrome).color)
            Text(verbatim: browser.trash.count == 1 ? "1 item" : "\(browser.trash.count) items")
                .font(Macaron.body(.text))
                .foregroundStyle(theme.outline(of: theme.chrome).color)
            Spacer()
            // Searching here searches the trash and nothing else: the trash
            // is not in the tree a search elsewhere reads.
            MacaronField(prompt: "Search", text: Bindable(browser).searchText)
                .frame(width: 180)
            MacaronButton(title: "Empty", fill: theme.accent, isEnabled: !browser.trash.isEmpty) {
                isEmptying = true
            }
        }
    }

    private func row(_ entry: TrashEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: entry.kind == .folder ? "folder" : "book.closed")
                .font(Macaron.body(.label))
                .foregroundStyle(theme.outline(of: theme.chrome).color)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(Macaron.title(.label))
                    .foregroundStyle(theme.outline(of: theme.chrome).color)
                Text(verbatim: caption(of: entry))
                    .font(Macaron.body(.caption))
                    .foregroundStyle(theme.outline(of: theme.chrome).color)
            }
            Spacer(minLength: 0)
            LibraryChevronMenu(name: entry.name) {
                Button {
                    workspace.changeLibrary { await browser.recover(entry) }
                } label: {
                    Label("Recover", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    deleting = entry
                } label: {
                    Label("Delete Permanently", systemImage: "trash")
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// When it was deleted, or, in its place, why its record could not say.
    private func caption(of entry: TrashEntry) -> String {
        switch entry.origin {
        case .success(let origin): "Deleted \(LibraryStyle.itemDate.string(from: origin.deletedAt))"
        case .failure(let fault): fault.description
        }
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}
