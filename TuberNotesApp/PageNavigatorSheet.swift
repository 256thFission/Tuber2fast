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
    /// The page a delete is being confirmed for. The toolbar's own dialog
    /// is bound to the current page and cannot take an argument.
    @State private var pageToDelete: PageID?
    @State private var tab = NavigatorTab.all
    @State private var bookmarkTarget: NavigatorPage?
    @State private var bookmarkTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MacaronHeader("Pages")
                Spacer()
                MacaronSegments(options: [(NavigatorTab.all, "All"), (NavigatorTab.marked, "Marked")], selection: $tab)
                Button("Done") { dismiss() }
                    .buttonStyle(MacaronWordChipStyle(fill: Macaron.vanilla))
            }
            .padding(20)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 20)], spacing: 20) {
                    ForEach(shown, id: \.element.id) { position, page in
                        cell(page, number: position + 1)
                    }
                    // Past the end of *every* page, which the Marked tab is
                    // not the end of.
                    if tab == .all { addTile }
                }
                .padding(20)
            }
            .macaronSheet()
            .overlay {
                // Only the Marked tab can be empty: a notebook always has a
                // page, and the All tab always has the "+" tile besides.
                if tab == .marked, shown.isEmpty {
                    ContentUnavailableView(
                        "No marked pages",
                        systemImage: "bookmark",
                        description: Text("Mark a page from its menu here, or from the toolbar.")
                    )
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
        .background(MacaronGround())
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
        VStack(spacing: 6) {
            PageThumbnail(editor: editor, page: page)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .modifier(MacaronSelectedFrame(isSelected: page.isCurrent, radius: 10))
                .overlay(alignment: .topTrailing) {
                    if page.bookmark != nil {
                        Image(systemName: "bookmark.fill")
                            .font(.footnote.weight(.black))
                            .foregroundStyle(Macaron.strawberry)
                            .padding(8)
                            .accessibilityLabel("Marked")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    dismiss()
                    editor.scroll(toPageIndex: number - 1)
                }
            HStack {
                Text("\(number)")
                    .font(Macaron.display(14).monospacedDigit())
                    .foregroundStyle(Macaron.ink)
                Spacer()
                Button(role: .destructive) {
                    pageToDelete = page.id
                } label: {
                    Label("Delete page", systemImage: "trash").labelStyle(.iconOnly)
                }
                .buttonStyle(MacaronChipStyle())
                .disabled(!page.isDeletable)
            }
            .padding(.top, 6)
            // A mark nobody named shows nothing here: the ordinal above is
            // already what it is called.
            if let title = page.bookmark, !title.isEmpty {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Macaron.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
    private var addTile: some View {
        Button {
            if let last = editor.navigatorPages.last { editor.addPage(after: last.id) }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.title)
                Text(Self.addAfterLabel)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Macaron.ink)
            .padding(12)
            .frame(maxWidth: .infinity)
            .aspectRatio(PageGeometry.letter.width / PageGeometry.letter.height, contentMode: .fit)
            .background(Macaron.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: Macaron.outline, dash: [8, 6])).foregroundStyle(Macaron.ink))
        }
        .buttonStyle(.plain)
        .dropDestination(for: DraggedPage.self) { dropped, _ in
            guard let dragged = dropped.first else { return false }
            editor.movePage(dragged.id, before: nil)
            return true
        }
    }

    /// Until a page-setup sheet exists, a new page copies the current page's
    /// paper and size, whichever page it is added after; the label says so.
    private static let addAfterLabel = "Add page (same paper as the current page)"
}

/// Naming a mark, from the navigator's menu or from the toolbar's button.
/// One definition, so the two surfaces cannot drift: Cancel, Save, and
/// Remove when the page is already marked. Saving an empty title is a mark
/// nobody named, which the Marked tab still lists.
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
            Rectangle().fill(Macaron.card)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
            }
        }
        .aspectRatio(page.geometry.width / page.geometry.height, contentMode: .fit)
        .task(id: FetchKey(version: page.version, isLoading: page.isLoading)) {
            // nil while the page is loading: the placeholder, or the last
            // image, stays until the load settles and the key changes.
            if let fetched = await editor.thumbnail(of: page.id) { image = fetched }
        }
    }
}
