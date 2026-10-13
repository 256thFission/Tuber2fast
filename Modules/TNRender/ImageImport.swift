import CoreGraphics
import Foundation
import ImageIO
import TNModel

/// Import-time normalization: any image becomes an upright HEIC with its
/// pixel size known; a PDF is kept as received and its pages measured.
package enum ImageImport {
    package struct Normalized: Sendable {
        package let heic: Data
        package let size: PixelSize
    }

    package static func normalize(_ data: Data) -> Normalized? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // Orientation: bake it in so the stored pixels are upright.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let upright = Self.upright(image, orientation: orientation) ?? image
        guard let heic = Renderer.encode(upright, as: "public.heic" as CFString) else { return nil }
        return Normalized(heic: heic, size: PixelSize(width: upright.width, height: upright.height))
    }

    private static func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        let rotated = [CGImagePropertyOrientation.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let width = rotated ? image.height : image.width, height = rotated ? image.width : image.height
        guard let context = Renderer.bitmap(width: width, height: height) else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        switch orientation {
        case .down, .downMirrored: context.rotate(by: .pi)
        case .left, .leftMirrored: context.rotate(by: .pi / 2)
        case .right, .rightMirrored: context.rotate(by: -.pi / 2)
        default: break
        }
        if [.upMirrored, .downMirrored, .leftMirrored, .rightMirrored].contains(orientation) { context.scaleBy(x: -1, y: 1) }
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }
}
