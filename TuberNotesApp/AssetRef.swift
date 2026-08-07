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
    /// A source PDF, byte for byte. **A `pdf` asset is never normalized and
    /// never rewritten** — the original bytes are the entire small-export
    /// story, and any re-encode would make the file the user gets back
    /// something other than the file they imported.
    case pdf

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

    /// The format, if this build recognizes it **as an image**; `nil` is a
    /// refusal, not a default.
    ///
    /// Exhaustive over `AssetFormat` on purpose: a new encoding cannot be added
    /// without deciding here whether an `image` layer may name it. `pdf` may
    /// not — a PDF is not a bitmap, and an `image` layer pointing at one is the
    /// same invalid state as one pointing at an encoding this build has no
    /// decoder for, so it takes the same refusal.
    var recognizedFormat: AssetFormat? {
        switch AssetFormat(rawValue: format) {
        case .png: .png
        case .jpeg: .jpeg
        case .pdf: nil
        case nil: nil
        }
    }

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

/// A `pdf` layer's payload: which asset, and **which of its source pages**.
///
/// Two fields, both read by shipped code. `assetID` locates the asset;
/// `sourcePageIndex` says which page of it this layer shows, zero-based, in the
/// source document's own order.
///
/// ## Why there is no `format` field here, unlike `ImageLayerRef`
///
/// An `image` layer genuinely needs one: `png` and `jpeg` are both images, and
/// the format is what completes `assets/<assetID>.<ext>`. A `pdf` layer's asset
/// is a PDF by definition of the kind, so a stored format could only ever
/// repeat the kind — and a value stored twice is a value that can disagree with
/// itself. The file name comes from `AssetFormat.pdf`, chosen by the kind.
/// The consequence, stated so it is not discovered later: **there is no
/// unsupported-format refusal for a `pdf` layer**, because there is no format
/// to be unsupported. Its refusals are an unreadable payload and a missing
/// asset.
///
/// ## Why the source page's *size in points* is not here either
///
/// This is the interesting call of phase 3, and it went the same way phase 2's
/// did for images — deliberately, not by inertia. A PDF page differs from a
/// bitmap in a way that seems to argue the other way: it has an intrinsic size
/// in points, a resolution-independent physical fact, where a bitmap has only
/// pixels. Storing it durably was still refused, on four grounds:
///
/// 1. **It restates the asset.** The page's box is in the PDF; a second copy in
///    the page file is the disagreement-with-itself failure that kept the
///    image's pixel size out of `ImageLayerRef`.
/// 2. **Nothing can use it without the asset anyway.** Every operation that
///    needs the source's size — rendering, a lens tile, drawing the page — must
///    open the PDF, and `CGPDFPage` states its own box when it does. There is
///    no consumer that needs the number but not the bytes. What the durable
///    form *does* have to answer without opening a 50 MB file is "where is this
///    layer on the page", and `pageSpaceTransform` answers exactly that.
/// 3. **"The source page's size" is a choice, not a fact.** A PDF page carries
///    MediaBox, CropBox, BleedBox, TrimBox and ArtBox, plus `/Rotate`. Pinning
///    one of those into the payload freezes a decision the renderer makes
///    independently, and the two can then drift with no way to detect it. The
///    unit square delegates the choice to one place — `PDFSource`, which states
///    it — and stays correct as long as that one place is self-consistent.
/// 4. **It would restate the page geometry, which is now a fact rather than a
///    forecast.** Per-page geometry landed in phase 3b: an imported page's own
///    geometry *is* its source's size in points, in `PageRecord`, so a durable
///    size in this payload would be a third copy of one number. The unit-square
///    payload needed no reconciliation when that landed — a stored point size
///    would have — and the transform an imported page's `pdf` layer carries is
///    now `{ a: pageWidth, d: pageHeight, tx: 0, ty: 0 }`, edge to edge, where
///    under one document-wide geometry it was a letterbox.
///
/// So `pageSpaceTransform` maps the source page's box — taken as the unit
/// square, origin top-left, matching page space — into page space, exactly as
/// an `image` layer's does. One convention for every asset-backed layer means
/// one hit-test path, one lens path, one transform composition, and no consumer
/// that has to branch on kind to know what its transform means.
///
/// `sourcePageIndex` is not a restatement and that is the distinction worth
/// keeping straight: the asset states all N pages, and which one this layer
/// shows is a durable *choice* the asset cannot answer.
struct PDFLayerRef: Codable, Sendable, Equatable {
    let assetID: UUID
    let sourcePageIndex: Int

    init(assetID: UUID, sourcePageIndex: Int) {
        self.assetID = assetID
        self.sourcePageIndex = sourcePageIndex
    }

    /// A `pdf` asset's file name inside `assets/`. Unconditional, unlike
    /// `ImageLayerRef.fileName`: the kind names the encoding, so there is no
    /// unrecognized case to refuse.
    var fileName: String { "\(assetID.uuidString).\(AssetFormat.pdf.fileExtension)" }

    // MARK: - The envelope payload

    /// The ref as the bytes that live in `LayerEnvelope.payload`, keeping the
    /// envelope uniform across kinds.
    func encodedPayload() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// The ref a `pdf` envelope carries, or a throw. A payload that will not
    /// decode refuses the layer at its caller; it is never defaulted.
    init(payload: Data) throws {
        self = try PropertyListDecoder().decode(PDFLayerRef.self, from: payload)
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
