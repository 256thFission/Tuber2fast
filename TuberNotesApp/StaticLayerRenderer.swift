import CoreGraphics
import Foundation
import ImageIO

/// Renders a page's static layers — everything below the ink — into one
/// texture, strictly off the main thread.
///
/// Phase 2 of `Docs/Forks/CanvasFeatureComplete.md`, rendering half. The
/// ink-last pin makes the whole stack below the ink static between edits, so
/// this flattens it: **a ten-layer page costs the compositor what a one-layer
/// page costs**, because the compositor only ever sees one texture. The layer
/// list is a durable and editing structure; it is never a compositing
/// structure.
///
/// Not a second owner. It writes nothing durable, holds no page identity, and
/// answers questions: given a layer list and a level of detail, here is the
/// texture, or here is a refusal. `EditorSession` remains the one writer of the
/// list (`Contract.md` — Owners, golden rule 5) and `DocumentStore` remains the
/// only thing that touches files — this actor reads asset bytes *through* the
/// store's own entry point and never opens a file itself.
///
/// It is an `actor` for the reason `DocumentStore` is one: decoding and
/// compositing are off the main actor by construction rather than by
/// discipline (`Contract.md` — Performance: "File encoding and disk I/O never
/// run on main", and the fork doc's "re-compositing happens only on a layer
/// edit, off-main"). The heavy work is further hoisted onto the global
/// executor by `render`, which is `nonisolated`, so a long composite does not
/// hold this actor's queue against a second page's request.
///
/// It imports CoreGraphics and ImageIO rather than UIKit deliberately: nothing
/// here is a view, a layer, or frame-frequency work, so it needs none of the
/// canvas runtime's vocabulary and stays off that allowlist.
actor StaticLayerRenderer {
    private let store: DocumentStore

    // MARK: - The cache
    //
    // `Contract.md` — Performance: "A cache states its owner, its bound, and
    // what evicts it, at its declaration. One that cannot state all three is
    // forbidden."
    //
    // OWNER: this actor. Nothing else holds a composite alive except the one
    //   `PageBackdrop` currently displaying it, which drops its reference when
    //   its page leaves the live window with the rest of the canvas.
    //
    // BOUND: `byteBound`, **in bytes** — 96 MB by default, and bytes rather
    //   than pages because a page is not a unit of memory. The arithmetic: a
    //   fit-width composite on a 13" iPad is about 2048 x 2700 x 4 = 22 MB, so
    //   96 MB is four such composites. The live window is three pages, so the
    //   visible working set fits with a page of headroom and this bound bites
    //   on a prefetched neighbour rather than on anything on screen. **The
    //   22 MB is the fork doc's estimate and nobody has measured it on a
    //   device**; if it is wrong, this number is wrong with it.
    //
    // EVICTION: two rules, in this order. `retain(layerIDs:)` drops every
    //   entry whose layers have all left the live window plus the prefetch
    //   radius — that is the policy, and the session calls it on every turn.
    //   The byte bound is the backstop: after an insert, least-recently-used
    //   entries are dropped until the total is under it, never including the
    //   entry just inserted.
    //
    // A refusal is cached too, at zero bytes. Without that, a page whose asset
    // will not decode re-attempts the decode on every layout pass. Assets are
    // write-once, so a render of one can be missing but never stale — which is
    // exactly what makes caching either outcome safe.
    static let defaultByteBound = 96 * 1024 * 1024

    private let byteBound: Int
    private var cache: [CompositeKey: Entry] = [:]
    private var cachedBytes = 0

    /// A monotonic stamp, so "least recently used" is an ordering rather than a
    /// wall clock that can go backwards.
    private var useCounter = 0

    /// Requests being served right now, so two canvases asking for the same
    /// composite decode it once. The same idea as `EditorSession`'s
    /// `pageLoadsInFlight`, one level down.
    private var inFlight: [CompositeKey: Task<StaticLayerRender, Never>] = [:]

    private struct Entry {
        let request: StaticLayerRequest
        let render: StaticLayerRender
        let byteCount: Int
        let layerIDs: Set<UUID>
        var lastUsed: Int
    }

    /// The identity of one cached composite: which layers, at what level of
    /// detail. Layer IDs are unique within a page and minted as UUIDs, so this
    /// needs no page identity — which is what lets `PageCanvasController` stay
    /// blind to which page it is (`Contract.md` — Owners, golden rule 7).
    ///
    /// The key is not the whole request: transforms are compared by the stored
    /// `Entry.request` on lookup, so a layer that moved is a miss rather than a
    /// wrong picture.
    private struct CompositeKey: Hashable {
        let layerIDs: [UUID]
        let scaleMilli: Int
        /// Geometry is per page since phase 3b, so it belongs in the key: the
        /// same layer list flattened into a differently sized page is a
        /// different texture, and a key that ignored it would hand a landscape
        /// page the portrait composite of the same layers.
        let widthMilli: Int
        let heightMilli: Int

        init(_ request: StaticLayerRequest) {
            layerIDs = request.layers.map(\.layerID)
            scaleMilli = Int((request.pixelsPerPagePoint * 1000).rounded())
            widthMilli = Int((request.geometry.width * 1000).rounded())
            heightMilli = Int((request.geometry.height * 1000).rounded())
        }
    }

    /// `byteBound` is injectable only so a test need not allocate 96 MB of
    /// pixels to watch the bound bite. The default is the only value the app
    /// uses.
    init(store: DocumentStore, byteBound: Int = StaticLayerRenderer.defaultByteBound) {
        precondition(byteBound > 0, "a render cache with a bound of \(byteBound) bytes cannot hold anything")
        self.store = store
        self.byteBound = byteBound
    }

    // MARK: - The one entry point

    /// The composite for one page's static layers, from the cache or freshly
    /// rendered.
    ///
    /// Never called from a gesture frame — the fork doc's rule is that a pinch
    /// shows the current texture scaled and slightly soft, exactly as every PDF
    /// viewer on iOS does, and `PageCanvasController` enforces it by requesting
    /// only at layout and at a layer edit.
    func composite(for request: StaticLayerRequest) async -> StaticLayerRender {
        guard !request.layers.isEmpty else { return .empty }
        precondition(
            request.pixelsPerPagePoint.isFinite && request.pixelsPerPagePoint > 0,
            "a composite at \(request.pixelsPerPagePoint) pixels per page point is not a level of detail"
        )

        let key = CompositeKey(request)
        if var entry = cache[key], entry.request == request {
            useCounter += 1
            entry.lastUsed = useCounter
            cache[key] = entry
            return entry.render
        }

        if let running = inFlight[key] { return await running.value }

        // KNOWN DEFECT: a `retain(layerIDs:)` that lands while this render is
        // in flight is undone by the `remember` below, so a page that left the
        // live window mid-render keeps its composite until the next turn. One
        // entry, bounded by the byte bound, dropped by the next `retain`. The
        // fix is a generation stamp compared after the await, and it is not
        // worth the machinery for a cache that self-corrects on the next
        // swipe.
        let task = Task { [store] in
            await Self.render(request, store: store)
        }
        inFlight[key] = task
        let render = await task.value
        inFlight[key] = nil

        remember(render, for: request, key: key)
        return render
    }

    // MARK: - Eviction

    /// Drops every composite none of whose layers is still in the live window
    /// plus the prefetch radius. **This is the eviction policy**; the byte
    /// bound below is only the backstop.
    ///
    /// Keyed on layer IDs rather than page IDs so that this actor never learns
    /// page identity. `EditorSession` — which owns page order — computes the
    /// live set.
    func retain(layerIDs live: Set<UUID>) {
        var dropped = 0
        for (key, entry) in cache where entry.layerIDs.isDisjoint(with: live) {
            cachedBytes -= entry.byteCount
            cache[key] = nil
            dropped += 1
        }
        if dropped > 0 {
            CanvasLog.event(
                .canvas,
                "render cache: dropped \(dropped) composite(s) that left the live window; "
                    + "holding \(cache.count) at \(cachedBytes) bytes"
            )
        }
    }

    private func remember(_ render: StaticLayerRender, for request: StaticLayerRequest, key: CompositeKey) {
        let bytes: Int
        if case .composited(let composite) = render { bytes = composite.byteCount } else { bytes = 0 }

        if let existing = cache[key] { cachedBytes -= existing.byteCount }
        useCounter += 1
        cache[key] = Entry(
            request: request,
            render: render,
            byteCount: bytes,
            layerIDs: Set(request.layers.map(\.layerID)),
            lastUsed: useCounter
        )
        cachedBytes += bytes
        trimToByteBound(protecting: key)
    }

    /// Drops least-recently-used entries until the cache is under its bound.
    /// The entry just inserted is never a candidate: a composite bigger than
    /// the whole bound would otherwise be evicted before it was ever shown, and
    /// the page would re-render it on the next layout pass forever.
    private func trimToByteBound(protecting key: CompositeKey) {
        guard cachedBytes > byteBound else { return }
        for candidate in cache.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            guard cachedBytes > byteBound else { break }
            guard candidate.key != key else { continue }
            cachedBytes -= candidate.value.byteCount
            cache[candidate.key] = nil
            CanvasLog.event(
                .canvas,
                "render cache: evicted a composite of \(candidate.value.byteCount) bytes at the "
                    + "\(byteBound)-byte bound; holding \(cache.count) at \(cachedBytes) bytes"
            )
        }
    }

    /// Read only by tests, which is how `Contract.md` — Performance's "a cache
    /// states its bound" becomes observable rather than merely written down.
    var cachedByteCount: Int { cachedBytes }
    var cachedCompositeCount: Int { cache.count }

    // MARK: - The render itself, off the actor and off main

    /// One page's static stack, flattened.
    ///
    /// `nonisolated` so the decode and the composite run on the global
    /// executor rather than on this actor: a second page asking for its
    /// composite must not queue behind this one's pixels.
    ///
    /// **Every layer is decoded before anything is drawn, and one failure
    /// refuses the whole composite.** A partial composite is the failure mode
    /// the layer model exists to prevent — it looks correct and is not
    /// (`Contract.md` — Invalid states fail loud). A page that cannot render
    /// honestly shows a refusal, never a picture missing a layer.
    nonisolated static func render(
        _ request: StaticLayerRequest,
        store: DocumentStore
    ) async -> StaticLayerRender {
        // Sampled before the first suspension, so it is the thread this
        // function actually began on. The contract's "File encoding and disk
        // I/O never run on main" is otherwise a claim nothing checks.
        //
        // `pthread_main_np` rather than `Thread.isMainThread`, which Swift 6
        // makes unavailable from an asynchronous context — reasonably, since
        // the question it usually answers is "am I on the main actor". Here the
        // thread genuinely is the question: this function is `nonisolated`, so
        // the guarantee being checked is that the global executor ran it.
        let builtOffMain = pthread_main_np() == 0

        let scale = request.pixelsPerPagePoint
        var placed: [(image: CGImage, transform: CGAffineTransform)] = []
        placed.reserveCapacity(request.layers.count)

        for layer in request.layers {
            guard layer.recognizedKind == .image else {
                return .refused(
                    "layer \(layer.layerID) is of kind \"\(layer.kind)\", which has no static rendering"
                )
            }

            let ref: ImageLayerRef
            do {
                ref = try ImageLayerRef(payload: layer.payload)
            } catch {
                return .refused("layer \(layer.layerID) has a payload that will not decode: \(error)")
            }
            guard let format = ref.recognizedFormat else {
                return .refused(
                    "layer \(layer.layerID) names asset format \"\(ref.format)\", "
                        + "which this build has no decoder for"
                )
            }

            let transform = layer.pageSpaceTransform
            guard transform.isInvertible else {
                return .refused("layer \(layer.layerID) has a singular transform and is not placeable")
            }

            let bytes: Data
            do {
                bytes = try await store.loadAsset(assetID: ref.assetID, format: format)
            } catch {
                return .refused("layer \(layer.layerID) could not read asset \(ref.assetID): \(error)")
            }

            guard let image = downsample(bytes, maxPixelSize: maxPixelSize(of: transform, at: scale)) else {
                return .refused("layer \(layer.layerID): asset \(ref.assetID) is not a decodable \(ref.format)")
            }

            placed.append((
                image,
                CGAffineTransform(
                    a: transform.a, b: transform.b,
                    c: transform.c, d: transform.d,
                    tx: transform.tx, ty: transform.ty
                )
            ))
        }

        let widthPixels = Int((request.geometry.width * scale).rounded())
        let heightPixels = Int((request.geometry.height * scale).rounded())
        guard widthPixels > 0, heightPixels > 0 else {
            return .refused("a composite of \(widthPixels)x\(heightPixels) pixels is not a page")
        }

        // Opaque, deliberately. The ink surface above goes transparent so this
        // shows through, and the fork doc prices that as the floor cost —
        // "marking the composite opaque holds the total at 2x". An alpha
        // channel here would make it three.
        guard let context = CGContext(
            data: nil,
            width: widthPixels,
            height: heightPixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return .refused("a \(widthPixels)x\(heightPixels) composite context could not be created")
        }

        // The page itself. The canvas above is transparent, so this is what
        // makes a page white.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: widthPixels, height: heightPixels))
        context.interpolationQuality = .high

        // Into page space: origin top-left, y down, units page points — the
        // space every durable transform is written in
        // (`Contract.md` — Geometry and coordinates). CoreGraphics is y-up
        // from the bottom left, so this is one flip, applied once.
        context.translateBy(x: 0, y: CGFloat(heightPixels))
        context.scaleBy(x: scale, y: -scale)

        for entry in placed {
            context.saveGState()
            // The durable transform maps the image's own extent, taken as the
            // unit square, into page space.
            context.concatenate(entry.transform)
            // A second flip inside the unit square: `CGContext.draw` lays an
            // image out bottom-up, and page space is y-down, so without this
            // every image renders upside down.
            context.translateBy(x: 0, y: 1)
            context.scaleBy(x: 1, y: -1)
            context.draw(entry.image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            context.restoreGState()
        }

        guard let image = context.makeImage() else {
            return .refused("the composite context yielded no image")
        }

        return .composited(
            StaticComposite(
                image: image,
                pixelsPerPagePoint: scale,
                byteCount: context.bytesPerRow * heightPixels,
                builtOffMain: builtOffMain
            )
        )
    }

    /// **Decode for the viewport, never for the source.**
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` with
    /// `kCGImageSourceThumbnailMaxPixelSize` decodes *at* the requested size
    /// rather than decoding the full bitmap and scaling it, so a 40-megapixel
    /// import placed a quarter of the way across a page never materializes as
    /// 160 MB of pixels.
    ///
    /// There is no separate "large image" threshold, and that is the point:
    /// the threshold is the layer's own placed extent in composite pixels,
    /// which is at most the composite's own long edge — about 2,800 px at the
    /// level-of-detail cap `PageCanvasController` applies. Every decode is
    /// bounded by where the layer actually lands, so no size of source is a
    /// special case.
    ///
    /// `kCGImageSourceCreateThumbnailWithTransform` applies the source's own
    /// orientation metadata. Without it a camera JPEG lands rotated, which is a
    /// wrong picture rather than a missing one.
    static func downsample(_ bytes: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            bytes as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// How many pixels of source this layer can possibly show, at this level of
    /// detail.
    ///
    /// The transform's columns are the images of the unit square's edges, so
    /// their lengths are the layer's placed extent in page points whatever
    /// rotation or skew the transform carries.
    ///
    /// The floor of 1 is not a clamped invalid state: a layer placed smaller
    /// than one composite pixel is a legal, if pointless, placement, and asking
    /// ImageIO for a zero-pixel thumbnail is meaningless.
    static func maxPixelSize(of transform: PageSpaceTransform, at scale: Double) -> Int {
        let widthPoints = (transform.a * transform.a + transform.b * transform.b).squareRoot()
        let heightPoints = (transform.c * transform.c + transform.d * transform.d).squareRoot()
        return max(1, Int((max(widthPoints, heightPoints) * scale).rounded(.up)))
    }
}

// MARK: - The values that cross the boundary

/// What the canvas runtime asks the renderer for: one page's static layers, in
/// order, and the level of detail to flatten them at.
///
/// Carries no page identity, by design — see `StaticLayerRenderer.CompositeKey`.
struct StaticLayerRequest: Sendable, Equatable {
    /// The page's recognized layers below the ink, in order. The ink layer is
    /// never here: PencilKit renders ink, above this texture, and a composite
    /// containing ink would be a derived artifact restating what the ink
    /// already says (`Contract.md` — Forbidden patterns).
    let layers: [LayerEnvelope]

    /// The page these layers are placed in, in page points. Part of the request
    /// since phase 3b: geometry is per page, so the composite's extent is a
    /// property of the page being asked about rather than of the application.
    /// It is part of the cache key too — the same layers in a differently sized
    /// page are a different picture.
    let geometry: PageGeometry

    /// Composite pixels per page point. Fit-width times the display scale, so
    /// the texture is pixel-exact at the scale the page opens at and merely
    /// soft when zoomed past it.
    let pixelsPerPagePoint: Double
}

/// One page's static stack, flattened.
struct StaticComposite: Sendable {
    let image: CGImage
    let pixelsPerPagePoint: Double

    /// The texture's cost, which is what the cache's bound is stated in.
    let byteCount: Int

    /// Whether this composite was built off the main thread. Read by tests:
    /// `Contract.md` — Performance forbids image work on main, and this is that
    /// rule in a form a test can fail on.
    let builtOffMain: Bool
}

/// What a page's static stack renders as. Three outcomes and no fourth: there
/// is deliberately no "partially rendered" case.
enum StaticLayerRender: Sendable {
    /// The page has no static layers. Not a failure — it is every page in a
    /// blank notebook, and it is the case that must cost nothing.
    case empty
    case composited(StaticComposite)
    /// The stack could not be rendered honestly. The page shows a refusal
    /// tint, never a composite missing a layer.
    case refused(String)
}
