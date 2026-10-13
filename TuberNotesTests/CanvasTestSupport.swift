import Foundation
import PencilKit
import Testing
@testable import TNCanvas
@testable import TNModel
@testable import TNNotebook
import UIKit

// What the hosted canvas suites share: page and layer fixtures, the suite
// that hosts a runtime in a window, a reporter that records, and the moves a
// test makes in place of a finger and a Pencil.

let testEnvironment = CanvasEnvironment(tool: .ink(PKInkingTool(.pen)), theme: .macaron)

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
        PageDescriptor(id: PageID(), geometry: .letter)
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

func textLayer(_ string: String, x: Double, y: Double, width: Double = 200, height: Double = 60) -> Layer {
    Layer(id: LayerID(), transform: .identity, payload: .text(TextLayer(
        rect: PageRect(x: x, y: y, width: width, height: height),
        runs: [TextRun(string: string, style: .body)], alignment: .leading
    )))
}

func linkLayer(x: Double, y: Double) -> Layer {
    Layer(id: LayerID(), transform: .identity, payload: .link(LinkLayer(
        rect: PageRect(x: x, y: y, width: 100, height: 40), style: .button, target: .internalPage(PageID())
    )))
}

func imageLayer(x: Double, y: Double, width: Double = 120, height: Double = 80) -> Layer {
    Layer(
        id: LayerID(),
        transform: .placing(sourceWidth: width, sourceHeight: height, at: (x, y), scale: 1),
        payload: .image(ImageLayer(
            asset: AssetRef(id: AssetID(), format: .heic),
            naturalSize: PixelSize(width: Int(width), height: Int(height))
        ))
    )
}

/// A page's first content: no ink, and `layers` over the paper.
@MainActor
func installBlank(_ page: PageID, on runtime: PagedCanvasController, layers: [Layer] = []) {
    runtime.installContent(.editable(id: page, ink: PKDrawing(), layers: layers, composite: nil, inkSeq: InkSeq(1)))
}

/// What a suite that hosts runtimes is built on. Swift Testing makes one
/// instance per test and lets it go when the test ends, and the windows that
/// test hosted go with it. A runtime left holding a canvas it never retired
/// then traps in PageCanvasController's deinit. UIKit keeps a dropped window
/// and its old root until the main queue next goes idle, so the trap can land
/// a few tests later; its violation line names the page.
@MainActor
class HostingSuite {
    /// Kept for the whole test: a window that goes away mid-test takes
    /// first-responder status with it.
    private var windows: [UIWindow] = []

    isolated deinit {
        for window in windows { window.rootViewController = nil }
    }

    /// A laid-out runtime in a key window. The first layout is the first
    /// viewport it has ever had, and the window is built there; the window is
    /// what lets a text view become first responder.
    func hosted(_ reporter: RecordingReporter) -> PagedCanvasController {
        let runtime = PagedCanvasController(reporter: reporter, environment: testEnvironment)
        host(runtime)
        return runtime
    }

    /// Gives a runtime its first viewport. Split out so a test can drive a
    /// runtime that has been told things before any layout existed, which is
    /// the state every tab opens in.
    @discardableResult
    func host(_ runtime: PagedCanvasController) -> UIWindow {
        // The host app's scene: these tests run inside it, and a window
        // without a scene is not a key window.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = runtime
        window.makeKeyAndVisible()
        windows.append(window)
        runtime.view.layoutIfNeeded()
        return window
    }

    /// One live page holding `layers`, with `tool` applied. The lasso is the
    /// only tool an object answers.
    func livePage(_ reporter: RecordingReporter, layers: [Layer], tool: PKTool = PKLassoTool()) throws
        -> (PagedCanvasController, PageID, PageCanvasController)
    {
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime, layers: layers)
        runtime.apply(CanvasEnvironment(tool: .ink(tool), theme: .macaron))
        let canvas = try #require(runtime.canvases[pages[0].id])
        return (runtime, pages[0].id, canvas)
    }
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

@MainActor
func frame(on canvas: PageCanvasController) -> LayerSelectionView? {
    canvas.overlayView.subviews.compactMap { $0 as? LayerSelectionView }.first
}

/// The middle of a layer's placement, in page points.
func centre(of layer: Layer) -> CGPoint {
    let point = layer.transform.apply(x: 0.5, y: 0.5)
    return CGPoint(x: point.x, y: point.y)
}

/// The page itself: the backdrop that draws the paper and its edge.
@MainActor
func paper(of canvas: PageCanvasController) -> UIImageView? {
    canvas.paperView.subviews.compactMap { $0 as? UIImageView }.first
}

/// A reporter that records what the runtime said, in the order it said it.
@MainActor
final class RecordingReporter: CanvasReporting {
    var inkChanges: [(page: PageID, ink: PKDrawing, echoOf: InkSeq?)] = []
    var retired: [(page: PageID, finalInk: PKDrawing?)] = []
    var windows: [[PageID]] = []
    var becameCurrent: [PageID] = []
    var boundaries: [ReportSeq] = []
    var links: [(page: PageID, layer: LayerID)] = []
    var undoRequests = 0
    var redoRequests = 0
    var textBoxRequests: [(page: PageID, point: PagePoint, style: TextStyle, alignment: TextAlignment)] = []
    var textEditRequests: [(page: PageID, layer: LayerID)] = []
    var textEditsEnded: [(page: PageID, layer: LayerID, text: TextLayer)] = []
    /// Every report by name, in order, so a test can assert what came first.
    var sequence: [String] = []

    /// Answers the end-boundary question, the way the notebook does.
    var onEndBoundary: (@MainActor (ReportSeq) -> Void)?

    /// Answers an ink report, synchronously and from inside it, the way a
    /// notebook that edits the ink it was just told about would.
    var onInkChanged: (@MainActor (PageID, PKDrawing, InkSeq?) -> Void)?

    func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?) {
        inkChanges.append((page, ink, echoOf))
        onInkChanged?(page, ink, echoOf)
    }

    var transforms: [(page: PageID, layer: LayerID, transform: PageSpaceTransform)] = []
    var deletes: [(page: PageID, layer: LayerID)] = []
    /// What the notebook answers a transform with. `.refused` is what a
    /// drag past the page's tenth edge would get.
    var transformOutcome: TransformOutcome = .accepted

    func layerTransformed(on page: PageID, layer: LayerID, to transform: PageSpaceTransform) -> TransformOutcome {
        transforms.append((page, layer, transform))
        sequence.append("layerTransformed")
        return transformOutcome
    }

    func layerDeleteRequested(on page: PageID, layer: LayerID) {
        deletes.append((page, layer))
        sequence.append("layerDeleteRequested")
    }

    var locks: [(page: PageID, layer: LayerID, locked: Bool)] = []

    func layerLockRequested(on page: PageID, layer: LayerID, locked: Bool) {
        locks.append((page, layer, locked))
        sequence.append("layerLockRequested")
    }

    func pageBecameCurrent(_ page: PageID) { becameCurrent.append(page) }
    func windowChanged(to pages: [PageID]) {
        windows.append(pages)
        sequence.append("windowChanged")
    }
    func endBoundaryReached(seq: ReportSeq) {
        boundaries.append(seq)
        onEndBoundary?(seq)
    }
    func linkActivated(on page: PageID, layer: LayerID) { links.append((page, layer)) }
    func retired(_ page: PageID, finalInk: PKDrawing?) {
        retired.append((page, finalInk))
        sequence.append("retired")
    }
    func undoRequested() { undoRequests += 1 }
    func redoRequested() { redoRequests += 1 }
    func textBoxRequested(on page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment) {
        textBoxRequests.append((page, point, style, alignment))
        sequence.append("textBoxRequested")
    }
    func textEditRequested(on page: PageID, layer: LayerID) {
        textEditRequests.append((page, layer))
        sequence.append("textEditRequested")
    }
    func textEditingEnded(on page: PageID, layer: LayerID, _ text: TextLayer) {
        textEditsEnded.append((page, layer, text))
        sequence.append("textEditingEnded")
    }
}
