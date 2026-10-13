import Foundation
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

@Suite("Notebook: Pencil gestures")
@MainActor
struct NotebookGestureTests {
    /// Three lines down the page, and a scratch-out across the top two.
    private static func scribbledLines() -> (lines: PKDrawing, scribbled: PKDrawing) {
        let lines = (0..<3).map { i in
            Ink.line(from: CGPoint(x: 0, y: CGFloat(i) * 50), to: CGPoint(x: 200, y: CGFloat(i) * 50))
        }
        let scribble = Ink.zigzag(over: CGRect(x: 20, y: -10, width: 80, height: 70), turns: 4)
        return (PKDrawing(strokes: lines), PKDrawing(strokes: lines + [scribble]))
    }

    private func gesturePage() async throws -> (Notebook, PageID, Scratch) {
        let scratch = try Scratch("nb-gesture")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        _ = notebook.drainChanges()
        return (notebook, page, scratch)
    }

    @Test("A scribble bound to erase takes its subject and itself, in one restore and one history entry")
    func scribbleErases() async throws {
        let (notebook, page, scratch) = try await gesturePage()
        _ = scratch
        let (lines, scribbled) = Self.scribbledLines()
        notebook.inkChanged(on: page, lines)
        _ = notebook.drainChanges()
        let editSeqBefore = notebook.state(of: page)!.content!.editSeq

        notebook.inkChanged(on: page, scribbled, bindings: [.scribble: .erase])
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 1, "the two crossed lines and the scribble are gone")
        let changes = notebook.drainChanges()
        let restores = changes.compactMap { change -> (PageID, PKDrawing)? in
            if case .inkRestored(let p, let ink, _) = change { (p, ink) } else { nil }
        }
        #expect(restores.count == 1, "\(changes)")
        let restore = try #require(restores.first)
        #expect(restore.0 == page && restore.1.strokes.count == 1)

        // The canvas reports the push back; it is the ink already held, so it is no edit.
        notebook.inkChanged(on: page, restore.1)
        #expect(notebook.state(of: page)!.content!.editSeq == editSeqBefore + 1, "the gesture is one edit and its echo is none")

        // Two entries stand: the one that laid the lines down and the
        // gesture. The gesture's is one, from before the trigger stroke to
        // after its effect, so the first undo lands on the three lines.
        #expect(notebook.canUndo)
        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 3, "undo brings the lines back and not the scribble")
        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.ink.strokes.isEmpty == true)
        #expect(!notebook.canUndo)
        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 3)
        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 1, "redo removes them again")
    }

    @Test("A gesture's entry is estimated per stroke; a stroke that only landed is the shared figure")
    func gestureEntryCostsPerStroke() async throws {
        let (notebook, page, scratch) = try await gesturePage()
        _ = scratch
        let (lines, scribbled) = Self.scribbledLines()
        notebook.inkChanged(on: page, lines)
        _ = notebook.drainChanges()
        #expect(notebook.historyByteEstimateForTesting == HistoryEntry.sharedEntryBytes, "the canvas handed that drawing over")

        notebook.inkChanged(on: page, scribbled, bindings: [.scribble: .erase])
        // One line survives the scratch-out, and the gesture built the
        // drawing that holds it, so its entry pays for that one stroke on
        // top of the shared figure every entry pays.
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 1)
        #expect(
            notebook.historyByteEstimateForTesting
                == 2 * HistoryEntry.sharedEntryBytes + HistoryEntry.rebuiltBytesPerStroke
        )
    }

    @Test("With no bindings the same scribble is ink: four strokes, no restore")
    func scribbleUnbound() async throws {
        let (notebook, page, scratch) = try await gesturePage()
        _ = scratch
        let (lines, scribbled) = Self.scribbledLines()
        notebook.inkChanged(on: page, lines)
        _ = notebook.drainChanges()
        notebook.inkChanged(on: page, scribbled)
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 4)
        #expect(!notebook.drainChanges().contains { if case .inkRestored = $0 { true } else { false } })
    }

    @Test("A scribble over blank paper stays, bound or not")
    func scribbleOverBlankPaper() async throws {
        for bindings in [GestureBindings(), [.scribble: .erase]] {
            let (notebook, page, scratch) = try await gesturePage()
            _ = scratch
            let scribble = PKDrawing(strokes: [Ink.zigzag(over: CGRect(x: 20, y: -10, width: 80, height: 70), turns: 4)])
            notebook.inkChanged(on: page, scribble, bindings: bindings)
            #expect(notebook.state(of: page)?.content?.ink.strokes.count == 1)
            #expect(!notebook.drainChanges().contains { if case .inkRestored = $0 { true } else { false } })
        }
    }

    /// Three lines down the page, and a double ring around the top two.
    private static func circledLines() -> (lines: PKDrawing, circled: PKDrawing) {
        let lines = [0, 20, 300].map { y in
            Ink.line(from: CGPoint(x: 0, y: CGFloat(y)), to: CGPoint(x: 200, y: CGFloat(y)))
        }
        let circle = Ink.loops(around: CGRect(x: 0, y: 0, width: 200, height: 20), count: 2)
        return (PKDrawing(strokes: lines), PKDrawing(strokes: lines + [circle]))
    }

    @Test("A double circle bound to erase takes what it encloses and itself, in one restore and one entry")
    func doubleCircleErases() async throws {
        let (notebook, page, scratch) = try await gesturePage()
        _ = scratch
        let (lines, circled) = Self.circledLines()
        notebook.inkChanged(on: page, lines)
        _ = notebook.drainChanges()
        let editSeqBefore = notebook.state(of: page)!.content!.editSeq

        notebook.inkChanged(on: page, circled, bindings: [.doubleCircle: .erase])
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 1, "the two enclosed lines and the ring are gone")
        let restores = notebook.drainChanges().compactMap { change -> (PageID, PKDrawing)? in
            if case .inkRestored(let p, let ink, _) = change { (p, ink) } else { nil }
        }
        #expect(restores.count == 1)
        let restore = try #require(restores.first)
        #expect(restore.0 == page && restore.1.strokes.count == 1)

        notebook.inkChanged(on: page, restore.1)
        #expect(notebook.state(of: page)!.content!.editSeq == editSeqBefore + 1, "the gesture is one edit and its echo is none")
        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 3, "undo brings the lines back and not the ring")
    }

    @Test("With only the scribble bound a double circle is ink")
    func doubleCircleUnbound() async throws {
        let (notebook, page, scratch) = try await gesturePage()
        _ = scratch
        let (lines, circled) = Self.circledLines()
        notebook.inkChanged(on: page, lines)
        _ = notebook.drainChanges()
        // The built-in bindings, which leave the second trigger off: the map
        // is the record, and a trigger it does not name is unbound.
        notebook.inkChanged(on: page, circled, bindings: [.scribble: .erase])
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 4)
        #expect(!notebook.drainChanges().contains { if case .inkRestored = $0 { true } else { false } })
    }

    /// A scratch-out drawn in loops: it encloses one line and crosses
    /// another, so the two triggers point at different strokes and which
    /// fires is the bindings' answer.
    private static func scratchOutInLoops() -> (before: PKDrawing, after: PKDrawing) {
        let crossing = Ink.line(from: CGPoint(x: -200, y: 10), to: CGPoint(x: 200, y: 10))
        let enclosed = Ink.line(from: CGPoint(x: 30, y: 10), to: CGPoint(x: 70, y: 10))
        let loops = Ink.loops(around: CGRect(x: 0, y: 0, width: 100, height: 20), count: 2, spikes: 4)
        return (PKDrawing(strokes: [crossing, enclosed]), PKDrawing(strokes: [crossing, enclosed, loops]))
    }

    @Test("With only the double circle bound, an unbound scribble does not swallow it")
    func unboundScribbleLeavesTheCircleFree() async throws {
        let (notebook, page, scratch) = try await gesturePage()
        _ = scratch
        let (before, after) = Self.scratchOutInLoops()
        notebook.inkChanged(on: page, before)
        _ = notebook.drainChanges()

        notebook.inkChanged(on: page, after, bindings: [.doubleCircle: .erase])
        let left = try #require(notebook.state(of: page)?.content?.ink.strokes)
        #expect(left.count == 1, "the enclosed line and the ring go")
        #expect(left.first?.renderBounds.minX ?? 0 < -100, "the line the loops crossed stays")
    }

    @Test("With both bound, the scribble wins the same stroke and the crossed line goes")
    func scribbleWinsOverTheCircle() async throws {
        let (notebook, page, scratch) = try await gesturePage()
        _ = scratch
        let (before, after) = Self.scratchOutInLoops()
        notebook.inkChanged(on: page, before)
        _ = notebook.drainChanges()

        notebook.inkChanged(on: page, after, bindings: [.scribble: .erase, .doubleCircle: .erase])
        let left = try #require(notebook.state(of: page)?.content?.ink.strokes)
        #expect(left.count == 1, "the crossed line and the ring go")
        #expect(left.first?.renderBounds.minX ?? 0 > 0, "the line the loops merely enclosed stays")
    }

    @Test("A report that adds two strokes at once is never examined")
    func twoStrokesAtOnceAreNotAGesture() async throws {
        let (notebook, page, scratch) = try await gesturePage()
        _ = scratch
        let (lines, scribbled) = Self.scribbledLines()
        notebook.inkChanged(on: page, lines)
        _ = notebook.drainChanges()
        let extra = Ink.line(from: CGPoint(x: 0, y: 200), to: CGPoint(x: 200, y: 200))
        // The scribble is still the last stroke; the count is what refuses it.
        let two = PKDrawing(strokes: lines.strokes + [extra] + scribbled.strokes.suffix(1))
        notebook.inkChanged(on: page, two, bindings: [.scribble: .erase])
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 5)
        #expect(!notebook.drainChanges().contains { if case .inkRestored = $0 { true } else { false } })
    }
}
