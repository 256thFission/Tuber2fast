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

    package init(image: CGImage) {
        self.image = image
    }

    package static func == (lhs: Composite, rhs: Composite) -> Bool {
        lhs.image === rhs.image
    }
}

/// A point in page space.
package struct PagePoint: Sendable, Equatable {
    package let x: Double
    package let y: Double
    package init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// What the runtime is told to open: the layer as the notebook holds it.
package struct TextEditStart: Sendable, Equatable {
    package let layer: LayerID
    package let text: TextLayer
    package init(layer: LayerID, text: TextLayer) { self.layer = layer; self.text = text }
}

/// Ink is a `PKTool`; text is a style to type with, and the drawing
/// gesture is off.
package enum CanvasTool: @unchecked Sendable {
    case ink(PKTool)
    case text(TextStyle, TextAlignment)
}

/// What the runtime is told about the editing environment: the tool.
package struct CanvasEnvironment: @unchecked Sendable {
    package let tool: CanvasTool
    package init(tool: CanvasTool) { self.tool = tool }
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
    /// A sharper or refreshed backdrop for a live page, with the layer list
    /// it was rendered from, so the runtime's hit rects match the picture.
    /// Ink is untouched.
    func updateComposite(on page: PageID, _ composite: Composite, layers: [Layer])
    /// The layer and its value; arrives with the composite that omits the
    /// layer, and the runtime raises a live text view over it.
    func beginTextEditing(on page: PageID, _ start: TextEditStart)
    /// Arrives with the composite that has the committed text; the runtime
    /// takes the live view down.
    func endTextEditing(on page: PageID, layer: LayerID)
    /// The tool and any other chrome fact, pushed, never parked here.
    func apply(_ environment: CanvasEnvironment)
    /// Typing owns undo while a box is open. One-way; the text view's own
    /// manager answers and nothing is reported back.
    func undoTyping()
    func redoTyping()
}

/// Up: value reports and answered questions.
@MainActor package protocol CanvasReporting: AnyObject {
    func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?)
    func layerTransformed(on page: PageID, layer: LayerID, to transform: PageSpaceTransform) -> TransformOutcome
    /// Delete from the selected object's menu. Answered by an
    /// `updateComposite` that omits the layer, which is also what takes the
    /// selection frame down.
    func layerDeleteRequested(on page: PageID, layer: LayerID)
    /// Lock or Unlock from the selected object's menu. Answered by an
    /// `updateComposite` whose layer list carries the flag, which is what
    /// takes the handles down or puts them back.
    func layerLockRequested(on page: PageID, layer: LayerID, locked: Bool)
    func pageBecameCurrent(_ page: PageID)
    func windowChanged(to pages: [PageID])
    func endBoundaryReached(seq: ReportSeq)
    func linkActivated(on page: PageID, layer: LayerID)
    func retired(_ page: PageID, finalInk: PKDrawing?)
    /// The system undo gesture or the toolbar, arriving through the runtime.
    func undoRequested()
    func redoRequested()
    /// A tap on paper with the text tool; the tool's style rides with it.
    /// Answered by `beginTextEditing` once the composite omits the layer.
    func textBoxRequested(on page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment)
    /// A tap in a text rect with the text tool. Answered the same way.
    func textEditRequested(on page: PageID, layer: LayerID)
    /// The whole committed value. Answered by `endTextEditing` once the
    /// composite has the text.
    func textEditingEnded(on page: PageID, layer: LayerID, _ text: TextLayer)
}
