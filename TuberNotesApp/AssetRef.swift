import Foundation

/// The asset ref, phase 2 of `Docs/Forks/CanvasFeatureComplete.md`: heavy bytes
/// live behind refs, so an `image` layer's payload names a file rather than
/// carrying one. Ink payloads stay inline, as ink is today.
///
/// Nothing here reads or writes a file. Resolving a ref to bytes is
/// `DocumentStore`'s, and only `DocumentStore`'s (`Docs/Contract.md` — Owners,
/// golden rule 4).

/// The closed set of asset encodings this build can name on disk.
///
/// Closed for the same reason `LayerKind` is: a format this enum does not name
/// is not guessed at, it is refused at the layer's own scope. The milestone's
/// own experimental normalization flag would add HEIC as a new case plus a
/// `CONTRACT:` amendment, which is exactly the cost the closed set is for.
enum AssetFormat: String, Sendable, Equatable, CaseIterable {
    case png
    case jpeg

    /// The extension in `assets/<assetID>.<ext>`. It is the raw value, and the
    /// two are deliberately the same string: a second mapping is a second place
    /// the file name could be decided.
    var fileExtension: String { rawValue }
}

/// An `image` layer's payload: which asset, and how to name its file. Two
/// fields, both read by shipped code — `assetID` locates the asset and `format`
/// completes its file name (`Docs/Contract.md` — Forbidden patterns: no field a
/// shipped kind does not read).
///
/// What is deliberately **not** here is the source's pixel size. The layer's
/// `pageSpaceTransform` maps the image's own extent — taken as the unit square,
/// origin top-left, matching page space — into page space, so placement is
/// resolution independent and complete without the asset. Storing the pixel
/// size as well would restate what the asset's own bytes already say, which is
/// a value in two places that can disagree with itself, and it would be
/// invalidated by any import-time downsample.
///
/// `format` is stored as its raw string for the same reason `LayerEnvelope.kind`
/// is: a file written by a newer build must decode as a ref whose format this
/// build refuses — refusing the layer, never the page or the document. A
/// format-typed field would turn an unknown format into a decode failure.
struct ImageLayerRef: Codable, Sendable, Equatable {
    let assetID: UUID
    let format: String

    /// The one initializer application code uses: a format must be named in the
    /// closed set to be written.
    init(assetID: UUID, format: AssetFormat) {
        self.assetID = assetID
        self.format = format.rawValue
    }

    /// A ref with an arbitrary format string. Tests are its only caller — it
    /// exists so a test can put a format this build does not know on disk.
    init(assetID: UUID, rawFormat: String) {
        self.assetID = assetID
        self.format = rawFormat
    }

    /// The format, if this build recognizes it; `nil` is a refusal, not a default.
    var recognizedFormat: AssetFormat? { AssetFormat(rawValue: format) }

    /// The asset's file name inside `assets/`, or `nil` when the format is one
    /// this build does not recognize — a ref this build cannot resolve does not
    /// get to guess at a name.
    var fileName: String? {
        guard let recognizedFormat else { return nil }
        return "\(assetID.uuidString).\(recognizedFormat.fileExtension)"
    }

    // MARK: - The envelope payload

    /// The ref as the bytes that live in `LayerEnvelope.payload`.
    ///
    /// A nested property list inside the envelope's opaque `payload` keeps the
    /// envelope uniform across kinds — `{ layerID, kind, payload,
    /// pageSpaceTransform }` — rather than growing a per-kind field on it.
    func encodedPayload() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// The ref an `image` envelope carries, or a throw. A payload that will not
    /// decode refuses the layer at its caller; it is never defaulted.
    init(payload: Data) throws {
        self = try PropertyListDecoder().decode(ImageLayerRef.self, from: payload)
    }
}

/// The asset store's invariants, violated. Assets are write-once and immutable
/// (`Docs/Forks/CanvasFeatureComplete.md` — Durable form), so there is no
/// update and no overwrite to fail at: only these.
enum AssetError: Error, Equatable {
    /// A write named an asset that already exists. Assets are write-once: an
    /// import writes a new asset, never mutates one. Reaching this means an
    /// asset ID was reused, which is a defect in whatever minted it.
    case assetAlreadyExists(assetID: UUID)
    /// A ref named a format this build does not know, so its file cannot be
    /// named at all.
    case unsupportedAssetFormat(assetID: UUID, format: String)
}
