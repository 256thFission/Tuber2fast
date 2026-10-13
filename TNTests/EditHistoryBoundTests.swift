import Foundation
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

/// The two bounds on the stack, against the constants rather than against
/// a real drawing: an estimate is arithmetic on a stroke count, so the
/// entries here carry one repeated stroke and no fixture is loaded.
@Suite("EditHistory: the count bound and the byte bound")
@MainActor
struct EditHistoryBoundTests {
    /// A revision whose drawing has `strokes` strokes, all the same one.
    private static func revision(strokes: Int) -> PageRevision {
        let stroke = Ink.line(from: .zero, to: CGPoint(x: 10, y: 10))
        return PageRevision(ink: PKDrawing(strokes: Array(repeating: stroke, count: strokes)), layers: [])
    }

    private static func entry(_ page: PageID, strokes: Int, rebuilt: Bool) -> HistoryEntry {
        HistoryEntry(page: page, before: revision(strokes: 0), after: revision(strokes: strokes), rebuilt: rebuilt)
    }

    @Test("An entry's estimate is the shared figure, or the per-stroke one when the drawing was rebuilt")
    func estimateArithmetic() {
        let shared = Self.entry(PageID(), strokes: 7, rebuilt: false)
        #expect(shared.byteEstimate == HistoryEntry.sharedEntryBytes, "a drawing from the canvas costs per entry, not per stroke")
        let rebuilt = Self.entry(PageID(), strokes: 7, rebuilt: true)
        #expect(rebuilt.byteEstimate == HistoryEntry.sharedEntryBytes + 7 * HistoryEntry.rebuiltBytesPerStroke)
    }

    @Test("Past the byte bound the oldest entries go and the newest stand")
    func byteBoundEvictsOldest() {
        // Four of these sum past 64 MB; three do not.
        let perEntry = 40_000
        let cost = HistoryEntry.sharedEntryBytes + perEntry * HistoryEntry.rebuiltBytesPerStroke
        #expect(3 * cost <= EditHistory.maximumBytes && 4 * cost > EditHistory.maximumBytes, "the sizing this test rests on")
        let after = Self.revision(strokes: perEntry)
        let before = Self.revision(strokes: 0)
        let pages = (0..<5).map { _ in PageID() }
        var history = EditHistory()
        for page in pages {
            history.record(HistoryEntry(page: page, before: before, after: after, rebuilt: true))
        }
        #expect(history.byteEstimate == 3 * cost)
        #expect(history.undo()?.page == pages[4])
        #expect(history.undo()?.page == pages[3])
        #expect(history.undo()?.page == pages[2])
        #expect(!history.canUndo, "the two oldest were evicted, not undone")
    }

    @Test("One entry larger than the whole bound is still kept, and it is the only one")
    func oversizedEntryIsKept() {
        let huge = EditHistory.maximumBytes / HistoryEntry.rebuiltBytesPerStroke + 1_000
        let hugeCost = HistoryEntry.sharedEntryBytes + huge * HistoryEntry.rebuiltBytesPerStroke
        var history = EditHistory()
        let small = PageID(), big = PageID()
        history.record(Self.entry(small, strokes: 1, rebuilt: false))
        history.record(HistoryEntry(page: big, before: Self.revision(strokes: 0), after: Self.revision(strokes: huge), rebuilt: true))
        #expect(history.byteEstimate == hugeCost)
        #expect(history.byteEstimate > EditHistory.maximumBytes, "kept although it alone is past the bound")
        #expect(history.undo()?.page == big)
        #expect(!history.canUndo, "the small entry went to make room")
    }

    @Test("The count bound still applies to entries the byte bound never reaches")
    func countBoundStillApplies() {
        var history = EditHistory()
        let pages = (0..<(EditHistory.maximumEntries + 20)).map { _ in PageID() }
        for page in pages { history.record(Self.entry(page, strokes: 1, rebuilt: false)) }
        #expect(history.byteEstimate == EditHistory.maximumEntries * HistoryEntry.sharedEntryBytes)
        #expect(history.byteEstimate < EditHistory.maximumBytes, "the count is what bounded this stack")
        #expect(history.undo()?.page == pages.last)
        for _ in 1..<EditHistory.maximumEntries { _ = history.undo() }
        #expect(!history.canUndo)
    }
}
