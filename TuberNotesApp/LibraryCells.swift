import CoreGraphics
import SwiftUI
import TNLibrary
import TNModel
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
/// `DraggedPage` in PageNavigatorSheet.swift carries and for the same reason,
/// so every folder cell lights up as a drop target for any data item dragged
/// in from another app. Such a drop decodes to nothing and moves nothing; only the
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

/// A cell's cap, which drops its wall when the cell is chosen. A face and
/// not a `Keycap`, because a cell's tap belongs to the listing, the only
/// place that knows whether a tap opens a notebook or chooses it.
struct LibraryCap<Content: View>: View {
    let fill: RGBA8
    var isSunk = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous))
            .modifier(KeycapFace(fill: fill, sunk: isSunk))
            .padding(.bottom, Macaron.chipWall)
    }
}

/// A menu's button, as a keycap's face: the menu needs the tap to open with.
struct MacaronMenuCap<Label: View, Content: View>: View {
    var fill: RGBA8?
    var padding: CGFloat = 14
    var height: CGFloat = Macaron.chip
    @ViewBuilder var menu: () -> Content
    @ViewBuilder var label: () -> Label

    @Environment(\.macaron) private var theme

    var body: some View {
        Menu {
            menu()
        } label: {
            label()
                .frame(height: height)
                .padding(.horizontal, padding)
                .modifier(KeycapFace(fill: fill ?? theme.chrome, sunk: false))
                .padding(.bottom, Macaron.chipWall)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

/// A folder is a destination and a notebook is not, so a notebook cell takes
/// no drop modifier at all rather than one that refuses every drop. The
/// highlight is drawn here, over whichever cell this wraps.
private struct LibraryFolderDrop: ViewModifier {
    let item: LibraryItem
    let drop: (Set<String>) -> Void

    @State private var isTargeted = false
    @Environment(\.macaron) private var theme

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
                // Dashed: what is being offered to this folder has no body
                // here until it is let go of.
                .overlay {
                    RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                        .strokeBorder(
                            theme.accent.color,
                            style: StrokeStyle(lineWidth: Macaron.line, dash: Macaron.dash)
                        )
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
    /// the move has to run through `Workspace.changeLibrary`, which clears
    /// the last refusal first and rebuilds the identity index after.
    let drop: (Set<String>) -> Void
    @ViewBuilder let menu: () -> MenuContent

    @Environment(\.macaron) private var theme

    private var isChosen: Bool { browser.selection?.contains(item.relativePath) == true }

    var body: some View {
        VStack(spacing: Macaron.rowGap) {
            // A notebook is paper and a folder is ground, which is how the
            // band's overflow chip keeps a count from reading as a fifth tab.
            LibraryCap(fill: item.kind == .notebook ? theme.paper : theme.ground, isSunk: isChosen) {
                artwork
            }
            .overlay(alignment: .topTrailing) {
                LibraryFavoriteStar(item: item, browser: browser)
                    .padding(Macaron.rowGap)
            }
            .overlay(alignment: .bottomLeading) {
                if browser.library.isLocked(item.relativePath) {
                    lock
                }
            }

            // The name keeps the cover's centre line. The menu hangs off
            // the trailing edge rather than sharing the row, which would
            // push the name off the cover it belongs to.
            Text(item.name)
                .font(Macaron.title(.label))
                .foregroundStyle(theme.outline(of: theme.ground).color)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Macaron.chip)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    LibraryChevronMenu(name: item.name, menu: menu)
                }

            Text(LibraryStyle.itemDate.string(from: item.modifiedAt))
                .font(Macaron.body(.caption))
                .foregroundStyle(theme.outline(of: theme.ground).color)

            if let fault = item.fault {
                Text(fault.description)
                    .font(Macaron.body(.caption))
                    .foregroundStyle(theme.outline(of: theme.ground).color)
                    .multilineTextAlignment(.center)
            }

            if let parent = parentWhileSearching(item, browser) {
                Text(parent)
                    .font(Macaron.body(.detail))
                    .foregroundStyle(theme.outline(of: theme.ground).color)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .contentShape(.rect)
        .contextMenu { menu() }
        .draggable(dragged(item, browser))
        .modifier(LibraryFolderDrop(item: item, drop: drop))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    @ViewBuilder private var artwork: some View {
        switch item.kind {
        case .notebook:
            LibraryCover(item: item, browser: browser)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
        case .folder:
            LibraryFolderGlyph(decoration: item.decoration)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .padding(Macaron.shellPadding)
        }
    }

    /// A readout — this notebook is open somewhere — so it is flat.
    private var lock: some View {
        RoundedRectangle(cornerRadius: Macaron.swatchRadius, style: .continuous)
            .fill(theme.chrome.color)
            .overlay {
                RoundedRectangle(cornerRadius: Macaron.swatchRadius, style: .continuous)
                    .strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
            }
            .overlay {
                Image(systemName: "lock.fill")
                    .font(Macaron.body(.caption))
                    .foregroundStyle(theme.outline(of: theme.chrome).color)
            }
            .frame(width: Macaron.heldSwatch, height: Macaron.heldSwatch)
            .padding(Macaron.rowGap)
            .accessibilityLabel("Open")
    }
}

/// One list row: a small cover, the name over its date, then the same menu,
/// the same star, and a disclosure chevron on folders.
struct LibraryListRow<MenuContent: View>: View {
    let item: LibraryItem
    let browser: LibraryBrowser
    let drop: (Set<String>) -> Void
    @ViewBuilder let menu: () -> MenuContent

    @Environment(\.macaron) private var theme

    private var isChosen: Bool { browser.selection?.contains(item.relativePath) == true }

    var body: some View {
        LibraryCap(fill: theme.chrome, isSunk: isChosen) {
            HStack(spacing: Macaron.columnGap) {
                Group {
                    switch item.kind {
                    case .notebook: LibraryCover(item: item, browser: browser)
                    case .folder: LibraryFolderGlyph(decoration: item.decoration)
                    }
                }
                .frame(width: 44, height: 58)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Macaron.rowGap) {
                        Text(item.name)
                            .font(Macaron.title(.label))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if browser.library.isLocked(item.relativePath) {
                            Image(systemName: "lock.fill")
                                .font(Macaron.body(.caption))
                                .accessibilityLabel("Open")
                        }
                    }
                    Text(LibraryStyle.itemDate.string(from: item.modifiedAt))
                        .font(Macaron.body(.caption))

                    if let fault = item.fault {
                        Text(fault.description)
                            .font(Macaron.body(.caption))
                            .lineLimit(2)
                    }

                    if let parent = parentWhileSearching(item, browser) {
                        Text(parent)
                            .font(Macaron.body(.detail))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer(minLength: 0)

                LibraryChevronMenu(name: item.name, menu: menu)
                LibraryFavoriteStar(item: item, browser: browser)

                if item.kind == .folder {
                    Image(systemName: "chevron.right")
                        .font(Macaron.body(.text))
                }
            }
            .padding(.horizontal, Macaron.shellPadding)
            .padding(.vertical, Macaron.rowGap)
        }
        .contentShape(.rect)
        .contextMenu { menu() }
        .draggable(dragged(item, browser))
        .modifier(LibraryFolderDrop(item: item, drop: drop))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// The first page of a notebook, small: a portrait card with a page-stack
/// edge behind it. The pixels are this view's own presentation state, not
/// ink, and they are re-asked for whenever the package changes underneath.
struct LibraryCover: View {
    let item: LibraryItem
    let browser: LibraryBrowser

    @Environment(\.macaron) private var theme
    @State private var image: CGImage?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            // The pages under the first one, in the paper's own outline:
            // a stack of paper has nothing in it that paper has not.
            shape.fill(theme.outline(of: theme.paper).color).offset(x: 5)
            shape.fill(theme.outline(of: theme.paper).color).offset(x: 2.5)
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    theme.paper.color
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.outline(of: theme.paper).color, lineWidth: Macaron.line) }
        }
        .task(id: item.modifiedAt) { image = await browser.cover(of: item) }
    }
}

/// A folder's symbol in the folder's colour, standing on a wall in that
/// colour's outline as a keycap does. The colour is the folder's and the
/// ground is the theme's, so nothing keeps them apart but the wall.
struct LibraryFolderGlyph: View {
    /// Nil when the sidecar holding it could not be read. Such a folder has
    /// lost its identity and its star and shows the fault; it draws as it
    /// drew before decoration existed rather than as nothing at all.
    let decoration: FolderDecoration?

    @Environment(\.macaron) private var theme

    private var shown: FolderDecoration { decoration ?? .plain }

    var body: some View {
        let fill = LibraryStyle.rgba(of: shown.color)
        symbol
            .foregroundStyle(fill.color)
            .background {
                symbol
                    .foregroundStyle(theme.outline(of: fill).color)
                    .offset(y: Macaron.chipWall)
            }
    }

    private var symbol: some View {
        Image(systemName: shown.symbol.rawValue).resizable().scaledToFit()
    }
}

/// The star sits on the cover, where GoodNotes puts it, and favouriting
/// lives here and in no menu.
struct LibraryFavoriteStar: View {
    let item: LibraryItem
    let browser: LibraryBrowser

    @Environment(Workspace.self) private var workspace
    @Environment(\.macaron) private var theme

    private var starred: Bool { browser.isFavorite(item) }

    var body: some View {
        // A star names an identity, so an item whose identity could not be
        // read has none to show.
        if item.identity != nil {
            // Favoured is the cap sunk, not a second colour: the filled star
            // is the word on the cap, not the state of it.
            Keycap(
                starred ? "Remove \(item.name) from Favorites" : "Add \(item.name) to Favorites",
                systemImage: starred ? "star.fill" : "star",
                fill: theme.chrome,
                isHeld: starred
            ) {
                workspace.changeLibrary { await browser.toggleFavorite(item) }
            }
        }
    }
}

struct LibraryChevronMenu<MenuContent: View>: View {
    let name: String
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        // Beside a name rather than in a bar: a full-height cap next to one
        // line of 14pt reads as a button from somewhere else, so this one is
        // as tall as the swatch a held tool shows.
        MacaronMenuCap(padding: Macaron.rowGap, height: Macaron.heldSwatch) {
            menu()
        } label: {
            Image(systemName: "chevron.down")
                .font(Macaron.body(.caption))
        }
        .accessibilityLabel("Actions for \(name)")
    }
}

@MainActor
enum LibraryStyle {
    /// A folder's colour is durable per-folder data: it is chosen once and
    /// kept, so it cannot come off the theme's colours, which change under
    /// it when the theme does. The hexes are written out rather than taken
    /// from the system palette so that nothing in the library reaches for a
    /// colour the app did not pick. `.neutral` is what a folder draws in
    /// when it has never been decorated.
    static func rgba(of color: FolderColor) -> RGBA8 {
        switch color {
        case .neutral: RGBA8(red: 0xC7, green: 0xB8, blue: 0x9C, alpha: 0xFF)
        case .red: RGBA8(red: 0xFF, green: 0x6B, blue: 0x6B, alpha: 0xFF)
        case .orange: RGBA8(red: 0xFF, green: 0x9E, blue: 0x45, alpha: 0xFF)
        case .yellow: RGBA8(red: 0xFF, green: 0xD1, blue: 0x4A, alpha: 0xFF)
        case .green: RGBA8(red: 0x8F, green: 0xD4, blue: 0x6E, alpha: 0xFF)
        case .blue: RGBA8(red: 0x5C, green: 0xA8, blue: 0xE8, alpha: 0xFF)
        case .purple: RGBA8(red: 0xA8, green: 0x8C, blue: 0xE8, alpha: 0xFF)
        case .pink: RGBA8(red: 0xFF, green: 0x6B, blue: 0x8C, alpha: 0xFF)
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
