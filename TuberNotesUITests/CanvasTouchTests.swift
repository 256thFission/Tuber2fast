import XCTest

/// Touch delivery against the real canvas.
///
/// This suite exists because of a specific failure: the app crashed inside
/// UIKit's touch machinery on the first stroke, while the structural gate, the
/// unit tests, and the simulator launch all passed. Unit tests drive the
/// controller headlessly, and `drawingPolicy = .pencilOnly` means the
/// simulator's pointer never draws — so nothing anywhere exercised a touch.
///
/// These tests deliver real touches through UIKit. They cannot prove Pencil
/// feel, pressure, or palm rejection, which remain device-and-human only.
@MainActor
final class CanvasTouchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The narrowest possible reproduction: does the app survive one touch?
    ///
    /// The crash was in `-[UIGestureRecognizer _delayTouchesForEvent:]`, which
    /// runs for any touch during event delivery, not only for drawing. A finger
    /// tap should therefore be enough to trip it even though it cannot draw.
    func testCanvasSurvivesASingleTap() {
        let app = XCUIApplication()
        app.launch()

        let canvas = canvasElement(in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()

        XCTAssertEqual(app.state, .runningForeground, "the app died on a single tap")
    }

    /// A drag across the page: the gesture shape a stroke actually makes.
    func testCanvasSurvivesADrag() {
        let app = XCUIApplication()
        app.launch()

        let canvas = canvasElement(in: app)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertEqual(app.state, .runningForeground, "the app died on a drag")
    }

    /// Repeated drags, because the first crash reports came in bursts.
    func testCanvasSurvivesRepeatedDrags() {
        let app = XCUIApplication()
        app.launch()

        let canvas = canvasElement(in: app)
        for step in 0..<5 {
            let offset = 0.25 + Double(step) * 0.08
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: offset))
            let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: offset))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertEqual(app.state, .runningForeground, "the app died on drag \(step)")
        }
    }

    /// The real canvas, and never a substitute.
    ///
    /// This deliberately does not fall back to the window. The canvas is hosted
    /// only once the document loads, so a failed load shows an error view
    /// instead — and touching that would pass every assertion below while
    /// proving nothing about the canvas.
    private func canvasElement(in app: XCUIApplication) -> XCUIElement {
        let canvas = app.descendants(matching: .any)["page.canvas"]
        XCTAssertTrue(
            canvas.waitForExistence(timeout: 15),
            "the canvas was never hosted; the document probably failed to load"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["page.error"].exists,
            "the app is showing the load-failure view, so no canvas was touched"
        )
        return canvas
    }
}

/// Pinch behavior, added after the crash was fixed and zoom was reported wrong.
@MainActor
final class CanvasZoomTests: XCTestCase {
    func testCanvasSurvivesPinch() {
        let app = XCUIApplication()
        app.launch()
        let canvas = app.descendants(matching: .any)["page.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))

        canvas.pinch(withScale: 2.5, velocity: 1.5)
        XCTAssertEqual(app.state, .runningForeground, "died zooming in")

        canvas.pinch(withScale: 0.4, velocity: -1.5)
        XCTAssertEqual(app.state, .runningForeground, "died zooming out")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertEqual(app.state, .runningForeground, "died panning after zoom")
    }
}
