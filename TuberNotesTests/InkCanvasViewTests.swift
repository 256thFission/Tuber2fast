import PencilKit
import Testing
import UIKit

@testable import TuberNotes

/// The ink canvas refuses PencilKit's editing menu.
///
/// Device finding, 2026-08-07: tapping an image raised a menu offering **Select
/// All** and **Insert Space**, neither of which means anything in this
/// application's model of a page — see `InkCanvasView` for why each one is
/// wrong rather than merely unwanted.
///
/// What can be proven here is the refusal, not the absence of the menu: whether
/// PencilKit still finds some other way to present one is a device question, and
/// `describeMenuMachinery` is what the next device run reads to answer it.
@Suite("Ink canvas editing menu")
@MainActor
struct InkCanvasViewTests {
    @Test("A hosted, inked, first-responder canvas vends no editing action")
    func theCanvasVendsNoEditingAction() throws {
        // Hosted, keyed, first responder, and carrying a stroke — the state the
        // canvas is actually in when a tap raises the menu, rather than a bare
        // view that would answer `false` to anything.
        //
        // **This passes with `canPerformAction` removed**, which is not a flaw
        // in the test but its result: it is what established that the menu is
        // not built from actions this responder vends, and sent the fix to the
        // interaction instead. Kept as a characterization — if a future
        // PencilKit starts vending `selectAll:` here, this is what says so.
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene, so nothing here can be first responder"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let canvas = InkCanvasView(frame: window.bounds)
        window.addSubview(canvas)
        window.makeKeyAndVisible()
        canvas.drawing = Self.oneStroke()
        #expect(canvas.becomeFirstResponder())

        #expect(!canvas.canPerformAction(#selector(UIResponder.selectAll(_:)), withSender: nil))
        #expect(!canvas.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil))
        #expect(!canvas.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil))
        #expect(!canvas.canPerformAction(#selector(UIResponder.cut(_:)), withSender: nil))
        #expect(!canvas.canPerformAction(#selector(UIResponder.delete(_:)), withSender: nil))
    }

    private static func oneStroke() -> PKDrawing {
        let point = PKStrokePoint(
            location: CGPoint(x: 100, y: 100),
            timeOffset: 0,
            size: CGSize(width: 3, height: 3),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
        let end = PKStrokePoint(
            location: CGPoint(x: 400, y: 400),
            timeOffset: 0.1,
            size: CGSize(width: 3, height: 3),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
        return PKDrawing(strokes: [
            PKStroke(
                ink: PKInk(.pen, color: .black),
                path: PKStrokePath(controlPoints: [point, end], creationDate: Date(timeIntervalSince1970: 0))
            )
        ])
    }

    @Test("An editing-menu interaction is refused at installation")
    func anEditMenuInteractionIsRefused() {
        let canvas = InkCanvasView()
        let before = canvas.interactions.count

        canvas.addInteraction(UIEditMenuInteraction(delegate: nil))

        #expect(canvas.interactions.count == before)
        #expect(!canvas.interactions.contains { $0 is UIEditMenuInteraction })
    }

    @Test("Every other interaction is installed untouched")
    func otherInteractionsAreUnaffected() {
        let canvas = InkCanvasView()
        let drop = UIDropInteraction(delegate: DropDelegate())

        canvas.addInteraction(drop)

        // The refusal is of one type, not of interactions in general: PencilKit
        // installs its own machinery here, and blanket refusal would break ink
        // rather than a menu.
        #expect(canvas.interactions.contains { $0 === drop })
    }

    @Test("The sweep finds an editing menu installed on a view inside the canvas")
    func theSweepReachesInsideTheCanvas() {
        let canvas = InkCanvasView()
        // `addInteraction` above governs only interactions added to the canvas
        // itself. PencilKit's content views are its own, so the sweep recurses —
        // this is that reach, standing in for a view it owns.
        let inner = UIView()
        canvas.addSubview(inner)

        // PencilKit installs an editing menu of its own on a view inside the
        // canvas — that is the defect, and this baseline sweep is the first
        // proof of it in the suite. It is cleared first so the count below
        // measures this test's own interaction and not PencilKit's.
        #expect(canvas.removeEditMenuInteractions() >= 1, "PencilKit installs one to begin with")

        inner.addInteraction(UIEditMenuInteraction(delegate: nil))

        #expect(canvas.removeEditMenuInteractions() == 1)
        #expect(!inner.interactions.contains { $0 is UIEditMenuInteraction })
        // Idempotent: a second page activation sweeping again must report
        // nothing, which is what makes a non-zero count in the device log a
        // signal rather than noise.
        #expect(canvas.removeEditMenuInteractions() == 0)
    }

    @Test("The machinery description names what is attached")
    func theDescriptionNamesWhatIsAttached() {
        let canvas = InkCanvasView()
        let inner = UIView()
        canvas.addSubview(inner)
        inner.addGestureRecognizer(UITapGestureRecognizer())

        let described = canvas.describeMenuMachinery()

        // A diagnostic is only worth shipping if it actually reports; this is
        // the assertion that the device log will not come back empty.
        #expect(described.contains("UITapGestureRecognizer"))
        #expect(described.contains("UIView"))
    }

    private final class DropDelegate: NSObject, UIDropInteractionDelegate {}
}
