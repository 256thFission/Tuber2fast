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

    @State private var isNamingFolder = false
    @State private var isCreatingNotebook = false
    @State private var isMakingNotebook = false
    @State private var renameTarget: LibraryItem?
    @State private var renameText = ""
    @State private var moveRequest: MoveRequest?
    @State private var styleTarget: LibraryItem?
    @State private var isDroppingOnBack = false
    @State private var isShowingSettings = LaunchScene.current.sheet == .settings

    /// The paths a move picker is open for. A sheet needs an identity, and a
    /// set of paths has none.
    private struct MoveRequest: Identifiable {
        let id = UUID()
        let paths: Set<String>
    }

    private var browser: LibraryBrowser { workspace.browser }

    /// A launch scene's layout is shown, not saved: a run that exists to be
    /// photographed leaves the preference as it found it.
    private var layout: LibraryLayout { LaunchScene.current.layout ?? browser.options.layout }

    var body: some View {
        HStack(alignment: .top, spacing: Macaron.inset) {
            LibrarySidebar(section: Bindable(browser).section) { isShowingSettings = true }
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
        .sheet(isPresented: $isNamingFolder) {
            NewFolderSheet { name in
                workspace.changeLibrary { await browser.createFolder(named: name) }
            }
        }
        .sheet(isPresented: $isCreatingNotebook) {
            NewNotebookSheet(opensOn: browser.options.newNotebook) { name, geometry, paper in
                // A notebook is made to be written in, so it opens as it lands.
                workspace.changeLibrary {
                    guard let made = await browser.createNotebook(named: name, geometry: geometry, paper: paper) else { return }
                    await workspace.open(path: made.relativePath, name: made.name)
                }
            }
        }
        .alert("Rename", isPresented: isRenaming, presenting: renameTarget) { item in
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { workspace.changeLibrary { await browser.rename(item, to: renameText) } }
        }
        .sheet(item: $moveRequest) { request in
            LibraryMovePicker(browser: browser, paths: request.paths) { destination in
                workspace.changeLibrary { await browser.move(request.paths, toFolder: destination) }
            }
        }
        .sheet(item: $styleTarget) { item in
            FolderStyleSheet(name: item.name, decoration: item.decoration) { decoration in
                workspace.changeLibrary { await browser.setDecoration(decoration, on: item) }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsPanel { isShowingSettings = false }
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
                        // One line while the name and the tray both fit on
                        // it. A truncated collection name is not a trade
                        // worth making for a shorter page. Under its name,
                        // the search field is what gives up width.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .center, spacing: Macaron.columnGap) {
                                header
                                Spacer(minLength: Macaron.inset)
                                toolbarRow(searchWidth: 180)
                            }
                            VStack(alignment: .leading, spacing: Macaron.columnGap) {
                                header
                                toolbarRow(searchWidth: 180)
                            }
                            VStack(alignment: .leading, spacing: Macaron.columnGap) {
                                header
                                toolbarRow(searchWidth: 90)
                            }
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
                Keycap("Back", systemImage: "chevron.left", fill: theme.chrome) { browser.back() }
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
                // The one way out of a folder by drag: there is no cell
                // for the parent to drop onto.
                .dropDestination(for: DraggedLibraryItems.self) { dropped, _ in
                    guard let dragged = dropped.first else { return false }
                    let destination = browser.parentFolder
                    workspace.changeLibrary { await browser.move(Set(dragged.paths), toFolder: destination) }
                    return true
                } isTargeted: { isDroppingOnBack = $0 }
            }
            Text(browser.title)
                .font(Macaron.title(.display))
                .foregroundStyle(theme.outline(of: theme.ground).color)
                .lineLimit(1)
        }
    }

    // MARK: Toolbar

    private func toolbarRow(searchWidth: CGFloat) -> some View {
        MacaronShell {
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
                    // The accent, because making a notebook is the one thing
                    // the library exists to do that nothing else in it can.
                    // A chip's height, so it stands level with the menu caps.
                    Keycap(fill: theme.accent, size: CGSize(width: 0, height: Macaron.chip)) {
                        isCreatingNotebook = true
                    } label: {
                        capLabel("New Notebook", "plus").padding(.horizontal, 14)
                    }
                    Keycap("New Folder", systemImage: "folder.badge.plus", fill: theme.chrome) {
                        isNamingFolder = true
                    }
                }

                viewOptionsMenu

                MacaronDivider()

                MacaronField(prompt: "Search", text: Bindable(browser).searchText)
                    .frame(width: searchWidth)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func capLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: Macaron.rowGap) {
            Image(systemName: symbol).font(Macaron.body(.label))
            Text(title).font(Macaron.title(.button))
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
            Image(systemName: "square.grid.2x2").font(Macaron.body(.label))
        }
        .accessibilityLabel("View options")
    }

    private func layoutButton(_ title: String, _ layout: LibraryLayout) -> some View {
        Button {
            browser.options.layout = layout
        } label: {
            if self.layout == layout {
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
                    .font(Macaron.title(.headline))
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
                    workspace.changeLibrary { await browser.duplicate(selection) }
                }
                // No colour of its own: the word is what says it destroys.
                MacaronButton(title: "Trash", icon: "trash", isEnabled: !selection.isEmpty) {
                    workspace.changeLibrary { await browser.trash(selection) }
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
                browser.section == .favorites ? "Favorites could not be shown" : "This folder could not be shown",
                symbol: "exclamationmark.triangle",
                detail: message,
                isEmptySlot: false,
                offersCreation: false
            )
        case .loaded(let items) where items.isEmpty:
            placeholder(
                browser.section == .favorites ? "No favorites yet" : "This folder is empty",
                symbol: browser.section == .favorites ? "star" : "folder",
                // Only the root's emptiness is the whole library's.
                detail: offersCreation && browser.folder.isEmpty ? "Create your first notebook" : nil,
                isEmptySlot: true,
                offersCreation: offersCreation
            )
        case .loaded:
            switch layout {
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
        isEmptySlot: Bool,
        offersCreation: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: Macaron.shellRadius, style: .continuous)
        return VStack(spacing: Macaron.columnGap) {
            Image(systemName: symbol).font(Macaron.title(.display))
            Text(title).font(Macaron.title(.headline))
            if let detail {
                Text(detail)
                    .font(Macaron.body(.text))
                    .multilineTextAlignment(.center)
            }
            if offersCreation {
                MacaronButton(title: "New Notebook", icon: "plus", fill: theme.accent) { isCreatingNotebook = true }
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
            // A ceiling as well as a floor: without one, a folder holding one
            // notebook draws that cover the width of the pane.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: Macaron.inset, alignment: .top)],
                spacing: Macaron.inset
            ) {
                if offersCreation {
                    NewNotebookTile(setup: browser.options.newNotebook, isEnabled: !isMakingNotebook)
                        .onTapGesture { createWithLastSetup() }
                }
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
                if offersCreation {
                    NewNotebookRow(setup: browser.options.newNotebook, isEnabled: !isMakingNotebook)
                        .onTapGesture { createWithLastSetup() }
                }
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
                workspace.changeLibrary { await browser.duplicate([item.relativePath]) }
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
            workspace.changeLibrary { await browser.trash([item.relativePath]) }
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }

    // MARK: Intentions

    /// A drop on a folder cell moves what was dragged into that folder. Every
    /// refusal — a folder into itself, a folder above an open notebook — is
    /// the store's or the ledger's and lands in the banner.
    private func dropTarget(_ item: LibraryItem) -> (Set<String>) -> Void {
        { paths in workspace.changeLibrary { await browser.move(paths, toFolder: item.relativePath) } }
    }

    /// Creation is out of the way while items are being picked, the other
    /// collections have nothing to create into, and a search's results span
    /// the whole library rather than the folder a notebook would land in.
    private var offersCreation: Bool {
        browser.section == .documents && !browser.isSelecting && browser.searchText.isEmpty
    }

    /// The sheet's path, minus the asking: the last setup, and the name the
    /// browser gives a blank one. One at a time, so a double tap is one
    /// notebook.
    private func createWithLastSetup() {
        guard !isMakingNotebook else { return }
        isMakingNotebook = true
        workspace.changeLibrary {
            defer { isMakingNotebook = false }
            guard let made = await browser.createNotebookWithLastSetup(named: "") else { return }
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
    let openSettings: () -> Void

    @Environment(\.macaron) private var theme

    var body: some View {
        // A shell hugs what is in it. The column is taller than its rows, so
        // the shell sits at the top of it and the ground shows below.
        MacaronShell {
            VStack(alignment: .leading, spacing: Macaron.rowGap) {
                row(.documents, title: "Documents", symbol: "folder.fill")
                row(.favorites, title: "Favorites", symbol: "star.fill")
                row(.trash, title: "Trash", symbol: "trash")
                // Not a collection, so it is never held: it opens a panel
                // over the library rather than showing a place in it.
                cap(title: "Settings", symbol: "gearshape", action: openSettings)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The band's tabs, in a column: the collection you are in is the cap
    /// that has dropped its wall, and nothing else marks it.
    private func row(_ target: LibrarySection, title: String, symbol: String) -> some View {
        cap(title: title, symbol: symbol, isHeld: section == target) { section = target }
            .accessibilityAddTraits(section == target ? .isSelected : [])
    }

    /// Composed here rather than taken from `MacaronButton`, which hugs its
    /// word by design: caps each as wide as their own word read as separate
    /// objects, not as one list. The label fills the column instead, and the
    /// glyph sits in a fixed slot so the words start on one edge.
    private func cap(
        title: String, symbol: String, isHeld: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Keycap(
            fill: isHeld ? theme.accent : theme.chrome,
            size: CGSize(width: 0, height: Macaron.chip + 6),
            isHeld: isHeld,
            action: action
        ) {
            HStack(spacing: Macaron.columnGap) {
                Image(systemName: symbol)
                    .font(Macaron.body(.label))
                    .frame(width: Macaron.swatch)
                Text(title).font(Macaron.title(.button))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
        }
        // The word, without the glyph beside it.
        .accessibilityLabel(title)
    }
}
