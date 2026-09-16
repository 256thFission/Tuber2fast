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
    @Environment(\.macaron) private var theme

    let editor: EditorViewModel

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: Macaron.columnGap)]

    /// Three chips high and wide: the chip is the document's size class for a
    /// pressable square, and a 44pt symbol over its name needs three of them.
    private static let cap = Macaron.chip * 3

    var body: some View {
        MacaronPanel(title: "Stickers", onClose: { dismiss() }) {
            LazyVGrid(columns: columns, spacing: Macaron.columnGap + Macaron.chipWall) {
                ForEach(StickerCatalogue.all) { sticker in
                    Keycap(
                        fill: theme.chrome,
                        size: CGSize(width: Self.cap, height: Self.cap),
                        action: {
                            dismiss()
                            Task { await editor.importSticker(sticker) }
                        }
                    ) {
                        VStack(spacing: Macaron.rowGap) {
                            // The sticker's own two colours, which are what it
                            // will be once it is on the page: content, not
                            // chrome, and so not the theme's to set.
                            Image(systemName: sticker.symbol)
                                .font(.system(size: 44))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Self.color(sticker.primary), Self.color(sticker.secondary))
                                .frame(width: 64, height: 64)
                            Text(sticker.title)
                                .font(Macaron.body(11))
                                .lineLimit(1)
                        }
                    }
                    .accessibilityLabel(sticker.title)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private static func color(_ rgba: RGBA8) -> Color {
        Color(red: Double(rgba.red) / 255, green: Double(rgba.green) / 255, blue: Double(rgba.blue) / 255)
    }
}
