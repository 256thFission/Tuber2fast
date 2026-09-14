import TNModel
import UIKit

/// One built-in sticker: an SF Symbol and the two palette colours it is
/// drawn in. There is no sticker file anywhere: the picture is rendered
/// from the symbol on the tap that places it, and from then on it is an
/// image layer with a HEIC asset like any photo.
package struct Sticker: Identifiable, Sendable, Equatable {
    package let symbol: String
    package let title: String
    package let primary: RGBA8
    package let secondary: RGBA8

    package var id: String { symbol }
}

/// The set the Insert menu offers, and the one way to turn one into bytes.
///
/// Rendered at runtime rather than shipped as PNGs because it is the
/// smaller of the two: no assets in the bundle, no build script under
/// `Tools/` that has to run before the bundle is right, and no resource
/// entry in `project.yml`. The symbol font is already on the device.
package enum StickerCatalogue {
    /// Symbols that every device this app runs on has: nothing here is
    /// newer than SF Symbols 5.
    package static let all: [Sticker] = [
        Sticker(symbol: "star.fill", title: "Star", primary: .stickerAmber, secondary: .stickerAmber),
        Sticker(symbol: "heart.fill", title: "Heart", primary: .stickerRose, secondary: .stickerRose),
        Sticker(symbol: "checkmark.circle.fill", title: "Done", primary: .stickerWhite, secondary: .stickerGreen),
        Sticker(symbol: "xmark.circle.fill", title: "No", primary: .stickerWhite, secondary: .stickerRose),
        Sticker(symbol: "exclamationmark.triangle.fill", title: "Warning", primary: .stickerInk, secondary: .stickerAmber),
        Sticker(symbol: "questionmark.circle.fill", title: "Question", primary: .stickerWhite, secondary: .stickerBlue),
        Sticker(symbol: "lightbulb.fill", title: "Idea", primary: .stickerAmber, secondary: .stickerAmber),
        Sticker(symbol: "flag.fill", title: "Flag", primary: .stickerRose, secondary: .stickerRose),
        Sticker(symbol: "pin.fill", title: "Pin", primary: .stickerBlue, secondary: .stickerBlue),
        Sticker(symbol: "bookmark.fill", title: "Bookmark", primary: .stickerViolet, secondary: .stickerViolet),
        Sticker(symbol: "bolt.fill", title: "Bolt", primary: .stickerAmber, secondary: .stickerAmber),
        Sticker(symbol: "flame.fill", title: "Flame", primary: .stickerOrange, secondary: .stickerOrange),
        Sticker(symbol: "sun.max.fill", title: "Sun", primary: .stickerAmber, secondary: .stickerAmber),
        Sticker(symbol: "moon.stars.fill", title: "Night", primary: .stickerViolet, secondary: .stickerAmber),
        Sticker(symbol: "cloud.rain.fill", title: "Rain", primary: .stickerGrey, secondary: .stickerBlue),
        Sticker(symbol: "leaf.fill", title: "Leaf", primary: .stickerGreen, secondary: .stickerGreen),
        Sticker(symbol: "hand.thumbsup.fill", title: "Thumbs up", primary: .stickerBlue, secondary: .stickerBlue),
        Sticker(symbol: "face.smiling.fill", title: "Smile", primary: .stickerInk, secondary: .stickerAmber),
        Sticker(symbol: "sparkles", title: "Sparkles", primary: .stickerViolet, secondary: .stickerViolet),
        Sticker(symbol: "trophy.fill", title: "Trophy", primary: .stickerAmber, secondary: .stickerAmber),
    ]

    /// The rendered edge, in pixels. Big enough that a sticker scaled up to
    /// the page's width on a 2800-pixel composite is still crisp.
    package static let edgePixels = 512

    /// The sticker as a PNG with transparency: the symbol at its point size,
    /// centred on a square, and nothing behind it. Nil only if UIKit has no
    /// such symbol, which the catalogue test rules out for every entry.
    @MainActor package static func png(_ sticker: Sticker) -> Data? {
        let configuration = UIImage.SymbolConfiguration(pointSize: CGFloat(edgePixels) * 0.7, weight: .regular)
            .applying(UIImage.SymbolConfiguration(paletteColors: [sticker.primary.uiColor, sticker.secondary.uiColor]))
        guard let symbol = UIImage(systemName: sticker.symbol, withConfiguration: configuration) else { return nil }
        let edge = CGFloat(edgePixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format).image { _ in
            let fit = min(edge / symbol.size.width, edge / symbol.size.height, 1)
            let size = CGSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
            symbol.draw(in: CGRect(x: (edge - size.width) / 2, y: (edge - size.height) / 2, width: size.width, height: size.height))
        }
        return rendered.pngData()
    }
}

extension RGBA8 {
    fileprivate static let stickerAmber = RGBA8(red: 0xF5, green: 0xA6, blue: 0x23, alpha: 0xFF)
    fileprivate static let stickerRose = RGBA8(red: 0xE5, green: 0x39, blue: 0x5F, alpha: 0xFF)
    fileprivate static let stickerGreen = RGBA8(red: 0x34, green: 0xA8, blue: 0x53, alpha: 0xFF)
    fileprivate static let stickerBlue = RGBA8(red: 0x2F, green: 0x80, blue: 0xED, alpha: 0xFF)
    fileprivate static let stickerViolet = RGBA8(red: 0x8E, green: 0x5C, blue: 0xD9, alpha: 0xFF)
    fileprivate static let stickerOrange = RGBA8(red: 0xF0, green: 0x6A, blue: 0x2A, alpha: 0xFF)
    fileprivate static let stickerGrey = RGBA8(red: 0x9A, green: 0xA3, blue: 0xAD, alpha: 0xFF)
    fileprivate static let stickerInk = RGBA8(red: 0x2B, green: 0x2B, blue: 0x2B, alpha: 0xFF)
    fileprivate static let stickerWhite = RGBA8(red: 0xFF, green: 0xFF, blue: 0xFF, alpha: 0xFF)

    fileprivate var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
    }
}
