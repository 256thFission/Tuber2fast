import SwiftUI
import TuberStore

/// The chevron popover: inline rename for both kinds; Color|Icon with the
/// nine primary dots for a folder; Duplicate for documents only; Move then
/// Move to Trash for both — the observed menus put Move first of the
/// non-duplicate action rows. Export is deliberately absent tonight — a
/// later lane — and the rows are structured so it appends cleanly.
struct LibraryItemMenuPopover: View {
    let item: LibraryItem
    let model: FolderListingModel
    /// The move picker is the cell's sheet, not this popover's — a popover
    /// cannot outlive its own dismissal to present it.
    let onMove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var inlineError: String?
    @State private var decorationTab: DecorationTab = .color
    @State private var committed = false

    private enum DecorationTab: Hashable {
        case color, icon
    }

    init(item: LibraryItem, model: FolderListingModel, onMove: @escaping () -> Void) {
        self.item = item
        self.model = model
        self.onMove = onMove
        self._name = State(initialValue: item.name)
    }

    private var decoration: FolderDecoration? {
        if case .folder(let decoration) = item.kind { return decoration }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { commitRenameInline() }

            if let inlineError {
                // The name gate's refusal, shown where the name is.
                Text(inlineError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let decoration {
                Picker("Decoration", selection: $decorationTab) {
                    Text("Color").tag(DecorationTab.color)
                    Text("Icon").tag(DecorationTab.icon)
                }
                .pickerStyle(.segmented)

                switch decorationTab {
                case .color:
                    // The nine primary dots; the full 26-swatch grid lives in
                    // the New Folder sheet.
                    HStack(spacing: 8) {
                        ForEach(LibraryStyle.primaryDots, id: \.self) { hex in
                            dot(hex, current: decoration)
                        }
                    }
                case .icon:
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(30)), count: 7),
                        spacing: 8
                    ) {
                        ForEach(LibraryStyle.folderGlyphs, id: \.self) { glyph in
                            glyphButton(glyph, current: decoration)
                        }
                    }
                }
            }

            Divider()

            if decoration == nil {
                // Documents only: the observed folder menu has no Duplicate
                // (spec §6.5, `03-review.md` UX-9) — a folder duplicate is a
                // tree copy this design deliberately does not build tonight.
                Button {
                    let target = item
                    let listing = model
                    Task { await listing.duplicate(target) }
                    dismiss()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.item.duplicate")
            }

            Button {
                dismiss()
                onMove()
            } label: {
                Label("Move", systemImage: "folder")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.item.move")

            // Recoverable, so no confirmation — platform convention; the
            // permanent deletes confirm on the Trash screen.
            Button(role: .destructive) {
                let target = item
                let listing = model
                Task {
                    await listing.trash(target)
                }
                dismiss()
            } label: {
                Label("Move to Trash", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
        .onDisappear {
            // Inline rename commits on dismiss. A refusal at this point has
            // no popover left to show it, so it surfaces in the listing's
            // banner instead of vanishing.
            commitRenameOnDismiss()
        }
    }

    private func dot(_ hex: String, current: FolderDecoration) -> some View {
        let selected = (current.color ?? LibraryStyle.defaultFolderHex) == hex
        return Button {
            var next = current
            next.color = hex
            let target = item
            let listing = model
            Task { await listing.setDecoration(next, for: target) }
        } label: {
            ZStack {
                Circle()
                    .fill(LibraryStyle.color(fromHex: hex))
                    .frame(width: 24, height: 24)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func glyphButton(_ glyph: String, current: FolderDecoration) -> some View {
        let selected = current.icon == glyph
        return Button {
            var next = current
            // Re-tapping the active glyph clears it: a folder with no icon is
            // a designed state, not an unreachable one.
            next.icon = selected ? nil : glyph
            let target = item
            let listing = model
            Task { await listing.setDecoration(next, for: target) }
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 15))
                .frame(width: 28, height: 28)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .background(
                    selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }

    /// Return key: commit while the popover is still up, so `invalidName`
    /// shows inline and the popover stays for the correction.
    private func commitRenameInline() {
        let proposed = name
        guard proposed != item.name else { return }
        let target = item
        let listing = model
        Task {
            if let reason = await listing.rename(target, to: proposed) {
                inlineError = reason
            } else {
                committed = true
                inlineError = nil
                dismiss()
            }
        }
    }

    private func commitRenameOnDismiss() {
        let proposed = name
        guard !committed, proposed != item.name else { return }
        let target = item
        let listing = model
        Task {
            if let reason = await listing.rename(target, to: proposed) {
                listing.mutationBanner = "\(target.name) was not renamed. \(reason)."
            }
        }
    }
}

/// The + New popover, in the observed band grammar at tonight's cardinality:
/// the Notebook square tile in the top band, the Import wide tile in the
/// middle band (spec §5.1's row 2), Folder in its own card at the bottom.
struct LibraryNewPopover: View {
    /// Nil while a dirty session drains — the notebook and import tiles both
    /// open a document and opening is blocked; folders stay available.
    let notebookBlockedReason: String?
    let onNotebook: () -> Void
    let onImport: () -> Void
    let onFolder: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            // Top band: the Notebook square tile.
            HStack {
                Button {
                    dismiss()
                    onNotebook()
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 26))
                        Text("Notebook")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .frame(width: 104, height: 96)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(notebookBlockedReason != nil)
                .opacity(notebookBlockedReason == nil ? 1 : 0.4)
                .accessibilityIdentifier("library.new.notebook")
                Spacer()
            }

            // Middle band: the Import wide tile. Blocked with the notebook
            // tile — an import ends in an open document.
            Button {
                dismiss()
                onImport()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 18))
                    Text("Import")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                }
                .padding(14)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(notebookBlockedReason != nil)
            .opacity(notebookBlockedReason == nil ? 1 : 0.4)
            .accessibilityIdentifier("library.new.import")

            // Bottom band: Folder in its own card.
            Button {
                dismiss()
                onFolder()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 18))
                    Text("Folder")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                }
                .padding(14)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.new.folder")
        }
        .padding(16)
        .frame(width: 360)
        .presentationCompactAdaptation(.popover)
    }
}
