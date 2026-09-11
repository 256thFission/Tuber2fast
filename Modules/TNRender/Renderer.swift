import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PencilKit
import TNCore
import TNFormat
import TNModel

/// Composites and thumbnails, off the main actor. A composite is paper plus
/// every static layer as pixels; the ink is never in it.
///
/// Cache: decoded assets by reference. Owner: this actor. Bound:
/// `assetCacheBound` bytes, evicting oldest first. Evictor: `trimCache`,
/// on insert and on memory pressure from the app.
package actor Renderer {
    package static let maximumLongEdgePixels: CGFloat = 2800
    package static let assetCacheBound = 48 * 1024 * 1024

    private let assets: any AssetReading
    private var decoded: [AssetRef: DecodedAsset] = [:]
    private var order: [AssetRef] = []
    private var cachedBytes = 0

    private enum DecodedAsset {
        case image(CGImage, bytes: Int)
        case pdf(PDFSource, bytes: Int)
        var bytes: Int {
            switch self {
            case .image(_, let bytes), .pdf(_, let bytes): bytes
            }
        }
    }

    package init(assets: any AssetReading) {
        self.assets = assets
    }

    package func purge() {
        decoded.removeAll()
        order.removeAll()
        cachedBytes = 0
    }

    /// The scale that fits the long edge under the pixel cap, no more than
    /// `requested`.
    package static func cappedScale(for geometry: PageGeometry, requested: CGFloat) -> CGFloat {
        let longEdge = max(geometry.width, geometry.height)
        return min(requested, maximumLongEdgePixels / longEdge)
    }

    /// Paper and layers at `scale` pixels per point, capped.
    package func composite(geometry: PageGeometry, paper: Paper?, layers: [Layer], scale requested: CGFloat) async -> Composite? {
        let scale = Self.cappedScale(for: geometry, requested: requested)
        let width = Int((geometry.width * scale).rounded(.up)), height = Int((geometry.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Page space: origin top-left, y down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height))
        await draw(paper ?? .drawn(.blank), geometry: geometry, in: context)
        for layer in layers {
            await draw(layer, in: context)
        }
        guard let image = context.makeImage() else { return nil }
        return Composite(image: image, scale: scale)
    }

    /// The page's paper. An asset fills the page rectangle exactly: the
    /// geometry was set from the asset's aspect when the paper was applied,
    /// so filling is not stretching.
    private func draw(_ paper: Paper, geometry: PageGeometry, in context: CGContext) async {
        switch paper {
        case .drawn(let drawn):
            PaperRenderer.draw(drawn, geometry: geometry, in: context)
        case .image(let ref):
            guard case .image(let image, _)? = await decodedAsset(ref) else { return }
            context.saveGState()
            // CGImage draws y-up; flip within the page rectangle.
            context.translateBy(x: 0, y: geometry.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height))
            context.restoreGState()
        case .pdf(let ref, let sourcePageIndex):
            guard case .pdf(let source, _)? = await decodedAsset(ref),
                  let page = source.page(at: sourcePageIndex),
                  let extent = PDFSource.displayExtent(of: page)
            else { return }
            context.saveGState()
            context.concatenate(CGAffineTransform(scaleX: geometry.width, y: geometry.height))
            PDFSource.draw(page, extent: extent, in: context)
            context.restoreGState()
        }
    }

    /// Height over width of an asset paper, from the decoded asset. Drawn
    /// paper has no aspect of its own.
    package func aspect(of paper: Paper) async -> Double? {
        switch paper {
        case .drawn:
            return nil
        case .image(let ref):
            guard case .image(let image, _)? = await decodedAsset(ref), image.width > 0 else { return nil }
            return Double(image.height) / Double(image.width)
        case .pdf(let ref, let sourcePageIndex):
            guard case .pdf(let source, _)? = await decodedAsset(ref),
                  let page = source.page(at: sourcePageIndex),
                  let extent = PDFSource.displayExtent(of: page), extent.width > 0
            else { return nil }
            return extent.height / extent.width
        }
    }

    /// A page's composite and its ink as one HEIC at asset resolution: the
    /// long edge at `maximumLongEdgePixels`, which is what a flattened page
    /// becomes as paper. The page it renders is not changed.
    package func flattened(geometry: PageGeometry, paper: Paper?, layers: [Layer], ink: PKDrawing) async -> Data? {
        let scale = Self.cappedScale(for: geometry, requested: .greatestFiniteMagnitude)
        guard let composite = await composite(geometry: geometry, paper: paper, layers: layers, scale: scale) else { return nil }
        let pageRect = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        // PencilKit rasterizes the ink itself, off this actor and off the
        // main one: a flatten is an intention, never a frame.
        let inkImage = await Task.detached(priority: .userInitiated) { () -> Composite? in
            guard let image = ink.image(from: pageRect, scale: scale).cgImage else { return nil }
            return Composite(image: image, scale: scale)
        }.value
        let width = composite.image.width, height = composite.image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let pixels = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(composite.image, in: pixels)
        if let inkImage { context.draw(inkImage.image, in: pixels) }
        guard let image = context.makeImage() else { return nil }
        return Self.heic(image)
    }

    private static func heic(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func draw(_ layer: Layer, in context: CGContext) async {
        let t = layer.transform
        let affine = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
        switch layer.payload {
        case .image(let image):
            guard case .image(let cgImage, _)? = await decodedAsset(image.asset) else { return }
            context.saveGState()
            context.concatenate(affine)
            // CGImage draws y-up; flip inside the unit square.
            context.translateBy(x: 0, y: 1)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            context.restoreGState()
        case .pdf(let pdf):
            guard case .pdf(let source, _)? = await decodedAsset(pdf.asset), let page = source.page(at: pdf.sourcePageIndex) else { return }
            guard PDFSource.displayExtent(of: page) == pdf.sourceExtent else {
                TNLog.event(.format, "pdf layer \(layer.id) extent disagrees with the asset; not drawn")
                return
            }
            context.saveGState()
            context.concatenate(affine)
            PDFSource.draw(page, extent: pdf.sourceExtent, in: context)
            context.restoreGState()
        case .link(let link):
            let rect = CGRect(x: link.rect.x, y: link.rect.y, width: link.rect.width, height: link.rect.height)
            context.saveGState()
            context.setFillColor(CGColor(srgbRed: 0.17, green: 0.44, blue: 0.76, alpha: 0.15))
            context.setStrokeColor(CGColor(srgbRed: 0.17, green: 0.44, blue: 0.76, alpha: 1))
            context.setLineWidth(1)
            let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            context.addPath(path); context.fillPath()
            context.addPath(path); context.strokePath()
            context.restoreGState()
            Self.drawText(TextLayer(rect: link.rect, runs: [TextRun(string: "Link", size: 13, color: "#2B70C2FF")], alignment: .center), in: context)
        case .text(let text):
            Self.drawText(text, in: context)
        }
    }

    /// One builder with the live text view, so the two engines lay the same
    /// runs on the same lines. The frame is the rect with no inset; the
    /// overlay copies that geometry.
    private static func drawText(_ text: TextLayer, in context: CGContext) {
        let attributed = TextTypesetting.attributed(text.runs, alignment: text.alignment)
        let rect = CGRect(x: text.rect.x, y: text.rect.y, width: text.rect.width, height: text.rect.height)
        context.saveGState()
        // CoreText draws y-up; flip within the rect.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func decodedAsset(_ ref: AssetRef) async -> DecodedAsset? {
        if let cached = decoded[ref] { return cached }
        let data: Data
        do { data = try await assets.readAsset(ref) } catch { return nil }
        let asset: DecodedAsset
        switch ref.format {
        case .heic:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
            else { return nil }
            asset = .image(image, bytes: image.bytesPerRow * image.height)
        case .pdf:
            guard let source = PDFSource(data: data) else { return nil }
            asset = .pdf(source, bytes: data.count)
        }
        decoded[ref] = asset
        order.append(ref)
        cachedBytes += asset.bytes
        trimCache()
        return asset
    }

    private func trimCache() {
        while cachedBytes > Self.assetCacheBound, let oldest = order.first {
            order.removeFirst()
            if let removed = decoded.removeValue(forKey: oldest) { cachedBytes -= removed.bytes }
        }
    }
}

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
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, upright, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Normalized(heic: output as Data, size: PixelSize(width: upright.width, height: upright.height))
    }

    private static func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        let rotated = [CGImagePropertyOrientation.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let width = rotated ? image.height : image.width, height = rotated ? image.width : image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
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
