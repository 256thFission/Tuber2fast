import PencilKit
import Testing
import UIKit

@testable import TuberNotes

/// The ink canvas refuses PencilKit's tap-raised context menu, and keeps its
/// lasso menu.
///
/// Device finding, 2026-08-07: tapping an image raised a menu offering **Select
/// All** and **Insert Space**. The first fix took the whole editing menu away
/// and Phillip found the cost the same evening — the lasso lost cut, copy and
/// delete, which had worked before this project touched anything. So the rule
/// has two halves now, and both are asserted here: **the bridge goes, the
/// presenter stays.**
@Suite("Ink canvas editing menu")
@MainActor
struct InkCanvasViewTests {
    @Test("A live canvas carries PencilKit's context-menu bridge, and the sweep takes it")
    func theSweepTakesTheContextMenuBridge() throws {
        let canvas = try Self.hostedCanvas()

        // Not a fixture of the test's own making: this is PencilKit's own
        // machinery, and the first assertion in this suite is that it is
        // actually there. If a future PencilKit stops installing it, this fails
        // here rather than the tap menu silently returning on a device.
        #expect(canvas.removeContextMenuBridge() == 1)
        // Idempotent, so a non-zero count in the device log after the first page
        // activation is a signal rather than noise.
        #expect(canvas.removeContextMenuBridge() == 0)
    }

    @Test("The sweep leaves the presenter the lasso menu needs")
    func theSweepLeavesTheEditMenuPresenter() throws {
        let canvas = try Self.hostedCanvas()
        #expect(canvas.hasEditMenuPresenter, "PencilKit installs one before anything is removed")

        canvas.removeContextMenuBridge()

        // The half that was got wrong the first time. `UIEditMenuInteraction`
        // is what PencilKit presents through when a lasso selection completes;
        // removing it is what cost cut, copy and delete. Nothing this project
        // does to suppress a tap menu may take it.
        #expect(
            canvas.hasEditMenuPresenter,
            "the lasso's menu presenter must survive the tap menu's removal"
        )
    }

    @Test("The canvas vends the standard editing actions to whatever asks")
    func theCanvasDoesNotOverrideTheResponderChain() throws {
        let canvas = try Self.hostedCanvas()
        canvas.drawing = Self.oneStroke()

        // There was a `canPerformAction` override returning `false` to
        // everything. It is gone, and this is what says it stays gone: a lasso
        // selection is exactly the state in which a canvas begins vending
        // `cut:` and `copy:`, and a blanket refusal would empty the menu this
        // file exists to protect. What the canvas answers here is PencilKit's
        // business; that the answer is *PencilKit's* is this project's.
        let unmodified = PKCanvasView(frame: canvas.frame)
        for action in [
            #selector(UIResponder.cut(_:)),
            #selector(UIResponder.copy(_:)),
            #selector(UIResponder.selectAll(_:)),
            #selector(UIResponder.paste(_:)),
        ] {
            #expect(
                canvas.canPerformAction(action, withSender: nil)
                    == unmodified.canPerformAction(action, withSender: nil),
                "\(action) must answer exactly as an unmodified PKCanvasView does"
            )
        }
    }

    @Test("The machinery description names what is attached")
    func theDescriptionNamesWhatIsAttached() throws {
        let canvas = try Self.hostedCanvas()

        let described = canvas.describeMenuMachinery()

        // The diagnostic that corrected this file's aim. A device log that came
        // back empty would have been worse than no diagnostic at all, so what
        // is asserted is that it reports the two names the fix turns on.
        #expect(described.contains("UIEditMenuInteraction"))
        #expect(described.contains("PKTiledView"))
    }

    // MARK: - Fixtures

    /// A canvas in a key window, first responder — the state PencilKit installs
    /// its menu machinery for. A bare `InkCanvasView()` has none of it, so a
    /// test built on one would assert nothing.
    private static func hostedCanvas() throws -> InkCanvasView {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene, so nothing here can be first responder"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let canvas = InkCanvasView(frame: window.bounds)
        window.addSubview(canvas)
        window.makeKeyAndVisible()
        #expect(canvas.becomeFirstResponder())
        window.layoutIfNeeded()
        return canvas
    }

    private static func oneStroke() -> PKDrawing {
        let start = PKStrokePoint(
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
                path: PKStrokePath(
                    controlPoints: [start, end],
                    creationDate: Date(timeIntervalSince1970: 0)
                )
            )
        ])
    }
}
