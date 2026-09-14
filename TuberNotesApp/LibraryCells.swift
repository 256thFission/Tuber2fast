import CoreGraphics
import SwiftUI
import TNLibrary
import UniformTypeIdentifiers

/// Where an item lives, shown only while a search is running: a search
/// lists the whole library, and a bare name does not say which folder it
/// came from. Nil at the root, where there is nothing to say.
@MainActor private func parentWhileSearching(_ item: LibraryItem, _ browser: LibraryBrowser) -> String? {
    guard !browser.searchText.isEmpty, !item.parentPath.isEmpty else { return nil }
    return item.parentPath
}

/// The drag payload: relative paths, because a path is what a move takes and
/// what a selection already holds. Declared beside the cells that carry it
/// and not `private`, because `LibraryView` names the type too.
///
/// KNOWN DEFECT: the representation is `public.data`, the same defect
/// `PageNavigatorSheet.DraggedPage` carries and for the same reason, so every
/// folder cell lights up as a drop target for any data item dragged in from
/// another app. Such a drop decodes to nothing and moves nothing; only the
/// highlight is wrong. The fix — one exported `UTType`, which needs a plist
/// array the app's generated Info.plist has no build-setting form for — is
/// written out at that declaration and serves both sites at once.
struct DraggedLibraryItems: Transferable, Codable {
    let paths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// What a drag off a cell carries: the whole selection when this cell is in
/// it, and this one item otherwise. So a chosen set moves in one gesture,
/// and dragging something that is not chosen does not quietly take the set
/// with it.
@MainActor private func dragged(_ item: LibraryItem, _ browser: LibraryBrowser) -> DraggedLibraryItems {
    guard let selection = browser.selection, selection.contains(item.relativePath) else {
        return DraggedLibraryItems(paths: [item.relativePath])
    }
    return DraggedLibraryItems(paths: selection.sorted())
}

/// A folder is a destination and a notebook is not, so a notebook cell takes
/// no drop modifier at all rather than one that refuses every drop. The
/// highlight is drawn here, over whichever cell this wraps.
private struct LibraryFolderDrop: ViewModifier {
    let item: LibraryItem
    let drop: (Set<String>) -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if item.kind == .folder {
            content
                .dropDestination(for: DraggedLibraryItems.self) { dropped, _ in
                    guard let dragged = dropped.first else { return false }
                    drop(Set(dragged.paths))
                    // True means the drop was taken, not that the move
                    // landed: a folder into itself, or a folder holding an
                    // open notebook, is refused by the store or the ledger
                    // and reaches the reader as the banner that exists.
                    return true
                } isTargeted: { isTargeted = $0 }
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .opacity(isTargeted ? 1 : 0)
                }
        } else {
            content
        }
    }
}

/// One grid cell: the cover or the folder glyph, the star on it, the name
/// with the chevron menu beside it, the date beneath. The menu is passed in
/// because the actions it offers need the browser's sheets and alerts, which
/// live one level up.
struct LibraryGridCell<MenuContent: View>: View {
    let item: LibraryItem
    let browser: LibraryBrowser
    /// Where a drop on this cell goes. A closure, not a browser call, because
    /// the move has to run through `LibraryView.run`, which clears the last
    /// refusal first and rebuilds the identity index after.
    let drop: (Set<String>) -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                artwork
                LibraryFavoriteStar(item: item, browser: browser)
                    .padding(item.kind == .notebook ? 6 : 2)
            }
            .overlay(alignment: .topLeading) {
                LibrarySelectionCheck(item: item, browser: browser)
                    .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if browser.library.isLocked(item.relativePath) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: .circle)
                        .padding(6)
                        .accessibilityLabel("Open")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                LibraryChevronMenu(name: item.name, menu: menu)
            }

            Text(LibraryStyle.itemDate.string(from: item.modifiedAt))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let parent = parentWhileSearching(item, browser) {
                Text(parent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .contentShape(.rect)
        .contextMenu { menu() }
        .draggable(dragged(item, browser))
        .modifier(LibraryFolderDrop(item: item, drop: drop))
    }

    @ViewBuilder private var artwork: some View {
        switch item.kind {
        case .notebook:
            LibraryCover(item: item, browser: browser)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        case .folder:
            LibraryFolderGlyph(decoration: item.decoration)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .padding(.vertical, 10)
        }
    }
}

/// One list row: a small cover, the name over its date, then the same menu,
/// the same star, and a disclosure chevron on folders.
struct LibraryListRow<MenuContent: View>: View {
    let item: LibraryItem
    let browser: LibraryBrowser
    let drop: (Set<String>) -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 14) {
            if browser.isSelecting {
                LibrarySelectionCheck(item: item, browser: browser)
            }

            Group {
                switch item.kind {
                case .notebook: LibraryCover(item: item, browser: browser)
                case .folder: LibraryFolderGlyph(decoration: item.decoration)
                }
            }
            .frame(width: 44, height: 58)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if browser.library.isLocked(item.relativePath) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Open")
                    }
                }
                Text(LibraryStyle.itemDate.string(from: item.modifiedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let parent = parentWhileSearching(item, browser) {
                    Text(parent)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 0)

            LibraryChevronMenu(name: item.name, menu: menu)
            LibraryFavoriteStar(item: item, browser: browser)

            if item.kind == .folder {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .contextMenu { menu() }
        .draggable(dragged(item, browser))
        .modifier(LibraryFolderDrop(item: item, drop: drop))
    }
}

/// The first page of a notebook, small: a portrait card with a page-stack
/// edge behind it. The pixels are this view's own presentation state, not
/// ink, and they are re-asked for whenever the package changes underneath.
struct LibraryCover: View {
    let item: LibraryItem
    let browser: LibraryBrowser

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(LibraryStyle.paperEdge)
                .offset(x: 5)
            RoundedRectangle(cornerRadius: 6)
                .fill(LibraryStyle.paperEdge.opacity(0.6))
                .offset(x: 2.5)
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    LibraryStyle.paper
                }
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 4, bottomLeadingRadius: 4,
                    bottomTrailingRadius: 8, topTrailingRadius: 8
                )
            )
        }
        .task(id: item.modifiedAt) { image = await browser.cover(of: item) }
    }
}

struct LibraryFolderGlyph: View {
    /// Nil when the sidecar holding it could not be read. Such a folder has
    /// already lost its identity and its star; it draws as it drew before
    /// decoration existed rather than as nothing at all.
    let decoration: FolderDecoration?

    private var shown: FolderDecoration { decoration ?? .plain }

    var body: some View {
        Image(systemName: shown.symbol.rawValue)
            .resizable()
            .scaledToFit()
            .foregroundStyle(LibraryStyle.color(of: shown.color))
    }
}

/// The star sits on the cover, where GoodNotes puts it, and favouriting
/// lives here and in no menu.
struct LibraryFavoriteStar: View {
    let item: LibraryItem
    let browser: LibraryBrowser

    private var starred: Bool { browser.isFavorite(item) }

    var body: some View {
        Button {
            browser.refusal = nil
            Task { await browser.toggleFavorite(item) }
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.footnote.weight(.medium))
                .foregroundStyle(starred ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(starred ? "Remove \(item.name) from Favorites" : "Add \(item.name) to Favorites")
    }
}

struct LibraryChevronMenu<MenuContent: View>: View {
    let name: String
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Actions for \(name)")
    }
}

/// Nothing while the browser is not selecting; an empty or filled circle
/// while it is.
private struct LibrarySelectionCheck: View {
    let item: LibraryItem
    let browser: LibraryBrowser

    var body: some View {
        if let selection = browser.selection {
            let chosen = selection.contains(item.relativePath)
            Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(chosen ? Color.white : Color.secondary, chosen ? Color.accentColor : Color.clear)
                .background(.thinMaterial, in: .circle)
                .accessibilityLabel(chosen ? "Selected" : "Not selected")
        }
    }
}

@MainActor
enum LibraryStyle {
    static let paper = Color(red: 0.98, green: 0.97, blue: 0.94)
    static let paperEdge = Color(red: 0.85, green: 0.84, blue: 0.81)

    /// The one place a durable colour name becomes something drawable.
    /// `TNLibrary` may not import SwiftUI, so the name travels and the colour
    /// is chosen here; the system colours are used because they already read
    /// in light and dark. `.neutral` is the accent colour every folder drew
    /// before decoration existed, so an undecorated folder does not change.
    static func color(of color: FolderColor) -> Color {
        switch color {
        case .neutral: .accentColor
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }

    /// The spec's absolute date, `MMM d, yyyy 'at' h:mm a`. `Date.FormatStyle`
    /// puts a comma where this wants "at", so the format string is written out.
    static let itemDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter
    }()
}
