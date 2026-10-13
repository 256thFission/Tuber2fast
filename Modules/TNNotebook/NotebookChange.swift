import Foundation
import PencilKit
import TNFormat
import TNModel

/// What the notebook tells the binding. Values only; the binding pushes
/// them to the surface after the intention that produced them returns.
package enum NotebookChange: Sendable {
    case structure([PageDescriptor], seq: StructureSeq, answering: ReportSeq?)
    case content(PageSnapshot)
    case unloaded(PageID)
    case inkRestored(PageID, PKDrawing, seq: InkSeq)
    case compositeUpdated(PageID, Composite, layers: [Layer])
    case textEditingBegan(PageID, TextEditStart)
    case textEditingEnded(PageID, LayerID)
}

/// Why the last save did not fully succeed. Typed, so the app can choose
/// the surface Part 7 names for each.
package enum SaveFailure: Sendable, Equatable {
    case insufficientSpace(needed: Int64, available: Int64)
    case io(FormatFault)
    case pagesRefused([PageID: PageRefusal])
    case indexWithheld
}

package enum CloseOutcome: Sendable, Equatable {
    case clean
    case dirty(pages: [PageID], indexUnsaved: Bool)
}
