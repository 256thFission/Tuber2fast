import SwiftUI
import TuberStore

/// The browser toolbar's ellipsis menu, beside the + New pill. One row
/// tonight — Trash — because Trash lives behind this menu by declared
/// deviation (`02-proposal.md` §6: iPad GoodNotes reaches Trash from a
/// gear/avatar menu TuberNotes does not have; the toolbar menu is the
/// honest nearest home). Later rows append here.
struct LibraryToolbarMenu: View {
    let coordinator: LibraryCoordinator

    @State private var showingTrash = false

    var body: some View {
        Menu {
            Button {
                showingTrash = true
            } label: {
                Label("Trash", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(white: 0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityIdentifier("library.toolbar.menu")
        .sheet(isPresented: $showingTrash) {
            TrashSheet(coordinator: coordinator)
        }
    }
}

/// The Trash screen (spec §9): titled "Trash", top-right Empty (red) and
/// Done, rows of trashed items, a per-item chevron menu offering Recover
/// and Delete Permanently. Only the permanent deletions confirm — Delete
/// Permanently and Empty Trash — anchored, destructive, Cancel last;
/// Recover never confirms, matching Move to Trash on the other side.
struct TrashSheet: View {
    let coordinator: LibraryCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var model: TrashListingModel
    @State private var confirmingEmpty = false

    init(coordinator: LibraryCoordinator) {
        self.coordinator = coordinator
        self._model = State(initialValue: TrashListingModel(library: coordinator.library))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            listing
        }
        .background(Color(white: 0.09))
        .preferredColorScheme(.dark)
        .task { await model.refresh() }
        .overlay(alignment: .bottom) { banner }
        .accessibilityIdentifier("library.trash")
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            HStack(spacing: 20) {
                Spacer()

                Button("Empty") {
                    confirmingEmpty = true
                }
                .font(.system(size: 17))
                .foregroundStyle(model.items.isEmpty ? Color.secondary : Color.red)
                .disabled(model.items.isEmpty)
                .accessibilityIdentifier("library.trash.empty")
                .confirmationDialog(
                    "Empty Trash?",
                    isPresented: $confirmingEmpty,
                    titleVisibility: .visible
                ) {
                    Button("Empty Trash", role: .destructive) {
                        Task {
                            await model.emptyTrash()
                            coordinator.noteLibraryMutated()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every item in the Trash will be deleted permanently. "
                        + "This cannot be undone.")
                }

                Button("Done") {
                    dismiss()
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue)
            }
            Text("Trash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(20)
    }

    // MARK: - Listing

    @ViewBuilder
    private var listing: some View {
        if model.items.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "trash")
                    .font(.system(size: 56))
                    .foregroundStyle(Color(white: 0.35))
                    .padding(.bottom, 10)
                Text("Trash is Empty")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.items) { item in
                        row(item)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func row(_ item: TrashItem) -> some View {
        HStack(spacing: 14) {
            glyph(for: item.kind)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Deleted \(LibraryStyle.itemDate.string(from: item.deletedAt))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.55))
            }

            Spacer()

            TrashItemMenu(item: item, model: model, coordinator: coordinator)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.15))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.trash.item.\(item.name)")
    }

    @ViewBuilder
    private func glyph(for kind: LibraryItem.Kind) -> some View {
        switch kind {
        case .document:
            Image(systemName: "doc.text.fill")
                .font(.system(size: 22))
                .foregroundStyle(LibraryStyle.paper)
                .frame(width: 36)
        case .folder(let decoration):
            Image(systemName: "folder.fill")
                .font(.system(size: 22))
                .foregroundStyle(LibraryStyle.folderColor(decoration))
                .frame(width: 36)
        }
    }

    /// The same non-modal surface the browser uses: a failed recover or a
    /// refused listing is a line, never an alert.
    @ViewBuilder
    private var banner: some View {
        if let message = model.banner {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 16)
        }
    }
}

/// The per-item chevron: Recover (no confirmation — it is the un-delete)
/// and Delete Permanently behind an anchored destructive confirmation.
private struct TrashItemMenu: View {
    let item: TrashItem
    let model: TrashListingModel
    let coordinator: LibraryCoordinator

    @State private var confirmingDelete = false

    var body: some View {
        Menu {
            Button {
                let listing = model
                let owner = coordinator
                let target = item
                Task {
                    await listing.recover(target)
                    owner.noteLibraryMutated()
                }
            } label: {
                Label("Recover", systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("library.trash.recover.\(item.name)")

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.gray)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Actions for \(item.name)")
        .confirmationDialog(
            "Delete \u{201C}\(item.name)\u{201D}?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                let listing = model
                let target = item
                Task { await listing.deletePermanently(target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This item will be deleted permanently. This cannot be undone.")
        }
    }
}

/// The trash listing as the sheet shows it: the store's last answer, newest
/// deletion first. Same discipline as `FolderListingModel` — no optimistic
/// mutation; every action is a store call followed by a re-list.
@MainActor
@Observable
final class TrashListingModel {
    private let library: LibraryStore

    private(set) var items: [TrashItem] = []
    /// A refused listing or a failed action, surfaced non-modally.
    var banner: String?

    init(library: LibraryStore) {
        self.library = library
    }

    func refresh() async {
        do {
            items = try await library.listTrash().sorted { a, b in
                if a.deletedAt != b.deletedAt { return a.deletedAt > b.deletedAt }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        } catch {
            items = []
            banner = FolderListingModel.describe(error)
        }
    }

    func recover(_ item: TrashItem) async {
        do {
            _ = try await library.recoverItem(named: item.id)
        } catch {
            banner = FolderListingModel.describe(error)
        }
        await refresh()
    }

    func deletePermanently(_ item: TrashItem) async {
        do {
            try await library.deletePermanently(named: item.id)
        } catch {
            banner = FolderListingModel.describe(error)
        }
        await refresh()
    }

    func emptyTrash() async {
        do {
            try await library.emptyTrash()
        } catch {
            banner = FolderListingModel.describe(error)
        }
        await refresh()
    }
}
