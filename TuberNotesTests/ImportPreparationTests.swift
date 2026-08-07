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

    @Test("A JPEG with EXIF orientation 6 reports the rotated extent and keeps its bytes")
    func exifOrientation6ReportsTheRotatedExtent() throws {
        // 100 × 50 as stored; orientation 6 (90° CW) means it *displays* as
        // 50 × 100. The renderer decodes with the transform applied, so the
        // prepared extent must be the displayed one.
        let jpeg = try encodedImage(width: 100, height: 50, type: .jpeg, orientation: 6)
        #expect(try reported(jpeg).orientation == 6, "the fixture must genuinely carry EXIF 6")

        let prepared = try ImageImportPreparation.prepare(jpeg)
        #expect(prepared.format == .jpeg)
        #expect(prepared.bytes == jpeg, "a jpeg source keeps its original bytes")
        #expect(prepared.orientedPixelWidth == 50)
        #expect(prepared.orientedPixelHeight == 100)
    }

    @Test("The orientation-applied extent reaches the saved transform, at the import seam")
    @MainActor
    func exifExtentReachesTheSavedTransform() async throws {
        let scratch = try Scratch()
        let session = EditorSession(store: scratch.store(), debounce: .milliseconds(20))
        await session.start()
        let pageID = session.currentPageID

        // The full path the import UI takes: prepared extent in, transform out.
        let jpeg = try encodedImage(width: 100, height: 50, type: .jpeg, orientation: 6)
        let prepared = try ImageImportPreparation.prepare(jpeg)
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

    // MARK: - The closed format set

    @Test("A PNG passes through untouched with its raw extent")
    func pngPassesThrough() throws {
        let png = try encodedImage(width: 64, height: 32, type: .png)
        let prepared = try ImageImportPreparation.prepare(png)
        #expect(prepared.format == .png)
        #expect(prepared.bytes == png)
        #expect(prepared.orientedPixelWidth == 64)
        #expect(prepared.orientedPixelHeight == 32)
    }

    @Test("A format outside the closed set transcodes to an upright JPEG")
    func otherFormatsTranscodeToUprightJPEG() throws {
        // TIFF stands in for HEIC: the simulator has no HEIC hardware
        // encoder, and the path under test is "decodable but not png/jpeg",
        // which both take. Orientation 6 as well, so the transcode must both
        // re-encode and apply the transform.
        let tiff = try encodedImage(width: 100, height: 50, type: .tiff, orientation: 6)

        let prepared = try ImageImportPreparation.prepare(tiff)
        #expect(prepared.format == .jpeg)
        #expect(prepared.bytes != tiff)
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
        #expect(outputType?.conforms(to: .jpeg) == true)
    }

    @Test("Bytes that are not an image are refused, not defaulted")
    func garbageIsRefused() {
        #expect(throws: ImageImportError.undecodableImage) {
            _ = try ImageImportPreparation.prepare(Data([0x00, 0x01, 0x02, 0x03]))
        }
    }

    // MARK: - Scratch

    /// A unique document directory per test, the same shape the other suites
    /// use, holding only what these tests read.
    private final class Scratch {
        let root: URL

        var documentURL: URL { root.appendingPathComponent("JustACanvas.tubernotes") }
        var pagesURL: URL { documentURL.appendingPathComponent("pages") }
        var layersURL: URL { documentURL.appendingPathComponent("layers") }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-import-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: pagesURL, withIntermediateDirectories: true
            )
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func store() -> DocumentStore { DocumentStore(directoryURL: documentURL) }

        /// One page's layer envelopes as they are on disk, read the way the
        /// store reads them.
        func layersOnDisk(ofPage pageID: UUID) throws -> [LayerEnvelope] {
            let page = try PropertyListDecoder().decode(
                PageFile.self,
                from: Data(contentsOf: pagesURL.appendingPathComponent("\(pageID.uuidString).plist"))
            )
            if let inline = page.inlineLayers { return inline }
            return try page.layerIDs.map { layerID in
                try PropertyListDecoder().decode(
                    LayerEnvelope.self,
                    from: Data(
                        contentsOf: layersURL.appendingPathComponent("\(layerID.uuidString).plist")
                    )
                )
            }
        }
    }
}
