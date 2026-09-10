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
    /// The rendered backdrop, a value the renderer produced.
    package var composite: Composite?
    package var editSeq: UInt64
    package var savedSeq: UInt64
    package var inkSeq: UInt64
    package var savedInkSeq: UInt64
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
        self.composite = nil
        self.editSeq = 0
        self.savedSeq = 0
        self.inkSeq = 0
        self.savedInkSeq = 0
        self.pendingLayerFiles = []
        self.pendingEcho = nil
        self.retired = false
    }

    /// An ink change: both sequences and the durable flag. History is the
    /// notebook's.
    package mutating func setInk(_ newInk: PKDrawing) {
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

/// One undo step: the page and the ink it returns to. Entries are values,
/// so the stack survives a page leaving the window; it lives as long as
/// the notebook is open, as GoodNotes' does.
package struct HistoryEntry: Sendable {
    package let page: PageID
    package let ink: PKDrawing
}

/// Undo and redo as one notebook-wide stack of ink values, bounded by
/// entries.
///
/// KNOWN DEFECT: the byte bound the spec states is not enforced, because a
/// PKDrawing's in-memory size is not observable without serializing it.
/// The entry bound stands in until the device spike measures what an entry
/// costs at 20k strokes.
package struct InkHistory: Sendable {
    package static let maximumEntries = 100

    package private(set) var undoStack: [HistoryEntry] = []
    package private(set) var redoStack: [HistoryEntry] = []

    package init() {}

    package var canUndo: Bool { !undoStack.isEmpty }
    package var canRedo: Bool { !redoStack.isEmpty }

    /// Records the state an undo returns to. A new edit clears redo.
    package mutating func recordEdit(on page: PageID, previous: PKDrawing) {
        undoStack.append(HistoryEntry(page: page, ink: previous))
        if undoStack.count > Self.maximumEntries { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// The entry to restore; `current` is what redo will return to.
    package mutating func undo(current: (PageID) -> PKDrawing?) -> HistoryEntry? {
        guard let entry = undoStack.popLast() else { return nil }
        if let ink = current(entry.page) { redoStack.append(HistoryEntry(page: entry.page, ink: ink)) }
        return entry
    }

    /// The redo entry for an undo whose page was not loaded when it ran:
    /// pushed when the page arrives and its current ink is known.
    package mutating func pushRedo(_ entry: HistoryEntry) {
        redoStack.append(entry)
    }

    package mutating func redo(current: (PageID) -> PKDrawing?) -> HistoryEntry? {
        guard let entry = redoStack.popLast() else { return nil }
        if let ink = current(entry.page) { undoStack.append(HistoryEntry(page: entry.page, ink: ink)) }
        return entry
    }
}
