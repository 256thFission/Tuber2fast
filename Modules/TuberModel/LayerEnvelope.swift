import Foundation

/// The durable layer model, phases 1 to 3 of
/// `Docs/Forks/CanvasFeatureComplete.md`: a page is an ordered list of layers,
/// and the kinds are `ink`, `image`, and `pdf`. The envelope is uniform across kinds;
/// the set of kinds is closed. Adding a kind is a new case plus a `CONTRACT:`
/// amendment — there is no metadata bag, no extension payload, and no field a
/// shipped kind does not read (`Docs/Contract.md` — Forbidden patterns).

/// A transform in page space, stored as its six coefficients.
///
/// Six doubles rather than `CGAffineTransform` because durable value types
/// import Foundation only (`Docs/Contract.md` — Owners).
package struct PageSpaceTransform: Codable, Sendable, Equatable {
    package let a: Double
    package let b: Double
    package let c: Double
    package let d: Double
    package let tx: Double
    package let ty: Double

    // Spelled out because a memberwise initializer is `internal` however
    // visible its type is, and every module above this one builds one.
    package init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    package static let identity = PageSpaceTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    package var isIdentity: Bool { self == .identity }

    package var determinant: Double { a * d - b * c }

    /// Whether this transform can be undone.
    ///
    /// Load-bearing for an asset-backed layer, which owns "the one invertible
    /// mapping from its source space": a hit test, a lens render, and every
    /// later transform gesture all run the mapping backwards. A singular one
    /// collapses the layer to a line or a point, so it is an invalid state
    /// rather than a degenerate but drawable one.
    package var isInvertible: Bool {
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite, tx.isFinite, ty.isFinite else {
            return false
        }
        return determinant.isFinite && determinant != 0
    }

    // MARK: - The algebra a transform gesture needs
    //
    // Phase 4 of `Docs/Forks/CanvasFeatureComplete.md`. All of it is pure
    // arithmetic on six doubles, so it lives with the durable value rather
    // than in the canvas runtime: the same mapping is what a hit test runs
    // backwards, what a gesture composes, and what the compositor concatenates.
    // `isInvertible` above already anticipated this in its own comment.
    //
    // The convention is `CGAffineTransform`'s, deliberately, because
    // `StaticLayerRenderer` hands these coefficients straight to CoreGraphics:
    // a point is a row vector, so `(x, y)` maps to
    // `(a·x + c·y + tx, b·x + d·y + ty)`.

    package static func translation(x: Double, y: Double) -> PageSpaceTransform {
        PageSpaceTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    /// A uniform scale about the origin.
    package static func scale(_ factor: Double) -> PageSpaceTransform {
        PageSpaceTransform(a: factor, b: 0, c: 0, d: factor, tx: 0, ty: 0)
    }

    /// A rotation about the origin, in radians.
    ///
    /// Page space is y-down (`Contract.md` — Geometry and coordinates), so a
    /// positive angle turns clockwise on screen. That is not a sign error: the
    /// gesture measures its angles with `atan2` in the same y-down space, so
    /// the two agree and the handle tracks the finger.
    package static func rotation(_ radians: Double) -> PageSpaceTransform {
        let cosine = cos(radians)
        let sine = sin(radians)
        return PageSpaceTransform(a: cosine, b: sine, c: -sine, d: cosine, tx: 0, ty: 0)
    }

    /// The point `(x, y)` mapped through this transform.
    package func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (x: a * x + c * y + tx, y: b * x + d * y + ty)
    }

    /// `self` applied first, then `later` — `CGAffineTransform.concatenating`'s
    /// order, so that reading a composition left to right reads it in the order
    /// the points travel.
    package func concatenating(_ later: PageSpaceTransform) -> PageSpaceTransform {
        PageSpaceTransform(
            a: a * later.a + b * later.c,
            b: a * later.b + b * later.d,
            c: c * later.a + d * later.c,
            d: c * later.b + d * later.d,
            tx: tx * later.a + ty * later.c + later.tx,
            ty: tx * later.b + ty * later.d + later.ty
        )
    }

    /// The mapping backwards, or `nil` when there is none.
    ///
    /// `nil` is unreachable for a layer that loaded: a singular transform is an
    /// invalid state refused at load (`Contract.md` — Durable form). It is
    /// returned rather than trapped because the *gesture* asks this question of
    /// candidate transforms it has not committed to, and declining a frame is
    /// not the same as accepting an invalid durable value.
    package var inverted: PageSpaceTransform? {
        guard isInvertible else { return nil }
        let determinant = self.determinant
        return PageSpaceTransform(
            a: d / determinant,
            b: -b / determinant,
            c: -c / determinant,
            d: a / determinant,
            tx: (c * ty - d * tx) / determinant,
            ty: (b * tx - a * ty) / determinant
        )
    }

    /// Whether a page point lands inside the source's unit square.
    ///
    /// **This is the whole hit test.** The payload of an asset-backed layer
    /// deliberately carries no pixel size (`Contract.proposed.md` A6/A6b): the
    /// transform maps the source's *unit square* into page space, so asking
    /// "did the user touch this layer" is inverting the transform and testing
    /// the point against `[0, 1] × [0, 1]`. No decode, no file, no knowledge of
    /// the source at all — which is exactly the property A6b was argued for.
    ///
    /// Traps on a singular transform rather than answering `false`, because a
    /// layer on a page has already been validated as invertible and a `false`
    /// here would read as "the user missed it".
    package func containsUnitSquarePoint(x: Double, y: Double) -> Bool {
        guard let inverse = inverted else {
            preconditionFailure(
                "a singular transform reached a hit test; a layer with one is refused at load"
            )
        }
        let local = inverse.apply(x: x, y: y)
        return local.x >= 0 && local.x <= 1 && local.y >= 0 && local.y <= 1
    }

    /// The transform that places a source of the given extent inside the page,
    /// aspect preserved and centred.
    ///
    /// Only the source's aspect ratio is used, so its extent may be given in
    /// pixels, points, or anything else consistent — the result maps the
    /// source's unit square into page space either way.
    package static func fittingSource(
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
package enum LayerKind: String, Sendable {
    case ink
    case image
    /// One page of a source PDF, shown beneath the ink. Its asset is never
    /// normalized and never rewritten, so what a later export hands back is the
    /// file the user imported.
    case pdf
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
///
/// Both halves of `Codable` are synthesized, so all five fields are required
/// on the way in. An envelope missing one is a file this build cannot read,
/// which is the loud failure and not a default.
package struct LayerEnvelope: Codable, Sendable, Equatable {
    package let layerID: UUID
    package let kind: String
    package let payload: Data
    package let pageSpaceTransform: PageSpaceTransform

    /// Whether this layer refuses transforms.
    ///
    /// Phase 4 of `Docs/Forks/CanvasFeatureComplete.md`, and it is here only
    /// because phase 4 **reads** it — twice, in two owners, which is the test
    /// *Forbidden patterns* sets for a field that would otherwise be an
    /// undefined placeholder. `LayerSelectionRuntime` refuses to begin a drag
    /// on a locked layer, so a locked image pans the page like bare paper; and
    /// `EditorSession.transformLayer` refuses the durable edit outright,
    /// because the session is the layer list's one writer and must not take a
    /// value merely because a caller asked.
    ///
    /// Locked is a bit on the envelope, not a property of the kind
    /// (`Contract.proposed.md` A11): a locked layer stays *selectable*, because
    /// selection is how a static layer has a UI path at all.
    package let locked: Bool

    /// The one initializer application code uses: a kind must be named in the
    /// closed set to be written.
    package init(
        layerID: UUID,
        kind: LayerKind,
        payload: Data,
        pageSpaceTransform: PageSpaceTransform,
        locked: Bool = false
    ) {
        self.layerID = layerID
        self.kind = kind.rawValue
        self.payload = payload
        self.pageSpaceTransform = pageSpaceTransform
        self.locked = locked
    }

    /// An envelope with an arbitrary kind string. Tests are its only caller —
    /// decoding goes through `init(from:)` — and it exists so a test can put an
    /// unknown kind on disk, which the save path refuses.
    package init(
        layerID: UUID,
        rawKind: String,
        payload: Data,
        pageSpaceTransform: PageSpaceTransform,
        locked: Bool = false
    ) {
        self.layerID = layerID
        self.kind = rawKind
        self.payload = payload
        self.pageSpaceTransform = pageSpaceTransform
        self.locked = locked
    }

    /// The kind, if this build recognizes it; `nil` is a refusal, not a default.
    package var recognizedKind: LayerKind? { LayerKind(rawValue: kind) }

    /// Whether a tap may address this layer.
    ///
    /// `Contract.proposed.md` A11: "A `pdf` or `image` layer is selectable —
    /// selection is how 'replace the worksheet' has a UI path at all. What a
    /// static kind refuses is *drawing* input, not addressability." Ink is not
    /// selectable: it is the drawing, and PencilKit's own lasso addresses it.
    package var isSelectable: Bool { recognizedKind == .image }

    /// Whether a drag on this layer is a transform. Selectable and unlocked.
    package var isTransformable: Bool { isSelectable && !locked }

    /// This layer, moved. The one mutation phase 4 makes to a committed value,
    /// and it produces a new immutable value rather than editing one — the
    /// handover the canvas runtime performs is one whole envelope.
    package func withPageSpaceTransform(_ transform: PageSpaceTransform) -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID,
            rawKind: kind,
            payload: payload,
            pageSpaceTransform: transform,
            locked: locked
        )
    }

    /// This layer under a new identity — the same picture, in a second place.
    ///
    /// The one caller is duplicating a page. A layer file is per layer, so two
    /// pages must never name the same `layerID` or they contend for one file
    /// and a delete on either takes the other's picture with it. The
    /// **payload is copied verbatim**, which is what makes the copy share the
    /// original's asset rather than duplicate it: assets are write-once and
    /// reference-counted by an on-disk scan, so sharing is what that scan is
    /// built to answer, and a fifty-megabyte import stays one file however
    /// many times its page is duplicated.
    package func withLayerID(_ layerID: UUID) -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID,
            rawKind: kind,
            payload: payload,
            pageSpaceTransform: pageSpaceTransform,
            locked: locked
        )
    }

    /// This layer, locked or unlocked.
    package func withLocked(_ locked: Bool) -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID,
            rawKind: kind,
            payload: payload,
            pageSpaceTransform: pageSpaceTransform,
            locked: locked
        )
    }

    /// An `image` layer: the ref as its payload, and the transform that says
    /// where on the page the image's unit square lands.
    package static func image(
        layerID: UUID,
        ref: ImageLayerRef,
        pageSpaceTransform: PageSpaceTransform,
        locked: Bool = false
    ) throws -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID,
            kind: .image,
            payload: try ref.encodedPayload(),
            pageSpaceTransform: pageSpaceTransform,
            locked: locked
        )
    }

    /// A `pdf` layer: which asset and which of its source pages as the payload,
    /// and the transform that says where on the page that source page's unit
    /// square lands. See `PDFLayerRef` for why the source page's size in points
    /// is not durable.
    package static func pdf(
        layerID: UUID,
        ref: PDFLayerRef,
        pageSpaceTransform: PageSpaceTransform
    ) throws -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID,
            kind: .pdf,
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
package struct RefusedLayer: Sendable, Equatable {
    package let layerID: UUID
    package let kind: String
    package let reason: Reason

    package init(layerID: UUID, kind: String, reason: Reason) {
        self.layerID = layerID
        self.kind = kind
        self.reason = reason
    }

    /// Why this build cannot open the layer. The distinction the save path
    /// needs is not the cause but `isReconstructable` below.
    package enum Reason: Sendable, Equatable {
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
    package var isReconstructable: Bool {
        switch reason {
        case .missingAsset: true
        case .unknownKind, .unreadablePayload, .unsupportedAssetFormat: false
        }
    }
}

/// What `DocumentStore.loadPage` hands the session: the page's ink layer,
/// already validated against the layer invariants, the recognized layers
/// beneath it, and any layers this build refused.
package struct LoadedPage: Sendable, Equatable {
    package let inkLayerID: UUID
    package let inkData: Data
    /// Every recognized layer below the ink, in order — the session's custody
    /// copy of the page's layer list, which it writes back on the page's next
    /// save. Without it every ink save would silently drop the page's images.
    ///
    /// A layer refused only because its asset is missing is here *and* in
    /// `refusedLayers`: the page refuses input for it, and it must still be
    /// preservable, because dropping it is the one repair.
    package let staticLayers: [LayerEnvelope]
    package let refusedLayers: [RefusedLayer]

    // Spelled out because a memberwise initializer is `internal` however
    // visible its type is, and the store is a module away.
    package init(
        inkLayerID: UUID,
        inkData: Data,
        staticLayers: [LayerEnvelope],
        refusedLayers: [RefusedLayer]
    ) {
        self.inkLayerID = inkLayerID
        self.inkData = inkData
        self.staticLayers = staticLayers
        self.refusedLayers = refusedLayers
    }
}

/// The layer invariants, violated. Each is an invalid state and fails loud;
/// nothing here is clamped or corrected (`Docs/Contract.md` — Invalid states
/// fail loud).
package enum LayerError: Error, Equatable {
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
    /// A page file names a layer whose file is not in `layers/`. **A dangling
    /// layer ref is fatal** — the same rule as a dangling page ref, one level
    /// down — because the missing file may be the page's ink and no other copy
    /// of it exists. The page is refused; the document opens.
    case missingLayerFile(pageID: UUID, layerID: UUID)
    /// A layer file's own `layerID` is not the one it is filed under. It
    /// catches a mixed-up or truncated directory, exactly as the page file's
    /// repeated `pageID` does.
    case layerFileIDMismatch(expected: UUID, found: UUID)
    /// A save would write a page file naming a layer with no file and none
    /// being written. Write order is leaf-to-root — layer files before page
    /// files — and this is that order enforced rather than described.
    case danglingLayerRef(pageID: UUID, layerID: UUID)
    /// A `pdf` layer named a negative source page. Page indices are zero-based
    /// counts into the source document; a negative one is structurally
    /// impossible from any correct writer. Whether the index is *within* the
    /// source is not checked here and deliberately so: answering it means
    /// opening the asset, and opening every asset on load is the
    /// whole-document read this format exists to avoid.
    case negativeSourcePageIndex(layerID: UUID, index: Int)
}
