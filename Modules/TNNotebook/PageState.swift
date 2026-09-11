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
    /// The live text session, if one is open. Never saved; it is what
    /// `rerenderComposite` reads to leave that layer out of the picture.
    package var textEditing: TextSession?
    /// Taken by every render; a result whose generation is no longer current
    /// is dropped at install. Comparison is the whole answer here: the
    /// renderer owns no droppable work of ours to cancel, and a stale
    /// composite costs nothing but the bytes it already spent.
    package var renderGeneration: UInt64
    /// Changes that ride behind the next composite that lands current:
    /// `.textEditingBegan` and `.textEditingEnded`. A superseded render
    /// leaves them for the current one, so a begin and an end milliseconds
    /// apart both arrive, in order, after the picture that reflects both.
    package var afterRender: [NotebookChange]

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
        self.textEditing = nil
        self.renderGeneration = 0
        self.afterRender = []
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

    package var revision: PageRevision {
        PageRevision(ink: ink, layers: layers, inkIndex: inkIndex)
    }

    /// Moves the page to `revision`, touching only the half that differs,
    /// and says which. The pending-layer arithmetic lives here alone, so a
    /// restore on a ready page and one folded into a load cannot drift.
    package mutating func adopt(_ revision: PageRevision) -> (ink: Bool, layers: Bool) {
        let inkDiffers = ink != revision.ink
        let layersDiffer = layers != revision.layers || inkIndex != revision.inkIndex
        if inkDiffers { setInk(revision.ink) }
        if layersDiffer {
            // A layer the revision removes is not pending: its file stays on
            // disk because only `compact()` deletes, and the page file stops
            // naming it.
            for layer in revision.layers where !layers.contains(layer) {
                pendingLayerFiles.insert(layer.id)
            }
            layers = revision.layers
            inkIndex = revision.inkIndex
            edited()
        }
        return (inkDiffers, layersDiffer)
    }
}

/// A text box being edited, and the revision the page had when the
/// session opened. One value, so the open layer and the revision the
/// commit records against cannot drift apart. For a box the session
/// created, `before` predates the box: the creation and the typing undo
/// as one step.
package struct TextSession: Sendable, Equatable {
    package let layer: LayerID
    package let before: PageRevision
}

/// What a page looked like at one moment. A value; ink is copy-on-write
/// and the layer list is small, so an entry costs what changed.
package struct PageRevision: Sendable, Equatable {
    package let ink: PKDrawing
    package let layers: [Layer]
    package let inkIndex: Int
}

/// One undo step: the page, the revision it had before the edit and the
/// revision the edit produced. Both sides, so undo pushes a complete redo
/// entry whether or not the page is loaded. Entries are values, so the
/// stack survives a page leaving the window; it lives as long as the
/// notebook is open, as GoodNotes' does.
package struct HistoryEntry: Sendable {
    package let page: PageID
    package let before: PageRevision
    package let after: PageRevision
}

/// Undo and redo as one notebook-wide stack of entries, bounded by count.
/// An entry moves between the stacks whole; nothing here reads a page.
///
/// KNOWN DEFECT: the byte bound the spec states is not enforced, because a
/// PKDrawing's in-memory size is not observable without serializing it.
/// The entry bound stands in until the device spike measures what an entry
/// costs at 20k strokes.
package struct EditHistory: Sendable {
    package static let maximumEntries = 100

    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []

    package init() {}

    package var canUndo: Bool { !undoStack.isEmpty }
    package var canRedo: Bool { !redoStack.isEmpty }

    /// A new edit clears redo.
    package mutating func record(_ entry: HistoryEntry) {
        undoStack.append(entry)
        if undoStack.count > Self.maximumEntries { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    package mutating func undo() -> HistoryEntry? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(entry)
        return entry
    }

    package mutating func redo() -> HistoryEntry? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(entry)
        return entry
    }
}
