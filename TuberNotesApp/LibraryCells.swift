import CoreGraphics
import SwiftUI
import TNLibrary

/// Where an item lives, shown only while a search is running: a search
/// lists the whole library, and a bare name does not say which folder it
/// came from. Nil at the root, where there is nothing to say.
@MainActor private func parentWhileSearching(_ item: LibraryItem, _ browser: LibraryBrowser) -> String? {
    guard !browser.searchText.isEmpty, !item.parentPath.isEmpty else { return nil }
    return item.parentPath
}

/// One grid cell: the cover or the folder glyph, the star on it, the name
/// with the chevron menu beside it, the date beneath. The menu is passed in
/// because the actions it offers need the browser's sheets and alerts, which
/// live one level up.
struct LibraryGridCell<MenuContent: View>: View {
    let item: LibraryItem
    let browser: LibraryBrowser
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
    }

    @ViewBuilder private var artwork: some View {
        switch item.kind {
        case .notebook:
            LibraryCover(item: item, browser: browser)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        case .folder:
            LibraryFolderGlyph()
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
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 14) {
            if browser.isSelecting {
                LibrarySelectionCheck(item: item, browser: browser)
            }

            Group {
                switch item.kind {
                case .notebook: LibraryCover(item: item, browser: browser)
                case .folder: LibraryFolderGlyph()
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
    var body: some View {
        Image(systemName: "folder.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.accentColor)
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

    /// The spec's absolute date, `MMM d, yyyy 'at' h:mm a`. `Date.FormatStyle`
    /// puts a comma where this wants "at", so the format string is written out.
    static let itemDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter
    }()
}
