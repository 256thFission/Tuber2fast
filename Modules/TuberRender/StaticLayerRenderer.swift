import CoreGraphics
import Foundation
import ImageIO
import TuberCore
import TuberModel
import TuberStore

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
/// Not a second owner. It writes nothing durable, owns no page state, and
/// answers questions: given a page's layer list and a level of detail, here is
/// the texture, or here is a refusal. It is *told* which page a request is for
/// — that is the cache's key and the unit its eviction is stated in — and it
/// asks nothing about page order, page numbers, or turns. `EditorSession`
/// remains the one writer of the list (`Contract.md` — Owners, golden rule 5)
/// and `DocumentStore` remains the only thing that touches files — this actor
/// reads asset bytes *through* the store's own entry point and never opens a
/// file itself.
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
package actor StaticLayerRenderer {
    private let store: any DocumentStoring

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
    // EVICTION: two rules, in this order. `retain(pageIDs:)` drops every
    //   entry whose page has left the live window plus the prefetch radius —
    //   that is the policy, and the session calls it on every turn.
    //   The byte bound is the backstop: after an insert, least-recently-used
    //   entries are dropped until the total is under it, never including the
    //   entry just inserted. Recency is kept as an order (`recency` below),
    //   so the backstop reads it rather than reconstructing it.
    //
    // A refusal is cached too, at zero bytes. Without that, a page whose asset
    // will not decode re-attempts the decode on every layout pass. Assets are
    // write-once, so a render of one can be missing but never stale — which is
    // exactly what makes caching either outcome safe.
    static let defaultByteBound = 96 * 1024 * 1024

    private let byteBound: Int
    private var cache: [CompositeKey: Entry] = [:]
    private var cachedBytes = 0

    /// Every cached key, least recently used first. This *is* the recency
    /// order, held rather than derived: a per-entry stamp only becomes an
    /// order once somebody sorts it, and the only place that needed the order
    /// was the byte-bound trim — which runs precisely when memory is tight, so
    /// it was the one path paying to reconstruct what every cheap path already
    /// knew.
    ///
    /// An array rather than a heap because the two questions this cache asks
    /// of recency are "who is oldest" and "skip that one, who is next", and a
    /// heap answers the second only by popping and re-pushing entries the trim
    /// is protecting. The array is also small by construction — the byte bound
    /// is stated in page-sized composites, so it holds a handful — which makes
    /// the linear touch below cheaper than the bookkeeping either alternative
    /// would need.
    ///
    /// A lens is not in here because a lens is not cached at all, and a warm
    /// hit deliberately does not touch it: the only thing that counts as a use
    /// is a `composite` call served from the cache, plus the insert itself.
    ///
    /// INVARIANT: `recency` holds exactly the keys of `cache`, once each. Every
    /// site that adds to or removes from `cache` maintains it in the same step,
    /// and `trimToByteBound` fails loud if it ever finds otherwise.
    private var recency: [CompositeKey] = []

    /// Requests being served right now, so two canvases asking for the same
    /// composite decode it once. The same idea as `EditorSession`'s
    /// `pageLoadsInFlight`, one level down.
    ///
    /// The full request travels with the task because the key deliberately
    /// omits transforms (see `CompositeKey`): joining a running render on key
    /// alone would hand a request for a *moved* layer the composite of where
    /// the layer used to be — a wrong picture the caller then records as
    /// satisfied. A non-matching request starts its own render and takes over
    /// the slot; the superseded task still answers its own awaiters.
    ///
    /// This is a **dedup** structure and not a staleness one
    /// (`CONTRIBUTING.md` — Cancellation): it answers "is someone already
    /// doing this?", never "is this still wanted?". The second question is
    /// answered by `renderAwaiters` below.
    private var inFlight: [CompositeKey: (request: StaticLayerRequest, task: Task<StaticLayerRender, Never>)] = [:]

    /// The awaiters of each in-flight render that have not been cancelled,
    /// as tickets.
    ///
    /// A render exists only to answer callers. When the last of them goes away
    /// — the page turned, the layer moved, the canvas retired — the render is
    /// cancelled and its slot cleared, which is how a superseded decode
    /// actually stops rather than merely being ignored. Counting rather than
    /// cancelling on the first departure is what preserves the in-flight join:
    /// a second canvas awaiting the same composite keeps it alive, which
    /// `inFlightDedupIsTransformAware` and `aJoinedRenderSurvivesOneAwaiterLeaving`
    /// hold together.
    ///
    /// Keyed by the task rather than by `CompositeKey`, because a superseded
    /// task keeps its awaiters after a newer request has taken its slot.
    private var renderAwaiters: [Task<StaticLayerRender, Never>: Set<Int>] = [:]
    private var nextAwaiterTicket = 0

    /// Awaited by every render task before it draws, when set. Exists so a
    /// test can hold a render in flight deterministically; the app never sets
    /// it.
    ///
    /// Debug-only, and the `#if` is load-bearing rather than tidy: this is a
    /// suspension point on a path the app runs, and in Release the path has no
    /// suspension point because these lines are not compiled. See
    /// `EditorSession.staticRendererForTesting` for why `#if DEBUG` is the
    /// idiom here rather than `@_spi(Testing)`.
    ///
    /// The store seam retired this one's sibling — `EditorSession`'s save
    /// delay became a store that does not return — and cannot retire this
    /// one: the gate keys on the *request*, which is the renderer's own
    /// vocabulary. `inFlightDedupIsTransformAware` releases two renders of the
    /// same layer, and so of the same asset, in a chosen order; a gate at the
    /// store cannot tell those two apart.
    #if DEBUG
    private var renderGateForTesting: (@Sendable (StaticLayerRequest) async -> Void)?

    func setRenderGateForTesting(_ gate: @escaping @Sendable (StaticLayerRequest) async -> Void) {
        renderGateForTesting = gate
    }
    #endif

    private struct Entry {
        let request: StaticLayerRequest
        let render: StaticLayerRender
        let byteCount: Int
        let pageID: UUID
    }

    /// The identity of one cached composite: whose page, which layers, at what
    /// level of detail.
    ///
    /// **The page ID is load-bearing and it used to be absent.** The claim it
    /// replaces was that layer IDs are unique within a page and minted as
    /// UUIDs, so the key needed no page identity — true only while every
    /// cached composite had at least one layer, which is a property of what
    /// this renderer happened to be asked for and never a property of the
    /// design. A layer-less page keyed on an empty list, and the empty set is
    /// disjoint with every set, so eviction dropped its composite on every
    /// turn including while it was the page on screen. Page identity makes
    /// both the key and the eviction a question about a page.
    ///
    /// It costs `PageCanvasController` nothing that golden rule 7 protects: it
    /// is *told* its page ID at construction, and remains blind to page
    /// numbers and to turns. Being told a UUID is telling, not asking.
    ///
    /// The key is not the whole request: transforms are compared by the stored
    /// `Entry.request` on lookup, so a layer that moved is a miss rather than a
    /// wrong picture.
    private struct CompositeKey: Hashable {
        let pageID: UUID
        let layerIDs: [UUID]
        let scaleMilli: Int
        /// Geometry is per page since phase 3b, so it belongs in the key: the
        /// same layer list flattened into a differently sized page is a
        /// different texture, and a key that ignored it would hand a landscape
        /// page the portrait composite of the same layers.
        let widthMilli: Int
        let heightMilli: Int

        init(_ request: StaticLayerRequest) {
            pageID = request.pageID
            layerIDs = request.layers.map(\.layerID)
            scaleMilli = Int((request.pixelsPerPagePoint * 1000).rounded())
            widthMilli = Int((request.geometry.width * 1000).rounded())
            heightMilli = Int((request.geometry.height * 1000).rounded())
        }
    }

    /// `byteBound` is injectable only so a test need not allocate 96 MB of
    /// pixels to watch the bound bite. The default is the only value the app
    /// uses.
    package init(store: any DocumentStoring, byteBound: Int = StaticLayerRenderer.defaultByteBound) {
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
    package func composite(for request: StaticLayerRequest) async -> StaticLayerRender {
        // The cheapest half of the win: a request whose caller was cancelled
        // before this ran — five pages into a flick — reaches no decoder at
        // all.
        if Task.isCancelled { return .cancelled }
        guard !request.layers.isEmpty else { return .empty }
        precondition(
            request.pixelsPerPagePoint.isFinite && request.pixelsPerPagePoint > 0,
            "a composite at \(request.pixelsPerPagePoint) pixels per page point is not a level of detail"
        )

        let key = CompositeKey(request)
        if let entry = cache[key], entry.request == request {
            touch(key)
            return entry.render
        }

        // Join a running render only when the *whole* request matches — the
        // key alone says nothing about transforms.
        if let running = inFlight[key], running.request == request {
            return await join(running.task, key: key)
        }

        // KNOWN DEFECT: a `retain(pageIDs:)` that lands while this render is
        // in flight is undone by the `remember` below, so a page that left the
        // live window mid-render keeps its composite until the next turn. One
        // entry, bounded by the byte bound, dropped by the next `retain`. The
        // fix is a generation stamp compared after the await, and it is not
        // worth the machinery for a cache that self-corrects on the next
        // swipe.
        #if DEBUG
        let gate = renderGateForTesting
        #endif
        let task = Task { [store] in
            #if DEBUG
            if let gate { await gate(request) }
            #endif
            return await Self.render(request, store: store)
        }
        inFlight[key] = (request, task)
        let render = await join(task, key: key)

        // Only the key's latest render is remembered. A superseded render —
        // one whose slot a newer request took over — still answers its own
        // awaiters above, but caching it would park a stale transform under a
        // key the newer request then misses forever. A cancelled render has no
        // slot either: `abandon` cleared it, so the check below is already
        // false and nothing half-drawn is ever cached.
        if inFlight[key]?.task == task {
            inFlight[key] = nil
            remember(render, for: request, key: key)
        }
        return render
    }

    /// Awaits one render as one awaiter, and cancels it if this awaiter was
    /// the last one that wanted it.
    ///
    /// The cancellation handler is why this exists at all: `Task { }` is
    /// unstructured, so cancelling the canvas's composite task does not reach
    /// the render it is waiting on. The handle is shared between awaiters by
    /// design (the in-flight join), so the render may only be cancelled once
    /// every awaiter has gone — which is what this counts.
    private func join(
        _ task: Task<StaticLayerRender, Never>,
        key: CompositeKey
    ) async -> StaticLayerRender {
        nextAwaiterTicket += 1
        let ticket = nextAwaiterTicket
        renderAwaiters[task, default: []].insert(ticket)

        let render = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // The handler runs synchronously on the cancelling task, so the
            // bookkeeping hops back here. One hop per abandoned render, at
            // page-turn and selection frequency — never per input sample.
            Task { await self.abandon(task, ticket: ticket, key: key) }
        }

        renderAwaiters[task]?.remove(ticket)
        if renderAwaiters[task]?.isEmpty == true { renderAwaiters[task] = nil }
        return render
    }

    /// One awaiter stopped wanting a render.
    private func abandon(
        _ task: Task<StaticLayerRender, Never>,
        ticket: Int,
        key: CompositeKey
    ) {
        guard var outstanding = renderAwaiters[task] else { return }
        outstanding.remove(ticket)
        guard outstanding.isEmpty else {
            renderAwaiters[task] = outstanding
            return
        }
        renderAwaiters[task] = nil
        task.cancel()
        // Cleared in the same step as the cancel, so a request arriving after
        // this point starts a fresh render instead of joining one already on
        // its way to `.cancelled`.
        if inFlight[key]?.task == task { inFlight[key] = nil }
    }

    /// Read only by tests: that a cancelled render's slot is released is
    /// otherwise observable only as the absence of something, and a test that
    /// waits on an absence waits on the machine's load instead
    /// (`CONTRIBUTING.md` — Rules for any check you add).
    var inFlightRenderCount: Int { inFlight.count }

    /// Read only by tests: how many awaiters are still waiting on a render.
    /// The join's refcount decides whether a cancel may stop the work, so a
    /// test proving "one awaiter leaving does not cancel the other" needs a
    /// positive signal that the second one arrived.
    var renderAwaiterCount: Int { renderAwaiters.values.reduce(0) { $0 + $1.count } }

    // MARK: - The prefetch warm

    /// Renders a composite into the cache so a coming page turn finds it
    /// warm, without counting as a use.
    ///
    /// The "at turn: prefetch" moment of the fork doc's zoom story: the
    /// session calls this for the pages in its prefetch radius after a
    /// settled turn — and turns settle exactly once
    /// (`PagedCanvasControllerTests` pins it), so an abandoned half-drag
    /// warms nothing and nothing decodes twice. A hit returns without
    /// touching the entry's recency: a warm is speculation, and speculation
    /// must not displace what a user actually looked at in the LRU order. A
    /// warm for a page that leaves the window before it lands is dropped by
    /// the next `retain`, which is the droppability this path needs — the
    /// session holds no handle to a warm and cancels nothing, because a warm
    /// that lands is a cache hit for the next turn rather than wasted work.
    /// Were one ever cancelled, `composite`'s join would carry it through.
    package func warm(_ request: StaticLayerRequest) async {
        guard !request.layers.isEmpty else { return }
        let key = CompositeKey(request)
        if let entry = cache[key], entry.request == request { return }
        _ = await composite(for: request)
    }

    // MARK: - The lens

    /// The visible sub-rect of one page's static stack, rendered at the
    /// settled zoom's own level of detail — the "lens" half of the fork doc's
    /// base-and-lens design.
    ///
    /// Never called from a gesture frame: during a pinch the compositor
    /// scales the base texture, and only at settle does
    /// `PageCanvasController` ask for this. **Decode for the viewport, never
    /// for the source**: `visibleRect` is viewport-sized at any zoom, so the
    /// context this builds is bounded by the screen, and a pdf layer
    /// rasterizes only the sub-rect of its source the viewport shows.
    ///
    /// **Deliberately uncached and never coalesced.** A lens is a render of
    /// one settled viewport, keyed by a rect of floats that never repeats
    /// exactly; caching it would put viewport-sized entries under a byte
    /// bound whose arithmetic is stated in page-sized composites, and an
    /// in-flight join keyed on anything less than the whole request is the
    /// stale-picture bug the composite path just fixed. Each settle renders
    /// once; staleness is the caller's generation guard, and the only lens
    /// retained is the one texture `PageBackdrop` is showing.
    ///
    /// `visibleRect` must already be clamped to the page — the rasterizer
    /// refuses out-of-page sub-rects, and this function additionally
    /// intersects per layer, so a caller that clamps can never be refused for
    /// geometry.
    package func lens(for request: StaticLayerRequest, visibleRect: CGRect) async -> StaticLayerRender {
        // No task handle and no join: a lens is never shared, so this call and
        // everything below it runs inside the caller's own task and inherits
        // its cancellation directly. That is the ordinary case
        // (`CONTRIBUTING.md` — Cancellation); `composite`'s ticketing exists
        // only because its render handle is shared.
        if Task.isCancelled { return .cancelled }
        precondition(
            request.pixelsPerPagePoint.isFinite && request.pixelsPerPagePoint > 0,
            "a lens at \(request.pixelsPerPagePoint) pixels per page point is not a level of detail"
        )
        #if DEBUG
        if let gate = renderGateForTesting { await gate(request) }
        #endif
        return await Self.renderLens(request, visibleRect: visibleRect, store: store)
    }

    /// Images inside the lens decode no finer than this long edge — the same
    /// texture-budget number the base composite's level-of-detail cap rests
    /// on. The fork doc's "an image past a size threshold renders through the
    /// same base-and-lens path" is deliberately **not** built: an image in
    /// the lens is present and correctly placed, but no sharper than in the
    /// base. `Docs/Forks/ImplementationStatus.md` records the gap.
    private static let lensImageMaxPixelSize = 2800

    /// `nonisolated` for the reason `render` is: the rasterization runs on
    /// the global executor, never on this actor and never on main.
    nonisolated static func renderLens(
        _ request: StaticLayerRequest,
        visibleRect: CGRect,
        store: any DocumentStoring
    ) async -> StaticLayerRender {
        guard !request.layers.isEmpty else { return .empty }
        let builtOffMain = pthread_main_np() == 0

        let scale = request.pixelsPerPagePoint
        let widthPixels = Int((visibleRect.width * scale).rounded())
        let heightPixels = Int((visibleRect.height * scale).rounded())
        guard widthPixels > 0, heightPixels > 0 else {
            return .refused("a lens of \(widthPixels)x\(heightPixels) pixels is not a viewport")
        }
        // Before the viewport-sized context is allocated: a settle the user
        // has already zoomed away from allocates nothing.
        if Task.isCancelled { return .cancelled }

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
            return .refused("a \(widthPixels)x\(heightPixels) lens context could not be created")
        }

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: widthPixels, height: heightPixels))
        context.interpolationQuality = .high

        // Into page space, windowed to the visible rect: the one y-flip, then
        // a translation so page-point coordinates draw directly.
        context.translateBy(x: 0, y: CGFloat(heightPixels))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -visibleRect.minX, y: -visibleRect.minY)

        for layer in request.layers {
            // One checkpoint per layer, for the reason `render` has one.
            if Task.isCancelled { return .cancelled }
            let transform = layer.pageSpaceTransform
            guard transform.isInvertible else {
                return .refused("layer \(layer.layerID) has a singular transform and is not placeable")
            }

            switch layer.recognizedKind {
            case .image:
                // Present and placed, bounded as the base bounds it: the
                // sharp-at-depth path is pdf's. See `lensImageMaxPixelSize`.
                guard let ref = try? ImageLayerRef(payload: layer.payload),
                      let format = ref.recognizedFormat,
                      let bytes = try? await store.loadAsset(assetID: ref.assetID, format: format),
                      let image = downsample(
                          bytes,
                          maxPixelSize: min(
                              maxPixelSize(of: transform, at: scale), lensImageMaxPixelSize
                          )
                      )
                else {
                    return .refused("layer \(layer.layerID) could not decode for the lens")
                }
                context.saveGState()
                context.concatenate(
                    CGAffineTransform(
                        a: transform.a, b: transform.b, c: transform.c, d: transform.d,
                        tx: transform.tx, ty: transform.ty
                    )
                )
                context.translateBy(x: 0, y: 1)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                context.restoreGState()

            case .pdf:
                let ref: PDFLayerRef
                do {
                    ref = try PDFLayerRef(payload: layer.payload)
                } catch {
                    return .refused("layer \(layer.layerID) has a payload that will not decode: \(error)")
                }
                let bytes: Data
                do {
                    bytes = try await store.loadAsset(assetID: ref.assetID, format: .pdf)
                } catch {
                    return .refused("layer \(layer.layerID) could not read asset \(ref.assetID): \(error)")
                }

                // The sharp path needs the placed rectangle as a rectangle:
                // pdf layers are not selectable, so every one this build can
                // have written is an axis-aligned scale-and-translate. Any
                // other transform is refused rather than approximated — a
                // lens showing the worksheet somewhere it is not would be a
                // wrong picture at the worst possible sharpness.
                guard transform.b == 0, transform.c == 0, transform.a > 0, transform.d > 0 else {
                    return .refused(
                        "layer \(layer.layerID) carries a non-axis-aligned pdf transform, "
                            + "which no lens this build renders"
                    )
                }
                let placed = CGRect(x: transform.tx, y: transform.ty, width: transform.a, height: transform.d)
                let target = placed.intersection(visibleRect)
                if target.isEmpty { continue }

                do {
                    // One open for this layer's whole contribution to this
                    // lens: the handle lives and dies inside this call, on the
                    // global executor, and is never shared or cached
                    // (`OpenPDFDocument`).
                    let document = try OpenPDFDocument(bytes: bytes)
                    let display = try document.displaySize(sourcePageIndex: ref.sourcePageIndex)
                    // The visible part of the layer, mapped back into the
                    // source's own display points — and intersected with the
                    // source's page so float arithmetic can never hand the
                    // rasterizer a rect it refuses.
                    let source = CGRect(
                        x: (target.minX - placed.minX) / placed.width * display.width,
                        y: (target.minY - placed.minY) / placed.height * display.height,
                        width: target.width / placed.width * display.width,
                        height: target.height / placed.height * display.height
                    ).intersection(CGRect(origin: .zero, size: display))
                    if source.isEmpty { continue }

                    let rasterScale = max(
                        Double(placed.width) * scale / Double(display.width),
                        Double(placed.height) * scale / Double(display.height)
                    )
                    let image = try document.rasterize(
                        sourcePageIndex: ref.sourcePageIndex,
                        pixelsPerPagePoint: rasterScale,
                        subRect: source
                    )
                    // Draw the raster over exactly the page-space region it
                    // shows. CGContext lays an image out bottom-up and page
                    // space is y-down, so one local flip about the target.
                    context.saveGState()
                    context.translateBy(x: target.minX, y: target.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(
                        image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height)
                    )
                    context.restoreGState()
                } catch {
                    return .refused(
                        "layer \(layer.layerID): asset \(ref.assetID) page "
                            + "\(ref.sourcePageIndex) will not rasterize for the lens: \(error)"
                    )
                }

            case .ink, nil:
                return .refused(
                    "layer \(layer.layerID) is of kind \"\(layer.kind)\", which has no static rendering"
                )
            }
        }

        guard let image = context.makeImage() else {
            return .refused("the lens context yielded no image")
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

    // MARK: - One layer, on its own

    /// One layer's own source, decoded for where that layer lands.
    ///
    /// Phase 4's lift: while a layer is being manipulated it is drawn live
    /// above a composite rendered *without* it, and this is the image that
    /// draws it. It is deliberately **not** a composite — no page-sized
    /// context, no white fill, no other layer — because it has to sit over the
    /// stack with its own alpha rather than replace it.
    ///
    /// **Not cached, and that is deliberate.** A selection is a user action,
    /// not a frame: this runs once when a layer is selected and never during
    /// the drag it precedes. Adding it to the composite cache would put a
    /// second kind of entry under a byte bound whose whole arithmetic is stated
    /// in page-sized composites.
    ///
    /// `nil` is a refusal, and the caller's response is to leave the layer in
    /// the composite where it already is. That ordering matters: the composite
    /// may only drop a layer once something else is drawing it, or the layer
    /// would simply vanish.
    ///
    /// A cancelled lift also answers `nil`, which is safe for exactly one
    /// reason: the only task that can be cancelled here is the caller's own,
    /// and `PageCanvasController` re-checks its own cancellation before it
    /// treats `nil` as "this layer cannot be lifted". Shared like `composite`
    /// is, this would need `composite`'s ticketing; a lift is never shared.
    package func sourceImage(for layer: LayerEnvelope, at pixelsPerPagePoint: Double) async -> CGImage? {
        if Task.isCancelled { return nil }
        precondition(
            pixelsPerPagePoint.isFinite && pixelsPerPagePoint > 0,
            "a source at \(pixelsPerPagePoint) pixels per page point is not a level of detail"
        )
        return await Self.decodeSource(layer, at: pixelsPerPagePoint, store: store)
    }

    /// `nonisolated` for the same reason `render` is: the decode runs on the
    /// global executor rather than on this actor, so it cannot queue behind a
    /// composite or hold one up.
    nonisolated static func decodeSource(
        _ layer: LayerEnvelope,
        at scale: Double,
        store: any DocumentStoring
    ) async -> CGImage? {
        guard layer.recognizedKind == .image else { return nil }

        let ref: ImageLayerRef
        do {
            ref = try ImageLayerRef(payload: layer.payload)
        } catch {
            CanvasLog.event(
                .canvas,
                "layer \(layer.layerID) cannot be lifted: its payload will not decode: \(error)"
            )
            return nil
        }
        guard let format = ref.recognizedFormat else { return nil }
        guard layer.pageSpaceTransform.isInvertible else { return nil }

        let bytes: Data
        do {
            bytes = try await store.loadAsset(assetID: ref.assetID, format: format)
        } catch {
            CanvasLog.event(
                .canvas,
                "layer \(layer.layerID) cannot be lifted: asset \(ref.assetID) "
                    + "could not be read: \(error)"
            )
            return nil
        }

        // After the read and before the decode: the selection moved on while
        // the asset was coming off disk, so the decode is nobody's.
        if Task.isCancelled { return nil }

        // The same bound the composite decodes to, so a lifted layer is exactly
        // as sharp as the one it replaced and no sharper.
        return downsample(bytes, maxPixelSize: maxPixelSize(of: layer.pageSpaceTransform, at: scale))
    }

    // MARK: - Eviction

    /// Drops every composite whose page has left the live window plus the
    /// prefetch radius. **This is the eviction policy**; the byte bound below
    /// is only the backstop.
    ///
    /// Keyed on page IDs, and it was keyed on layer IDs until a layer-less page
    /// could exist. A page with no static layers has no layer ID to be live by,
    /// and the empty set is disjoint with every set, so its composite was
    /// dropped by every turn — including the turn that landed on it. `EditorSession`
    /// — which owns page order — computes the live set either way; what changed
    /// is that eviction is now a question with an answer for every page.
    ///
    /// `protecting` names the page the user is looking at: its composite is
    /// exempt from the byte-bound trim, though never from this window eviction
    /// itself. It exists for the prefetch warm (phase 3c) — five pages of
    /// warmed composites can legitimately exceed the byte bound, and without
    /// this the LRU backstop could answer that pressure by evicting the one
    /// composite that is on screen, which is speculation costing the user a
    /// visible re-render.
    package func retain(pageIDs live: Set<UUID>, protecting visible: Set<UUID> = []) {
        protectedPageIDs = visible
        var dropped = 0
        for (key, entry) in cache where !live.contains(entry.pageID) {
            cachedBytes -= entry.byteCount
            cache[key] = nil
            dropped += 1
        }
        if dropped > 0 {
            // The recency order names exactly what the cache holds, so the
            // keys just dropped leave it in the same step.
            recency.removeAll { cache[$0] == nil }
            CanvasLog.event(
                .canvas,
                "render cache: dropped \(dropped) composite(s) that left the live window; "
                    + "holding \(cache.count) at \(cachedBytes) bytes"
            )
        }
    }

    private func remember(_ render: StaticLayerRender, for request: StaticLayerRequest, key: CompositeKey) {
        if case .cancelled = render {
            // Unreachable: a render is cancelled only by `abandon`, which
            // clears the slot in the same step, and `composite` remembers only
            // the render still holding the slot. Stated as a trap because the
            // alternative — caching half-drawn pixels under a live key — is a
            // wrong picture served forever after.
            preconditionFailure("a cancelled render reached the cache")
        }
        let bytes: Int
        if case .composited(let composite) = render { bytes = composite.byteCount } else { bytes = 0 }

        if let existing = cache[key] { cachedBytes -= existing.byteCount }
        cache[key] = Entry(
            request: request,
            render: render,
            byteCount: bytes,
            pageID: request.pageID
        )
        cachedBytes += bytes
        // An insert is a use: what was just rendered is what a caller is about
        // to show.
        touch(key)
        trimToByteBound(protecting: key)
    }

    /// The visible page, whose composite is exempt from the byte-bound trim.
    /// Set by `retain(pageIDs:protecting:)` — the session, which is the one
    /// place that knows which page is visible — and empty until it says.
    ///
    /// A set rather than one ID because the visible *window* is what the
    /// session protects, and it is more than one page on a wide layout.
    private var protectedPageIDs: Set<UUID> = []

    /// Records that `key` was just used, which is what makes it the last thing
    /// the trim below would drop.
    ///
    /// A `warm` hit does not come through here, deliberately: speculation must
    /// not displace what a user actually looked at.
    private func touch(_ key: CompositeKey) {
        if let existing = recency.firstIndex(of: key) { recency.remove(at: existing) }
        recency.append(key)
    }

    /// The byte-bound backstop, and its whole policy in one sentence:
    ///
    /// **walk the cache oldest use first and drop entries until the total is
    /// under the bound, passing over exactly two — the entry just inserted,
    /// and any composite of the visible page.**
    ///
    /// The entry just inserted is passed over because a composite bigger than
    /// the whole bound would otherwise be evicted before it was ever shown, and
    /// the page would re-render it on the next layout pass forever. The visible
    /// page's is passed over because its composite is never traded for
    /// speculation. When everything left is passed over the walk simply
    /// finishes over-bound — a bounded overshoot of one page's composites,
    /// corrected by the next `retain`.
    ///
    /// The walk reads `recency` rather than ordering the cache itself. This is
    /// the path that runs under memory pressure, so it is the last place that
    /// should be sorting `cache.count` entries and copying their requests to do
    /// it; the order it needs is maintained by `touch`, at page-turn frequency,
    /// where nothing is competing for the CPU.
    private func trimToByteBound(protecting key: CompositeKey) {
        guard cachedBytes > byteBound else { return }
        var kept: [CompositeKey] = []
        kept.reserveCapacity(recency.count)
        for candidate in recency {
            guard let entry = cache[candidate] else {
                preconditionFailure("the recency order names a composite the cache does not hold")
            }
            guard cachedBytes > byteBound,
                  candidate != key,
                  !protectedPageIDs.contains(entry.pageID)
            else {
                kept.append(candidate)
                continue
            }
            cachedBytes -= entry.byteCount
            cache[candidate] = nil
            CanvasLog.event(
                .canvas,
                "render cache: evicted a composite of \(entry.byteCount) bytes at the "
                    + "\(byteBound)-byte bound; holding \(cache.count) at \(cachedBytes) bytes"
            )
        }
        recency = kept
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
        store: any DocumentStoring
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
            // The honest checkpoint of this function: one per layer, before
            // the decode that is the expensive thing. A ten-layer page
            // superseded mid-flick stops at the next layer rather than
            // decoding the remaining nine (`CONTRIBUTING.md` — Cancellation).
            if Task.isCancelled { return .cancelled }
            let transform = layer.pageSpaceTransform
            guard transform.isInvertible else {
                return .refused("layer \(layer.layerID) has a singular transform and is not placeable")
            }

            let image: CGImage
            switch layer.recognizedKind {
            case .image:
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

                let bytes: Data
                do {
                    bytes = try await store.loadAsset(assetID: ref.assetID, format: format)
                } catch {
                    return .refused("layer \(layer.layerID) could not read asset \(ref.assetID): \(error)")
                }

                guard let decoded = downsample(bytes, maxPixelSize: maxPixelSize(of: transform, at: scale)) else {
                    return .refused("layer \(layer.layerID): asset \(ref.assetID) is not a decodable \(ref.format)")
                }
                image = decoded

            case .pdf:
                // Phase 3c: a pdf layer rasterizes through the one place that
                // opens a PDF. The decode is bounded exactly the way an image
                // layer's is — by where the layer lands on the page at this
                // level of detail, never by the source (`Docs/Forks/
                // CanvasFeatureComplete.md` — "decode for the viewport, never
                // for the source"). The raster is baked into this composite,
                // so its pixels count against the same byte bound every
                // composite does.
                let ref: PDFLayerRef
                do {
                    ref = try PDFLayerRef(payload: layer.payload)
                } catch {
                    return .refused("layer \(layer.layerID) has a payload that will not decode: \(error)")
                }

                let bytes: Data
                do {
                    bytes = try await store.loadAsset(assetID: ref.assetID, format: .pdf)
                } catch {
                    return .refused("layer \(layer.layerID) could not read asset \(ref.assetID): \(error)")
                }

                do {
                    // Pixels per *source* point: the placed extent in composite
                    // pixels, divided by the source's own extent, per axis, and
                    // the finer of the two so neither axis undersamples. For an
                    // imported page — the unit square edge to edge — both
                    // ratios equal the composite's own scale.
                    // One open per layer per composite: the handle lives and
                    // dies inside this call, on the global executor, and is
                    // never shared or cached (`OpenPDFDocument`).
                    let document = try OpenPDFDocument(bytes: bytes)
                    let display = try document.displaySize(sourcePageIndex: ref.sourcePageIndex)
                    let widthPoints = (transform.a * transform.a + transform.b * transform.b).squareRoot()
                    let heightPoints = (transform.c * transform.c + transform.d * transform.d).squareRoot()
                    let rasterScale = max(
                        widthPoints * scale / Double(display.width),
                        heightPoints * scale / Double(display.height)
                    )
                    guard rasterScale.isFinite, rasterScale > 0 else {
                        return .refused(
                            "layer \(layer.layerID) rasterizes at scale \(rasterScale), "
                                + "which is not a level of detail"
                        )
                    }
                    image = try document.rasterize(
                        sourcePageIndex: ref.sourcePageIndex,
                        pixelsPerPagePoint: rasterScale
                    )
                } catch {
                    return .refused(
                        "layer \(layer.layerID): asset \(ref.assetID) page "
                            + "\(ref.sourcePageIndex) will not rasterize: \(error)"
                    )
                }

            case .ink, nil:
                return .refused(
                    "layer \(layer.layerID) is of kind \"\(layer.kind)\", which has no static rendering"
                )
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

        // The second honest checkpoint, and the one review finding 13 is
        // about: the page-sized context below is the ~24 MB allocation, and a
        // flick used to hold one per superseded render.
        if Task.isCancelled { return .cancelled }

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
package struct StaticLayerRequest: Sendable, Equatable {
    /// Whose page this is. Not used to *find* anything on disk — this renderer
    /// still reads only the assets its layers name — but it is the identity
    /// the cache is keyed and evicted by, and it is the only reason a page
    /// with no static layers can be cached at all.
    let pageID: UUID

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
    package let pixelsPerPagePoint: Double

    // Spelled out because a memberwise initializer is `internal` however
    // visible its type is, and the canvas runtime builds the request.
    package init(
        pageID: UUID,
        layers: [LayerEnvelope],
        geometry: PageGeometry,
        pixelsPerPagePoint: Double
    ) {
        self.pageID = pageID
        self.layers = layers
        self.geometry = geometry
        self.pixelsPerPagePoint = pixelsPerPagePoint
    }
}

/// One page's static stack, flattened.
package struct StaticComposite: Sendable {
    package let image: CGImage
    package let pixelsPerPagePoint: Double

    /// The texture's cost, which is what the cache's bound is stated in.
    package let byteCount: Int

    /// Whether this composite was built off the main thread. Read by tests:
    /// `Contract.md` — Performance forbids image work on main, and this is that
    /// rule in a form a test can fail on.
    package let builtOffMain: Bool
}

/// What a page's static stack renders as. Four outcomes and no fifth: there
/// is deliberately no "partially rendered" case.
package enum StaticLayerRender: Sendable {
    /// The page has no static layers. Not a failure — it is every page in a
    /// blank notebook, and it is the case that must cost nothing.
    case empty
    case composited(StaticComposite)
    /// The stack could not be rendered honestly. The page shows a refusal
    /// tint, never a composite missing a layer.
    case refused(String)
    /// Nobody was left who wanted this render, so it stopped where it was.
    ///
    /// Its own case rather than a refusal, and the distinction is load-bearing
    /// twice: a refusal is cached (assets are write-once, so a refusal cannot
    /// go stale) and a stopped render must never be, and a refusal paints the
    /// page's refusal tint, which a page the user merely swiped past must
    /// never flash. Nothing installs this — the only caller that can receive
    /// it is one that was itself cancelled.
    case cancelled
}
