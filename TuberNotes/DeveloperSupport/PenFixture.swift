import Foundation
import PencilKit

// MARK: - Fixture

struct PenFixture: Codable, Equatable {
    let name: String
    let description: String
    let events: [Event]
    var requestID: String?
    var recordedAt: Date?

    struct Event: Codable, Equatable {
        enum Phase: String, Codable { case began, moved, ended }
        let x: CGFloat
        let y: CGFloat
        let time: TimeInterval
        let phase: Phase
        let pressure: CGFloat?
        let altitude: CGFloat?
        let azimuth: CGFloat?
    }

    func makeDrawing(in size: CGSize) -> PKDrawing {
        let grouped = events.splitAfter { $0.phase == .ended }
        let strokes = grouped.compactMap { events -> PKStroke? in
            guard events.count > 1 else { return nil }
            let points = events.map {
                PKStrokePoint(
                    location: CGPoint(x: $0.x * size.width, y: $0.y * size.height),
                    timeOffset: $0.time,
                    size: CGSize(width: 3, height: 3),
                    opacity: 1,
                    force: $0.pressure ?? 1,
                    azimuth: $0.azimuth ?? 0,
                    altitude: $0.altitude ?? .pi / 2
                )
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        return PKDrawing(strokes: strokes)
    }
}

// MARK: - Agent interaction request (DEBUG human-in-the-loop)

struct AgentInteractionRequest: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case penFixture = "pen-fixture", review = "review" }
    enum Status: String, Codable {
        case awaitingHuman = "awaiting-human"
        case recorded
        case answered
        case cancelled
    }

    enum Verdict: String, Codable {
        case looksGood = "looks-good"
        case needsWork = "needs-work"
        case blocked
    }

    struct Requester: Codable, Equatable {
        var id: String
    }

    struct Owner: Codable, Equatable {
        var tokenHash: String
        var tokenRequired: Bool
    }

    struct Delivery: Codable, Equatable {
        struct Target: Codable, Equatable {
            var kind: String
            var id: String
        }

        var sequence: Int?
        var state: String
        var target: Target
        var selectedAt: Date?
        var deliveredAt: Date?
        var launchAttempted: Bool?
    }

    var schemaVersion: Int?
    var id: String
    var kind: Kind
    var title: String
    /// Shown at the top of the Debug app. Human-facing instruction from the agent.
    var prompt: String
    var status: Status
    var createdAt: Date
    var completedAt: Date?
    var expiresAt: Date?
    var cancellationReason: String?
    var fixtureName: String?
    var fixturePath: String?
    var eventCount: Int?
    var verdict: Verdict?
    var humanNotes: String?
    var scenario: String?
    var screenshotHint: String?
    var requester: Requester?
    var owner: Owner?
    var delivery: Delivery?

    static func penFixture(id: String, prompt: String, fixtureName: String, scenario: String? = nil) -> Self {
        Self(
            schemaVersion: nil,
            id: id,
            kind: .penFixture,
            title: "Pencil capture",
            prompt: prompt,
            status: .awaitingHuman,
            createdAt: Date(),
            completedAt: nil,
            expiresAt: nil,
            cancellationReason: nil,
            fixtureName: fixtureName,
            fixturePath: nil,
            eventCount: nil,
            verdict: nil,
            humanNotes: nil,
            scenario: scenario,
            screenshotHint: nil,
            requester: nil,
            owner: nil,
            delivery: nil
        )
    }
}

struct AgentInteractionIndex: Codable, Equatable {
    var updatedAt: Date
    var entries: [Entry]

    struct Entry: Codable, Equatable, Identifiable {
        var id: String
        var kind: AgentInteractionRequest.Kind
        var status: AgentInteractionRequest.Status
        var title: String
        var prompt: String
        var fixtureName: String?
        var createdAt: Date
        var completedAt: Date?
        var verdict: AgentInteractionRequest.Verdict?
        var eventCount: Int?
        var requesterID: String?
        var deliveryTarget: AgentInteractionRequest.Delivery.Target?
        var humanNotes: String?
        var fixturePath: String?
        var cancellationReason: String?
    }

    static var empty: Self { Self(updatedAt: Date(), entries: []) }

    mutating func upsert(_ request: AgentInteractionRequest) {
        let entry = Entry(
            id: request.id,
            kind: request.kind,
            status: request.status,
            title: request.title,
            prompt: request.prompt,
            fixtureName: request.fixtureName,
            createdAt: request.createdAt,
            completedAt: request.completedAt,
            verdict: request.verdict,
            eventCount: request.eventCount,
            requesterID: request.requester?.id,
            deliveryTarget: request.delivery?.target,
            humanNotes: request.humanNotes,
            fixturePath: request.fixturePath,
            cancellationReason: request.cancellationReason
        )
        if let idx = entries.firstIndex(where: { $0.id == request.id }) {
            entries[idx] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        updatedAt = Date()
    }
}

// MARK: - Store

enum PenFixtureStore {
    static let fixturesDirectoryName = "pen-fixtures"
    static let requestsDirectoryName = "agent-requests"
    static let pendingDirectoryName = "pending"
    static let completedDirectoryName = "completed"
    static let indexFileName = "index.json"

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var fixturesDirectory: URL {
        ensureDirectory(documentsDirectory.appendingPathComponent(fixturesDirectoryName, isDirectory: true))
    }

    static var requestsRoot: URL {
        ensureDirectory(documentsDirectory.appendingPathComponent(requestsDirectoryName, isDirectory: true))
    }

    static var pendingRequestsDirectory: URL {
        ensureDirectory(requestsRoot.appendingPathComponent(pendingDirectoryName, isDirectory: true))
    }

    static var completedRequestsDirectory: URL {
        ensureDirectory(requestsRoot.appendingPathComponent(completedDirectoryName, isDirectory: true))
    }

    static var indexURL: URL {
        fixturesDirectory.appendingPathComponent(indexFileName)
    }

    static func loadRequestedFixture() -> PenFixture? {
        guard let name = ProcessInfo.processInfo.environment["TUBER_PEN_FIXTURE"] else { return nil }
        return loadFixture(named: name)
    }

    static func loadFixture(named name: String) -> PenFixture? {
        let url = fixturesDirectory.appendingPathComponent(name).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(PenFixture.self, from: data)
    }

    static func saveFixture(_ fixture: PenFixture) throws {
        let url = fixturesDirectory.appendingPathComponent(fixture.name).appendingPathExtension("json")
        try JSONEncoder.pretty.encode(fixture).write(to: url, options: .atomic)
    }

    static func deleteFixture(named name: String) throws {
        let url = fixturesDirectory.appendingPathComponent(name).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func loadIndex() -> AgentInteractionIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder.iso8601.decode(AgentInteractionIndex.self, from: data) else {
            return .empty
        }
        return index
    }

    static func saveIndex(_ index: AgentInteractionIndex) throws {
        try JSONEncoder.pretty.encode(index).write(to: indexURL, options: .atomic)
    }

    static func loadPendingRequests() -> [AgentInteractionRequest] {
        reconcileTerminalPendingRequests()
        return decodedPendingRequests()
            .filter { $0.status == .awaitingHuman }
            .sorted(by: fifoPrecedes)
    }

    private static func decodedPendingRequests() -> [AgentInteractionRequest] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: pendingRequestsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> AgentInteractionRequest? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.iso8601.decode(AgentInteractionRequest.self, from: data)
            }
    }

    private static func fifoPrecedes(_ lhs: AgentInteractionRequest, _ rhs: AgentInteractionRequest) -> Bool {
        switch (lhs.delivery?.sequence, rhs.delivery?.sequence) {
        case let (lhsSequence?, rhsSequence?) where lhsSequence != rhsSequence:
            return lhsSequence < rhsSequence
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    private static func reconcileTerminalPendingRequests(now: Date = Date()) {
        for request in decodedPendingRequests() {
            var terminal = request
            if terminal.status == .awaitingHuman,
               let expiresAt = terminal.expiresAt,
               expiresAt <= now {
                terminal.status = .cancelled
                terminal.cancellationReason = terminal.cancellationReason ?? "stale-expired"
                terminal.completedAt = terminal.completedAt ?? now
            }
            guard terminal.status == .cancelled else { continue }
            try? completeRequest(terminal)
        }
    }

    static func savePendingRequest(_ request: AgentInteractionRequest) throws {
        let url = pendingRequestsDirectory.appendingPathComponent(request.id).appendingPathExtension("json")
        try JSONEncoder.pretty.encode(request).write(to: url, options: .atomic)
        var index = loadIndex()
        index.upsert(request)
        try saveIndex(index)
    }

    static func completeRequest(_ request: AgentInteractionRequest) throws {
        var finished = request
        if finished.completedAt == nil { finished.completedAt = Date() }
        let completedURL = completedRequestsDirectory.appendingPathComponent(finished.id).appendingPathExtension("json")

        // A cancellation can race a Pencil stroke or verdict crossing the USB boundary.
        // Preserve the human's already-written result instead of replacing it with a
        // later cancellation copied into pending/.
        if finished.status == .cancelled,
           let existingData = try? Data(contentsOf: completedURL),
           let existing = try? JSONDecoder.iso8601.decode(AgentInteractionRequest.self, from: existingData),
           existing.status != .cancelled {
            let pendingURL = pendingRequestsDirectory.appendingPathComponent(finished.id).appendingPathExtension("json")
            try? FileManager.default.removeItem(at: pendingURL)
            var index = loadIndex()
            index.upsert(existing)
            try saveIndex(index)
            return
        }

        try JSONEncoder.pretty.encode(finished).write(to: completedURL, options: .atomic)
        let pendingURL = pendingRequestsDirectory.appendingPathComponent(finished.id).appendingPathExtension("json")
        try? FileManager.default.removeItem(at: pendingURL)
        var index = loadIndex()
        index.upsert(finished)
        try saveIndex(index)
    }

    /// Prefer on-disk pending request; fall back to legacy launch env vars.
    static func resolveActiveRequest() -> AgentInteractionRequest? {
#if DEBUG
        if let pending = loadPendingRequests().first {
            return pending
        }
        if let name = ProcessInfo.processInfo.environment["TUBER_RECORD_PEN_FIXTURE"] {
            guard !hasCompletedRequest(idOrFixtureName: name) else { return nil }
            let prompt = ProcessInfo.processInfo.environment["TUBER_PEN_DESCRIPTION"] ?? name
            let request = AgentInteractionRequest.penFixture(
                id: name,
                prompt: prompt,
                fixtureName: name,
                scenario: ProcessInfo.processInfo.environment["TUBER_SCENARIO"]
            )
            try? savePendingRequest(request)
            return request
        }
#endif
        return nil
    }

    private static func hasCompletedRequest(idOrFixtureName name: String) -> Bool {
        let exactURL = completedRequestsDirectory.appendingPathComponent(name).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: exactURL.path) { return true }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: completedRequestsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .contains { url in
                guard let data = try? Data(contentsOf: url),
                      let request = try? JSONDecoder.iso8601.decode(AgentInteractionRequest.self, from: data) else {
                    return false
                }
                return request.id == name || request.fixtureName == name
            }
    }

    private static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Recorder

enum PenFixtureRecorder {
    static func makeFixture(
        name: String,
        description: String,
        requestID: String?,
        drawing: PKDrawing,
        canvasSize: CGSize
    ) -> PenFixture? {
        guard canvasSize.width > 0, canvasSize.height > 0, let stroke = drawing.strokes.last else { return nil }
        let points = stride(from: CGFloat.zero, through: stroke.path.count > 1 ? CGFloat(stroke.path.count - 1) : 0, by: 1).map {
            stroke.path[Int($0)]
        }
        guard points.count > 1 else { return nil }
        let events = points.enumerated().map { index, point in
            PenFixture.Event(
                x: point.location.x / canvasSize.width,
                y: point.location.y / canvasSize.height,
                time: point.timeOffset,
                phase: index == 0 ? .began : (index == points.count - 1 ? .ended : .moved),
                pressure: point.force,
                altitude: point.altitude,
                azimuth: point.azimuth
            )
        }
        return PenFixture(
            name: name,
            description: description,
            events: events,
            requestID: requestID,
            recordedAt: Date()
        )
    }
}

private extension Array {
    func splitAfter(_ predicate: (Element) -> Bool) -> [[Element]] {
        var result: [[Element]] = []
        var current: [Element] = []
        for element in self {
            current.append(element)
            if predicate(element) { result.append(current); current = [] }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
