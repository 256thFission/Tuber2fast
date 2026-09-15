import SwiftUI
import TNLibrary

/// What the trash holds, and the three things you can do with it. The
/// listing is the browser's; this view draws it and sends intentions.
struct LibraryTrashView: View {
    let browser: LibraryBrowser
    @Environment(Workspace.self) private var workspace

    @State private var deleting: TrashEntry?
    @State private var isEmptying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 14)

            if browser.trash.isEmpty {
                ContentUnavailableView("Trash is empty", systemImage: "trash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.displayedTrash.isEmpty {
                ContentUnavailableView.search(text: browser.searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(browser.displayedTrash) { entry in
                    row(entry)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .foregroundStyle(Macaron.ink)
        .tint(Macaron.strawberry)
        .background(MacaronGround())
        .confirmationDialog(
            "Delete permanently?", isPresented: isDeleting, titleVisibility: .visible, presenting: deleting
        ) { entry in
            Button("Delete \(entry.name)", role: .destructive) {
                run { await browser.deletePermanently(entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This cannot be undone.")
        }
        .confirmationDialog("Empty the trash?", isPresented: $isEmptying, titleVisibility: .visible) {
            Button("Delete \(browser.trash.count) items", role: .destructive) {
                run { await browser.emptyTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            MacaronHeader("Trash", size: 34)
            Text(browser.trash.count == 1 ? "1 ITEM" : "\(browser.trash.count) ITEMS")
                .font(Macaron.display(13))
                .opacity(0.7)
            Spacer()
            // Searching here searches the trash and nothing else: the trash
            // is not in the tree a search elsewhere reads.
            LibrarySearchField(text: Bindable(browser).searchText)
            Button("Empty", role: .destructive) { isEmptying = true }
                .buttonStyle(MacaronWordChipStyle(isOn: true))
                .disabled(browser.trash.isEmpty)
        }
    }

    private func row(_ entry: TrashEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: entry.kind == .folder ? "folder.fill" : "book.closed.fill")
                .font(.system(size: 16, weight: .black))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(Macaron.display(14))
                Text("Deleted \(LibraryStyle.itemDate.string(from: entry.origin.deletedAt))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .opacity(0.7)
            }
            Spacer(minLength: 0)
            LibraryChevronMenu(name: entry.name) {
                Button {
                    run { await browser.recover(entry) }
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
        .foregroundStyle(Macaron.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .macaronCard(fill: Macaron.card, radius: 12, shadow: 5)
        .padding([.trailing, .bottom], 5)
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    /// Recovering and deleting move an identity in or out of the tree, so the
    /// index a link resolves through is rebuilt after each.
    private func run(_ work: @escaping () async -> Void) {
        browser.refusal = nil
        Task {
            await work()
            await workspace.refreshIdentities()
        }
    }
}
