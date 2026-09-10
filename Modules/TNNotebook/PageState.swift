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

    package var isDirty: Bool { content?.isDirty ?? false }
}

/// A page's content in custody, and the bookkeeping that makes dirty a
/// derived fact. Two sequence pairs, because two files: `editSeq` says the
/// page file needs rewriting, `inkSeq` says the ink container does.
package struct PageContent: Sendable {
    /// Once a page is ready its ink is a value; empty means no strokes.
    package var ink: PKDrawing
    package var layers: [Layer]
    /// The durable flag: once true, every save writes the container.
    package var hasInk: Bool
    package var inkIndex: Int
    package var editSeq: UInt64
    package var savedSeq: UInt64
    package var inkSeq: UInt64
    package var savedInkSeq: UInt64
    package var history: InkHistory
    /// Layers whose files must be written by the next save.
    package var pendingLayerFiles: Set<LayerID>
    /// The sequence of the last ink pushed down, whose echo is not an edit.
    package var pendingEcho: InkSeq?
    /// The runtime has retired this page's canvas; it may be pruned.
    package var retired: Bool

    package var isDirty: Bool { editSeq > savedSeq }
    package var inkIsDirty: Bool { inkSeq > savedInkSeq }

    package init(ink: PKDrawing, layers: [Layer], hasInk: Bool, inkIndex: Int) {
        self.ink = ink
        self.layers = layers
        self.hasInk = hasInk
        self.inkIndex = inkIndex
        self.editSeq = 0
        self.savedSeq = 0
        self.inkSeq = 0
        self.savedInkSeq = 0
        self.history = InkHistory()
        self.pendingLayerFiles = []
        self.pendingEcho = nil
        self.retired = false
    }

    /// An ink change: history, both sequences, the durable flag.
    package mutating func setInk(_ newInk: PKDrawing, recordingHistory: Bool) {
        if recordingHistory { history.recordEdit(previous: ink) }
        ink = newInk
        hasInk = true
        editSeq += 1
        inkSeq += 1
    }

    /// A non-ink change: layers, index. The page file is due, the ink is not.
    package mutating func edited() {
        editSeq += 1
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

    package private(set) var undoStack: [PKDrawing] = []
    package private(set) var redoStack: [PKDrawing] = []

    package init() {}

    package var canUndo: Bool { !undoStack.isEmpty }
    package var canRedo: Bool { !redoStack.isEmpty }

    /// Records `previous` as the state an undo returns to. A new edit
    /// clears redo, as every undo model does.
    package mutating func recordEdit(previous: PKDrawing) {
        undoStack.append(previous)
        if undoStack.count > Self.maximumEntries { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    package mutating func undo(current: PKDrawing) -> PKDrawing? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    package mutating func redo(current: PKDrawing) -> PKDrawing? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
