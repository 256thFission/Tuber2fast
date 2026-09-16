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
    @Environment(\.macaron) private var theme

    @State private var newFolderName = ""
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
        HStack(alignment: .top, spacing: Macaron.inset) {
            LibrarySidebar(section: Bindable(browser).section)
                .frame(width: 232)
                .padding(.leading, Macaron.inset)
                .padding(.top, Macaron.inset)
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
            VStack(alignment: .leading, spacing: Macaron.inset) {
                Group {
                    if browser.isSelecting {
                        selectBar
                    } else {
                        HStack(alignment: .center, spacing: Macaron.columnGap) {
                            header
                            Spacer(minLength: Macaron.inset)
                            toolbarRow
                        }
                    }
                }
                .padding(.horizontal, Macaron.inset)
                .padding(.top, Macaron.inset)
                listing
            }
        }
    }

    // MARK: Header

    /// At the root of a collection, the large title. Inside a folder, the
    /// small centred title with the back chevron at the pane's top left.
    @ViewBuilder private var header: some View {
        HStack(spacing: Macaron.columnGap) {
            if browser.section == .documents && !browser.folder.isEmpty {
                Keycap(
                    fill: theme.chrome,
                    size: CGSize(width: Macaron.chip, height: Macaron.chip)
                ) {
                    browser.back()
                } label: {
                    Image(systemName: "chevron.left").font(Macaron.body(14))
                }
                // Dashed, because what is hovering over the way out has
                // no body here until it is let go of.
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                        .strokeBorder(
                            theme.accent.color,
                            style: StrokeStyle(lineWidth: Macaron.line, dash: Macaron.dash)
                        )
                        .frame(width: Macaron.chip, height: Macaron.chip)
                        .opacity(isDroppingOnBack ? 1 : 0)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Back")
                // The one way out of a folder by drag: there is no cell
                // for the parent to drop onto.
                .dropDestination(for: DraggedLibraryItems.self) { dropped, _ in
                    guard let dragged = dropped.first else { return false }
                    let destination = parentFolder
                    run { await browser.move(Set(dragged.paths), toFolder: destination) }
                    return true
                } isTargeted: { isDroppingOnBack = $0 }
            }
            Text(browser.title)
                .font(Macaron.title(28))
                .foregroundStyle(theme.outline(of: theme.ground).color)
                .lineLimit(1)
        }
    }

    // MARK: Toolbar

    private var toolbarRow: some View {
        HStack(spacing: Macaron.columnGap) {
            MacaronMenuCap {
                Picker("Filter", selection: Bindable(browser).filter) {
                    Text("All").tag(LibraryFilter.all)
                    Text("Notebooks").tag(LibraryFilter.notebooks)
                    Text("Folders").tag(LibraryFilter.folders)
                }
                .pickerStyle(.inline)
            } label: {
                capLabel(Self.name(of: browser.filter), "line.3.horizontal.decrease")
            }

            if browser.section == .documents {
                // The accent, because making a notebook is the one thing the
                // library exists to do that nothing else in it can.
                MacaronMenuCap(fill: theme.accent) {
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
                    capLabel("New", "plus")
                }
            }

            viewOptionsMenu

            LibrarySearchField(text: Bindable(browser).searchText)
        }
    }

    private func capLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: Macaron.rowGap) {
            Image(systemName: symbol).font(Macaron.body(14))
            Text(title).font(Macaron.title(15))
        }
    }

    private var viewOptionsMenu: some View {
        MacaronMenuCap(padding: Macaron.rowGap) {
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
            Image(systemName: "square.grid.2x2").font(Macaron.body(14))
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
        VStack(spacing: Macaron.columnGap) {
            HStack {
                MacaronButton(title: "Select All", fill: theme.secondary) { browser.selectAll() }
                Spacer()
                Text(browser.title)
                    .font(Macaron.title(17))
                    .foregroundStyle(theme.outline(of: theme.ground).color)
                Spacer()
                // Leaving the mode is the one action this row exists for;
                // the three beneath it act on what is chosen.
                MacaronButton(title: "Done", fill: theme.accent) { browser.endSelecting() }
            }
            HStack(spacing: Macaron.columnGap) {
                Spacer()
                MacaronButton(title: "Move", icon: "folder", isEnabled: !selection.isEmpty) {
                    moveRequest = MoveRequest(paths: selection)
                }
                MacaronButton(
                    title: "Duplicate",
                    icon: "plus.square.on.square",
                    isEnabled: !selection.isEmpty
                ) {
                    run { await browser.duplicate(selection) }
                }
                // No colour of its own: the word is what says it destroys.
                MacaronButton(title: "Trash", icon: "trash", isEnabled: !selection.isEmpty) {
                    run { await browser.trash(selection) }
                }
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
                .tint(theme.outline(of: theme.ground).color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .refused(let message):
            // A refusal has a body: it is a thing that happened, and it
            // stays until the folder changes.
            placeholder(
                "This folder could not be shown",
                symbol: "exclamationmark.triangle",
                detail: message,
                isEmptySlot: false
            )
        case .loaded(let items) where items.isEmpty:
            placeholder(
                browser.section == .favorites ? "No favorites yet" : "This folder is empty",
                symbol: browser.section == .favorites ? "star" : "folder",
                detail: nil,
                isEmptySlot: true
            )
        case .loaded:
            switch browser.options.layout {
            case .grid: grid
            case .list: list
            }
        }
    }

    /// An empty collection is a slot with nothing in it, so it is dashed and
    /// has no fill. Anything else here is a real thing to read, so it has a
    /// body and a solid line.
    private func placeholder(
        _ title: String,
        symbol: String,
        detail: String?,
        isEmptySlot: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: Macaron.shellRadius, style: .continuous)
        return VStack(spacing: Macaron.columnGap) {
            Image(systemName: symbol).font(Macaron.title(28))
            Text(title).font(Macaron.title(17))
            if let detail {
                Text(detail)
                    .font(Macaron.body(13))
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(theme.outline(of: isEmptySlot ? theme.ground : theme.chrome).color)
        .padding(Macaron.shellRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if isEmptySlot {
                shape.strokeBorder(
                    theme.accent.color,
                    style: StrokeStyle(lineWidth: Macaron.line, dash: Macaron.dash)
                )
            } else {
                shape.fill(theme.chrome.color)
                    .overlay {
                        shape.strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
                    }
            }
        }
        .padding(Macaron.inset)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Macaron.inset, alignment: .top)], spacing: Macaron.inset) {
                ForEach(browser.displayed) { item in
                    LibraryGridCell(item: item, browser: browser, drop: dropTarget(item)) { itemMenu(for: item) }
                        .onTapGesture { tap(item) }
                }
            }
            .padding(.horizontal, Macaron.inset)
            .padding(.bottom, Macaron.inset)
        }
    }

    private var list: some View {
        ScrollView {
            // Each row is its own card with its own line, so there is no
            // divider left to draw between them.
            LazyVStack(spacing: Macaron.rowGap) {
                ForEach(browser.displayed) { item in
                    LibraryListRow(item: item, browser: browser, drop: dropTarget(item)) { itemMenu(for: item) }
                        .onTapGesture { tap(item) }
                }
            }
            .padding(.horizontal, Macaron.inset)
            .padding(.bottom, Macaron.inset)
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

/// The one search field, drawn over a folder's listing and over the trash.
/// The text is the browser's; what it narrows is the section's.
struct LibrarySearchField: View {
    @Binding var text: String

    @Environment(\.macaron) private var theme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
    }

    /// Typing into it is not pressing it, so it is flat.
    var body: some View {
        HStack(spacing: Macaron.rowGap) {
            Image(systemName: "magnifyingglass")
                .font(Macaron.body(13))
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(Macaron.body(14))
                .tint(theme.accent.color)
                .frame(width: 180)
        }
        .foregroundStyle(theme.outline(of: theme.chrome).color)
        .padding(.horizontal, Macaron.shellPadding)
        .frame(height: Macaron.chip)
        .background { shape.fill(theme.chrome.color) }
        .overlay { shape.strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line) }
    }
}

/// The collections, in a floating panel: the row you are in is highlighted,
/// and entering a folder does not move the highlight.
private struct LibrarySidebar: View {
    @Binding var section: LibrarySection

    @Environment(\.macaron) private var theme

    var body: some View {
        // A shell hugs what is in it. The column is taller than three rows,
        // so the shell sits at the top of it and the ground shows below.
        MacaronShell {
            VStack(alignment: .leading, spacing: Macaron.rowGap) {
                row(.documents, title: "Documents", symbol: "folder.fill")
                row(.favorites, title: "Favorites", symbol: "star.fill")
                row(.trash, title: "Trash", symbol: "trash")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The band's tabs, in a column: the collection you are in is the cap
    /// that has dropped its wall, and nothing else marks it.
    ///
    /// The cap is composed here rather than taken from `MacaronButton`,
    /// which hugs its word by design: three caps each as wide as their own
    /// word read as three objects, not as one list. The label fills the
    /// column instead, and the glyph sits in a fixed slot so the words start
    /// on one edge.
    private func row(_ target: LibrarySection, title: String, symbol: String) -> some View {
        Keycap(
            fill: section == target ? theme.accent : theme.chrome,
            size: CGSize(width: 0, height: Macaron.chip + 6),
            isHeld: section == target
        ) {
            section = target
        } label: {
            HStack(spacing: Macaron.columnGap) {
                Image(systemName: symbol)
                    .font(Macaron.body(14))
                    .frame(width: Macaron.swatch)
                Text(title).font(Macaron.title(15))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
        }
        .accessibilityAddTraits(section == target ? .isSelected : [])
    }
}
