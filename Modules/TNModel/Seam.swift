import Foundation
import PencilKit

/// Monotonic sequence numbers that cross the seam. Each is its own type so a
/// structure sequence cannot be passed where an ink sequence is expected.
package struct StructureSeq: Hashable, Sendable, Comparable {
    package let raw: UInt64
    package init(_ raw: UInt64) { self.raw = raw }
    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
}

package struct InkSeq: Hashable, Sendable, Comparable {
    package let raw: UInt64
    package init(_ raw: UInt64) { self.raw = raw }
    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
}

package struct ReportSeq: Hashable, Sendable, Comparable {
    package let raw: UInt64
    package init(_ raw: UInt64) { self.raw = raw }
    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
}

/// What the runtime is told about a page's structure: identity, geometry,
/// paper. Enough to lay out a slot and draw a placeholder.
package struct PageDescriptor: Sendable, Equatable, Identifiable {
    package let id: PageID
    package let geometry: PageGeometry
    package let paper: Paper?

    package init(id: PageID, geometry: PageGeometry, paper: Paper?) {
        self.id = id
        self.geometry = geometry
        self.paper = paper
    }
}

/// One page's content, pushed down as a value. `ink == nil` means the page
/// has no ink yet (a blank page is editable). A page with faults is a
/// placeholder and `isEditable` is false.
package struct PageSnapshot: Sendable, Equatable {
    package let id: PageID
    package let ink: PKDrawing?
    package let layers: [Layer]
    package let faults: [PageFault]
    package let isEditable: Bool
    package let inkSeq: InkSeq

    package init(id: PageID, ink: PKDrawing?, layers: [Layer], faults: [PageFault], isEditable: Bool, inkSeq: InkSeq) {
        self.id = id
        self.ink = ink
        self.layers = layers
        self.faults = faults
        self.isEditable = isEditable
        self.inkSeq = inkSeq
    }
}

package enum TransformOutcome: Sendable, Equatable {
    case accepted
    case refused(reason: String)
}

package enum RetireOutcome: Sendable, Equatable {
    case retired
    case deferred
}

/// Down: the runtime is driven.
@MainActor package protocol CanvasSurface: AnyObject {
    func setPages(_ pages: [PageDescriptor], seq: StructureSeq, answering: ReportSeq?)
    func installContent(_ snapshot: PageSnapshot)
    func restoreInk(on page: PageID, _ ink: PKDrawing, seq: InkSeq)
    func scroll(to page: PageID)
    func retire(_ page: PageID) -> RetireOutcome
}

/// Up: value reports and answered questions.
@MainActor package protocol CanvasReporting: AnyObject {
    func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?)
    func layerTransformed(on page: PageID, layer: LayerID, to transform: PageSpaceTransform) -> TransformOutcome
    func pageBecameCurrent(_ page: PageID)
    func windowChanged(to pages: [PageID])
    func endBoundaryReached(seq: ReportSeq)
    func linkActivated(on page: PageID, layer: LayerID)
    func retired(_ page: PageID, finalInk: PKDrawing?)
}
