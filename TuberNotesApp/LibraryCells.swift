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
            paperCover
        case .folder(let decoration):
            folderGlyph(decoration)
        }
    }

    /// The portrait 'paper' cover: cream face, a subtle page-stack edge on
    /// the trailing side, a soft shadow — the thumbnail base case until
    /// ink renders land (a later lane).
    private var paperCover: some View {
        ZStack(alignment: .topTrailing) {
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
            .shadow(color: .black.opacity(0.45), radius: 8, y: 4)

            star
                .padding(8)
        }
    }

    /// The flat saturated folder: SF `folder.fill` tinted with the
    /// decoration's color, optional white glyph centered on the body.
    private func folderGlyph(_ decoration: FolderDecoration) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(LibraryStyle.folderColor(decoration))
                if let icon = decoration.icon {
                    Image(systemName: icon)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                        .offset(y: 8)
                }
            }
            .padding(.vertical, 14)
            .aspectRatio(0.76, contentMode: .fit)

            star
                .padding(4)

            if item.decorationDegraded {
                // The sidecar was missing or set aside: the folder renders
                // the default and wears the warning rather than refusing.
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.yellow)
                            .padding(6)
                        Spacer()
                    }
                }
            }
        }
    }

    /// Static tonight: the outline renders so the cell reads GoodNotes; the
    /// favorites toggle lands with the favorites lane.
    private var star: some View {
        Image(systemName: item.isFavorite ? "star.fill" : "star")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(item.isFavorite ? Color.red : Color(white: 0.55))
    }
}
