import Foundation
import PencilKit
import TNModel

/// Every page has one of these. The notebook holds custody of the newest
/// ink for every page in `ready`; a page in any other state has no ink in
/// memory and cannot be drawn on.
package enum PageState: Sendable {
    case unloaded
    case loading(generation: UInt64)
    case ready(PageContent)
    case unreadable([PageFault])

    package var content: PageContent? {
        if case .ready(let content) = self { return content }
        return nil
    }
}

/// A page's content in custody, and the bookkeeping that makes dirty a
/// derived fact: `editSeq > savedSeq`.
package struct PageContent: Sendable {
    package var ink: PKDrawing?
    package var layers: [Layer]
    package var hasInk: Bool
    package var inkIndex: Int
    package var editSeq: UInt64
    package var savedSeq: UInt64
    package var history: InkHistory
    /// Layers whose files must be written by the next save.
    package var pendingLayerFiles: Set<LayerID>
    /// The sequence of the last ink pushed down, whose echo is not an edit.
    package var pendingEcho: InkSeq?
    /// The runtime has retired this page's canvas; it may be pruned.
    package var retired: Bool

    package var isDirty: Bool { editSeq > savedSeq }

    package init(ink: PKDrawing?, layers: [Layer], hasInk: Bool, inkIndex: Int, editSeq: UInt64 = 0, savedSeq: UInt64 = 0) {
        self.ink = ink
        self.layers = layers
        self.hasInk = hasInk
        self.inkIndex = inkIndex
        self.editSeq = editSeq
        self.savedSeq = savedSeq
        self.history = InkHistory()
        self.pendingLayerFiles = []
        self.pendingEcho = nil
        self.retired = false
    }
}

/// Undo and redo as lists of ink values, bounded by entries.
///
/// KNOWN DEFECT: the byte bound the spec states (32 MB per page) is not
/// enforced, because a PKDrawing's in-memory size is not observable without
/// serializing it. The entry bound stands in until the device spike measures
/// what an entry costs at 20k strokes.
package struct InkHistory: Sendable {
    package static let maximumEntries = 50

    package private(set) var undoStack: [PKDrawing?] = []
    package private(set) var redoStack: [PKDrawing?] = []

    package init() {}

    package var canUndo: Bool { !undoStack.isEmpty }
    package var canRedo: Bool { !redoStack.isEmpty }

    /// Records `previous` as the state an undo returns to. A new edit
    /// clears redo, as every undo model does.
    package mutating func recordEdit(previous: PKDrawing?) {
        undoStack.append(previous)
        if undoStack.count > Self.maximumEntries { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    package mutating func undo(current: PKDrawing?) -> PKDrawing?? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return .some(previous)
    }

    package mutating func redo(current: PKDrawing?) -> PKDrawing?? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return .some(next)
    }
}
