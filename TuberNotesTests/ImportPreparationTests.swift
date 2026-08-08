import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import TuberNotes

/// The import UI's data half, and above all the EXIF hole
/// (`Docs/Forks/ReviewFindings.md`, finding 8): `importImage` trusts the
/// caller's extent while the renderer decodes with orientation applied, so the
/// caller must pass the orientation-applied extent. These are the first tests
/// in the suite that feed any asset whose EXIF orientation is not 1.
///
/// The picker presentations themselves are device-only: no headless test can
/// drive PHPicker or the Files picker. What is pinned here is everything
/// between the picked bytes and the saved transform.
@Suite("Import preparation")
struct ImportPreparationTests {

    // MARK: - Fixtures

    /// A real encoded image: `width` × `height` pixels of solid color, in
    /// `type`, carrying `orientation` as metadata when given.
    private func encodedImage(
        width: Int,
        height: Int,
        type: UTType,
        orientation: Int? = nil
    ) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let encoded = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil)
        )
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    /// A PNG whose left half is opaque and whose right half is fully
    /// transparent — a cut-out, the shape of source the old transcode-to-JPEG
    /// path destroyed.
    private func halfTransparentPNG(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(context.makeImage())

        let encoded = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    /// What ImageIO reports about encoded bytes: pixel extent as stored, and
    /// the orientation tag if any.
    private func reported(_ bytes: Data) throws -> (width: Int, height: Int, orientation: Int?) {
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return (
            width: try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue),
            height: try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue),
            orientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        )
    }

    // MARK: - The EXIF hole

    @Test("A HEIC with EXIF orientation 6 reports the rotated extent and keeps its bytes")
    func exifOrientation6ReportsTheRotatedExtent() throws {
        // 100 × 50 as stored; orientation 6 (90° CW) means it *displays* as
        // 50 × 100. The renderer decodes with the transform applied, so the
        // prepared extent must be the displayed one.
        //
        // A HEIC source, because that is now the one source kind whose bytes
        // pass through: the orientation must be read out of metadata rather
        // than baked by a re-encode, which is the case that can go wrong
        // silently.
        let heic = try encodedImage(width: 100, height: 50, type: .heic, orientation: 6)
        #expect(try reported(heic).orientation == 6, "the fixture must genuinely carry EXIF 6")

        let prepared = try ImageImportPreparation.prepare(heic)
        #expect(prepared.format == .heic)
        #expect(prepared.bytes == heic, "a heic source keeps its original bytes")
        #expect(prepared.orientedPixelWidth == 50)
        #expect(prepared.orientedPixelHeight == 100)
    }

    @Test("The orientation-applied extent reaches the saved transform, at the import seam")
    @MainActor
    func exifExtentReachesTheSavedTransform() async throws {
        let scratch = try TestScratch("import")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let pageID = session.currentPageID

        // The full path the import UI takes: prepared extent in, transform out.
        let heic = try encodedImage(width: 100, height: 50, type: .heic, orientation: 6)
        let prepared = try ImageImportPreparation.prepare(heic)
        let layerID = try await session.importImage(
            prepared.bytes,
            format: prepared.format,
            sourceWidth: prepared.orientedPixelWidth,
            sourceHeight: prepared.orientedPixelHeight
        )
        #expect(session.lastSaveError == nil)

        let layers = try scratch.layersOnDisk(ofPage: pageID)
        let placed = try #require(layers.first { $0.layerID == layerID }).pageSpaceTransform

        // `fittingSource` preserves the source's aspect ratio, so the placed
        // extent states which extent was trusted. Orientation applied: the
        // image is twice as tall as wide (d == 2a). Had the raw stored
        // dimensions leaked through, it would be twice as wide as tall
        // (d == a / 2) — durably stretched, which is finding 8's failure.
        #expect(placed.d == placed.a * 2)
        #expect(placed.a > 0)
    }

    // MARK: - One image format

    @Test("A HEIC passes through untouched with its raw extent")
    func heicPassesThrough() throws {
        let heic = try encodedImage(width: 64, height: 32, type: .heic)
        let prepared = try ImageImportPreparation.prepare(heic)
        #expect(prepared.format == .heic)
        #expect(prepared.bytes == heic, "already in the one durable format: no lossy generation")
        #expect(prepared.orientedPixelWidth == 64)
        #expect(prepared.orientedPixelHeight == 32)
    }

    @Test("Every other format transcodes to an upright HEIC", arguments: [UTType.png, .jpeg, .tiff])
    func otherFormatsTranscodeToUprightHEIC(_ type: UTType) throws {
        // Three sources, one destination — that is the whole of
        // `image-format-is-heic` at this seam. PNG and JPEG are in the list
        // because they used to be pass-throughs: the narrowing is only real if
        // they now transcode like anything else. Orientation 6 as well, so the
        // transcode must both re-encode and apply the transform.
        let source = try encodedImage(width: 100, height: 50, type: type, orientation: 6)

        let prepared = try ImageImportPreparation.prepare(source)
        #expect(prepared.format == .heic)
        #expect(prepared.bytes != source)
        #expect(prepared.orientedPixelWidth == 50)
        #expect(prepared.orientedPixelHeight == 100)

        // The written pixels are upright: stored extent equals the oriented
        // extent, and no transposing orientation tag survives to be applied
        // a second time by the renderer.
        let output = try reported(prepared.bytes)
        #expect(output.width == 50)
        #expect(output.height == 100)
        #expect((output.orientation ?? 1) == 1)

        let outputType = CGImageSourceCreateWithData(prepared.bytes as CFData, nil)
            .flatMap(CGImageSourceGetType)
            .flatMap { UTType($0 as String) }
        #expect(outputType?.conforms(to: .heic) == true)
    }

    // MARK: - The defect the narrowing closes

    @Test("A transparent PNG keeps its transparency through the transcode")
    func transparencySurvivesTheImportTranscode() throws {
        // The alpha-flattening defect, at the seam it used to happen at: this
        // path transcoded everything unfamiliar to JPEG, and assets are
        // write-once, so a cut-out imported through the Files picker lost its
        // transparent regions permanently. `HEICAlphaTests` pins the codec;
        // this pins that the *import path* actually reaches it.
        let png = try halfTransparentPNG(width: 64, height: 64)
        let prepared = try ImageImportPreparation.prepare(png)
        #expect(prepared.format == .heic)

        let decoded = try #require(
            StaticLayerRenderer.downsample(prepared.bytes, maxPixelSize: 64)
        )
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(
            CGContext(
                data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        // The transparent half, sampled away from the seam.
        context.translateBy(x: -CGFloat(decoded.width - 8), y: CGFloat(1 - decoded.height / 2))
        context.draw(
            decoded,
            in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
        )
        #expect(bytes[3] == 0, "the imported asset baked the transparency into opaque pixels")
    }

    @Test("Bytes that are not an image are refused, not defaulted")
    func garbageIsRefused() {
        #expect(throws: ImageImportError.undecodableImage) {
            _ = try ImageImportPreparation.prepare(Data([0x00, 0x01, 0x02, 0x03]))
        }
    }
}
