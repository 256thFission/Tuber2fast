import CoreGraphics
import PencilKit
import Testing
@testable import TNCanvas
@testable import TNModel
import UIKit

/// Text editing on a hosted canvas: the open box, the taps around it, and
/// what a retire, a departure or a tool change does with the draft.
@Suite("Canvas text editing")
@MainActor
final class TNCanvasTextTests: HostingSuite {
    /// One live page holding `layers`, with the text tool applied and a
    /// session open on the first text layer.
    private func openSession(_ reporter: RecordingReporter, layers: [Layer]) throws -> (PagedCanvasController, PageID, PageCanvasController, TextEditingView) {
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime, layers: layers)
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading), theme: .macaron))
        let canvas = try #require(runtime.canvases[pages[0].id])
        let first = try #require(layers.first)
        guard case .text(let text) = first.payload else { throw TestFailure.notText }
        canvas.tapped(at: CGPoint(x: text.rect.x + 5, y: text.rect.y + 5))
        #expect(reporter.textEditRequests.map(\.layer) == [first.id])
        runtime.beginTextEditing(on: pages[0].id, TextEditStart(layer: first.id, text: text))
        let overlays = canvas.overlayView.subviews.compactMap { $0 as? TextEditingView }
        let overlay = try #require(overlays.first)
        return (runtime, pages[0].id, canvas, overlay)
    }

    private enum TestFailure: Error { case notText }

    @Test("A begin adds one overlay over the ink and makes it first responder")
    func beginAddsOneOverlay() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        #expect(canvas.overlayView.subviews.filter { $0 is TextEditingView }.count == 1)
        #expect(overlay.isFirstResponder)
        #expect(overlay.frame == CGRect(x: 100, y: 100, width: 200, height: 60))
        if case .editing = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        _ = runtime.retireAll()
    }

    @Test("An open box takes the Pencil as Scribble inside its bounds only, with spelling and autocorrection on")
    func scribbleAndSpellingInAnOpenBox() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        #expect(overlay.spellCheckingType == .yes)
        #expect(overlay.autocorrectionType == .yes)
        let interaction = try #require(overlay.interactions.first { $0 is UIScribbleInteraction } as? UIScribbleInteraction)
        #expect(interaction.delegate === overlay)
        // Inside the box, in the view's own coordinates, is Scribble's.
        #expect(overlay.scribbleInteraction(interaction, shouldBeginAt: CGPoint(x: 10, y: 10)))
        #expect(overlay.scribbleInteraction(interaction, shouldBeginAt: CGPoint(x: 199, y: 59)))
        // Outside, including on the handles and the slop UIKit would allow,
        // is refused: the Pencil there is the canvas's.
        #expect(!overlay.scribbleInteraction(interaction, shouldBeginAt: CGPoint(x: -1, y: 10)))
        #expect(!overlay.scribbleInteraction(interaction, shouldBeginAt: CGPoint(x: 10, y: -8)))
        #expect(!overlay.scribbleInteraction(interaction, shouldBeginAt: CGPoint(x: 201, y: 61)))
        // The ink gesture is off while the session is open, so a Scribble
        // scratch-out can never arrive at the notebook as a stroke.
        #expect(!canvas.canvasView.drawingGestureRecognizer.isEnabled)
        _ = runtime.retireAll()
    }

    @Test("The drawing gesture follows the tool: off for text, on for ink, session or no session")
    func drawingGestureFollowsTheTool() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)
        let canvas = try #require(runtime.canvases[pages[0].id])
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading), theme: .macaron))
        #expect(!canvas.canvasView.drawingGestureRecognizer.isEnabled)
        runtime.apply(CanvasEnvironment(tool: .ink(PKInkingTool(.pen)), theme: .macaron))
        #expect(canvas.canvasView.drawingGestureRecognizer.isEnabled)
        // A canvas built after the tool was applied starts with the gesture
        // in the tool's state.
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading), theme: .macaron))
        _ = runtime.retire(pages[0].id)
        runtime.installContent(.editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(2)))
        let rebuilt = try #require(runtime.canvases[pages[0].id])
        #expect(!rebuilt.canvasView.drawingGestureRecognizer.isEnabled)
        _ = runtime.retireAll()
    }

    @Test("A tap on paper commits the typed runs, then asks for a box, and the overlay waits in closing until the end lands")
    func tapOutsideCommitsThenCreates() throws {
        let reporter = RecordingReporter()
        let layer = textLayer("hi", x: 100, y: 100)
        let (runtime, page, canvas, overlay) = try openSession(reporter, layers: [layer])
        overlay.insertText("!")
        canvas.tapped(at: CGPoint(x: 400, y: 500))
        #expect(reporter.sequence.suffix(2) == ["textEditingEnded", "textBoxRequested"])
        let committed = try #require(reporter.textEditsEnded.last)
        #expect(committed.layer == layer.id)
        #expect(committed.text.runs.map(\.string).joined() == "hi!")
        #expect(committed.text.runs.allSatisfy { $0.style == .body })
        #expect(committed.text.rect == PageRect(x: 100, y: 100, width: 200, height: 60))
        #expect(reporter.textBoxRequests.last?.point == PagePoint(x: 400, y: 500))
        #expect(reporter.textBoxRequests.last?.style == .body)
        #expect(canvas.closing.keys.map { $0 } == [layer.id])
        #expect(overlay.superview != nil)
        runtime.endTextEditing(on: page, layer: layer.id)
        #expect(canvas.closing.isEmpty)
        #expect(overlay.superview == nil)
        _ = runtime.retireAll()
    }

    @Test("A tap in a second text rect commits the first, then requests the second")
    func tapInAnotherBox() throws {
        let reporter = RecordingReporter()
        let first = textLayer("a", x: 100, y: 100), second = textLayer("b", x: 100, y: 400)
        let (runtime, _, canvas, _) = try openSession(reporter, layers: [first, second])
        canvas.tapped(at: CGPoint(x: 110, y: 410))
        #expect(reporter.sequence.suffix(2) == ["textEditingEnded", "textEditRequested"])
        #expect(reporter.textEditsEnded.last?.layer == first.id)
        #expect(reporter.textEditRequests.last?.layer == second.id)
        #expect(canvas.closing.count == 1)
        if case .opening = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        _ = runtime.retireAll()
    }

    @Test("A tap inside the open box is the text view's, and a link under the text tool is nothing")
    func tapsInsideAndOnLinks() throws {
        let reporter = RecordingReporter()
        let link = linkLayer(x: 100, y: 600)
        let (runtime, _, canvas, _) = try openSession(reporter, layers: [textLayer("a", x: 100, y: 100), link])
        // A recognizer with no touch reports the origin of the view asked,
        // which is inside the overlay's bounds: the delegate must refuse it.
        let tap = try #require(canvas.canvasView.gestureRecognizers?.first { $0 is UITapGestureRecognizer })
        #expect(!canvas.gestureRecognizerShouldBegin(tap))
        let before = reporter.sequence
        canvas.tapped(at: CGPoint(x: 110, y: 610))
        #expect(reporter.sequence == before, "a link under the text tool edits nothing and activates nothing")
        #expect(reporter.links.isEmpty)
        _ = runtime.retireAll()
    }

    @Test("A locked text box under the text tool is nothing: no edit request, no new box, no session")
    func aLockedTextBoxDoesNotOpen() throws {
        let reporter = RecordingReporter()
        let box = textLayer("hi", x: 100, y: 200).withLock(true)
        let (runtime, _, canvas) = try livePage(reporter, layers: [box])
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading), theme: .macaron))

        canvas.tapped(at: centre(of: box))
        #expect(reporter.textEditRequests.isEmpty)
        #expect(reporter.textBoxRequests.isEmpty)
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(!canvas.overlayView.subviews.contains { $0 is TextEditingView })
        _ = runtime.retireAll()
    }

    @Test("undoTyping reaches the open text view's own manager, and does nothing while the view is still opening")
    func undoTypingReachesTheTextView() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        overlay.insertText("!")
        #expect(overlay.text == "hi!")
        runtime.undoTyping()
        #expect(overlay.text == "hi")
        runtime.redoTyping()
        #expect(overlay.text == "hi!")
        #expect(reporter.undoRequests == 0 && reporter.redoRequests == 0, "nothing went up")

        canvas.tapped(at: CGPoint(x: 400, y: 500))
        if case .opening = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        runtime.undoTyping()
        canvas.undoTyping()
        canvas.redoTyping()
        if case .opening = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(overlay.text == "hi!", "the inert overlay in closing is not the session")
        _ = runtime.retireAll()
    }

    @Test("Retiring reports the draft before the final ink")
    func retireReportsDraftBeforeInk() throws {
        let reporter = RecordingReporter()
        let layer = textLayer("hi", x: 100, y: 100)
        let (runtime, page, _, overlay) = try openSession(reporter, layers: [layer])
        overlay.insertText("!")
        #expect(runtime.retire(page) == .retired)
        #expect(reporter.sequence.suffix(2) == ["textEditingEnded", "retired"])
        #expect(reporter.textEditsEnded.last?.text.runs.map(\.string).joined() == "hi!")
        #expect(overlay.superview == nil)
    }

    @Test("A page that leaves the list takes its session with it: the draft is a dead letter, the ink is not")
    func departedPageDropsTheDraft() throws {
        let reporter = RecordingReporter()
        let (runtime, page, _, _) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        runtime.setPages([], seq: StructureSeq(2), answering: nil)
        #expect(reporter.textEditsEnded.isEmpty)
        #expect(reporter.retired.map(\.page) == [page])
        #expect(runtime.canvases.isEmpty)
    }

    @Test("Switching to ink mid-session commits before the Pencil can draw")
    func inkToolCommits() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, _) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        runtime.apply(CanvasEnvironment(tool: .ink(PKInkingTool(.pen)), theme: .macaron))
        #expect(reporter.textEditsEnded.count == 1)
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(canvas.canvasView.drawingGestureRecognizer.isEnabled)
        _ = runtime.retireAll()
    }

    @Test("Applying a text style mid-session changes what the caret types with")
    func styleMidSession() throws {
        let reporter = RecordingReporter()
        let (runtime, _, _, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        let bold = TextStyle(font: .system, size: 16, bold: true, italic: false, underline: false, color: TextStyle.body.color)
        runtime.apply(CanvasEnvironment(tool: .text(bold, .center), theme: .macaron))
        overlay.insertText("!")
        let runs = overlay.committedLayer.runs
        #expect(runs.last == TextRun(string: "!", style: bold))
        #expect(overlay.committedLayer.alignment == .center)
        _ = runtime.retireAll()
    }

    @Test("A theme alone hands no canvas a tool: an open box keeps its selected words as they were, and a selection stays up")
    func themeOnlyApplyKeepsTheSession() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        let bold = TextStyle(font: .system, size: 16, bold: true, italic: false, underline: false, color: TextStyle.body.color)
        // Bold is what the caret types with; the words already there stay
        // body, so a tool handed down again would visibly restyle them.
        overlay.selectedRange = NSRange(location: 2, length: 0)
        runtime.apply(CanvasEnvironment(tool: .text(bold, .leading), theme: .macaron))
        overlay.selectedRange = NSRange(location: 0, length: 2)
        let before = overlay.committedLayer
        #expect(before.runs == [TextRun(string: "hi", style: .body)])

        runtime.apply(CanvasEnvironment(tool: .text(bold, .leading), theme: .macaronDark))

        #expect(overlay.committedLayer == before, "the selected words keep their own style")
        #expect(overlay.selectedRange == NSRange(location: 0, length: 2))
        #expect(reporter.textEditsEnded.isEmpty)
        if case .editing = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        _ = runtime.retireAll()

        let image = imageLayer(x: 100, y: 200)
        let (lasso, _, page) = try livePage(reporter, layers: [image])
        page.tapped(at: centre(of: image))
        let selection = try #require(frame(on: page))

        lasso.apply(CanvasEnvironment(tool: .ink(PKLassoTool()), theme: .macaronDark))

        #expect(frame(on: page) === selection)
        if case .selected = page.phase {} else { Issue.record("phase is \(page.phase)") }
        _ = lasso.retireAll()
    }

    @Test("An open box draws its border and handles in the theme's accent, and follows a theme change")
    func textBoxBorderUsesTheAccent() throws {
        let reporter = RecordingReporter()
        let (runtime, _, _, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        let lime = try #require(Theme.preset(ThemeID(rawValue: "lime"))).theme
        #expect(lime.accent != Theme.macaron.accent)
        for theme in [Theme.macaron, lime] {
            runtime.apply(CanvasEnvironment(tool: .text(.body, .leading), theme: theme))
            let accent = theme.accent.uiColor
            #expect(overlay.layer.borderColor == accent.cgColor)
            #expect(overlay.subviews.filter { $0.backgroundColor == accent }.count == 2, "the move and resize handles")
        }
        _ = runtime.retireAll()
    }

    @Test("A resize cannot go below one line, and typing past the bottom grows the box")
    func resizeFloorAndGrowth() throws {
        let reporter = RecordingReporter()
        let (runtime, _, _, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        overlay.resize(by: CGPoint(x: -1000, y: -1000))
        #expect(overlay.frame.width == overlay.lineHeight)
        #expect(overlay.frame.height == overlay.lineHeight)
        overlay.resize(by: CGPoint(x: 100, y: 0))
        overlay.insertText("\n\n\n\n")
        #expect(overlay.frame.height > overlay.lineHeight * 4)
        overlay.move(by: CGPoint(x: 10, y: -5))
        #expect(overlay.frame.origin == CGPoint(x: 110, y: 95))
        _ = runtime.retireAll()
    }

    @Test("A geometry change leaves the overlay where its rect says")
    func geometryLeavesTheOverlay() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        canvas.updateGeometry(PageGeometry(width: 500, height: 700))
        canvas.view.layoutIfNeeded()
        #expect(overlay.frame.origin == CGPoint(x: 100, y: 100))
        _ = runtime.retireAll()
    }

    @Test("The keyboard's overlap becomes a bottom inset, and leaves with it")
    func keyboardInset() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, _) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        let resting = canvas.canvasView.contentInset.bottom
        canvas.keyboardWillChange(showing: true, frame: CGRect(x: 0, y: 880, width: 820, height: 300))
        #expect(canvas.canvasView.contentInset.bottom >= 300)
        canvas.keyboardWillChange(showing: false, frame: nil)
        #expect(canvas.canvasView.contentInset.bottom == resting)
        _ = runtime.retireAll()
    }

    @Test("A begin for a page with no canvas is answered with the value unchanged")
    func beginWithoutACanvasIsAnswered() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(4)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        let far = pages[3].id
        #expect(runtime.canvases[far] == nil)
        let text = TextLayer(rect: PageRect(x: 1, y: 1, width: 10, height: 10), runs: [], alignment: .leading)
        let layer = LayerID()
        runtime.beginTextEditing(on: far, TextEditStart(layer: layer, text: text))
        #expect(reporter.textEditsEnded.last?.layer == layer)
        #expect(reporter.textEditsEnded.last?.text == text)
        _ = runtime.retireAll()
    }
}
