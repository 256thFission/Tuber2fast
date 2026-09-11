import Darwin
import Foundation
import PencilKit
import Testing
@testable import TNModel
@testable import TNNotebook

/// What a history entry costs, measured rather than guessed. This is the
/// lever behind the `KNOWN DEFECT` at `EditHistory`: the count bound stands
/// in for a byte bound nobody had measured, and this test is the
/// measurement. It is hosted because the numbers come from real PencilKit
/// storage, not from a model of it.
///
/// Each shape is run a hundred times over the same fixture twice: once
/// keeping only the newest revision, once recording every entry into an
/// `EditHistory`. The difference is what a hundred entries retain. Two
/// readings are taken at every point. Resident size from
/// `mach_task_basic_info` is the number the plan asks for, and it is what
/// the device actually pays, but it counts pages, so a run whose retained
/// bytes fit in pages the allocator already held reads as zero. The
/// allocator's own bytes-in-use count is taken beside it because it is
/// exact at byte granularity; where the two disagree, resident is the
/// noisier one. The noise floor is stated by differencing two identical
/// non-recording runs after a warm-up.
///
/// This runs on the simulator, which is not an iPad: a different
/// allocator, a different page size, and PencilKit built for the Mac. The
/// simulator number says which shapes share and which copy; the device
/// number is the one the bound is set from.
@Suite("History entry cost", .serialized)
struct HistoryEntryCostTests {
    static let strokeCount = 20_000
    static let entries = EditHistory.maximumEntries

    struct Shape {
        let name: String
        let edit: (PageRevision) -> PageRevision
    }

    struct Reading {
        let resident: Int64
        let mallocInUse: Int64

        static func now() -> Reading {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            precondition(result == KERN_SUCCESS, "task_info failed: \(result)")
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return Reading(resident: Int64(info.resident_size), mallocInUse: Int64(stats.size_in_use))
        }

        static func - (lhs: Reading, rhs: Reading) -> Reading {
            Reading(resident: lhs.resident - rhs.resident, mallocInUse: lhs.mallocInUse - rhs.mallocInUse)
        }
    }

    struct Cost {
        let name: String
        let noise: Reading
        let hundredEntries: Reading

        var perEntryResident: Int64 { hundredEntries.resident / Int64(entries) }
        var perEntryMalloc: Int64 { hundredEntries.mallocInUse / Int64(entries) }
    }

    @Test("A hundred entries of each shape, against a hundred copies of the drawing")
    func entryCost() {
        let page = PageID()
        let drawing = Self.drawing(strokes: Self.strokeCount)
        let longText = Self.textLayer(runs: 50, charactersPerRun: 2_000)
        let image = Layer(
            id: LayerID(),
            transform: .placing(sourceWidth: 300, sourceHeight: 200, at: (10, 20), scale: 1),
            payload: .image(ImageLayer(asset: AssetRef(id: AssetID(), format: .heic), naturalSize: PixelSize(width: 300, height: 200)))
        )
        let inkOnly = PageRevision(ink: drawing, layers: [], inkIndex: 0)
        let withText = PageRevision(ink: drawing, layers: [longText, image], inkIndex: 0)

        // Both the erase shapes rebuild the stroke array through `strokes`,
        // which is what an eraser pass or a lasso delete hands `inkChanged`.
        // A real eraser never removes a stroke the drawing does not hold, so
        // the pass steps through the array rather than draining one end.
        var erasePass = 0
        var lassoPass = 0
        let shapes = [
            Shape(name: "append one stroke") { revision in
                var ink = revision.ink
                ink.append(Self.drawing(strokes: 1, offset: Double(revision.ink.strokes.count)))
                return PageRevision(ink: ink, layers: revision.layers, inkIndex: revision.inkIndex)
            },
            Shape(name: "erase five scattered strokes") { revision in
                erasePass += 1
                var strokes = revision.ink.strokes
                for slot in stride(from: 4, through: 0, by: -1) {
                    strokes.remove(at: (erasePass * 7 + slot * (strokes.count / 5)) % strokes.count)
                }
                return PageRevision(ink: PKDrawing(strokes: strokes), layers: revision.layers, inkIndex: revision.inkIndex)
            },
            Shape(name: "lasso-delete twenty contiguous strokes") { revision in
                lassoPass += 1
                var strokes = revision.ink.strokes
                let start = (lassoPass * 131) % (strokes.count - 20)
                strokes.removeSubrange(start..<start + 20)
                return PageRevision(ink: PKDrawing(strokes: strokes), layers: revision.layers, inkIndex: revision.inkIndex)
            },
            Shape(name: "transform an image beside a long text layer") { revision in
                var layers = revision.layers
                let moved = layers[1].withTransform(.translation(x: layers[1].transform.tx + 1, y: layers[1].transform.ty))
                layers[1] = moved
                return PageRevision(ink: revision.ink, layers: layers, inkIndex: revision.inkIndex)
            },
        ]
        let starts = [inkOnly, inkOnly, inkOnly, withText]

        let costs = zip(shapes, starts).map { shape, start in
            Self.measure(shape, from: start, on: page)
        }
        let hundredCopies = Self.measureCopies(of: drawing)
        let compare = Self.timeCompare(drawing)

        print("""
        history entry cost, \(Self.strokeCount) strokes, \(Self.entries) entries per shape, simulator
        \(costs.map(Self.line).joined(separator: "\n"))
          a hundred independent copies of the drawing: resident \(Self.mb(hundredCopies.resident)), malloc \(Self.mb(hundredCopies.mallocInUse))
          compare at \(Self.strokeCount) strokes, result and time: same storage \(compare.identical), rebuilt from the same strokes \(compare.rebuiltEqual), one stroke apart \(compare.oneStrokeApart), decoded from the same bytes \(compare.independentEqual)
        """)

        // The assertion is the shape of the answer, not a byte count. A
        // hundred appended-stroke entries share the base strokes, so they
        // must cost a small fraction of a hundred independent drawings; if
        // sharing broke, an entry would cost a whole drawing and this fails
        // by an order of magnitude. Malloc bytes are the exact reading;
        // resident is reported beside them and left out of the assertion
        // because its page-granular slack is the noise this test names.
        let append = costs[0]
        #expect(append.hundredEntries.mallocInUse * 10 < hundredCopies.mallocInUse, "appended entries retain \(Self.mb(append.hundredEntries.mallocInUse)) against \(Self.mb(hundredCopies.mallocInUse)) for copies")
        for cost in costs {
            #expect(cost.hundredEntries.mallocInUse < hundredCopies.mallocInUse, "\(cost.name) retains \(Self.mb(cost.hundredEntries.mallocInUse)), no less than a hundred copies")
        }
        // A walk over 160,000 points would take longer than this even on a
        // fast Mac; the compare is on stroke identity, so it does not.
        #expect(compare.independentEqual.1 < .milliseconds(10), "an equal-content compare at \(Self.strokeCount) strokes took \(compare.independentEqual.1)")
    }

    // MARK: - Measurement

    /// Warm-up, then two readings around a non-recording run for the noise
    /// floor, then one around a recording run. The recording run's history
    /// stays alive until after its reading.
    static func measure(_ shape: Shape, from start: PageRevision, on page: PageID) -> Cost {
        _ = run(shape, from: start, on: page, recording: false)
        let base = Reading.now()
        _ = run(shape, from: start, on: page, recording: false)
        let afterUnrecorded = Reading.now()
        let history = run(shape, from: start, on: page, recording: true)
        let afterRecorded = Reading.now()
        withExtendedLifetime(history) {}
        return Cost(name: shape.name, noise: afterUnrecorded - base, hundredEntries: afterRecorded - afterUnrecorded)
    }

    static func run(_ shape: Shape, from start: PageRevision, on page: PageID, recording: Bool) -> EditHistory? {
        var history: EditHistory? = recording ? EditHistory() : nil
        var current = start
        for _ in 0..<entries {
            let next = shape.edit(current)
            history?.record(HistoryEntry(page: page, before: current, after: next))
            current = next
        }
        return history
    }

    /// A drawing decoded from its own bytes shares nothing with the
    /// original, so ten of them, scaled up, are what a hundred entries
    /// would cost if `PKDrawing` were not a value over shared storage.
    static func measureCopies(of drawing: PKDrawing) -> Reading {
        let bytes = drawing.dataRepresentation()
        let decode = { (0..<10).map { _ in try! PKDrawing(data: bytes) } }
        _ = decode()
        let base = Reading.now()
        let copies = decode()
        let after = Reading.now()
        withExtendedLifetime(copies) {}
        let ten = after - base
        return Reading(resident: ten.resident * 10, mallocInUse: ten.mallocInUse * 10)
    }

    struct CompareTiming {
        let identical: (Bool, Duration)
        let rebuiltEqual: (Bool, Duration)
        let oneStrokeApart: (Bool, Duration)
        let independentEqual: (Bool, Duration)
    }

    /// `adopt` pays `ink != revision.ink` on every restore. Four cases,
    /// because the plan's fallback is an identity check on the storage
    /// before the compare: the same value copied; a drawing rebuilt from the
    /// same strokes; the entry's real case, one stroke apart; and a drawing
    /// decoded from the same bytes that shares nothing. The result is
    /// reported with the time because the rebuilt case compares unequal:
    /// `PKDrawing(strokes:)` mints new stroke identities, and equality is
    /// on those, not on points.
    static func timeCompare(_ drawing: PKDrawing) -> CompareTiming {
        let clock = ContinuousClock()
        func fastest(_ body: () -> Bool) -> (Bool, Duration) {
            (body(), (0..<5).map { _ in clock.measure { _ = body() } }.min()!)
        }
        let copy = drawing
        let rebuilt = PKDrawing(strokes: drawing.strokes)
        var appended = drawing
        appended.append(Self.drawing(strokes: 1, offset: Double(strokeCount)))
        let independent = try! PKDrawing(data: drawing.dataRepresentation())
        return CompareTiming(
            identical: fastest { drawing == copy },
            rebuiltEqual: fastest { drawing == rebuilt },
            oneStrokeApart: fastest { drawing == appended },
            independentEqual: fastest { drawing == independent }
        )
    }

    // MARK: - Fixtures

    static func drawing(strokes: Int, offset: Double = 0) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let all = (0..<strokes).map { index -> PKStroke in
            let y = 10 + Double(index + Int(offset)).truncatingRemainder(dividingBy: 700)
            let points = (0..<8).map { step in
                PKStrokePoint(
                    location: CGPoint(x: 10 + Double(step) * 20, y: y),
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
        return PKDrawing(strokes: all)
    }

    static func textLayer(runs: Int, charactersPerRun: Int) -> Layer {
        let text = (0..<runs).map { run in
            TextRun(string: String(repeating: Character(UnicodeScalar(UInt8(97 + run % 26))), count: charactersPerRun))
        }
        return Layer(
            id: LayerID(),
            transform: .identity,
            payload: .text(TextLayer(rect: PageRect(x: 10, y: 10, width: 500, height: 600), runs: text, alignment: .leading))
        )
    }

    // MARK: - Report

    static func line(_ cost: Cost) -> String {
        "  \(cost.name): per entry resident \(kb(cost.perEntryResident)), malloc \(kb(cost.perEntryMalloc)); noise floor over a hundred unrecorded edits resident \(kb(cost.noise.resident)), malloc \(kb(cost.noise.mallocInUse))"
    }

    static func kb(_ bytes: Int64) -> String { String(format: "%.1f KB", Double(bytes) / 1024) }
    static func mb(_ bytes: Int64) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }
}
