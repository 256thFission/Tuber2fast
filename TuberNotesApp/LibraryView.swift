import SwiftUI
import TNLibrary
import TNModel

/// SwiftUI re-exports `DeveloperToolsSupport.LibraryItem`, so the name has to
/// be said once here or every use of it would be ambiguous.
typealias LibraryItem = TNLibrary.LibraryItem

/// The library browser: a sidebar of collections beside one folder's
/// listing. Every listing, option, filter, search and selection is the
/// `LibraryBrowser`'s; this view holds only what is on screen over it.
struct LibraryView: View {
    @Environment(Workspace.self) private var workspace

    @State private var newFolderName = ""
    @State private var isNamingFolder = false
    @State private var isCreatingNotebook = false
    @State private var renameTarget: LibraryItem?
    @State private var renameText = ""
    @State private var moveRequest: MoveRequest?
    @State private var isDroppingOnBack = false

    /// The paths a move picker is open for. A sheet needs an identity, and a
    /// set of paths has none.
    private struct MoveRequest: Identifiable {
        let id = UUID()
        let paths: Set<String>
    }

    private var browser: LibraryBrowser { workspace.browser }

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(section: Bindable(browser).section)
                .frame(width: 260)
                .padding([.leading, .vertical], 12)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // The lock badge depends on what is checked out, so a tab opening or
        // closing reloads the listing as much as a folder change does.
        // Whether a search is running, not the text: the tree is read once
        // when the search starts and once when it ends, and `displayed`
        // narrows it per keystroke without touching the disk.
        .task(id: "\(browser.section)|\(browser.folder)|\(workspace.tabs.count)|\(browser.searchText.isEmpty)") {
            await browser.reload()
        }
        .onChange(of: browser.refusal) { _, refusal in
            if let refusal { workspace.banner = refusal }
        }
        .alert("New folder", isPresented: $isNamingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { run { await browser.createFolder(named: newFolderName) } }
        }
        .sheet(isPresented: $isCreatingNotebook) {
            NewNotebookSheet(opensOn: browser.options.newNotebook) { name, geometry, paper in
                run { await browser.createNotebook(named: name, geometry: geometry, paper: paper) }
            }
        }
        .alert("Rename", isPresented: isRenaming, presenting: renameTarget) { item in
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { run { await browser.rename(item, to: renameText) } }
        }
        .sheet(item: $moveRequest) { request in
            LibraryMovePicker(browser: browser, paths: request.paths) { destination in
                run { await browser.move(request.paths, toFolder: destination) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch browser.section {
        case .trash:
            LibraryTrashView(browser: browser)
        case .documents, .favorites:
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                if browser.isSelecting {
                    selectBar
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                } else {
                    toolbarRow
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                }
                listing
            }
        }
    }

    // MARK: Header

    /// At the root of a collection, the large title. Inside a folder, the
    /// small centred title with the back chevron at the pane's top left.
    @ViewBuilder private var header: some View {
        if browser.section == .documents && !browser.folder.isEmpty {
            ZStack {
                HStack {
                    Button {
                        browser.back()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(.quaternary, in: .circle)
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                                    .opacity(isDroppingOnBack ? 1 : 0)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    // The one way out of a folder by drag: there is no cell
                    // for the parent to drop onto.
                    .dropDestination(for: DraggedLibraryItems.self) { dropped, _ in
                        guard let dragged = dropped.first else { return false }
                        let destination = parentFolder
                        run { await browser.move(Set(dragged.paths), toFolder: destination) }
                        return true
                    } isTargeted: { isDroppingOnBack = $0 }
                    Spacer()
                }
                Text(browser.title)
                    .font(.headline)
            }
        } else {
            Text(browser.title)
                .font(.largeTitle.weight(.bold))
                .frame(height: 44, alignment: .leading)
        }
    }

    // MARK: Toolbar

    private var toolbarRow: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Filter", selection: Bindable(browser).filter) {
                    Text("All").tag(LibraryFilter.all)
                    Text("Notebooks").tag(LibraryFilter.notebooks)
                    Text("Folders").tag(LibraryFilter.folders)
                }
                .pickerStyle(.inline)
            } label: {
                Label(Self.name(of: browser.filter), systemImage: "line.3.horizontal.decrease")
            }

            Spacer()

            if browser.section == .documents {
                Menu {
                    Button {
                        isCreatingNotebook = true
                    } label: {
                        Label("Notebook", systemImage: "book.closed")
                    }
                    Button {
                        newFolderName = "New folder"
                        isNamingFolder = true
                    } label: {
                        Label("Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            viewOptionsMenu

            searchField
        }
    }

    private var viewOptionsMenu: some View {
        Menu {
            Button {
                browser.beginSelecting()
            } label: {
                Label("Select Items", systemImage: "checkmark.circle")
            }
            Divider()
            layoutButton("Grid", .grid)
            layoutButton("List", .list)
            Divider()
            sortButton("Date Created", .dateCreated)
            sortButton("Last Modified", .lastModified)
            sortButton("Name", .name)
            sortButton("Type", .type)
        } label: {
            Image(systemName: "square.grid.2x2")
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("View options")
    }

    private func layoutButton(_ title: String, _ layout: LibraryLayout) -> some View {
        Button {
            browser.options.layout = layout
        } label: {
            if browser.options.layout == layout {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func sortButton(_ title: String, _ key: LibrarySortKey) -> some View {
        Button {
            browser.options = browser.options.tapping(key)
        } label: {
            if browser.options.sortKey == key {
                Label(title, systemImage: browser.options.ascending ? "chevron.up" : "chevron.down")
            } else {
                Text(title)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: Bindable(browser).searchText)
                .textFieldStyle(.plain)
                .frame(width: 180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary, in: .capsule)
    }

    /// The toolbar row's replacement while selecting, on the spec's shape:
    /// Select All, the collection's name, Done, and the actions beneath.
    private var selectBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Select All") { browser.selectAll() }
                Spacer()
                Text(browser.title)
                    .font(.headline)
                Spacer()
                Button("Done") { browser.endSelecting() }
            }
            HStack(spacing: 24) {
                Spacer()
                Button {
                    moveRequest = MoveRequest(paths: selection)
                } label: {
                    Label("Move", systemImage: "folder")
                }
                Button {
                    run { await browser.duplicate(selection) }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) {
                    run { await browser.trash(selection) }
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                .tint(.red)
                Spacer()
            }
            .disabled(selection.isEmpty)
        }
    }

    private var selection: Set<String> { browser.selection ?? [] }

    // MARK: Listing

    @ViewBuilder private var listing: some View {
        switch browser.listing {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .refused(let message):
            ContentUnavailableView(
                "This folder could not be shown",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let items) where items.isEmpty:
            ContentUnavailableView(
                browser.section == .favorites ? "No favorites yet" : "This folder is empty",
                systemImage: browser.section == .favorites ? "star" : "folder"
            )
        case .loaded:
            switch browser.options.layout {
            case .grid: grid
            case .list: list
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 28, alignment: .top)], spacing: 28) {
                ForEach(browser.displayed) { item in
                    LibraryGridCell(item: item, browser: browser, drop: dropTarget(item)) { itemMenu(for: item) }
                        .onTapGesture { tap(item) }
                }
            }
            .padding(28)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(browser.displayed) { item in
                    LibraryListRow(item: item, browser: browser, drop: dropTarget(item)) { itemMenu(for: item) }
                        .onTapGesture { tap(item) }
                    Divider()
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private func itemMenu(for item: LibraryItem) -> some View {
        Button {
            renameTarget = item
            renameText = item.name
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        if item.kind == .notebook {
            Button {
                run { await browser.duplicate([item.relativePath]) }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        Button {
            moveRequest = MoveRequest(paths: [item.relativePath])
        } label: {
            Label("Move", systemImage: "folder")
        }
        Button(role: .destructive) {
            run { await browser.trash([item.relativePath]) }
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }

    // MARK: Intentions

    /// A drop on a folder cell moves what was dragged into that folder. Every
    /// refusal — a folder into itself, a folder above an open notebook — is
    /// the store's or the ledger's and lands in the banner.
    private func dropTarget(_ item: LibraryItem) -> (Set<String>) -> Void {
        { paths in run { await browser.move(paths, toFolder: item.relativePath) } }
    }

    /// One level up from the folder showing, which is where `browser.back()`
    /// goes and so where a drop on the back chevron lands.
    private var parentFolder: String {
        guard let slash = browser.folder.lastIndex(of: "/") else { return "" }
        return String(browser.folder[..<slash])
    }

    private func tap(_ item: LibraryItem) {
        if browser.isSelecting {
            browser.toggleSelected(item)
            return
        }
        switch item.kind {
        case .folder: browser.enter(item)
        case .notebook: Task { await workspace.open(path: item.relativePath, name: item.name) }
        }
    }

    /// Every mutation here moves an identity within the tree or adds one, so
    /// the index a link resolves through is rebuilt after each. The refusal
    /// is cleared first: twice refused with the same words is a value that
    /// never changes, and the banner watches for a change.
    private func run(_ work: @escaping () async -> Void) {
        browser.refusal = nil
        Task {
            await work()
            await workspace.refreshIdentities()
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private static func name(of filter: LibraryFilter) -> String {
        switch filter {
        case .all: "All"
        case .notebooks: "Notebooks"
        case .folders: "Folders"
        }
    }
}

/// The collections, in a floating panel: the row you are in is highlighted,
/// and entering a folder does not move the highlight.
private struct LibrarySidebar: View {
    @Binding var section: LibrarySection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(.documents, title: "Documents", symbol: "folder.fill")
            row(.favorites, title: "Favorites", symbol: "star.fill")
            row(.trash, title: "Trash", symbol: "trash")
            Spacer()
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 24))
    }

    private func row(_ target: LibrarySection, title: String, symbol: String) -> some View {
        Button {
            section = target
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 22)
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                section == target ? Color.accentColor.opacity(0.18) : .clear,
                in: .rect(cornerRadius: 12)
            )
            .foregroundStyle(section == target ? Color.accentColor : Color.primary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
