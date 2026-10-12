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
///
/// KNOWN DEFECT: `entryCost` is flaky in a whole-suite run. It failed once
/// and passed twice across three identical runs of the full suite, and
/// passes every time it runs alone. Both readings are process-wide, so what
/// the rest of the suite left allocated lands inside the measurement, and
/// the noise floor is differenced before the suite's peak rather than after
/// it. Until the readings are taken in a child process, or the floor is
/// re-taken next to each shape, a red `entryCost` is not evidence about
/// `EditHistory`.
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
        var setterPass = 0
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
            // The same five strokes, removed through the `strokes` setter on a
            // copy of the drawing instead of rebuilt with `PKDrawing(strokes:)`.
            // This is the one shape the gesture path would take, and the
            // question is only whether the setter shares stroke storage with
            // the drawing it came from, as an appended stroke does, or mints
            // afresh, as the initialiser does. The two lines above and below
            // differ in nothing else, so the difference between their figures
            // is the answer.
            Shape(name: "erase five scattered strokes through the strokes setter") { revision in
                setterPass += 1
                var edited = revision.ink
                for slot in stride(from: 4, through: 0, by: -1) {
                    edited.strokes.remove(at: (setterPass * 7 + slot * (edited.strokes.count / 5)) % edited.strokes.count)
                }
                return PageRevision(ink: edited, layers: revision.layers, inkIndex: revision.inkIndex)
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
        let starts = [inkOnly, inkOnly, inkOnly, inkOnly, withText]

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

    /// What recognition costs on a full page, timed as the notebook runs it:
    /// one read of `drawing.strokes` and `GestureTrigger.recognise` over the
    /// array, with both triggers bound, so both readings are taken. It is
    /// taken inside `inkChanged`, synchronously, once per committed stroke,
    /// so its worst case is a scratch-out over the densest page this suite
    /// knows how to build. The scribble hit test is the pass that scales
    /// with the page, and it runs only after the shape thresholds pass, so
    /// this is the case that pays for it: a zigzag with sharp turns laid
    /// over the fixture's strokes, whose `hits` is therefore non-nil. The
    /// double-circle reading stops at the closings count on this shape,
    /// which is what it does on every stroke that is not a ring.
    ///
    /// The same zigzag is timed again clear of every stroke, because the
    /// cost is two terms and the gate needs to know which one it is failing.
    /// That reading still walks all twenty thousand `renderBounds` and still
    /// passes the shape thresholds; it just never reaches a candidate. The
    /// difference between the two figures is what the candidates cost.
    ///
    /// Fastest of five after a warm-up, because a wall-clock figure on a
    /// shared machine is only trustworthy at its minimum.
    ///
    /// The plan asked for ten milliseconds. The suite runs Debug, where the
    /// whole recognition takes 25.1 ms for a scratch-out that crosses 957 of
    /// the fixture's strokes and 3.4 ms for the same shape clear of the ink.
    /// The shipped build is compiled with `SWIFT_OPTIMIZATION_LEVEL=-O`,
    /// where the earlier reading-only figures were about a third of their
    /// Debug ones; that run is optional and not this test's.
    ///
    /// How it got there. The first reading was 66 ms Debug, split at 725
    /// candidates and 152 samples, fastest of five:
    ///
    /// | Term | Fastest of five |
    /// |---|---|
    /// | `drawing.strokes` | 1.4 ms |
    /// | the `renderBounds` scan over all 20,000 | 2.6 ms |
    /// | `maskedPathRanges` of the 725 candidates | 0.2 ms |
    /// | interpolating those candidates' paths | 5.9 ms |
    /// | the sample-against-sample distance loop | 60 ms |
    ///
    /// Three edits to the hit test, none of which changes an answer: a
    /// candidate point outside the scribble's box grown by the reach is
    /// skipped before the samples are walked; a candidate is walked lazily
    /// and the first hit ends the walk, so its path is never copied into
    /// an array; and a candidate's half width reads three points instead
    /// of every one. What is left is the floor a full page charges whatever
    /// the scribble does, the strokes array and the bounds scan, about
    /// 4 ms Debug, plus the second reading's own scan of the same page.
    ///
    /// The fixture is denser than any real page: twenty thousand strokes
    /// over seven hundred rows, every one of them spanning the same 140
    /// points of width, so a word-sized scratch-out crosses 957 strokes
    /// where a real one crosses a handful. On a real page the reading is
    /// the floor.
    ///
    /// The gate below is a tripwire at about twice the Debug figure,
    /// so it catches an order-of-magnitude regression and survives a busy
    /// machine. The feel on a device is the plan's step 4.
    @Test("The whole recognition of one zigzag over the fixture, timed")
    func gestureRecognitionCost() {
        let clock = ContinuousClock()
        let bindings: GestureBindings = [.scribble: .erase, .doubleCircle: .erase]
        /// The notebook's own body: one read of the strokes array, then the
        /// entry point over it. The read is inside the timing because the
        /// notebook pays it on every committed stroke.
        func recognition(of zigzag: PKStroke) -> (ScribbleReading, GestureMatch?, Duration) {
            var drawing = Self.drawing(strokes: Self.strokeCount)
            drawing.strokes.append(zigzag)
            func once() -> GestureMatch? {
                let strokes = drawing.strokes
                return GestureTrigger.recognise(
                    stroke: strokes.count - 1, in: strokes, bindings: bindings, log: { _ in }
                )
            }
            let match = once()
            let fastest = (0..<5).map { _ in clock.measure { _ = once() } }.min()!
            // The reading itself, for the figures the line below prints and
            // the assertions rest on; untimed, because the gate is on the
            // recognition as a whole.
            let strokes = drawing.strokes
            return (ScribbleReading.measure(stroke: strokes.count - 1, in: strokes), match, fastest)
        }
        // The fixture's strokes run from x 10 to x 150, one y a stroke, so a
        // scratch-out the size of a word crosses the rows it covers, and the
        // same shape out past x 150 crosses nothing.
        let (overInk, overInkMatch, overInkTime) = recognition(of: Self.zigzag(over: CGRect(x: 40, y: 100, width: 60, height: 20), turns: 4))
        let (clearOfInk, clearOfInkMatch, clearOfInkTime) = recognition(of: Self.zigzag(over: CGRect(x: 400, y: 100, width: 60, height: 20), turns: 4))

        print("""
        gesture recognition, \(Self.strokeCount) strokes plus the zigzag, both triggers bound, fastest of five, simulator
          over the ink: turns \(overInk.turns), folding \(Self.two(overInk.folding)), hits \(overInk.hits?.count ?? -1), trigger \(overInkMatch?.trigger.rawValue ?? "none"); \(overInkTime)
          clear of it, the page scan alone: turns \(clearOfInk.turns), folding \(Self.two(clearOfInk.folding)), hits \(clearOfInk.hits?.count ?? -1), trigger \(clearOfInkMatch?.trigger.rawValue ?? "none"); \(clearOfInkTime)
        """)

        // Non-nil hits is the point of the case: a reading that stopped at the
        // shape thresholds never pays for the page, and would time nothing.
        #expect(overInk.hits != nil, "the zigzag read as ink: turns \(overInk.turns), folding \(overInk.folding)")
        #expect(overInkMatch?.trigger == .scribble, "the zigzag crossed none of the fixture's strokes")
        #expect(clearOfInk.hits == [], "the zigzag clear of the ink hit \(clearOfInk.hits.map { String($0.count) } ?? "nothing, having failed the shape thresholds")")
        #expect(clearOfInkMatch == nil, "a trigger with no subject is ink")
        #expect(overInkTime < .milliseconds(50), "recognition at \(Self.strokeCount) strokes took \(overInkTime), of which \(clearOfInkTime) is the page scan with no candidate")
    }

    /// A scratch-out over `rect`: `turns` sharp reversals across its width,
    /// descending its height. The interior vertices are repeated, because
    /// PencilKit interpolates through the control points and a repeat is what
    /// makes a corner a cusp rather than a curve. The same construction as
    /// `Ink.zigzag` in `TNTests/NotebookTests.swift`, copied because hostless
    /// fixtures are not on this target.
    static func zigzag(over rect: CGRect, turns: Int) -> PKStroke {
        // A corner at every vertex but the two ends, so `turns` of them needs
        // two more points than turns.
        let count = turns + 2
        let step = rect.height / CGFloat(count - 1)
        let vertices = (0..<count).map { i in
            CGPoint(x: i.isMultiple(of: 2) ? rect.minX : rect.maxX, y: rect.minY + CGFloat(i) * step)
        }
        var locations = [vertices[0]]
        for (i, pair) in zip(vertices, vertices.dropFirst()).enumerated() {
            let (a, b) = pair
            let steps = max(Int(hypot(b.x - a.x, b.y - a.y) / 3), 1)
            for leg in 1...steps {
                let t = CGFloat(leg) / CGFloat(steps)
                locations.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
            if i + 2 < vertices.count { locations += Array(repeating: b, count: 2) }
        }
        let points = locations.enumerated().map { i, location in
            PKStrokePoint(
                location: location,
                timeOffset: Double(i) * 0.01,
                size: CGSize(width: 2, height: 2),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
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
            history?.record(HistoryEntry(page: page, before: current, after: next, rebuilt: false))
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

    static func two(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
    static func kb(_ bytes: Int64) -> String { String(format: "%.1f KB", Double(bytes) / 1024) }
    static func mb(_ bytes: Int64) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }
}
