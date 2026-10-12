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

    @State private var isNamingFolder = false
    @State private var isCreatingNotebook = false
    @State private var renameTarget: LibraryItem?
    @State private var renameText = ""
    @State private var moveRequest: MoveRequest?
    @State private var styleTarget: LibraryItem?
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
        .sheet(isPresented: $isNamingFolder) {
            NewFolderSheet { name in
                run { await browser.createFolder(named: name) }
            }
        }
        .sheet(isPresented: $isCreatingNotebook) {
            NewNotebookSheet(opensOn: browser.options.newNotebook) { name, geometry, paper in
                // A notebook is made to be written in, so it opens as it lands.
                run {
                    guard let made = await browser.createNotebook(named: name, geometry: geometry, paper: paper) else { return }
                    await workspace.open(path: made.relativePath, name: made.name)
                }
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
        .sheet(item: $styleTarget) { item in
            FolderStyleSheet(name: item.name, decoration: item.decoration) { decoration in
                run { await browser.setDecoration(decoration, on: item) }
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

    /// Portrait leaves the pane about 500pt for this row, and every label
    /// wrapped letter by letter when the row was asked to hold more than
    /// that. The sort caption is the one thing that can go, so it goes
    /// first; the search field gives up width before anything else does.
    private var toolbarRow: some View {
        ViewThatFits(in: .horizontal) {
            toolbarItems(showingSort: true)
            toolbarItems(showingSort: false)
        }
    }

    private func toolbarItems(showingSort: Bool) -> some View {
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
                    .fixedSize()
            }

            if showingSort {
                HStack(spacing: 4) {
                    Text(Self.name(of: browser.options.sortKey))
                    Image(systemName: browser.options.ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize()
            }

            Spacer(minLength: 12)

            if browser.section == .documents {
                Button {
                    isCreatingNotebook = true
                } label: {
                    Label("New Notebook", systemImage: "plus")
                        .fixedSize()
                }
                .buttonStyle(.borderedProminent)

                Button {
                    isNamingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("New Folder")
            }

            viewOptionsMenu

            LibrarySearchField(text: Bindable(browser).searchText)
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
            if browser.section == .documents && browser.searchText.isEmpty {
                ContentUnavailableView {
                    Label("This folder is empty", systemImage: "folder")
                } description: {
                    Text("Create your first notebook")
                } actions: {
                    Button("New Notebook") { isCreatingNotebook = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    browser.section == .favorites ? "No favorites yet" : "This folder is empty",
                    systemImage: browser.section == .favorites ? "star" : "folder"
                )
            }
        case .loaded:
            switch browser.options.layout {
            case .grid: grid
            case .list: list
            }
        }
    }

    private var grid: some View {
        ScrollView {
            // A ceiling as well as a floor: without one, a folder holding one
            // notebook draws that cover the width of the pane.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 28, alignment: .top)], spacing: 28) {
                if offersCreation {
                    NewNotebookTile(setup: browser.options.newNotebook, create: createWithLastSetup)
                }
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
                if offersCreation {
                    NewNotebookRow(setup: browser.options.newNotebook, create: createWithLastSetup)
                    Divider()
                }
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
        if item.kind == .folder {
            Button {
                styleTarget = item
            } label: {
                Label("Customize", systemImage: "paintpalette")
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

    /// The leading tile stands for a creation, so it is out of the way while
    /// items are being picked, and the other collections have nothing to
    /// create into.
    private var offersCreation: Bool {
        browser.section == .documents && !browser.isSelecting
    }

    /// The same path the sheet takes, minus the asking.
    private func createWithLastSetup() {
        run {
            guard let made = await browser.createNotebookWithLastSetup(named: "New notebook") else { return }
            await workspace.open(path: made.relativePath, name: made.name)
        }
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

    /// The placeholder is the name until something else is typed; a field
    /// left blank is not a refusal.
    static func nameOrDefault(_ typed: String, _ fallback: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private static func name(of key: LibrarySortKey) -> String {
        switch key {
        case .dateCreated: "Date Created"
        case .lastModified: "Last Modified"
        case .name: "Name"
        case .type: "Type"
        }
    }

    private static func name(of filter: LibraryFilter) -> String {
        switch filter {
        case .all: "All"
        case .notebooks: "Notebooks"
        case .folders: "Folders"
        }
    }
}

/// The grid's leading tile: a cover-shaped dashed frame that creates on the
/// setup named beneath it, with no sheet in the way.
private struct NewNotebookTile: View {
    let setup: NotebookSetup?
    let create: () -> Void

    var body: some View {
        Button(action: create) {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        Color.accentColor.opacity(0.6),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.title)
                            .foregroundStyle(Color.accentColor)
                    }

                Text("New Notebook")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Text(PageNames.setup(setup))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The same creation as `NewNotebookTile`, on the list layout's row.
private struct NewNotebookRow: View {
    let setup: NotebookSetup?
    let create: () -> Void

    var body: some View {
        Button(action: create) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        Color.accentColor.opacity(0.6),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .overlay {
                        Image(systemName: "plus")
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 44, height: 58)

                VStack(alignment: .leading, spacing: 3) {
                    Text("New Notebook")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(PageNames.setup(setup))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The one search field, drawn over a folder's listing and over the trash.
/// The text is the browser's; what it narrows is the section's.
struct LibrarySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .frame(minWidth: 90, maxWidth: 180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary, in: .capsule)
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
