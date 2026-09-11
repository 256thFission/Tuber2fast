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

/// A grid of every page: tap to go, drag to reorder, delete, add after.
/// Reads `editor.navigatorPages` and sends intentions; the pixels in each
/// cell are the cell's own state, fetched by the page's content version.
struct PageNavigatorSheet: View {
    let editor: EditorViewModel

    @Environment(\.dismiss) private var dismiss
    /// The page a delete is being confirmed for. The toolbar's own dialog
    /// is bound to the current page and cannot take an argument.
    @State private var pageToDelete: PageID?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                    ForEach(Array(editor.navigatorPages.enumerated()), id: \.element.id) { position, page in
                        cell(page, number: position + 1)
                    }
                    addTile
                }
                .padding(20)
            }
            .navigationTitle("Pages")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pageToDelete != nil }, set: { if !$0 { pageToDelete = nil } })
    }

    // MARK: Cells

    private func cell(_ page: NavigatorPage, number: Int) -> some View {
        VStack(spacing: 6) {
            PageThumbnail(editor: editor, page: page)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(page.isCurrent ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: page.isCurrent ? 3 : 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    dismiss()
                    editor.scroll(toPageIndex: number - 1)
                }
            HStack {
                Text("\(number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(page.isCurrent ? .primary : .secondary)
                Spacer()
                Button(role: .destructive) {
                    pageToDelete = page.id
                } label: {
                    Label("Delete page", systemImage: "trash").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(!page.isDeletable)
            }
        }
        .draggable(DraggedPage(id: page.id))
        .dropDestination(for: DraggedPage.self) { dropped, _ in
            guard let dragged = dropped.first else { return false }
            editor.movePage(dragged.id, before: page.id)
            return true
        }
        .contextMenu {
            Button {
                editor.addPage(after: page.id)
            } label: {
                Label(Self.addAfterLabel, systemImage: "plus.rectangle.portrait")
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
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .aspectRatio(PageGeometry.letter.width / PageGeometry.letter.height, contentMode: .fit)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6])).foregroundStyle(.secondary))
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
            Rectangle().fill(Color(uiColor: .systemBackground))
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
