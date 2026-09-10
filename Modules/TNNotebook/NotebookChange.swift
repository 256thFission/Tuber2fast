import Foundation
import PencilKit
import TNModel

/// What the notebook tells the binding. Values only; the binding pushes
/// them to the surface after the intention that produced them returns.
package enum NotebookChange: Sendable {
    case structure([PageDescriptor], seq: StructureSeq, answering: ReportSeq?)
    case content(PageSnapshot)
    case inkRestored(PageID, PKDrawing, seq: InkSeq)
    case pageStateChanged(PageID)
}
