import Foundation
import PencilKit
import Testing
@testable import TuberCanvas
@testable import TuberModel
import UIKit

/// A deterministic heavy page: enough ink that `PKDrawing(data:)` costs
/// something worth measuring.
///
/// Deterministic in its *strokes*, which is the property that matters: the
/// numbers this fixture produces are compared across machines — a simulator
/// run today against a device run later — and a fixture that drew a different
/// picture on each would make the comparison meaningless.
///
/// Not deterministic in its *bytes*. Two `dataRepresentation()` calls over
/// equal drawings return equal-length, non-identical data; PencilKit's
/// encoding carries something we do not control. The size is stable and the
/// ink is stable, so the measurement is comparable; nothing here may assert
/// byte equality, and `heavyFixtureIsDeterministic` asserts the stroke
/// geometry instead.
enum HeavyPageFixture {
    /// SplitMix64. Chosen because it is eight lines and its output does not
    /// depend on the standard library's generator, which is free to change
    /// under us and would take the cross-machine comparison with it.
    struct Seeded: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The scale the fork document names: a 20k-stroke page, which encodes to
    /// 4.64 MB on the pinned simulator's SDK against its 4.6 MB. The size is
    /// reported by the benchmark rather than asserted — the encoding is
    /// Apple's, and a suite that failed because iOS got better at compression
    /// would be a check that cries wolf.
    static let heavyStrokeCount = 20_000

    /// Control points per stroke. Eight is a short deliberate mark rather than
    /// a scribble; the stroke *count* is what the fixture is about.
    static let defaultPointsPerStroke = 8

    static func drawing(
        strokeCount: Int = heavyStrokeCount,
        pointsPerStroke: Int = defaultPointsPerStroke,
        seed: UInt64 = 0x7E57_C0DE
    ) -> PKDrawing {
        var random = Seeded(seed: seed)
        var strokes: [PKStroke] = []
        strokes.reserveCapacity(strokeCount)

        // Canonical portrait page space, inset so nothing lands off the page.
        let width = 612.0
        let height = 792.0

        for _ in 0..<strokeCount {
            let originX = Double.random(in: 12...(width - 60), using: &random)
            let originY = Double.random(in: 12...(height - 60), using: &random)
            var points: [PKStrokePoint] = []
            points.reserveCapacity(pointsPerStroke)
            for step in 0..<pointsPerStroke {
                let t = Double(step)
                points.append(
                    PKStrokePoint(
                        location: CGPoint(
                            x: originX + t * Double.random(in: 1...6, using: &random),
                            y: originY + t * Double.random(in: -3...3, using: &random)
                        ),
                        timeOffset: t * 0.01,
                        size: CGSize(width: 3, height: 3),
                        opacity: 1,
                        force: Double.random(in: 0.3...1, using: &random),
                        azimuth: 0,
                        altitude: .pi / 2
                    )
                )
            }
            strokes.append(
                PKStroke(
                    ink: PKInk(.pen, color: .black),
                    path: PKStrokePath(
                        controlPoints: points,
                        // Fixed, not `Date()`: a creation date that moved would
                        // make the ink differ run to run.
                        creationDate: Date(timeIntervalSince1970: 0)
                    )
                )
            )
        }
        return PKDrawing(strokes: strokes)
    }

    static func inkData(
        strokeCount: Int = heavyStrokeCount,
        seed: UInt64 = 0x7E57_C0DE
    ) -> Data {
        drawing(strokeCount: strokeCount, seed: seed).dataRepresentation()
    }
}

/// # The settle-path decode benchmark
///
/// ## What it is for
///
/// `refreshWindow` builds every slot that entered the window, on main, from a
/// settle callback. Each inked slot used to cost one synchronous
/// `PKDrawing(data:)`, and the window is a radius of two, so a settle that
/// jumped five pages paid five decodes in one main-thread turn. This suite is
/// the measurement that decided what to do about that, and it stays because
/// the decision it supports is provisional — see below.
///
/// What it measured, on the pinned simulator, with the fixture above:
///
/// | | median |
/// |---|---|
/// | one `PKDrawing(data:)` over a 20k-stroke / 4.64 MB page | **32 ms** |
/// | one settle building five such pages, decoding on main | **219 ms** |
///
/// Against a 8–16 ms frame budget that is one decode over budget on its own,
/// and thirteen budgets for the settle. So the decode moved off main and
/// installs on arrival, and `perSettleCost` below now measures what is left
/// on main — *and asserts that the decode is not back on it*, which is the
/// part of this file that can actually fail.
///
/// ## A simulator number bounds nothing about an iPad
///
/// This runs on a Mac's CPU, with a Mac's memory bandwidth, through a
/// PencilKit built for the simulator. It is not slower-than-device in a known
/// direction and it is not faster-than-device in a known direction — it is
/// *unrelated*, and no inequality may be inferred from it either way.
/// `Docs/Unproven.md` carries the device measurement as owed.
///
/// ## Running it on hardware
///
/// The same code, a different destination — which is why the measurement is a
/// test rather than a procedure written down somewhere:
///
/// ```bash
/// xcodebuild test -project TuberNotes.xcodeproj -scheme TuberNotes \
///   -destination "platform=iOS,name=<your iPad>" \
///   -only-testing:TuberNotesTests/SettleDecodeBenchmark 2>&1 | grep TN_BENCH
/// ```
///
/// ## It runs in every suite run, and asserts nothing about time
///
/// No opt-in gate. An environment-variable gate cannot be set on the test
/// process by `xcodebuild` on both destinations — `TEST_RUNNER_` does not
/// reach an app-hosted unit test here — and a benchmark nobody can re-run on
/// the device has already failed at its one job. The suite costs about three
/// seconds.
///
/// No timing assertion either, on either destination. A threshold on wall
/// time is the definition of a check that cries wolf, and the verdict on
/// whether a number is a hitch belongs to a maintainer holding the iPad. What
/// is asserted is *shape*: that a settle returns having installed nothing,
/// with its decodes still outstanding.
@Suite("Settle-path decode benchmark")
@MainActor
struct SettleDecodeBenchmark {
    @Test("The heavy-page fixture draws the same ink for a given seed")
    func heavyFixtureIsDeterministic() throws {
        // Small, so an ordinary run pays milliseconds. Determinism is a
        // property of the generator, not of the stroke count.
        let first = HeavyPageFixture.drawing(strokeCount: 64, seed: 99)
        let second = HeavyPageFixture.drawing(strokeCount: 64, seed: 99)
        let other = HeavyPageFixture.drawing(strokeCount: 64, seed: 100)

        #expect(controlPoints(of: first) == controlPoints(of: second))
        #expect(controlPoints(of: first) != controlPoints(of: other))

        // And it survives a round trip through the encoding the benchmark
        // actually times, which is what the measurement runs on.
        let restored = try PKDrawing(data: first.dataRepresentation())
        #expect(restored.strokes.count == 64)
    }

    @Test("Decoding one heavy page's ink")
    func perDecodeCost() throws {
        let data = HeavyPageFixture.inkData()
        let strokes = try PKDrawing(data: data).strokes.count

        // One discarded warm-up: the first decode in a process pays PencilKit's
        // one-time setup, which a settle mid-session does not.
        _ = try PKDrawing(data: data)

        var samples: [Duration] = []
        for _ in 0..<7 {
            var decoded: PKDrawing?
            let elapsed = try ContinuousClock().measure {
                decoded = try PKDrawing(data: data)
            }
            #expect(decoded != nil)
            samples.append(elapsed)
        }

        report(
            "per-decode",
            detail: "\(strokes) strokes, \(bytes(data.count)) encoded",
            samples: samples
        )
    }

    @Test("One settle that brings five heavy pages into the window")
    func perSettleCost() async throws {
        let data = HeavyPageFixture.inkData()

        var settleSamples: [Duration] = []
        var installSamples: [Duration] = []

        for _ in 0..<5 {
            let session = TestCanvasSession()
            session.content = { _ in .ink(data) }
            let controller = PagedCanvasController(session: session)
            let root = controller.view!
            root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
            root.layoutIfNeeded()
            controller.setTestPages(count: 40, current: 0)
            controller.markEditable()

            // A jump of ten pages: the old window and the new share nothing, so
            // `refreshWindow` retires five slots and builds five — the worst
            // settle the window radius admits.
            let scroll = controller.scrollView
            scroll.contentOffset = CGPoint(x: scroll.bounds.width * 10, y: 0)
            let clock = ContinuousClock()
            let started = clock.now
            let settled = clock.measure {
                controller.scrollViewDidEndDecelerating(scroll)
            }

            // The assertion, and the only thing in this file that fails. A
            // settle that installed ink synchronously would have five canvases
            // here and nothing outstanding — which is the 219 ms this
            // benchmark was written to measure, come back.
            #expect(controller.liveCanvasCount == 0)
            #expect(controller.pendingInkDecodeCount == 5)

            for _ in 0..<400 where controller.pendingInkDecodeCount > 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            let installed = started.duration(to: clock.now)
            #expect(controller.liveCanvasCount == 5)

            settleSamples.append(settled)
            installSamples.append(installed)
        }

        report(
            "per-settle, main thread",
            detail: "5 heavy pages entering the window, \(bytes(data.count)) each",
            samples: settleSamples
        )
        // Wall time, not main-thread time: it includes this test's own 5 ms
        // polling granularity and whatever else the machine was doing. It says
        // how long the pages read "loading", not what the frame path paid.
        report(
            "settle to all five installed (wall, ±5 ms polling)",
            detail: "5 heavy pages",
            samples: installSamples
        )
    }

    // MARK: - Reporting

    /// Prints median, min, and max. Median rather than mean: a single
    /// scheduling stall on a shared machine moves a mean and does not move a
    /// median, and a run this short makes one stall likely.
    private func report(_ label: String, detail: String, samples: [Duration]) {
        let ms = samples.map(milliseconds).sorted()
        print(
            String(
                format: "TN_BENCH %@ — %@ — n=%d median %.2f ms (min %.2f, max %.2f)",
                label, detail, ms.count, median(ms), ms.first ?? 0, ms.last ?? 0
            )
        )
    }

    private func median(_ sorted: [Double]) -> Double {
        sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }

    private func bytes(_ count: Int) -> String {
        String(format: "%.2f MB", Double(count) / (1024 * 1024))
    }

    /// Every control point in the drawing, as comparable numbers. `PKStroke`
    /// is not `Equatable`, and the geometry is the part this fixture promises.
    private func controlPoints(of drawing: PKDrawing) -> [CGPoint] {
        drawing.strokes.flatMap { stroke in
            stroke.path.map(\.location)
        }
    }
}
