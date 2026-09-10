import CoreGraphics
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
    /// `PaperKind`, not `Paper`: a placeholder for unknown paper names it.
    package let paper: PaperKind

    package init(id: PageID, geometry: PageGeometry, paper: PaperKind) {
        self.id = id
        self.geometry = geometry
        self.paper = paper
    }
}

/// A rendered backdrop: paper and every static layer, as pixels. `CGImage`
/// is immutable, which is what makes the wrapper a value for the seam.
package struct Composite: @unchecked Sendable, Equatable {
    package let image: CGImage
    /// Pixels per page point the image was rendered at.
    package let scale: CGFloat

    package init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    package static func == (lhs: Composite, rhs: Composite) -> Bool {
        lhs.image === rhs.image && lhs.scale == rhs.scale
    }
}

/// What the runtime is told about the editing environment: the tool.
package struct CanvasEnvironment: @unchecked Sendable {
    package let tool: PKTool
    package init(tool: PKTool) { self.tool = tool }
}

/// One page's content, pushed down as a value. Two shapes, two factories:
/// an editable page carries ink (empty means no strokes) and a sequence;
/// a placeholder carries faults and no ink. The memberwise form is private
/// so no third shape can be built.
package struct PageSnapshot: Sendable, Equatable {
    package let id: PageID
    package let ink: PKDrawing?
    package let layers: [Layer]
    package let composite: Composite?
    package let faults: [PageFault]
    package let inkSeq: InkSeq?

    private init(id: PageID, ink: PKDrawing?, layers: [Layer], composite: Composite?, faults: [PageFault], inkSeq: InkSeq?) {
        self.id = id
        self.ink = ink
        self.layers = layers
        self.composite = composite
        self.faults = faults
        self.inkSeq = inkSeq
    }

    package static func editable(id: PageID, ink: PKDrawing, layers: [Layer], composite: Composite?, inkSeq: InkSeq) -> PageSnapshot {
        PageSnapshot(id: id, ink: ink, layers: layers, composite: composite, faults: [], inkSeq: inkSeq)
    }

    package static func placeholder(id: PageID, faults: [PageFault]) -> PageSnapshot {
        PageSnapshot(id: id, ink: nil, layers: [], composite: nil, faults: faults, inkSeq: nil)
    }

    package var isEditable: Bool { faults.isEmpty }
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
    /// A sharper or refreshed backdrop for a live page; ink is untouched.
    func updateComposite(on page: PageID, _ composite: Composite)
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
    /// The system undo gesture or the toolbar, arriving through the runtime.
    func undoRequested()
    func redoRequested()
}
