import SwiftUI
import TNEditor
import TNModel

/// The built-in stickers, as a grid. A tap places one on the current page
/// through the photo's own insert and closes the sheet; the frame that
/// moves it is the lasso's, as it is for a photo.
///
/// The cells draw the symbol directly rather than the PNG the catalogue
/// renders: twenty renders on every open of the sheet would be twenty
/// megabyte-sized bitmaps for a grid of 64-point icons.
struct StickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let editor: EditorViewModel

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(StickerCatalogue.all) { sticker in
                        Button {
                            dismiss()
                            Task { await editor.importSticker(sticker) }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: sticker.symbol)
                                    .font(.system(size: 44))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Self.color(sticker.primary), Self.color(sticker.secondary))
                                    .frame(width: 64, height: 64)
                                Text(sticker.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(sticker.title)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private static func color(_ rgba: RGBA8) -> Color {
        Color(red: Double(rgba.red) / 255, green: Double(rgba.green) / 255, blue: Double(rgba.blue) / 255)
    }
}
