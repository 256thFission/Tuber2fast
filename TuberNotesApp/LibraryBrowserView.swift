import SwiftUI
import TuberStore

/// The library browser: a floating sidebar beside a content column that owns
/// a `NavigationStack` over folder paths. The sidebar sits **outside** the
/// stack, so a folder push moves only the content pane (UX-7) — hand-walk
/// check: the sidebar does not move on push.
struct LibraryBrowserView: View {
    let coordinator: LibraryCoordinator

    @State private var sidebarCollapsed = false
    @State private var selection: SidebarSelection = .documents
    @State private var path: [String] = []
    /// One prefs snapshot for the whole browser — sort and view mode are
    /// global, not per-folder, so every folder view renders from this one
    /// object and a change anywhere re-orders them all.
    @State private var viewOptions: LibraryViewOptionsModel

    init(coordinator: LibraryCoordinator) {
        self.coordinator = coordinator
        self._viewOptions = State(
            initialValue: LibraryViewOptionsModel(library: coordinator.library)
        )
    }

    enum SidebarSelection: Hashable {
        case documents, favorites
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    LibrarySidebar(selection: $selection, collapsed: $sidebarCollapsed)
                        .frame(width: 280)
                        .padding([.leading, .vertical], 12)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                content
                    .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            drainBanner
        }
        .preferredColorScheme(.dark)
        // The one thumbnail store, reachable by every document cell — grid,
        // list, and anything presented from them — without threading it
        // through each initializer.
        .environment(coordinator.thumbnails)
        .task { await viewOptions.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .documents:
            NavigationStack(path: $path) {
                FolderContentView(
                    folderPath: "",
                    coordinator: coordinator,
                    viewOptions: viewOptions,
                    sidebarCollapsed: $sidebarCollapsed,
                    path: $path
                )
                .navigationDestination(for: String.self) { folderPath in
                    FolderContentView(
                        folderPath: folderPath,
                        coordinator: coordinator,
                        viewOptions: viewOptions,
                        sidebarCollapsed: $sidebarCollapsed,
                        path: $path
                    )
                }
            }
        case .favorites:
            FavoritesStubView(sidebarCollapsed: $sidebarCollapsed)
        }
    }

    /// The `save.error` visual language, relocated: a session closed dirty
    /// and is draining off-screen. Retry is `close()` again — it re-checks
    /// dirtiness; no timer (`02-proposal.md` §4, B3's retain-if-dirty).
    @ViewBuilder
    private var drainBanner: some View {
        if let draining = coordinator.draining {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(draining.displayName) has unsaved changes")
                        .font(.headline)
                    Text("\(draining.message) Opening documents is paused until they are saved.")
                        .font(.caption)
                        .lineLimit(2)
                }
                Button("Retry") {
                    Task { await coordinator.retryDrain() }
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(24)
            .accessibilityIdentifier("save.error")
        }
    }
}

/// The floating sidebar panel: Documents and Favorites rows, collapse toggle
/// top-right. Shared, Marketplace, bell, and avatar are deliberately absent —
/// nothing exists behind them (`02-proposal.md` §6, chrome deviations).
struct LibrarySidebar: View {
    @Binding var selection: LibraryBrowserView.SidebarSelection
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { collapsed = true }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide sidebar")
            }
            .padding(.bottom, 12)

            row(.documents, symbol: "folder.fill", title: "Documents", tint: .blue)
            row(.favorites, symbol: "bookmark.fill", title: "Favorites", tint: .secondary)

            Spacer()
        }
        .padding(14)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityIdentifier("library.sidebar")
    }

    private func row(
        _ target: LibraryBrowserView.SidebarSelection,
        symbol: String,
        title: String,
        tint: Color
    ) -> some View {
        Button {
            selection = target
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                selection == target ? Color(white: 0.2) : .clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
    }
}

/// One folder of the content column: header, toolbar row, then the listing
/// in one of its four states — loading, refused, empty, grid.
struct FolderContentView: View {
    let folderPath: String
    let coordinator: LibraryCoordinator
    let viewOptions: LibraryViewOptionsModel
    @Binding var sidebarCollapsed: Bool
    @Binding var path: [String]

    @State private var model: FolderListingModel
    @State private var showingNewPopover = false
    @State private var showingViewOptions = false
    @State private var showingNewFolderSheet = false
    @State private var showingNewNotebookSheet = false
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        folderPath: String,
        coordinator: LibraryCoordinator,
        viewOptions: LibraryViewOptionsModel,
        sidebarCollapsed: Binding<Bool>,
        path: Binding<[String]>
    ) {
        self.folderPath = folderPath
        self.coordinator = coordinator
        self.viewOptions = viewOptions
        self._sidebarCollapsed = sidebarCollapsed
        self._path = path
        self._model = State(
            initialValue: FolderListingModel(folderPath: folderPath, library: coordinator.library)
        )
    }

    private var isRoot: Bool { folderPath.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 16)

            toolbarRow
                .padding(.horizontal, 28)
                .padding(.vertical, 14)

            listingBody
        }
        .background(Color.black)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: coordinator.libraryGeneration) {
            await model.refresh()
        }
        .overlay(alignment: .bottom) { degradationBanner }
        .sheet(isPresented: $showingNewFolderSheet) {
            NewFolderSheet(model: model)
        }
        .sheet(isPresented: $showingNewNotebookSheet) {
            NewNotebookSheet { name in
                Task {
                    do {
                        try await coordinator.createAndOpenNotebook(named: name, in: folderPath)
                    } catch {
                        model.mutationBanner = FolderListingModel.describe(error)
                        await model.refresh()
                    }
                }
            }
        }
    }

    // MARK: - Header

    /// Root: the large left-aligned title. Inside a folder: small centered
    /// title with the circular back chevron at the pane's top-left. No
    /// breadcrumb, deliberately.
    @ViewBuilder
    private var header: some View {
        if isRoot {
            HStack(spacing: 12) {
                sidebarToggleIfCollapsed
                Text("Documents")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                searchControl
            }
        } else {
            ZStack {
                HStack(spacing: 12) {
                    sidebarToggleIfCollapsed
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color(white: 0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("library.folder.back")
                    Spacer()
                    searchControl
                }
                Text(model.displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    /// The top-right magnifier (spec §8's Gen-2 entry point), expanding into
    /// a text field in place. A custom field rather than `.searchable`
    /// because the navigation bar is hidden — this pane draws its own header,
    /// and `.searchable` would resurrect chrome the layout deliberately cut.
    @ViewBuilder
    private var searchControl: some View {
        if searchExpanded {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                TextField("Search", text: Bindable(model).searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .frame(width: 200)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .accessibilityIdentifier("library.search.field")
                Button {
                    model.searchText = ""
                    searchExpanded = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(white: 0.15), in: Capsule())
        } else {
            Button {
                searchExpanded = true
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color(white: 0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search this folder")
            .accessibilityIdentifier("library.search")
        }
    }

    @ViewBuilder
    private var sidebarToggleIfCollapsed: some View {
        if sidebarCollapsed {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { sidebarCollapsed = false }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show sidebar")
        }
    }

    // MARK: - Toolbar row

    private var toolbarRow: some View {
        HStack {
            LibraryFilterChip(model: model)

            Spacer()

            Button {
                showingNewPopover = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("New")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.blue, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.new")
            .popover(isPresented: $showingNewPopover, arrowEdge: .top) {
                LibraryNewPopover(
                    notebookBlockedReason: coordinator.canOpenDocuments
                        ? nil
                        : "A document with unsaved changes is still saving.",
                    onNotebook: { showingNewNotebookSheet = true },
                    onFolder: { showingNewFolderSheet = true }
                )
            }

            Button {
                showingViewOptions = true
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View options")
            .accessibilityIdentifier("library.viewoptions")
            .popover(isPresented: $showingViewOptions, arrowEdge: .top) {
                LibraryViewOptionsPopover(options: viewOptions)
            }

            LibraryToolbarMenu(coordinator: coordinator)
                .padding(.leading, 10)
        }
    }

    // MARK: - Listing body

    @ViewBuilder
    private var listingBody: some View {
        switch model.state {
        case .loading:
            Spacer()
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            Spacer()
        case .refused(let message):
            refusedView(message)
        case .loaded where model.items.isEmpty:
            emptyView
        case .loaded:
            // The designed empty state is for a truly empty folder; a filter
            // or search that hides everything says so in its own words.
            let displayed = model.displayed(under: viewOptions.prefs)
            if displayed.isEmpty {
                noMatchesView
            } else {
                switch viewOptions.prefs.viewMode {
                case .grid: grid(displayed)
                case .list: list(displayed)
                }
            }
        }
    }

    private var openBlockedReason: String? {
        coordinator.canOpenDocuments
            ? nil
            : "A document with unsaved changes is still saving."
    }

    private func grid(_ displayed: [LibraryItem]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 36, alignment: .top),
                    count: 4
                ),
                alignment: .center,
                spacing: 44
            ) {
                ForEach(displayed) { item in
                    LibraryItemCell(
                        item: item,
                        model: model,
                        openBlockedReason: openBlockedReason,
                        onOpen: { open(item) }
                    )
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
        }
        .accessibilityIdentifier("library.grid")
    }

    /// The list presentation (spec §2.4): full-width rows, thin hairline
    /// separators, same interleaved order as the grid.
    private func list(_ displayed: [LibraryItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(displayed) { item in
                    LibraryItemRow(
                        item: item,
                        model: model,
                        openBlockedReason: openBlockedReason,
                        onOpen: { open(item) }
                    )
                    Divider()
                        .overlay(Color(white: 0.18))
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("library.list")
    }

    /// A filter or search narrowed the listing to nothing — distinct from
    /// the empty-folder state, which only a successful empty listing renders.
    private var noMatchesView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(Color(white: 0.35))
                .padding(.bottom, 8)
            Text("No Matches")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text("Nothing here matches the current filter or search.")
                .font(.system(size: 15))
                .foregroundStyle(Color(white: 0.55))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func open(_ item: LibraryItem) {
        switch item.kind {
        case .document:
            coordinator.openDocument(at: item.id, named: item.name)
        case .folder:
            path.append(item.id)
        }
    }

    /// Refused, not emptied (`03-review.md` M-E): a thrown enumeration renders
    /// this, and the designed empty state renders only on a successful empty
    /// listing.
    private func refusedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("This folder could not be shown.")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("Retry") {
                Task { await model.refresh() }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("library.error")
    }

    /// The observed empty copy, with **no button** (UX-13). First-run root
    /// renders the same pattern; adoption already ran inside the store's
    /// first root listing.
    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(Color(white: 0.35))
                .padding(.bottom, 10)
            Text("This Folder is Empty")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text("Create a new document or move existing ones here.")
                .font(.system(size: 15))
                .foregroundStyle(Color(white: 0.55))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// One non-modal banner for listing degradations and mutation failures.
    @ViewBuilder
    private var degradationBanner: some View {
        let messages = (model.mutationBanner.map { [$0] } ?? []) + model.degradations
        if let first = messages.first {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(messages.count == 1 ? first : "\(first) (+\(messages.count - 1) more)")
                    .font(.caption)
                    .lineLimit(2)
                Button {
                    model.mutationBanner = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 16)
            .accessibilityIdentifier("library.degradations")
        }
    }
}

/// The Favorites row's stub: the collection lands with the favorites lane;
/// the row exists so the sidebar reads GoodNotes.
struct FavoritesStubView: View {
    @Binding var sidebarCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if sidebarCollapsed {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { sidebarCollapsed = false }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
                Text("Favorites")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)

            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "bookmark")
                    .font(.system(size: 56))
                    .foregroundStyle(Color(white: 0.35))
                    .padding(.bottom, 10)
                Text("Nothing is in Favorites yet")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.black)
    }
}
