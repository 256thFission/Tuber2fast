import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TuberModel
@testable import TuberNotes
@testable import TuberRender
import UniformTypeIdentifiers

/// The pin under `image-format-is-heic` (`Docs/Queue.md`): HEIC is only allowed
/// to be the one image format because it carries transparency, so that claim is
/// checked here before any import path is allowed to depend on it.
///
/// Assets are write-once. A format that flattens alpha does not produce a
/// recoverable mistake — it produces a document that has permanently lost the
/// transparent regions of an imported cut-out, which is the very defect
/// consolidating on HEIC is meant to close in the transcode-to-JPEG path. So
/// the round trip that matters is the whole one: this build's encoder, this
/// build's decoder, alpha still there at the end.
///
/// This runs in the simulator, deliberately. The simulator's HEVC encode is a
/// software path where a device has a hardware one; what is pinned here is that
/// ImageIO writes and reads the alpha auxiliary image at all, which is a format
/// and framework question, not a silicon one. Whether the hardware encoder
/// agrees remains a device-evidence obligation, as `AGENTS.md` requires of any
/// claim green CI cannot make.
@Suite("HEIC alpha")
struct HEICAlphaTests {

    /// Encode an image that is half opaque and half fully transparent, read it
    /// back the way the renderer does, and demand the transparent half is still
    /// transparent.
    @Test("Transparency survives encode and the renderer's own decode")
    func transparencySurvivesTheRoundTrip() throws {
        let source = halfTransparentImage(width: 128, height: 128)
        #expect(alpha(of: source, x: 96, y: 64) == 0, "the fixture must genuinely carry alpha")

        let heic = try #require(
            ImageImportPreparation.heicEncoded(source),
            """
            HEIC encoding is unavailable on this OS. That contradicts the \
            premise of image-format-is-heic — stop, do not narrow AssetFormat.
            """
        )

        // The bytes really are HEIC, not something ImageIO substituted.
        let type = CGImageSourceCreateWithData(heic as CFData, nil)
            .flatMap(CGImageSourceGetType)
            .flatMap { UTType($0 as String) }
        #expect(type?.conforms(to: .heic) == true)

        // Read back through the renderer's own decode, not a private one: the
        // question is what the composite will see, and `downsample` asks
        // ImageIO for a thumbnail, which is its own opportunity to drop an
        // auxiliary image.
        let decoded = try #require(
            StaticLayerRenderer.downsample(heic, maxPixelSize: 128),
            "the encoded HEIC did not decode back"
        )

        #expect(
            alpha(of: decoded, x: 96, y: 64) == 0,
            "a fully transparent source pixel came back opaque — alpha was flattened"
        )
        #expect(
            alpha(of: decoded, x: 32, y: 64) == 255,
            "an opaque source pixel must stay opaque"
        )
    }

    /// Alpha survives the size reduction as well, since the renderer decodes at
    /// the layer's placed extent and almost never at full size.
    @Test("Transparency survives a decode smaller than the source")
    func transparencySurvivesADownsample() throws {
        let heic = try #require(
            ImageImportPreparation.heicEncoded(halfTransparentImage(width: 256, height: 256))
        )
        let decoded = try #require(StaticLayerRenderer.downsample(heic, maxPixelSize: 64))
        #expect(decoded.width <= 64 && decoded.height <= 64)

        // Sampled away from the seam: resampling legitimately blends alpha
        // across the boundary, and a blended edge is correct behaviour rather
        // than the flattening this pin is about.
        let far = decoded.width - decoded.width / 8
        #expect(alpha(of: decoded, x: far, y: decoded.height / 2) == 0)
        #expect(alpha(of: decoded, x: decoded.width / 8, y: decoded.height / 2) == 255)
    }

    /// The composited consequence, which is what a user would actually see: a
    /// transparent region lets the page through instead of painting black over
    /// it. Distinct from the byte assertions above because a decode can report
    /// an alpha channel that every pixel of is opaque.
    @Test("A transparent region does not paint over what is behind it")
    func transparencyLetsTheBackgroundThrough() throws {
        let heic = try #require(
            ImageImportPreparation.heicEncoded(halfTransparentImage(width: 128, height: 128))
        )
        let decoded = try #require(StaticLayerRenderer.downsample(heic, maxPixelSize: 128))

        var bytes = [UInt8](repeating: 0, count: 4 * decoded.width * decoded.height)
        let context = try #require(
            CGContext(
                data: &bytes,
                width: decoded.width,
                height: decoded.height,
                bitsPerComponent: 8,
                bytesPerRow: 4 * decoded.width,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        context.draw(
            decoded,
            in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
        )

        let index = 4 * (decoded.height / 2 * decoded.width + decoded.width - 8)
        #expect(bytes[index] > 200, "the red backdrop must show through the transparent half")
        #expect(bytes[index + 1] < 60)
    }

    // MARK: - Fixtures

    /// The left half opaque green, the right half fully transparent. Real
    /// alpha, and a large flat region on each side so a sampled pixel is not
    /// reading a resampling artefact.
    private func halfTransparentImage(width: Int, height: Int) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            preconditionFailure("could not build a \(width)x\(height) context")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage() else {
            preconditionFailure("the context yielded no image")
        }
        return image
    }

    /// One pixel's alpha, 0–255, with row 0 the top — the same convention
    /// `CGImage` uses and the opposite of CoreGraphics' draw origin, so the y
    /// axis is flipped once here.
    private func alpha(of image: CGImage, x: Int, y: Int) -> Int {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("could not build a one-pixel context")
            return -1
        }
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Int(bytes[3])
    }
}
