import CoreGraphics
import PencilKit
import Testing
@testable import TNCanvas
@testable import TNModel
import UIKit

/// Objects on a hosted canvas: what a tap hits, the frame the lasso raises,
/// and the one report each move, delete or lock makes.
@Suite("Canvas selection")
@MainActor
final class TNCanvasSelectionTests: HostingSuite {
    @Test("Hit-testing: topmost wins, a link is nothing, paper is a box")
    func textHitTesting() {
        let a = LayerID(), b = LayerID(), link = LayerID()
        let rects = [
            HitTarget(id: a, kind: .text, transform: .unitSquare(to: PageRect(x: 0, y: 0, width: 100, height: 100)), locked: false),
            HitTarget(id: b, kind: .text, transform: .unitSquare(to: PageRect(x: 50, y: 50, width: 100, height: 100)), locked: false),
            HitTarget(id: link, kind: .link, transform: .unitSquare(to: PageRect(x: 300, y: 300, width: 50, height: 50)), locked: false),
        ]
        #expect(PageCanvasController.textHit(at: CGPoint(x: 10, y: 10), targets: rects) == .edit(a))
        #expect(PageCanvasController.textHit(at: CGPoint(x: 75, y: 75), targets: rects) == .edit(b))
        #expect(PageCanvasController.textHit(at: CGPoint(x: 310, y: 310), targets: rects) == nil)
        #expect(PageCanvasController.textHit(at: CGPoint(x: 500, y: 500), targets: rects) == .create(PagePoint(x: 500, y: 500)))
        #expect(PageCanvasController.linkHit(at: CGPoint(x: 310, y: 310), targets: rects) == link)
        #expect(PageCanvasController.linkHit(at: CGPoint(x: 10, y: 10), targets: rects) == nil)
    }

    @Test("A tap on an image with the lasso raises one frame at the layer's placement")
    func lassoTapSelectsAnImage() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])

        canvas.tapped(at: centre(of: image))
        guard case .selected(let layer, _) = canvas.phase else {
            Issue.record("phase is \(canvas.phase)")
            return
        }
        #expect(layer == image.id)
        let selection = try #require(frame(on: canvas))
        #expect(canvas.overlayView.subviews.filter { $0 is LayerSelectionView }.count == 1)
        #expect(selection.frame.origin == CGPoint(x: image.transform.tx, y: image.transform.ty))
        #expect(selection.bounds.size == CGSize(width: 120, height: 80))
        _ = runtime.retireAll()
    }

    @Test("The same tap with a pen selects nothing: a Pencil over a photo writes on it")
    func aPenSelectsNothing() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image], tool: PKInkingTool(.pen, color: .black))

        canvas.tapped(at: centre(of: image))
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(frame(on: canvas) == nil)
        _ = runtime.retireAll()
    }

    @Test("A tap on paper clears the selection; a tap on a second image replaces the frame")
    func tapsClearAndReplace() throws {
        let reporter = RecordingReporter()
        let first = imageLayer(x: 40, y: 40)
        let second = imageLayer(x: 300, y: 400)
        let (runtime, _, canvas) = try livePage(reporter, layers: [first, second])

        canvas.tapped(at: centre(of: first))
        #expect(frame(on: canvas)?.layerID == first.id)

        canvas.tapped(at: centre(of: second))
        #expect(canvas.overlayView.subviews.filter { $0 is LayerSelectionView }.count == 1)
        #expect(frame(on: canvas)?.layerID == second.id)

        canvas.tapped(at: CGPoint(x: 580, y: 760))
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(frame(on: canvas) == nil)
        _ = runtime.retireAll()
    }

    @Test("A move reports the whole transform once, at the drag's end, and nothing before it")
    func aMoveReportsOnceAtTheEnd() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, page, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))

        selection.beginDrag(at: CGPoint(x: 60, y: 40))
        selection.continueDrag(to: CGPoint(x: 90, y: 80), by: CGPoint(x: 30, y: 40))
        #expect(reporter.transforms.isEmpty, "nothing is reported while the finger is down")
        #expect(selection.working.tx == 130 && selection.working.ty == 240)

        selection.endDrag()
        #expect(reporter.transforms.count == 1)
        let reported = try #require(reporter.transforms.first)
        #expect(reported.page == page && reported.layer == image.id)
        #expect(reported.transform.tx == 130 && reported.transform.ty == 240)
        #expect(reported.transform.a == image.transform.a && reported.transform.d == image.transform.d)
        _ = runtime.retireAll()
    }

    @Test("A refusal puts the frame back where the notebook holds the layer")
    func aRefusalRestoresTheAcceptedPlacement() throws {
        let reporter = RecordingReporter()
        reporter.transformOutcome = .refused(reason: "off the page")
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))

        selection.move(by: CGPoint(x: 5000, y: 5000))
        selection.beginDrag(at: CGPoint(x: 60, y: 40))
        selection.endDrag()
        #expect(selection.working == image.transform)
        #expect(selection.frame.origin == CGPoint(x: 100, y: 200))
        _ = runtime.retireAll()
    }

    @Test("A composite restates the frame, clears it when the layer is gone, and leaves a drag in flight alone")
    func setLayersRestatesTheFrame() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))

        let moved = image.withTransform(.placing(sourceWidth: 120, sourceHeight: 80, at: (300, 500), scale: 1))
        canvas.setLayers([moved])
        #expect(selection.working.tx == 300 && selection.working.ty == 500)
        #expect(selection.frame.origin == CGPoint(x: 300, y: 500))

        selection.beginDrag(at: CGPoint(x: 60, y: 40))
        selection.continueDrag(to: CGPoint(x: 70, y: 40), by: CGPoint(x: 10, y: 0))
        canvas.setLayers([image])
        #expect(selection.accepted == image.transform, "the notebook's value is recorded")
        #expect(selection.working.tx == 310, "the drag is not interrupted")
        selection.endDrag()

        canvas.setLayers([])
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(frame(on: canvas) == nil)
        _ = runtime.retireAll()
    }

    @Test("A corner scale is uniform and cannot take either extent below eight points")
    func aCornerScaleIsUniformAndFloored() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))

        selection.scale(fromCorner: .bottomRight, to: CGPoint(x: 160, y: 240))
        let half = selection.working.unitExtents
        #expect(abs(half.width - 60) < 1e-9 && abs(half.height - 40) < 1e-9)
        #expect(abs(half.width / half.height - 1.5) < 1e-9, "the ratio is kept")
        #expect(selection.working.tx == 100 && selection.working.ty == 200, "the opposite corner stays")

        selection.scale(fromCorner: .bottomRight, to: CGPoint(x: 100, y: 200))
        let floored = selection.working.unitExtents
        #expect(floored.height >= LayerSelectionView.minimumExtent)
        #expect(abs(floored.width / floored.height - 1.5) < 1e-9)
        _ = runtime.retireAll()
    }

    @Test("Where the touch lands decides what the drag is, once, at its start")
    func theCornerDecidesTheDrag() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))
        canvas.view.layoutIfNeeded()

        // The bottom-right corner of the bounds, which its handle straddles.
        selection.beginDrag(at: CGPoint(x: 120, y: 80))
        selection.continueDrag(to: CGPoint(x: 60, y: 40), by: CGPoint(x: -60, y: -40))
        let extents = selection.working.unitExtents
        #expect(abs(extents.width - 60) < 1e-9 && abs(extents.height - 40) < 1e-9, "a corner scales")
        #expect(selection.working.tx == 100 && selection.working.ty == 200)
        selection.endDrag()
        #expect(reporter.transforms.count == 1)
        _ = runtime.retireAll()
    }

    @Test("A quarter turn rotates about the centre and leaves it where it was")
    func aQuarterTurnKeepsTheCentre() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))
        let before = selection.pageCentre

        selection.rotate(to: .pi / 2)
        #expect(selection.working.b > 0 && selection.working.c < 0)
        #expect(abs(selection.working.a) < 1e-9 && abs(selection.working.d) < 1e-9)
        #expect(abs(selection.pageCentre.x - before.x) < 1e-9)
        #expect(abs(selection.pageCentre.y - before.y) < 1e-9)
        let extents = selection.working.unitExtents
        #expect(abs(extents.width - 120) < 1e-9 && abs(extents.height - 80) < 1e-9)
        _ = runtime.retireAll()
    }

    @Test("A rotated image is hit by its own shape, not by the box around it")
    func aRotatedImageIsHitByItsOwnShape() throws {
        let reporter = RecordingReporter()
        let eighth = Double.pi / 4
        let turn = PageSpaceTransform(a: cos(eighth), b: sin(eighth), c: -sin(eighth), d: cos(eighth), tx: 0, ty: 0)
        let turned = Layer(
            id: LayerID(),
            transform: PageSpaceTransform.placing(sourceWidth: 120, sourceHeight: 80, at: (0, 0), scale: 1)
                .concatenating(turn)
                .concatenating(.translation(x: 300, y: 200)),
            payload: .image(ImageLayer(
                asset: AssetRef(id: AssetID(), format: .heic),
                naturalSize: PixelSize(width: 120, height: 80)
            ))
        )
        let (runtime, _, canvas) = try livePage(reporter, layers: [turned])

        canvas.tapped(at: centre(of: turned))
        #expect(frame(on: canvas)?.layerID == turned.id)

        // The top-left of the axis-aligned box around a diamond is outside
        // the diamond. A `CGRect.contains` would select here.
        let corners = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)].map { turned.transform.apply(x: $0.0, y: $0.1) }
        let boxCorner = CGPoint(
            x: corners.map(\.x).min()! + 0.5,
            y: corners.map(\.y).min()! + 0.5
        )
        canvas.tapped(at: boxCorner)
        #expect(frame(on: canvas) == nil, "a point the box admits and the shape does not clears the selection")
        _ = runtime.retireAll()
    }

    @Test("The text tool takes the frame down, and so does retiring, which reports only its ink")
    func aToolChangeAndARetireDropTheFrame() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])

        canvas.tapped(at: centre(of: image))
        #expect(frame(on: canvas) != nil)
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading), theme: .macaron))
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(frame(on: canvas) == nil)

        runtime.apply(CanvasEnvironment(tool: .ink(PKLassoTool()), theme: .macaron))
        canvas.tapped(at: centre(of: image))
        #expect(frame(on: canvas) != nil)
        _ = runtime.retireAll()
        #expect(reporter.transforms.isEmpty, "a selection is not a value, so a retire reports none of it")
        #expect(reporter.retired.count == 1)
    }

    @Test("Delete from the frame's menu is one report, and the frame waits for the composite")
    func deleteIsOneReport() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, page, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))

        selection.deleteRequested()
        #expect(reporter.deletes.count == 1)
        #expect(reporter.deletes.first?.page == page && reporter.deletes.first?.layer == image.id)
        #expect(frame(on: canvas) != nil, "the frame stays until the composite without the layer lands")

        canvas.setLayers([])
        #expect(frame(on: canvas) == nil)
        _ = runtime.retireAll()
    }

    @Test("Lock from the frame's menu is one report; the composite that answers takes the handles down and the drag with them")
    func lockIsOneReportAndTheCompositeLocksTheFrame() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, page, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))
        #expect(!selection.isLocked)
        #expect(selection.menuActions().map(\.title) == ["Lock", "Delete"])

        selection.lockRequested(true)
        #expect(reporter.locks.count == 1)
        #expect(reporter.locks.first?.page == page && reporter.locks.first?.layer == image.id)
        #expect(reporter.locks.first?.locked == true)
        #expect(!selection.isLocked, "the frame waits for the composite, as it does for a delete")

        canvas.setLayers([image.withLock(true)])
        #expect(selection.isLocked)
        #expect(frame(on: canvas) === selection, "the same frame, restated")
        #expect(selection.menuActions().map(\.title) == ["Unlock"])
        #expect(!selection.panRecognizer.isEnabled)
        canvas.view.layoutIfNeeded()
        #expect(!selection.point(inside: CGPoint(x: 60, y: -30), with: nil), "the knob is gone")
        #expect(selection.point(inside: CGPoint(x: 60, y: 40), with: nil), "the border still takes the tap that opens the menu")
        selection.beginDrag(at: CGPoint(x: 60, y: 40))
        selection.continueDrag(to: CGPoint(x: 90, y: 80), by: CGPoint(x: 30, y: 40))
        selection.endDrag()
        #expect(selection.working == image.transform, "a locked frame does not start a drag")
        #expect(reporter.transforms.isEmpty)

        selection.lockRequested(false)
        #expect(reporter.locks.count == 2 && reporter.locks.last?.locked == false)
        canvas.setLayers([image])
        #expect(!selection.isLocked)
        #expect(selection.menuActions().map(\.title) == ["Lock", "Delete"])
        #expect(selection.panRecognizer.isEnabled)
        _ = runtime.retireAll()
    }

    @Test("A tap on a locked image with the lasso raises a frame with the unlock affordance and no handles")
    func aLockedImageSelectsLocked() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200).withLock(true)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])

        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))
        #expect(selection.layerID == image.id)
        #expect(selection.isLocked)
        #expect(selection.menuActions().map(\.title) == ["Unlock"])
        #expect(!selection.panRecognizer.isEnabled)
        #expect(selection.frame.origin == CGPoint(x: 100, y: 200))
        _ = runtime.retireAll()
    }
}
