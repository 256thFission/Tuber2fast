import Foundation
import TuberModel

/// What one page's runtime reports to whoever placed it.
///
/// The other half of `PagedCanvasSession`, one level down and inside this
/// module: a `PageCanvasController` is blind to which page it is
/// (`Contract.md` — Owners, golden rule 7), so it reports to its host and the
/// host adds the index. Required for the same reason and in the same way — a
/// page canvas cannot be constructed without a host, so there is no unwired
/// state in which a drawing change goes unreported or a refused layer
/// transform reads as accepted.
///
/// **Ownership**, as for `PagedCanvasSession`: the page holds its host
/// strongly so the reference can be non-optional, and the host that
/// `PagedCanvasController` supplies refers back to the runtime `unowned`. The
/// runtime owns the page, the page owns its host, and the host outlives
/// nothing.
@MainActor
package protocol PageCanvasHost: AnyObject {
    /// One coarse notification that the drawing changed. It carries no
    /// drawing, no sample, and no generation number (`Contract.md` — Saving).
    func drawingChanged()

    /// One committed layer transform, and whether the session accepted it.
    func layerTransformed(_ layerID: UUID, to transform: PageSpaceTransform) -> Bool
}
