import Foundation
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

/// Forwards every `PackageStoring` call to a real store. The doubles below
/// override exactly the one method they exist to bend.
class ForwardingStore: PackageStoring, @unchecked Sendable {
    let base: PackageStore
    init(_ base: PackageStore) { self.base = base }
    func load() async throws(FormatFault) -> LoadedNotebook { try await base.load() }
    func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes { try await base.loadPage(page) }
    func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport { try await base.save(batch) }
    func writeAsset(_ data: Data, _ ref: AssetRef) async throws(FormatFault) { try await base.writeAsset(data, ref) }
    func readAsset(_ ref: AssetRef) async throws(FormatFault) -> Data { try await base.readAsset(ref) }
    func readView() async -> ViewState? { await base.readView() }
    func writeView(_ view: ViewState) async throws(FormatFault) { try await base.writeView(view) }
    func compact(now: Date, keeping: Set<AssetRef>) async throws(FormatFault) -> CompactReport { try await base.compact(now: now, keeping: keeping) }
}

/// A real store whose `save` waits until released.
final class HeldStore: ForwardingStore, @unchecked Sendable {
    let gate = Gate()
    func hold() async { await gate.close() }
    func release() async { await gate.open() }
    override func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport {
        await gate.wait()
        return try await base.save(batch)
    }
}

/// A real store whose `loadPage` waits until released, so a page can be
/// held in `.loading` for as long as a test needs.
final class HeldLoadStore: ForwardingStore, @unchecked Sendable {
    private let gate = Gate()
    func hold() async { await gate.close() }
    func release() async { await gate.open() }
    override func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes {
        await gate.wait()
        return try await base.loadPage(page)
    }
}

/// A real store whose `loadPage` refuses every call once told to, so a page
/// that loaded clean once can fail its next load.
final class RefusingLoadStore: ForwardingStore, @unchecked Sendable {
    private let refusing = Gate()
    func refuse() async { await refusing.close() }
    override func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes {
        if !(await refusing.isOpen) { throw .corruptJSON("refused by the test") }
        return try await base.loadPage(page)
    }
}

/// A real store whose `save` throws while told to refuse, as a pass fails
/// on a full disk or a write the file system refused.
final class FailingSaveStore: ForwardingStore, @unchecked Sendable {
    private let refusing = Gate()
    func refuse() async { await refusing.close() }
    func accept() async { await refusing.open() }
    override func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport {
        if !(await refusing.isOpen) { throw .corruptJSON("refused by the test") }
        return try await base.save(batch)
    }
}

/// A real store whose `writeAsset` waits until released, so an import can
/// be caught between two of its asset writes.
final class HeldAssetStore: ForwardingStore, @unchecked Sendable {
    let gate = Gate()
    func hold() async { await gate.close() }
    func release() async { await gate.open() }
    override func writeAsset(_ data: Data, _ ref: AssetRef) async throws(FormatFault) {
        await gate.wait()
        try await base.writeAsset(data, ref)
    }
}

/// A gate a test can wait on until enough calls have reached it.
protocol Arrivals: Actor {
    var arrivals: Int { get }
}

actor Gate: Arrivals {
    private(set) var isOpen = true
    /// Every call that reached `wait`, held or let through.
    private(set) var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func close() { isOpen = false }
    func open() {
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }
    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Drops every write for a page that has no file yet, so the real store
/// commits an index without it, then reports it refused: a refused *new*
/// page, whatever its identity.
final class RefusingNewPagesStore: ForwardingStore, @unchecked Sendable {
    override func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport {
        let isNew: (PageWrite) -> Bool = { !FileManager.default.fileExists(atPath: self.base.layout.pageURL($0.pageID).path) }
        let refusedIDs = batch.pages.filter(isNew).map(\.pageID)
        let filtered = SaveBatch(index: batch.index, indexChanged: batch.indexChanged, pages: batch.pages.filter { !isNew($0) })
        let report = try await base.save(filtered)
        var refusals = report.refusals
        for id in refusedIDs { refusals[id] = .encodeFailed("refused by the test") }
        return SaveReport(committed: report.committed, refusals: refusals, indexWritten: report.indexWritten, omitted: report.omitted, indexWithheld: report.indexWithheld)
    }
}

/// Refuses every write of one page as a dangling asset, which the store
/// would give again on any retry, and keeps each ink archive it was handed
/// for that page.
final class PermanentlyRefusingStore: ForwardingStore, @unchecked Sendable {
    let page: PageID
    private(set) var archives: [Data] = []
    init(_ base: PackageStore, refusing page: PageID) {
        self.page = page
        super.init(base)
    }
    override func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport {
        let refused = batch.pages.filter { $0.pageID == page }
        for write in refused { if case .archive(let bytes) = write.ink { archives.append(bytes) } }
        let report = try await base.save(SaveBatch(index: batch.index, indexChanged: batch.indexChanged, pages: batch.pages.filter { $0.pageID != page }))
        var refusals = report.refusals
        if !refused.isEmpty { refusals[page] = .danglingAsset(LayerID(), AssetRef(id: AssetID(), format: .heic)) }
        return SaveReport(committed: report.committed, refusals: refusals, indexWritten: report.indexWritten, omitted: report.omitted, indexWithheld: report.indexWithheld)
    }
}

/// A real store whose `readAsset` parks every call until the test releases
/// it by index, so a render can be held while the notebook moves on, and
/// whose `loadPage` waits while `loadGate` is closed.
final class GatedAssetStore: ForwardingStore, @unchecked Sendable {
    let gate = CallGate()
    let loadGate = Gate()
    override func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes {
        await loadGate.wait()
        return try await base.loadPage(page)
    }
    override func readAsset(_ ref: AssetRef) async throws(FormatFault) -> Data {
        await gate.park()
        return try await base.readAsset(ref)
    }
}

/// A real store whose `loadPage` parks every call until the test releases
/// it by index, so a read of a page's files can be held while the notebook
/// moves on.
final class GatedLoadStore: ForwardingStore, @unchecked Sendable {
    let gate = CallGate()
    override func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes {
        await gate.park()
        return try await base.loadPage(page)
    }
}

actor CallGate: Arrivals {
    private var parked: [CheckedContinuation<Void, Never>?] = []
    var arrivals: Int { parked.count }
    func park() async {
        await withCheckedContinuation { parked.append($0) }
    }
    func release(_ index: Int) {
        parked[index]?.resume()
        parked[index] = nil
    }
}

/// One pixel of a composite, as bytes. Premultiplied RGBA, the layout the
/// renderer draws into.
func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
}

func textLayer(_ string: String, rect: PageRect = PageRect(x: 10, y: 10, width: 200, height: 60), size: Double = 40) -> Layer {
    let style = TextStyle(font: .system, size: size, bold: false, italic: false, underline: false, color: TextStyle.body.color)
    return Layer(id: LayerID(), transform: .identity, payload: .text(TextLayer(rect: rect, runs: [TextRun(string: string, style: style)], alignment: .leading)))
}

enum Ink {
    static func drawing(strokes: Int, seed: Double = 0) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let all = (0..<strokes).map { i -> PKStroke in
            let points = (0..<4).map { j in
                PKStrokePoint(location: CGPoint(x: 10 + Double(j) * 20 + seed, y: 10 + Double(i) * 15), timeOffset: Double(j) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        return PKDrawing(strokes: all)
    }

    static func stroke(
        _ path: [CGPoint],
        width: CGFloat = 3,
        type: PKInk.InkType = .pen,
        transform: CGAffineTransform = .identity,
        mask: UIBezierPath? = nil
    ) -> PKStroke {
        let points = path.enumerated().map { i, location in
            PKStrokePoint(location: location, timeOffset: Double(i) * 0.01, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(type, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()), transform: transform, mask: mask)
    }

    /// Control points every `spacing` along each leg, with `cusps` copies of
    /// every interior vertex. PencilKit interpolates through the control
    /// points, so a repeated point is what makes a corner sharp rather than
    /// rounded; a hand-drawn scratch-out corner is a cusp, a letter's is not.
    static func polyline(_ vertices: [CGPoint], spacing: CGFloat = 3, cusps: Int = 3) -> [CGPoint] {
        var points = [vertices[0]]
        for (i, pair) in zip(vertices, vertices.dropFirst()).enumerated() {
            let (a, b) = pair
            let steps = max(Int(hypot(b.x - a.x, b.y - a.y) / spacing), 1)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
            if i + 2 < vertices.count { points += Array(repeating: b, count: cusps - 1) }
        }
        return points
    }

    /// A scratch-out over `rect`: `turns` sharp reversals across its width,
    /// descending its height.
    static func zigzag(over rect: CGRect, turns: Int) -> PKStroke {
        // A corner at every vertex but the two ends, so `turns` of them needs
        // two more points than turns.
        let count = turns + 2
        let step = rect.height / CGFloat(count - 1)
        let vertices = (0..<count).map { i in
            CGPoint(x: i.isMultiple(of: 2) ? rect.minX : rect.maxX, y: rect.minY + CGFloat(i) * step)
        }
        return stroke(polyline(vertices), width: 2)
    }

    static func line(from: CGPoint, to: CGPoint, width: CGFloat = 3, type: PKInk.InkType = .pen, transform: CGAffineTransform = .identity, mask: UIBezierPath? = nil) -> PKStroke {
        stroke(polyline([from, to]), width: width, type: type, transform: transform, mask: mask)
    }

    /// `count` turns of a widening ring around `rect`, drawn as a hand draws
    /// one: no corner anywhere, unless `spikes` asks for some. A spike is an
    /// inward flick and straight back out, the cusp a scratch-out has and a
    /// ring does not, so a stroke can read as both shapes at once and the
    /// order the notebook tries them in is what decides it.
    static func loops(around rect: CGRect, count: Int, spikes: Int = 0, depth: CGFloat = 14) -> PKStroke {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = hypot(rect.width, rect.height) / 2 + 10
        let sweep = CGFloat(count) * 2 * .pi
        let steps = max(Int(sweep * radius / 3), 8)
        let every = spikes > 0 ? max(steps / (spikes + 1), 1) : 0
        var points: [CGPoint] = []
        for step in 0...steps {
            let angle = sweep * CGFloat(step) / CGFloat(steps)
            let r = radius + angle
            let point = CGPoint(x: centre.x + r * cos(angle), y: centre.y + r * sin(angle))
            points.append(point)
            guard every > 0, step > 0, step < steps, step.isMultiple(of: every) else { continue }
            let inner = CGPoint(x: centre.x + (r - depth) * cos(angle), y: centre.y + (r - depth) * sin(angle))
            points += polyline([point, inner]).dropFirst()
            points += Array(repeating: inner, count: 2)
            points += polyline([inner, point]).dropFirst()
        }
        return stroke(points, width: 2)
    }

    /// A "w": a cusp at each bottom and a rounded middle apex, the way a hand
    /// writes one. Two sharp turns, not three.
    static func w(in rect: CGRect) -> PKStroke {
        let quarter = rect.width / 4
        let bottomLeft = CGPoint(x: rect.minX + quarter, y: rect.maxY)
        let bottomRight = CGPoint(x: rect.maxX - quarter, y: rect.maxY)
        let apex = CGPoint(x: rect.midX, y: rect.minY)
        let radius = rect.width / 8
        let apexLeft = CGPoint(x: apex.x - radius / 2, y: apex.y + radius)
        let apexRight = CGPoint(x: apex.x + radius / 2, y: apex.y + radius)
        var points = polyline([CGPoint(x: rect.minX, y: rect.minY), bottomLeft])
        points += Array(repeating: bottomLeft, count: 2)
        points += polyline([bottomLeft, apexLeft]).dropFirst()
        let cap = 10
        points += (1...cap).map { step -> CGPoint in
            let t = CGFloat(step) / CGFloat(cap + 1)
            let u = 1 - t
            return CGPoint(
                x: u * u * apexLeft.x + 2 * u * t * apex.x + t * t * apexRight.x,
                y: u * u * apexLeft.y + 2 * u * t * apex.y + t * t * apexRight.y
            )
        }
        points += polyline([apexRight, bottomRight])
        points += Array(repeating: bottomRight, count: 2)
        points += polyline([bottomRight, CGPoint(x: rect.maxX, y: rect.minY)]).dropFirst()
        return stroke(points, width: 2)
    }
}

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

/// A new notebook whose first page is loaded and ready.
@MainActor
func readyPage(_ name: String) async throws -> (Scratch, Notebook, PageID) {
    let scratch = try Scratch(name)
    let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
    let page = notebook.pageIDs[0]
    notebook.windowChanged(to: [page])
    try await waitUntil { notebook.state(of: page)?.content != nil }
    return (scratch, notebook, page)
}

/// One row per layer edit the notebook offers: a new edit is a new case.
enum LayerEdit: String, CaseIterable, Sendable {
    case insert, transform, lock, delete, moveLink, moveText, commitText, emptyText
}

extension Notebook {
    /// Waits until `count` calls have reached the gate.
    func waitForArrivals(_ gate: some Arrivals, _ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await gate.arrivals < count {
            try #require(ContinuousClock.now < deadline, "timed out waiting for \(count) calls")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
