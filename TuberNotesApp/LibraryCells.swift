import SwiftUI
import TuberStore

/// One grid cell: thumbnail (paper cover or folder glyph), title with the
/// chevron menu affordance immediately right, grey absolute date beneath.
/// The anatomy is the fidelity commitment (UX-2), built from directory facts
/// alone — rendering a cell never opens the package.
struct LibraryItemCell: View {
    let item: LibraryItem
    let model: FolderListingModel
    /// Non-nil while a dirty session drains: documents refuse to open and the
    /// cover dims to say so; the drain banner carries the reason.
    let openBlockedReason: String?
    let onOpen: () -> Void

    @State private var showingMenu = false
    @State private var showingMovePicker = false

    private var isDocument: Bool {
        if case .document = item.kind { return true }
        return false
    }

    private var openDisabled: Bool { isDocument && openBlockedReason != nil }

    var body: some View {
        VStack(spacing: 10) {
            Button(action: onOpen) {
                thumbnail
            }
            .buttonStyle(.plain)
            .disabled(openDisabled)
            .opacity(openDisabled ? 0.4 : 1)
            // The star overlays the open button rather than living inside its
            // label: a button nested in a button's label yields its tap to
            // the outer one, and the star's tap must never open the document.
            .overlay(alignment: .topTrailing) {
                LibraryFavoriteStar(item: item, model: model)
                    .padding(isDocument ? 8 : 4)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Button {
                    showingMenu = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.gray)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Actions for \(item.name)")
                .accessibilityIdentifier("library.item.menu.\(item.name)")
                .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                    LibraryItemMenuPopover(item: item, model: model) {
                        showingMovePicker = true
                    }
                }
                .sheet(isPresented: $showingMovePicker) {
                    MovePickerSheet(item: item, model: model)
                }
            }

            Text(LibraryStyle.itemDate.string(from: item.modifiedAt))
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.55))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.item.\(item.name)")
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.kind {
        case .document:
            LibraryPaperCover()
                .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        case .folder(let decoration):
            ZStack(alignment: .topTrailing) {
                LibraryFolderGlyph(decoration: decoration)
                    .padding(.vertical, 14)
                if item.decorationDegraded {
                    // The sidecar was missing or set aside: the folder renders
                    // the default and wears the warning rather than refusing.
                    VStack {
                        Spacer()
                        HStack {
                            LibraryDegradedBadge()
                                .padding(6)
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

/// One list row: small cover thumbnail, title with grey date stacked beneath,
/// spacer, the same chevron menu the grid cell carries, the static star, and
/// — on folder rows only — a trailing grey disclosure chevron (spec §2.4).
struct LibraryItemRow: View {
    let item: LibraryItem
    let model: FolderListingModel
    /// Same contract as the grid cell: documents dim and refuse while a
    /// dirty session drains.
    let openBlockedReason: String?
    let onOpen: () -> Void

    @State private var showingMenu = false
    @State private var showingMovePicker = false

    private var isDocument: Bool {
        if case .document = item.kind { return true }
        return false
    }

    private var openDisabled: Bool { isDocument && openBlockedReason != nil }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    thumbnail
                        .frame(width: 44, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if item.decorationDegraded {
                                LibraryDegradedBadge()
                            }
                        }
                        Text(LibraryStyle.itemDate.string(from: item.modifiedAt))
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.55))
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(openDisabled)
            .opacity(openDisabled ? 0.4 : 1)

            Button {
                showingMenu = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.gray)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Actions for \(item.name)")
            .accessibilityIdentifier("library.item.menu.\(item.name)")
            .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                LibraryItemMenuPopover(item: item, model: model) {
                    showingMovePicker = true
                }
            }
            .sheet(isPresented: $showingMovePicker) {
                MovePickerSheet(item: item, model: model)
            }

            LibraryFavoriteStar(item: item, model: model, size: 15)

            if !isDocument {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.45))
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.item.\(item.name)")
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.kind {
        case .document:
            LibraryPaperCover()
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        case .folder(let decoration):
            LibraryFolderGlyph(decoration: decoration, iconSize: 13)
        }
    }
}

// MARK: - Shared building blocks

/// The portrait 'paper' cover: cream face, a subtle page-stack edge on the
/// trailing side — the thumbnail base case until ink renders land (a later
/// lane). Shared by the grid cell and the list row; the caller sizes and
/// shadows it.
struct LibraryPaperCover: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(LibraryStyle.paperEdge)
                .offset(x: 5)
            RoundedRectangle(cornerRadius: 6)
                .fill(LibraryStyle.paperEdge.opacity(0.7))
                .offset(x: 2.5)
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 8,
                topTrailingRadius: 8
            )
            .fill(LibraryStyle.paper)
        }
        .aspectRatio(0.76, contentMode: .fit)
    }
}

/// The flat saturated folder: SF `folder.fill` tinted with the decoration's
/// color, optional white glyph centered on the body. Shared by the grid cell
/// and the list row; the caller sizes it.
struct LibraryFolderGlyph: View {
    let decoration: FolderDecoration
    var iconSize: CGFloat = 34

    var body: some View {
        ZStack {
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(LibraryStyle.folderColor(decoration))
            if let icon = decoration.icon {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white)
                    .offset(y: iconSize / 4)
            }
        }
        .aspectRatio(0.76, contentMode: .fit)
    }
}

/// The favorites toggle, on the thumbnail where GoodNotes puts it: grey
/// outline off, red filled on; favoriting lives here and in no menu
/// (spec §10). The tap flips through the model — snapshot in, intention out.
struct LibraryFavoriteStar: View {
    let item: LibraryItem
    let model: FolderListingModel
    var size: CGFloat = 16

    var body: some View {
        Button {
            let target = item
            let listing = model
            Task { await listing.toggleFavorite(target) }
        } label: {
            Image(systemName: item.isFavorite ? "star.fill" : "star")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(item.isFavorite ? Color.red : Color(white: 0.55))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            item.isFavorite
                ? "Remove \(item.name) from Favorites"
                : "Add \(item.name) to Favorites"
        )
        .accessibilityIdentifier("library.item.star.\(item.name)")
    }
}

/// The corrupt-sidecar warning a degraded folder wears.
struct LibraryDegradedBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 14))
            .foregroundStyle(.yellow)
    }
}
