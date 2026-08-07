import Foundation

/// The durable layer model, phase 1 of `Docs/Forks/CanvasFeatureComplete.md`:
/// a page is an ordered list of layers, and at this phase the only kind is
/// `ink`. The envelope is uniform across kinds; the set of kinds is closed.
/// Adding a kind is a new case plus a `CONTRACT:` amendment — there is no
/// metadata bag, no extension payload, and no field a shipped kind does not
/// read (`Docs/Contract.md` — Forbidden patterns).

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
}

/// The closed set of layer kinds this build recognizes.
///
/// Closed is the point: a kind this enum does not name is not "extended", it
/// is refused, as a `RefusedLayer`, at the layer's own scope. Adding a case
/// here is a `CONTRACT:` amendment.
enum LayerKind: String, Sendable {
    case ink
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

    /// An envelope with an arbitrary kind string. Only decoding and tests
    /// construct these; the save path refuses any kind outside the closed set.
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
}

/// A layer whose kind this build does not recognize: a typed refused state,
/// never a dropped one.
///
/// The refusal is scoped to the layer — the document opens, the other pages
/// load — but the page carrying it refuses input: a page is editable exactly
/// when its ink layer is editable and no layer is refused or unreadable.
/// A refused layer is never silently dropped, rewritten, or carried blind
/// through a save; `DocumentStore.save` refuses to write such a page at all.
struct RefusedLayer: Sendable, Equatable {
    let layerID: UUID
    let kind: String
}

/// What `DocumentStore.loadPage` hands the session: the page's ink layer,
/// already validated against the layer invariants, plus any layers this
/// build refused.
struct LoadedPage: Sendable, Equatable {
    let inkLayerID: UUID
    let inkData: Data
    let refusedLayers: [RefusedLayer]
}

/// The layer invariants, violated. Each is an invalid state and fails loud;
/// nothing here is clamped or corrected (`Docs/Contract.md` — Invalid states
/// fail loud).
enum LayerError: Error, Equatable {
    /// A page has exactly one `ink` layer.
    case notExactlyOneInkLayer(pageID: UUID, count: Int)
    /// The page's single `ink` layer is always last: ink renders above every
    /// static layer.
    case inkLayerNotLast(pageID: UUID)
    /// The `ink` layer's `pageSpaceTransform` is identity, always.
    case nonIdentityInkTransform(layerID: UUID)
    /// A save carried a kind outside the closed set. The session only ever
    /// constructs `ink` envelopes, so reaching this is a defect, not data.
    case unknownKindOnSave(layerID: UUID, kind: String)
    /// A save targeted a page whose file carries a refused layer. Writing it
    /// would silently drop that layer; the save is refused instead.
    case refusedLayerWouldBeLost(pageID: UUID)
}
