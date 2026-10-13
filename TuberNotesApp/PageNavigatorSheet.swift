import CoreGraphics
import SwiftUI
import TNEditor
import TNModel
import UniformTypeIdentifiers

/// The drag payload. A retroactive `Transferable` on `PageID` would be a
/// warning, and warnings are errors; a local wrapper is not.
///
/// KNOWN DEFECT: the representation is `public.data`, so every cell and the
/// "+" tile light up as drop targets for any data item dragged in from
/// another app. Such a drop decodes to nothing and moves nothing; only the
/// highlight is wrong. The fix is an exported custom `UTType`, which needs a
/// declaration in the app's Info.plist, and the plist is generated from
/// build settings today (`project.yml`, `GENERATE_INFOPLIST_FILE`), so that
/// is a build change rather than a line here.
private struct DraggedPage: Transferable, Codable {
    let id: PageID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// Which pages the grid shows: every one, or the marked ones. The outline is
/// the second tab of this grid rather than a surface of its own, because the
/// thumbnail fetch, the dismiss-then-scroll tap, the context menu and the
/// delete confirmation are all here already.
private enum NavigatorTab: Hashable {
    case all, marked
}

/// Reorder by drag, on the All tab only. `movePage(_:before:)` names the page
/// a drop lands on, and in a filtered list the cell before a marked page may
/// be twenty pages away, so "before this one" would not mean what it looks
/// like. The gesture is withheld rather than refused after the lift.
private struct NavigatorReorder: ViewModifier {
    let page: NavigatorPage
    let enabled: Bool
    let move: (PageID) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(DraggedPage(id: page.id))
                .dropDestination(for: DraggedPage.self) { dropped, _ in
                    guard let dragged = dropped.first else { return false }
                    move(dragged.id)
                    return true
                }
        } else {
            content
        }
    }
}

/// A grid of every page: tap to go, drag to reorder, delete, add after, and
/// a second tab holding the marked ones. Reads `editor.navigatorPages` and
/// sends intentions; the pixels in each cell are the cell's own state,
/// fetched by the page's content version.
struct PageNavigatorSheet: View {
    let editor: EditorViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.macaron) private var theme
    /// The page a delete is being confirmed for. Insert's own dialog is
    /// bound to the current page and cannot take an argument.
    @State private var pageToDelete: PageID?
    @State private var tab = NavigatorTab.all
    @State private var bookmarkTarget: NavigatorPage?
    @State private var bookmarkTitle = ""

    /// Five chips tall, and never wider than the column the grid asks for;
    /// the cap keeps the page's own aspect inside that box, which is what
    /// makes it page-shaped rather than cell-shaped.
    private static let thumbnailHeight = Macaron.chip * 5
    private static let column: CGFloat = 140
    /// The ordinal and the delete cap under the thumbnail. A cap stands on
    /// its wall, so the row is as tall as both.
    private static let caption = Macaron.chip + Macaron.chipWall

    private static func thumbnailSize(of geometry: PageGeometry) -> CGSize {
        let aspect = CGFloat(geometry.width / geometry.height)
        let tall = CGSize(width: thumbnailHeight * aspect, height: thumbnailHeight)
        guard tall.width > column else { return tall }
        return CGSize(width: column, height: column / aspect)
    }

    var body: some View {
        MacaronPanel(title: "Pages", onClose: { dismiss() }) {
            HStack(spacing: Macaron.columnGap) {
                MacaronButton(title: "All", isHeld: tab == .all) { tab = .all }
                MacaronButton(title: "Marked", isHeld: tab == .marked) { tab = .marked }
            }

            // Only the Marked tab can be empty: a notebook always has a
            // page, and the All tab always has the "+" tile besides.
            if tab == .marked, shown.isEmpty {
                VStack(alignment: .leading, spacing: Macaron.rowGap) {
                    MacaronHeading(text: "No marked pages")
                    Text("Mark a page from its menu here.")
                        .font(Macaron.body(.text))
                        .foregroundStyle(theme.outline(of: theme.chrome).color)
                }
                .padding(.vertical, 20)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.column), spacing: Macaron.columnGap)],
                    spacing: Macaron.columnGap + Macaron.chipWall
                ) {
                    ForEach(shown, id: \.element.id) { position, page in
                        cell(page, number: position + 1)
                    }
                    // Past the end of *every* page, which the Marked tab is
                    // not the end of.
                    if tab == .all { addTile }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("Delete this page?", isPresented: isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete page", role: .destructive) {
                if let page = pageToDelete { editor.deletePage(page) }
                pageToDelete = nil
            }
            Button("Cancel", role: .cancel) { pageToDelete = nil }
        } message: {
            Text("The page and everything on it are removed.")
        }
        .bookmarkAlert(editor: editor, page: $bookmarkTarget, title: $bookmarkTitle)
    }

    /// The pages this tab shows, as *enumerated pairs*.
    ///
    /// The filter is over the pairs and not the array, so a page keeps the
    /// ordinal it has in the whole notebook: the label under a marked cell is
    /// its own page number, and the tap — which uses that number as an
    /// absolute index — lands on that page. Filtering the array first would
    /// renumber from 1 and send the third mark of a forty-page notebook to
    /// page 3.
    private var shown: [(offset: Int, element: NavigatorPage)] {
        let pairs = Array(editor.navigatorPages.enumerated())
        return tab == .all ? pairs : pairs.filter { $0.element.bookmark != nil }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pageToDelete != nil }, set: { if !$0 { pageToDelete = nil } })
    }

    // MARK: Cells

    private func cell(_ page: NavigatorPage, number: Int) -> some View {
        let thumbnail = Self.thumbnailSize(of: page.geometry)
        return VStack(spacing: Macaron.rowGap) {
            // The page itself, as a cap: white paper, radius 10, the derived
            // 3pt outline. The page being read is sunk, and that is the whole
            // of the current state.
            Keycap(
                fill: theme.paper,
                size: thumbnail,
                radius: Macaron.chipRadius,
                isHeld: page.isCurrent,
                name: "Page \(number)",
                action: {
                    dismiss()
                    editor.scroll(toPageIndex: number - 1)
                }
            ) {
                PageThumbnail(editor: editor, page: page)
            }
            .overlay(alignment: .topTrailing) {
                if page.bookmark != nil {
                    Image(systemName: "bookmark.fill")
                        .font(Macaron.body(.text))
                        .foregroundStyle(theme.outlineOnPaper(of: theme.secondary).color)
                        .padding(5)
                        .accessibilityLabel("Marked")
                }
            }

            HStack(spacing: Macaron.columnGap) {
                Text(verbatim: "\(number)")
                    .font(Macaron.title(.text))
                    .monospacedDigit()
                    .foregroundStyle(theme.outline(of: theme.chrome).color)
                Spacer()
                Keycap("Delete page", systemImage: "trash", fill: theme.chrome, isEnabled: page.isDeletable) {
                    pageToDelete = page.id
                }
            }
            .frame(height: Self.caption)
            // A mark nobody named shows nothing here: the ordinal above is
            // already what it is called.
            if let title = page.bookmark, !title.isEmpty {
                Text(title)
                    .font(Macaron.body(.caption))
                    .foregroundStyle(theme.outline(of: theme.chrome).color)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: thumbnail.width)
        .modifier(
            NavigatorReorder(page: page, enabled: tab == .all) { dragged in
                editor.movePage(dragged, before: page.id)
            }
        )
        .contextMenu {
            Button {
                bookmarkTitle = page.bookmark ?? ""
                bookmarkTarget = page
            } label: {
                Label(
                    page.bookmark == nil ? "Bookmark page" : "Edit bookmark",
                    systemImage: page.bookmark == nil ? "bookmark" : "bookmark.fill"
                )
            }
            Button {
                editor.addPage(after: page.id)
            } label: {
                Label(Self.addAfterLabel, systemImage: "plus.rectangle.portrait")
            }
            Button {
                Task { await editor.duplicatePage(page.id) }
            } label: {
                Label("Duplicate page", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                pageToDelete = page.id
            } label: {
                Label("Delete page", systemImage: "trash")
            }
            .disabled(!page.isDeletable)
        }
    }

    /// The past-the-end drop target, and a tap adds after the last page.
    ///
    /// Dashed, and with no body behind it: the page it stands for does not
    /// exist yet, which is exactly what a dashed line says in this design.
    private var addTile: some View {
        // The page it stands for would be added after the last one, so it
        // takes that page's footprint and the grid stays one grid.
        let thumbnail = Self.thumbnailSize(of: editor.navigatorPages.last?.geometry ?? .letter)
        return Button {
            if let last = editor.navigatorPages.last { editor.addPage(after: last.id) }
        } label: {
            VStack(spacing: Macaron.rowGap) {
                Image(systemName: "plus")
                    .font(Macaron.title(.large))
                Text(Self.addAfterLabel)
                    .font(Macaron.body(.caption))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(theme.outline(of: theme.chrome).color)
            .padding(8)
            .frame(width: thumbnail.width, height: thumbnail.height)
            .overlay {
                RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                    .strokeBorder(
                        theme.accent.color,
                        style: StrokeStyle(lineWidth: Macaron.line, dash: Macaron.dash)
                    )
            }
        }
        .buttonStyle(.plain)
        .frame(
            width: thumbnail.width,
            height: thumbnail.height + Macaron.rowGap + Self.caption,
            alignment: .top
        )
        .dropDestination(for: DraggedPage.self) { dropped, _ in
            guard let dragged = dropped.first else { return false }
            editor.movePage(dragged.id, before: nil)
            return true
        }
    }

    /// The grid's add asks nothing, so a new page copies the current page's
    /// paper and size, whichever page it is added after; the label says so.
    /// Insert's Add page is where a paper and a size are chosen.
    private static let addAfterLabel = "Add page (same paper as the current page)"
}

/// Naming a mark, from a cell's menu: Cancel, Save, and Remove when the
/// page is already marked. Saving an empty title is a mark nobody named,
/// which the Marked tab still lists.
struct BookmarkAlert: ViewModifier {
    let editor: EditorViewModel
    @Binding var page: NavigatorPage?
    @Binding var title: String

    func body(content: Content) -> some View {
        content.alert("Bookmark", isPresented: isPresented, presenting: page) { page in
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) {}
            Button("Save") { editor.bookmark(page.id, titled: title) }
            if page.bookmark != nil {
                Button("Remove", role: .destructive) { editor.removeBookmark(page.id) }
            }
        } message: { _ in
            Text("Marked pages are listed under Marked in the page grid.")
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { page != nil }, set: { if !$0 { page = nil } })
    }
}

extension View {
    func bookmarkAlert(
        editor: EditorViewModel,
        page: Binding<NavigatorPage?>,
        title: Binding<String>
    ) -> some View {
        modifier(BookmarkAlert(editor: editor, page: page, title: title))
    }
}

/// One page's pixels over a page-shaped placeholder. The fetch is keyed by
/// the content version and the loading flag, so it re-fires when the page
/// changes or its load settles, and is cancelled when the cell scrolls away.
///
/// The paper under it belongs to the cap this sits in, so the placeholder is
/// nothing at all: a second white rectangle would square off the page's
/// corners.
private struct PageThumbnail: View {
    let editor: EditorViewModel
    let page: NavigatorPage

    @State private var image: CGImage?

    private struct FetchKey: Equatable {
        let version: UInt64
        let isLoading: Bool
    }

    var body: some View {
        ZStack {
            Color.clear
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
            }
        }
        .aspectRatio(page.geometry.width / page.geometry.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous))
        .task(id: FetchKey(version: page.version, isLoading: page.isLoading)) {
            // nil while the page is loading: the placeholder, or the last
            // image, stays until the load settles and the key changes.
            if let fetched = await editor.thumbnail(of: page.id) { image = fetched }
        }
    }
}
