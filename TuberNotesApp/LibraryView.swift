import SwiftUI
import TNLibrary
import TNModel

/// SwiftUI re-exports `DeveloperToolsSupport.LibraryItem`, so the name has to
/// be said once here or every use of it would be ambiguous.
typealias LibraryItem = TNLibrary.LibraryItem

/// The library browser: one folder at a time, its items in a grid, and every
/// mutation through `Library` so the checkout ledger gets to refuse it.
struct LibraryView: View {
    @Environment(Workspace.self) private var workspace

    @State private var folder = ""
    @State private var items: [LibraryItem] = []
    @State private var isLoading = false

    @State private var newFolderName = ""
    @State private var isNamingFolder = false
    @State private var newNotebookName = ""
    @State private var isNamingNotebook = false
    @State private var renameTarget: LibraryItem?
    @State private var renameText = ""
    @State private var isShowingTrash = false

    private var library: Library { workspace.library }

    var body: some View {
        VStack(spacing: 0) {
            LibraryPathBar(folder: folder) { folder = $0 }
            Divider()
            content
        }
        .safeAreaInset(edge: .top, spacing: 0) { toolbar }
        // The lock badge depends on what is checked out, so a tab opening or
        // closing reloads the listing as much as a folder change does.
        .task(id: "\(folder)|\(workspace.tabs.count)") { await reload() }
        .alert("New folder", isPresented: $isNamingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createFolder() } }
        }
        .alert("New notebook", isPresented: $isNamingNotebook) {
            TextField("Name", text: $newNotebookName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createNotebook() } }
        }
        .alert("Rename", isPresented: isRenaming, presenting: renameTarget) { item in
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await rename(item) } }
        }
        // Recovery puts an item back in the tree, so the browser behind the
        // sheet reloads when the sheet goes away.
        .sheet(isPresented: $isShowingTrash, onDismiss: { Task { await reload() } }) {
            TrashSheet()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Text(folder.isEmpty ? "Library" : Workspace.displayName(ofPath: folder))
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button {
                newNotebookName = "New notebook"
                isNamingNotebook = true
            } label: {
                Label("New notebook", systemImage: "square.and.pencil")
            }
            Button {
                newFolderName = "New folder"
                isNamingFolder = true
            } label: {
                Label("New folder", systemImage: "folder.badge.plus")
            }
            Button {
                isShowingTrash = true
            } label: {
                Label("Trash", systemImage: "trash")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        if isLoading && items.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            ContentUnavailableView("Nothing here yet", systemImage: "books.vertical", description: Text("Make a notebook to start writing."))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 20)], spacing: 20) {
                    ForEach(items) { item in
                        LibraryItemCell(item: item, isLocked: library.isLocked(item.relativePath))
                            .onTapGesture { Task { await tap(item) } }
                            .contextMenu { menu(for: item) }
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder private func menu(for item: LibraryItem) -> some View {
        Button {
            renameTarget = item
            renameText = item.name
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        if item.kind == .notebook {
            Button {
                Task { await duplicate(item) }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        Button(role: .destructive) {
            Task { await trash(item) }
        } label: {
            Label("Move to trash", systemImage: "trash")
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    // MARK: Intentions

    private func tap(_ item: LibraryItem) async {
        switch item.kind {
        case .folder: folder = item.relativePath
        case .notebook: await workspace.open(path: item.relativePath, name: item.name)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await library.store.list(folder: folder)
        } catch {
            workspace.banner = "\(error)"
            items = []
        }
    }

    private func createFolder() async {
        do {
            // Nothing to gate: the ledger has no entry for an item that does
            // not exist yet, which is why creation is the store's alone.
            _ = try await library.store.createFolder(named: newFolderName, in: folder)
            await reload()
        } catch {
            workspace.banner = "\(error)"
        }
    }

    private func createNotebook() async {
        do {
            _ = try await library.store.createNotebook(named: newNotebookName, in: folder)
            await reload()
        } catch {
            workspace.banner = "\(error)"
        }
    }

    private func rename(_ item: LibraryItem) async {
        do {
            _ = try await library.rename(at: item.relativePath, to: renameText)
            await reload()
            await workspace.refreshIdentities()
        } catch {
            workspace.banner = "\(error)"
        }
    }

    private func duplicate(_ item: LibraryItem) async {
        do {
            _ = try await library.duplicateNotebook(at: item.relativePath)
            await reload()
            await workspace.refreshIdentities()
        } catch {
            workspace.banner = "\(error)"
        }
    }

    private func trash(_ item: LibraryItem) async {
        do {
            _ = try await library.trash(at: item.relativePath)
            await reload()
            await workspace.refreshIdentities()
        } catch {
            workspace.banner = "\(error)"
        }
    }
}
