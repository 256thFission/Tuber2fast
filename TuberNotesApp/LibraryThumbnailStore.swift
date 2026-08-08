import Foundation
import Observation
import PencilKit
import SwiftUI
import TuberModel
import TuberStore
import UIKit

/// The browser's page-1 thumbnails: an in-memory cache in front of an
/// off-main render of a closed document's first page.
///
/// It lives in the **app target**, not `TuberRender`, deliberately: the render
/// needs `PKDrawing` (PencilKit) and a UIKit image context, and `TuberRender`'s
/// machine-checked import policy is CoreGraphics-only. Widening a
/// machine-checked policy for a browser nicety is A15's mistake again
/// (`Docs/Forks/Library/02-proposal.md` §3).
///
/// The read that fills the cache is the one licensed read of a closed package
/// outside an editor session: **a read-only, per-package `DocumentStore`,
/// constructed for the render and discarded** (`Docs/Contract.proposed.md`
/// L5 — the reader was named because the review found the read path
/// unlicensed, `03-review.md` B5). Only ink is composited over the paper
/// color; static layers are explicitly out of scope tonight — a PDF-backed
/// page-1 is a per-cell asset decode that can reach tens of megabytes, which
/// is why ink-only renders are the frontier and static composites are not
/// built at all. The cell still reads as the page's ink.
@MainActor
@Observable
final class LibraryThumbnailStore {

    /// What a cache entry is keyed by: the package's library-relative path
    /// plus its modification date.
    ///
    /// A rename changes the key, so the same ink re-renders under the new
    /// path — an accepted cost, not a defect. A save changes `modifiedAt`, so
    /// a stale thumbnail is *impossible without any invalidation machinery*:
    /// the new listing carries a new date, the cell asks under a new key, and
    /// the old entry ages out by LRU rather than by anyone remembering to
    /// purge it.
    struct Key: Hashable, Sendable {
        let path: String
        let modifiedAt: Date
    }

    /// A finished entry: the render, or the fact that the package refused
    /// one. Refusals are cached on purpose (`03-review.md` B5): a corrupt
    /// package costs one failed decode, not one per scroll-past.
    enum Thumbnail {
        case image(UIImage)
        case refused
    }

    private struct Entry {
        let thumbnail: Thumbnail
        let cost: Int
    }

    // CACHE (Contract.md — Performance: a cache states its owner, its bound,
    // and what evicts it, at its declaration):
    //   owner    — this `LibraryThumbnailStore`, one instance for the browser,
    //              owned by `LibraryCoordinator`;
    //   bound    — `byteBound` bytes of rendered pixels (32 MB by default:
    //              a 160×212 pt @2x thumbnail is ~550 KB, so ≈60 cells), with
    //              refusals negative-cached as entries under the same bound
    //              at a nominal cost each;
    //   eviction — LRU, and nothing is ever written to disk (a durable
    //              thumbnail is forbidden by Forbidden patterns; a cold
    //              launch re-renders).
    private var entries: [Key: Entry] = [:]
    /// Least-recently-used first. Touched on install and on each cell's
    /// render request — not on `cached(for:)`, which SwiftUI bodies call and
    /// which therefore must not mutate observed state.
    private var recency: [Key] = []
    private var heldBytes = 0
    private let byteBound: Int

    /// What a refusal weighs under the bound. Nonzero so refusals age out
    /// with everything else instead of accreting forever.
    private static let refusalCost = 4096

    /// DEDUP, not staleness (CONTRIBUTING — Cancellation): `inFlight` and
    /// `waiters` answer "is someone already rendering this key?", never "is
    /// this still wanted?". A second request for a key in flight *joins* the
    /// render — it suspends until the runner resolves, then re-checks the
    /// cache — and never cancels or restarts it. Wanting is the per-cell
    /// task's business: `.task(id:)` cancels on scroll-away, and the render
    /// checkpoints notice.
    @ObservationIgnored private var inFlight: Set<Key> = []
    @ObservationIgnored private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    /// `byteBound` is injectable for the eviction tests only; the browser
    /// uses the default.
    init(byteBound: Int = 32 * 1024 * 1024) {
        self.byteBound = byteBound
    }

    // MARK: - What a cell reads

    /// The cached entry, or nil while none exists. Pure on purpose: SwiftUI
    /// bodies call this, and a body that mutates observed state re-renders
    /// itself forever. Recency moves in `renderIfNeeded`, which every visible
    /// cell's `.task(id:)` runs on appearance.
    func cached(for key: Key) -> Thumbnail? {
        entries[key]?.thumbnail
    }

    // MARK: - The per-cell request

    /// One cell's request: render `key` if nothing has, join the render if
    /// one is in flight, and return quietly when the cache already answers.
    ///
    /// Called from the cell's `.task(id: key)`, so the request is a per-cell
    /// structured `Task` cancelled the moment the cell scrolls away or its
    /// key changes — and the render below runs *in this task*, inheriting
    /// that cancellation (CONTRIBUTING — Getting off the main actor).
    func renderIfNeeded(for key: Key, documentURL: URL) async {
        while entries[key] == nil {
            if Task.isCancelled { return }
            if inFlight.contains(key) {
                // Join the render already in flight, never restart it. The
                // runner resumes every waiter when it resolves; the loop then
                // re-checks the cache, and if the runner was cancelled before
                // installing, the first waiter through becomes the new runner.
                await withCheckedContinuation { continuation in
                    waiters[key, default: []].append(continuation)
                }
                continue
            }

            inFlight.insert(key)
            let outcome = await Self.renderPageOne(documentURL: documentURL)
            inFlight.remove(key)
            let joined = waiters.removeValue(forKey: key) ?? []

            switch outcome {
            case .cancelled:
                break
            case .image(let image):
                // Pixel bytes, which is what the bound is written in.
                install(
                    Entry(
                        thumbnail: .image(image),
                        cost: Int(image.size.width * image.size.height) * 4
                    ),
                    for: key
                )
            case .refused:
                install(Entry(thumbnail: .refused, cost: Self.refusalCost), for: key)
            }

            for waiter in joined { waiter.resume() }
            return
        }
        touch(key)
    }

    // MARK: - Cache mechanics

    /// The install site's currency check, and why comparison is the whole
    /// answer here (CONTRIBUTING — Cancellation: sites that only compare say
    /// so): the key *is* the currency. A render carries the key it was asked
    /// under, and a save or rename that superseded it changed the key — so a
    /// late-finishing render installs under a key no cell will ask for again
    /// and ages out by LRU, never under the current one. The one comparison
    /// left to make is against the cache itself, so a joined double-request
    /// cannot double-count the bytes. A render that finished after its
    /// cell's cancel landed still installs — a completed result for a
    /// still-current key is a valid entry looking for somewhere to go.
    private func install(_ entry: Entry, for key: Key) {
        guard entries[key] == nil else { return }
        entries[key] = entry
        recency.append(key)
        heldBytes += entry.cost

        // LRU eviction against the byte bound. `count > 1` so the entry just
        // installed is never its own eviction victim — a single render larger
        // than a test-sized bound must not become a render-per-scroll loop.
        while heldBytes > byteBound, recency.count > 1 {
            let oldest = recency.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) {
                heldBytes -= evicted.cost
            }
        }
    }

    private func touch(_ key: Key) {
        guard let position = recency.firstIndex(of: key) else { return }
        recency.remove(at: position)
        recency.append(key)
    }

    // MARK: - The render, off-main

    private enum RenderOutcome {
        case image(UIImage)
        case refused
        case cancelled
    }

    /// The thumbnail's target box: ~160×212 pt at @2x, in pixels. The page is
    /// aspect-fit inside it, so the rendered image carries the page's own
    /// aspect ratio.
    private nonisolated static let targetPixels = CGSize(width: 320, height: 424)

    /// The paper the ink composites over — `LibraryStyle.paper`'s components,
    /// spelled as `UIColor` because the render runs off the main actor and
    /// UIKit's `UIColor(_: Color)` bridge is main-actor-isolated. Change the
    /// two together.
    private nonisolated static let paperColor = UIColor(
        red: 0.973, green: 0.965, blue: 0.925, alpha: 1
    )

    /// Page 1, rendered. `nonisolated static async`: it runs on the generic
    /// executor, off the main actor, *in the caller's task* — so the cell's
    /// `.task(id:)` cancelling on scroll-away is this render's cancellation,
    /// checked at the honest checkpoints: before the load, before the decode,
    /// before the raster (CONTRIBUTING — Cancellation).
    ///
    /// The `DocumentStore` constructed here is THE licensed reader of a
    /// closed package outside an editor session (`Docs/Contract.proposed.md`
    /// L5): read-only, per-package, constructed for this render and
    /// discarded with it. Every byte read passes through it; this file does
    /// no file I/O of its own.
    ///
    /// Every failure is a refusal, never a throw: a library-enumerated
    /// package whose index is gone or unreadable is a damaged document
    /// (`03-review.md` B2), and the cell's answer is the degraded badge, not
    /// an error surface. `load()` returning nil means no index — for an
    /// enumerated package that *is* the damaged case, so it refuses too.
    private nonisolated static func renderPageOne(documentURL: URL) async -> RenderOutcome {
        if Task.isCancelled { return .cancelled }
        let store = DocumentStore(directoryURL: documentURL)

        let index: DocumentIndex?
        do {
            index = try await store.load()
        } catch {
            return .refused
        }
        guard let index, let first = index.pages.first else { return .refused }

        if Task.isCancelled { return .cancelled }
        let page: LoadedPage
        do {
            page = try await store.loadPage(first.id)
        } catch {
            return .refused
        }

        // Before the decode: an ink payload can be megabytes.
        if Task.isCancelled { return .cancelled }
        let drawing: PKDrawing
        if page.inkData.isEmpty {
            // A page whose ink has never been written renders as blank paper —
            // a real image, not a placeholder, so the cell settles instead of
            // re-requesting forever.
            drawing = PKDrawing()
        } else {
            do {
                drawing = try PKDrawing(data: page.inkData)
            } catch {
                return .refused
            }
        }

        // Before the raster: the page-sized allocation.
        if Task.isCancelled { return .cancelled }
        return .image(composite(drawing, geometry: first.geometry))
    }

    /// Ink over paper, aspect-fit into the target box. Static layers are NOT
    /// composited — explicitly out of scope tonight (see the type comment).
    ///
    /// `UIGraphicsImageRenderer` and `PKDrawing.image(from:scale:)` are both
    /// documented safe off the main thread; the ink test's pixel assertions
    /// are the evidence this holds in the simulator too.
    private nonisolated static func composite(
        _ drawing: PKDrawing,
        geometry: PageGeometry
    ) -> UIImage {
        let pageRect = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        // Geometry is validated finite and positive (`PageGeometry.isValid`
        // gates every load), so the fit is well-defined.
        let fit = min(
            targetPixels.width / pageRect.width,
            targetPixels.height / pageRect.height
        )
        let pixelSize = CGSize(
            width: max(1, (pageRect.width * fit).rounded()),
            height: max(1, (pageRect.height * fit).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // pixelSize is already in pixels
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            paperColor.setFill()
            UIRectFill(CGRect(origin: .zero, size: pixelSize))
            if !drawing.strokes.isEmpty {
                drawing.image(from: pageRect, scale: fit)
                    .draw(in: CGRect(origin: .zero, size: pixelSize))
            }
        }
    }
}
