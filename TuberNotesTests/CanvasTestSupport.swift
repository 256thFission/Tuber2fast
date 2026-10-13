import Foundation
import PencilKit
import Testing
@testable import TNCanvas
@testable import TNModel
@testable import TNNotebook
import UIKit

// What the hosted canvas suites share: page fixtures, a window to host a
// runtime in, and the moves a test makes in place of a finger and a Pencil.

let testEnvironment = CanvasEnvironment(tool: .ink(PKInkingTool(.pen)))

// `fast` and `waitUntil` are TNTests' own, copied: that target is not
// linked here.

var fast: SaveSchedule {
    var schedule = SaveSchedule()
    schedule.idleFloor = .milliseconds(10)
    schedule.idleCeiling = .milliseconds(20)
    schedule.backoffCap = .milliseconds(50)
    return schedule
}

@MainActor
func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        try #require(clock.now < deadline, "timed out")
        try await Task.sleep(for: .milliseconds(5))
    }
}

func descriptors(_ count: Int) -> [PageDescriptor] {
    (0..<count).map { _ in
        PageDescriptor(id: PageID(), geometry: .letter, paper: .known(.drawn(.blank)))
    }
}

func strokeDrawing(strokes: Int) -> PKDrawing {
    let ink = PKInk(.pen, color: .black)
    return PKDrawing(
        strokes: (0..<strokes).map { index in
            let y = Double(index) * 20 + 40
            let points = (0..<8).map { step in
                PKStrokePoint(
                    location: CGPoint(x: Double(step) * 40 + 40, y: y),
                    timeOffset: Double(step) * 0.01,
                    size: CGSize(width: 3, height: 3),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                )
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
    )
}

/// A laid-out runtime in a key window. The first layout is the first
/// viewport it has ever had, and the window is built there; the window is
/// what lets a text view become first responder.
@MainActor
func hosted(_ reporter: RecordingReporter) -> PagedCanvasController {
    let runtime = PagedCanvasController(reporter: reporter)
    host(runtime)
    return runtime
}

/// Gives a runtime its first viewport. Split out so a test can drive a
/// runtime that has been told things before any layout existed, which is
/// the state every tab opens in.
@MainActor
@discardableResult
func host(_ runtime: PagedCanvasController) -> UIWindow {
    // The host app's scene: these tests run inside it, and a window
    // without a scene is not a key window.
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
    window.rootViewController = runtime
    window.makeKeyAndVisible()
    WindowKeeper.shared.windows.append(window)
    runtime.view.layoutIfNeeded()
    return window
}

/// A finger turn that comes to rest on `index`.
@MainActor
func settle(_ runtime: PagedCanvasController, at index: Int) {
    runtime.scrollView.setContentOffset(CGPoint(x: runtime.currentLayout.offsetX(at: index), y: 0), animated: false)
    runtime.scrollViewDidEndDecelerating(runtime.scrollView)
}

/// One trip through the main queue: everything queued on it before this
/// call has run when it returns.
@MainActor
func hop() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// The drawing grows the way it does under the Pencil: nothing is reported.
/// Assigning `drawing` with the delegate attached reports at once, which
/// PencilKit does not do mid-stroke.
@MainActor
func draw(_ drawing: PKDrawing, on canvas: PageCanvasController) {
    let delegate = canvas.canvasView.delegate
    canvas.canvasView.delegate = nil
    canvas.canvasView.drawing = drawing
    canvas.canvasView.delegate = delegate
}

/// One stroke the way PencilKit delivers it: the use begins, the drawing
/// grows unreported, the use ends, and one change commits it.
@MainActor
func commitStroke(_ drawing: PKDrawing, on canvas: PageCanvasController) {
    canvas.canvasViewDidBeginUsingTool(canvas.canvasView)
    draw(drawing, on: canvas)
    canvas.canvasViewDidEndUsingTool(canvas.canvasView)
    canvas.canvasViewDrawingDidChange(canvas.canvasView)
}
