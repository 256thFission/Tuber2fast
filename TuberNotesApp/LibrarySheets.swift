import SwiftUI
import TuberStore

/// The one reusable modal shell (UX-5/UX-6): circular X top-left, centered
/// title, blue circular check top-right, content beneath.
struct LibraryModalShell<Content: View>: View {
    let title: String
    let onConfirm: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color(white: 0.2), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")

                    Spacer()

                    Button(action: onConfirm) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.blue, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Done")
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(20)

            content()

            Spacer(minLength: 0)
        }
        .background(Color(white: 0.09))
        .preferredColorScheme(.dark)
    }
}

/// The New Folder sheet, the observed sheet's skeleton: live preview
/// tracking the selection, centered "Untitled" field, Color|Icon segmented
/// control, 26 swatches plus the custom wheel in the 9×3 layout, and an
/// SF-symbol grid on the Icon tab (our glyph set — GoodNotes' is unobserved).
struct NewFolderSheet: View {
    let model: FolderListingModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var decoration = FolderDecoration()
    @State private var tab: Tab = .color
    @State private var customColor: Color = .blue

    private enum Tab: Hashable { case color, icon }

    var body: some View {
        LibraryModalShell(title: "New Folder", onConfirm: create) {
            VStack(spacing: 24) {
                // The live preview: the folder exactly as the grid will
                // render it, tracking color and icon as they change.
                ZStack {
                    Image(systemName: "folder.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 190)
                        .foregroundStyle(LibraryStyle.folderColor(decoration))
                    if let icon = decoration.icon {
                        Image(systemName: icon)
                            .font(.system(size: 52, weight: .medium))
                            .foregroundStyle(.white)
                            .offset(y: 14)
                    }
                }
                .padding(.top, 30)

                TextField("Untitled", text: $name)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 22))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 620)
                    .submitLabel(.done)
                    .onSubmit(create)

                Picker("Decoration", selection: $tab) {
                    Text("Color").tag(Tab.color)
                    Text("Icon").tag(Tab.icon)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                switch tab {
                case .color:
                    swatchGrid
                case .icon:
                    glyphGrid
                }
            }
            .padding(.horizontal, 40)
        }
        .accessibilityIdentifier("library.sheet.newfolder")
    }

    /// 9×3: 26 swatches, the custom ColorPicker wheel in slot 27.
    private var swatchGrid: some View {
        VStack(spacing: 14) {
            ForEach(Array(LibraryStyle.paletteRows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 20) {
                    ForEach(row, id: \.self) { hex in
                        swatch(hex)
                    }
                    if index == LibraryStyle.paletteRows.count - 1 {
                        ColorPicker("Custom color", selection: $customColor, supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 28, height: 28)
                            .onChange(of: customColor) { _, next in
                                decoration.color = LibraryStyle.hex(from: next)
                            }
                    }
                }
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        let selected = (decoration.color ?? LibraryStyle.defaultFolderHex) == hex
        return Button {
            decoration.color = hex
        } label: {
            ZStack {
                Circle()
                    .fill(LibraryStyle.color(fromHex: hex))
                    .frame(width: 28, height: 28)
                if selected {
                    Circle().fill(Color.black.opacity(0.25)).frame(width: 28, height: 28)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var glyphGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 7), spacing: 14) {
            ForEach(LibraryStyle.folderGlyphs, id: \.self) { glyph in
                let selected = decoration.icon == glyph
                Button {
                    decoration.icon = selected ? nil : glyph
                } label: {
                    Image(systemName: glyph)
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .background(
                            selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(white: 0.18)),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func create() {
        // An empty field takes the placeholder, exactly as it reads: the name
        // gate refuses genuinely empty names, and "Untitled" is what the
        // sheet promised.
        let chosen = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = chosen.isEmpty ? "Untitled" : chosen
        let listing = model
        let chosenDecoration = decoration
        Task { await listing.createFolder(named: finalName, decoration: chosenDecoration) }
        dismiss()
    }
}

/// The New Notebook sheet's surviving skeleton (UX-6): left paper preview,
/// Name row, Size row showing the canonical size with its chevron — inert
/// tonight, the size popover defers; Language and Cover are deliberately
/// not built.
struct NewNotebookSheet: View {
    /// Creates and opens; failures surface in the listing's banner.
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        LibraryModalShell(title: "New Notebook", onConfirm: create) {
            HStack(alignment: .top, spacing: 28) {
                // The left paper panel: the cream canonical page.
                VStack(spacing: 12) {
                    Text("PAPER")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LibraryStyle.paper)
                        .frame(width: 170, height: 224)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    Text("Blank")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 16))

                VStack(spacing: 1) {
                    HStack {
                        Text("Name")
                            .font(.system(size: 16))
                        Spacer()
                        TextField("Untitled Notebook", text: $name)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 300)
                            .submitLabel(.done)
                            .onSubmit(create)
                    }
                    .padding(16)
                    .background(Color(white: 0.15))

                    HStack {
                        Text("Size")
                            .font(.system(size: 16))
                        Spacer()
                        // Inert tonight: the row states the one size that
                        // exists; the picker arrives with the template lane.
                        Text("TuberNotes Standard, Portrait")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color(white: 0.15))
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: 560)
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)
        }
        .accessibilityIdentifier("library.sheet.newnotebook")
    }

    private func create() {
        let chosen = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(chosen.isEmpty ? "Untitled Notebook" : chosen)
        dismiss()
    }
}
