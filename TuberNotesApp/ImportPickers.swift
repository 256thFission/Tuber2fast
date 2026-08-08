import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The import UI's plumbing: the system photo picker wrapped for SwiftUI, the
/// security-scoped read a document-picker URL requires, and the one place a
/// picked image's bytes are turned into what `EditorSession.importImage`
/// actually needs.
///
/// Everything here is off the frame path: a picker presentation is a user
/// action, the data work runs off the main actor, and the session call is one
/// awaited intention. Nothing here writes durable state — the store still owns
/// every byte that lands in the document.

// MARK: - Preparing a picked image

/// A picked image cannot be refused by the durable form, so it is prepared here
/// first: the bytes to store, the format naming them, and the extent the layer
/// is placed by.
enum ImageImportError: Error, CustomStringConvertible {
    /// The picked bytes are not an image this device can decode at all.
    case undecodableImage
    /// The image decoded, but re-encoding it as HEIC — the durable form's one
    /// image encoding (`AssetFormat`) — failed. There is no second format to
    /// fall back to, by design: falling back is how a closed set stops being
    /// one, and a refused import is recoverable where a wrongly stored asset is
    /// not.
    case transcodeFailed

    var description: String {
        switch self {
        case .undecodableImage: "The selected file is not an image this device can read."
        case .transcodeFailed: "The selected image could not be converted for storage."
        }
    }
}

/// A picked image, ready for `EditorSession.importImage`.
struct PreparedImageImport: Sendable, Equatable {
    /// The bytes to write as the asset. The original bytes when the source is
    /// already HEIC; a HEIC re-encode otherwise.
    let bytes: Data
    let format: AssetFormat
    /// The image's extent **with its orientation metadata applied** — for a
    /// camera JPEG shot in portrait, the portrait dimensions.
    ///
    /// This is the EXIF hole (`Docs/Forks/ReviewFindings.md`, finding 8), and
    /// this type is where it is closed: `importImage` trusts these numbers,
    /// and the renderer decodes with `kCGImageSourceCreateThumbnailWithTransform`,
    /// which applies orientation. Passing the raw pixel dimensions here would
    /// save a transform whose aspect ratio disagrees with every pixel the
    /// renderer will ever produce — a stretched image, durably.
    let orientedPixelWidth: Double
    let orientedPixelHeight: Double
}

enum ImageImportPreparation {
    /// EXIF orientations 5 through 8 are the transposed ones: applying them
    /// swaps the image's width and height.
    private static let transposedOrientations: ClosedRange<UInt32> = 5...8

    /// The quality every HEIC this build writes is encoded at.
    ///
    /// A fresh choice, not JPEG's 0.9 carried over: with one alpha-carrying
    /// format this knob now governs the *matte* as well as the colour, because
    /// HEIC stores alpha as a separately coded auxiliary image. A quality that
    /// is merely fine for photographs would soften the edge of a cut-out, and a
    /// soft edge on an imported sticker is a wrong picture in a way that a
    /// slightly soft photograph is not. So it stays high, and the reason it is
    /// high is different from the reason JPEG's was.
    static let heicCompressionQuality = 0.9

    /// The one place this build encodes HEIC bytes.
    ///
    /// One site, so the alpha behaviour pinned by
    /// `HEICAlphaTests.transparencySurvivesTheRoundTrip` is the behaviour every
    /// stored asset actually gets. `nil` is a refusal — this build does not
    /// have a second format to fall back to, and silently writing something
    /// else is how a closed set stops being one.
    ///
    /// `CGImageDestination` rather than `CIContext.heifRepresentation`: it is
    /// the same ImageIO the renderer's `downsample` reads back with, it does
    /// embed the alpha auxiliary image (`urn:mpeg:hevc:2015:auxid:1`), and it
    /// needs no `CIContext` — a GPU-backed object with a lifetime — on a path
    /// that is otherwise pure bytes-to-bytes. The pin is what says the first of
    /// those is true rather than hoped.
    static func heicEncoded(_ image: CGImage) -> Data? {
        let encoded = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encoded, UTType.heic.identifier as CFString, 1, nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: heicCompressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }

    /// Turns picked bytes into what `importImage` needs.
    ///
    /// A **HEIC** source keeps its original bytes — the asset store is
    /// write-once, and re-encoding bytes that are already in the one durable
    /// format would spend a lossy generation to arrive where it started — and
    /// only its *reported* extent is corrected for orientation, via the ImageIO
    /// properties (`kCGImagePropertyPixelWidth`/`Height` swapped when
    /// `kCGImagePropertyOrientation` is 5–8). Everything else — PNG, JPEG,
    /// TIFF, GIF — is re-encoded to HEIC, because `AssetFormat` names one image
    /// encoding and a format it does not name is refused at load. The re-encode
    /// decodes with the orientation transform applied, so the output is upright
    /// with orientation 1 and its own pixel extent is the oriented extent.
    ///
    /// A PNG loses a little to that transcode, and the alpha it may be carrying
    /// does not: the whole reason the one format is HEIC and not JPEG is that
    /// this path used to bake transparency into an opaque asset, permanently,
    /// since assets are write-once (`Docs/Queue.md` — `image-format-is-heic`).
    ///
    /// Pure bytes to values, no file and no UI, so it may run anywhere;
    /// callers run it off the main actor because a decode is not interaction
    /// work.
    static func prepare(_ bytes: Data) throws -> PreparedImageImport {
        guard
            let source = CGImageSourceCreateWithData(
                bytes as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else {
            throw ImageImportError.undecodableImage
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let transposed = transposedOrientations.contains(orientation)
        let orientedWidth = transposed ? pixelHeight : pixelWidth
        let orientedHeight = transposed ? pixelWidth : pixelHeight

        let sourceType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        if let sourceType, sourceType.conforms(to: .heic) {
            return PreparedImageImport(
                bytes: bytes,
                format: .heic,
                orientedPixelWidth: orientedWidth,
                orientedPixelHeight: orientedHeight
            )
        }

        // Every other decodable format — PNG, JPEG, TIFF, GIF — is re-encoded
        // to HEIC. `kCGImageSourceCreateThumbnailWithTransform` applies the
        // orientation while decoding, exactly as the renderer's `downsample`
        // does, so the written pixels are upright and the extent below is the
        // oriented one by construction. The max pixel size is the source's own
        // long edge: a transcode, never a downsample.
        //
        // The decode keeps whatever alpha the source had — the thumbnail
        // inherits the source's alpha info — and `heicEncoded` carries it into
        // the written bytes. `HEICAlphaTests` is what says so.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight),
        ]
        guard
            let decoded = CGImageSourceCreateThumbnailAtIndex(
                source, 0, decodeOptions as CFDictionary
            )
        else {
            throw ImageImportError.undecodableImage
        }

        guard let encoded = heicEncoded(decoded) else {
            throw ImageImportError.transcodeFailed
        }

        return PreparedImageImport(
            bytes: encoded,
            format: .heic,
            orientedPixelWidth: Double(decoded.width),
            orientedPixelHeight: Double(decoded.height)
        )
    }
}

// MARK: - Reading a picked document

/// Reads the bytes behind a document-picker URL.
///
/// The URL is outside the sandbox and readable only under its security scope,
/// which is balanced here — started, read, stopped — and nowhere else. This is
/// a read of the *user's* file at the moment of import, not of durable state:
/// `DocumentStore` remains the one writer (and reader) of the document itself,
/// and the bytes read here reach disk only through `EditorSession.importPDF`
/// and the store.
enum PickedFileReading {
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return try Data(contentsOf: url)
    }
}

// MARK: - The photo picker

/// `PHPickerViewController`, wrapped for one job: hand back the picked image's
/// original bytes, or say why it could not.
///
/// PHPicker runs out of process and needs no photo-library permission. The
/// bytes are loaded as a *data representation* — the file's own bytes, not a
/// re-render — so a JPEG stays the user's JPEG; deciding what to do with the
/// format is `ImageImportPreparation`'s, not this view's.
struct PhotoImportPicker: UIViewControllerRepresentable {
    enum Outcome: Sendable {
        /// The user dismissed the picker without choosing. Not an error, and
        /// callers must not surface it as one.
        case cancelled
        case picked(Data)
        case failed(String)
    }

    let completion: @MainActor @Sendable (Outcome) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let completion: @MainActor @Sendable (Outcome) -> Void
        /// One outcome per presentation: the delegate can only fire once, but
        /// the load callback below is asynchronous and this makes "exactly
        /// once" a checked fact rather than a hope.
        private var finished = false

        init(completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
            self.completion = completion
        }

        private func finish(_ outcome: Outcome) {
            guard !finished else { return }
            finished = true
            completion(outcome)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                finish(.cancelled)
                return
            }
            // The provider registers concrete types (`public.jpeg`,
            // `public.heic`, …); ask for the first one that is an image
            // rather than for the abstract `public.image`, which some
            // providers decline to materialize.
            let typeIdentifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            } ?? UTType.image.identifier

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                Task { @MainActor [weak self] in
                    if let data {
                        self?.finish(.picked(data))
                    } else {
                        self?.finish(
                            .failed(String(describing: error ?? ImageImportError.undecodableImage))
                        )
                    }
                }
            }
        }
    }
}
