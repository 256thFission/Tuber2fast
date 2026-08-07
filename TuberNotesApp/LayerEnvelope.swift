import Foundation

/// The durable layer model, phases 1 and 2 of
/// `Docs/Forks/CanvasFeatureComplete.md`: a page is an ordered list of layers,
/// and the kinds are `ink` and `image`. The envelope is uniform across kinds;
/// the set of kinds is closed. Adding a kind is a new case plus a `CONTRACT:`
/// amendment — there is no metadata bag, no extension payload, and no field a
/// shipped kind does not read (`Docs/Contract.md` — Forbidden patterns).

/// A transform in page space, stored as its six coefficients.
///
/// Six doubles rather than `CGAffineTransform` because durable value types
/// import Foundation only (`Docs/Contract.md` — Owners).
struct PageSpaceTransform: Codable, Sendable, Equatable {
    let a: Double
    let b: Double
    let c: Double
    let d: Double
    let tx: Double
    let ty: Double

    static let identity = PageSpaceTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    var isIdentity: Bool { self == .identity }

    var determinant: Double { a * d - b * c }

    /// Whether this transform can be undone.
    ///
    /// Load-bearing for an asset-backed layer, which owns "the one invertible
    /// mapping from its source space": a hit test, a lens render, and every
    /// later transform gesture all run the mapping backwards. A singular one
    /// collapses the layer to a line or a point, so it is an invalid state
    /// rather than a degenerate but drawable one.
    var isInvertible: Bool {
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite, tx.isFinite, ty.isFinite else {
            return false
        }
        return determinant.isFinite && determinant != 0
    }

    /// The transform that places a source of the given extent inside the page,
    /// aspect preserved and centred.
    ///
    /// Only the source's aspect ratio is used, so its extent may be given in
    /// pixels, points, or anything else consistent — the result maps the
    /// source's unit square into page space either way.
    static func fittingSource(
        width: Double,
        height: Double,
        inPageOfWidth pageWidth: Double,
        height pageHeight: Double
    ) -> PageSpaceTransform {
        precondition(
            width.isFinite && width > 0 && height.isFinite && height > 0,
            "a source extent of \(width)x\(height) is not a placeable image"
        )
        precondition(
            pageWidth.isFinite && pageWidth > 0 && pageHeight.isFinite && pageHeight > 0,
            "a page of \(pageWidth)x\(pageHeight) is not a page"
        )
        let scale = min(pageWidth / width, pageHeight / height)
        let placedWidth = width * scale
        let placedHeight = height * scale
        return PageSpaceTransform(
            a: placedWidth,
            b: 0,
            c: 0,
            d: placedHeight,
            tx: (pageWidth - placedWidth) / 2,
            ty: (pageHeight - placedHeight) / 2
        )
    }
}

/// The closed set of layer kinds this build recognizes.
///
/// Closed is the point: a kind this enum does not name is not "extended", it
/// is refused, as a `RefusedLayer`, at the layer's own scope. Adding a case
/// here is a `CONTRACT:` amendment.
enum LayerKind: String, Sendable {
    case ink
    case image
}

/// One durable layer: `{ layerID, kind, payload, pageSpaceTransform }`,
/// uniform across kinds.
///
/// `kind` is stored as its raw string, deliberately: a page file written by a
/// newer build must decode as an envelope whose kind this build refuses —
/// refusing the layer, never the page or the document. An enum-typed field
/// would turn an unknown kind into a decode failure of the whole page.
///
/// The `ink` layer's `pageSpaceTransform` is identity, always. The field is
/// present because the envelope is uniform and constrained because ink is
/// authored in page space; a non-identity ink transform is an invalid state
/// and fails loud at load (`Docs/Contract.md` — Invalid states fail loud).
/// The constraint is ink's alone: an `image` layer's `pageSpaceTransform` is a
/// real durable value — the invertible mapping from the image's own extent,
/// taken as the unit square, into page space — and is where the layer is.
struct LayerEnvelope: Codable, Sendable, Equatable {
    let layerID: UUID
    let kind: String
    let payload: Data
    let pageSpaceTransform: PageSpaceTransform

    /// The one initializer application code uses: a kind must be named in the
    /// closed set to be written.
    init(
        layerID: UUID,
        kind: LayerKind,
        payload: Data,
        pageSpaceTransform: PageSpaceTransform
    ) {
        self.layerID = layerID
        self.kind = kind.rawValue
        self.payload = payload
        self.pageSpaceTransform = pageSpaceTransform
    }

    /// An envelope with an arbitrary kind string. Tests are its only caller —
    /// decoding goes through the synthesized `init(from:)` — and it exists so
    /// a test can put an unknown kind on disk, which the save path refuses.
    init(
        layerID: UUID,
        rawKind: String,
        payload: Data,
        pageSpaceTransform: PageSpaceTransform
    ) {
        self.layerID = layerID
        self.kind = rawKind
        self.payload = payload
        self.pageSpaceTransform = pageSpaceTransform
    }

    /// The kind, if this build recognizes it; `nil` is a refusal, not a default.
    var recognizedKind: LayerKind? { LayerKind(rawValue: kind) }

    /// An `image` layer: the ref as its payload, and the transform that says
    /// where on the page the image's unit square lands.
    static func image(
        layerID: UUID,
        ref: ImageLayerRef,
        pageSpaceTransform: PageSpaceTransform
    ) throws -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID,
            kind: .image,
            payload: try ref.encodedPayload(),
            pageSpaceTransform: pageSpaceTransform
        )
    }
}

/// A layer this build cannot open: a typed refused state, never a dropped one.
///
/// The refusal is scoped to the layer — the document opens, the other pages
/// load — but the page carrying it refuses input: a page is editable exactly
/// when its ink layer is editable and no layer is refused or unreadable.
/// A refused layer is never silently dropped or rewritten.
struct RefusedLayer: Sendable, Equatable {
    let layerID: UUID
    let kind: String
    let reason: Reason

    /// Why this build cannot open the layer. The distinction the save path
    /// needs is not the cause but `isReconstructable` below.
    enum Reason: Sendable, Equatable {
        /// A kind outside the closed set — a newer build's file.
        case unknownKind
        /// A recognized kind whose payload will not decode.
        case unreadablePayload
        /// A recognized kind whose ref names an encoding this build has no
        /// decoder for — the shape a future HEIC asset takes to this build.
        /// The asset it names is still known, so reclamation can still see the
        /// reference and refuse to delete underneath it.
        case unsupportedAssetFormat(assetID: UUID, format: String)
        /// The layer's asset file is not there. A dangling asset ref is fatal
        /// to the layer, and the page refuses input while carrying it.
        case missingAsset(UUID)
    }

    /// Whether this build could write the layer back byte-for-byte.
    ///
    /// It decides whether a save may overwrite the page file: a layer this
    /// build cannot re-encode would be silently dropped by the rewrite, so the
    /// save is refused instead. A layer whose *asset* is missing is different
    /// in kind — the envelope is fully understood, only the file it names is
    /// gone — and refusing to rewrite that page would make it unrepairable,
    /// because dropping the broken layer is the repair and dropping it is a
    /// save.
    var isReconstructable: Bool {
        switch reason {
        case .missingAsset: true
        case .unknownKind, .unreadablePayload, .unsupportedAssetFormat: false
        }
    }
}

/// What `DocumentStore.loadPage` hands the session: the page's ink layer,
/// already validated against the layer invariants, the recognized layers
/// beneath it, and any layers this build refused.
struct LoadedPage: Sendable, Equatable {
    let inkLayerID: UUID
    let inkData: Data
    /// Every recognized layer below the ink, in order — the session's custody
    /// copy of the page's layer list, which it writes back on the page's next
    /// save. Without it every ink save would silently drop the page's images.
    ///
    /// A layer refused only because its asset is missing is here *and* in
    /// `refusedLayers`: the page refuses input for it, and it must still be
    /// preservable, because dropping it is the one repair.
    let staticLayers: [LayerEnvelope]
    let refusedLayers: [RefusedLayer]
}

/// The layer invariants, violated. Each is an invalid state and fails loud;
/// nothing here is clamped or corrected (`Docs/Contract.md` — Invalid states
/// fail loud).
enum LayerError: Error, Equatable {
    /// Layer IDs are unique within a page — the document-level "Page IDs are
    /// unique and stable" rule, one level down.
    case duplicateLayerID(pageID: UUID, layerID: UUID)
    /// A page has exactly one `ink` layer.
    case notExactlyOneInkLayer(pageID: UUID, count: Int)
    /// The page's single `ink` layer is always last: ink renders above every
    /// static layer.
    case inkLayerNotLast(pageID: UUID)
    /// The `ink` layer's `pageSpaceTransform` is identity, always.
    case nonIdentityInkTransform(layerID: UUID)
    /// An asset-backed layer's transform is its one invertible mapping from
    /// source space; a singular one is an invalid state.
    case nonInvertibleLayerTransform(layerID: UUID)
    /// A save carried a layer this build cannot open. The session only ever
    /// constructs envelopes it understands, so reaching this is a defect, not
    /// data.
    case refusedLayerOnSave(layerID: UUID, kind: String)
    /// A save carried an `image` layer whose asset is not on disk. Write order
    /// is leaf-to-root — assets, then page files, then the index — and this is
    /// that order enforced rather than described: an interrupted save leaves an
    /// orphan asset, never a page file naming an asset that is not there.
    case danglingAssetRef(layerID: UUID, assetID: UUID)
    /// A save targeted a page whose file carries a layer this build cannot
    /// re-encode. Writing it would silently drop that layer; the save is
    /// refused instead.
    case refusedLayerWouldBeLost(pageID: UUID)
}
