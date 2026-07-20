import Foundation

public enum RecordedAgentScenario: Sendable {
    case success
    case retrieval
    case failure(AgentFailure)
    case invalidCoordinates
}

/// Deterministic, credential-free client used by tests, previews, and reliable demos.
public struct RecordedAgentClient: AgentClient {
    private let scenario: RecordedAgentScenario
    private let eventDelay: Duration
    private let registry = RecordedInvestigationRegistry()

    public init(
        scenario: RecordedAgentScenario = .success,
        eventDelay: Duration = .milliseconds(60)
    ) {
        self.scenario = scenario
        self.eventDelay = eventDelay
    }

    public func investigate(_ request: InvestigationRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let events = Self.events(for: scenario, conversationID: request.conversationID)
        let token = UUID()
        let registry = registry
        let delay = eventDelay

        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                Task { await registry.terminate(id: request.id, token: token) }
            }
            Task {
                guard await registry.register(id: request.id, token: token, continuation: continuation) else {
                    return
                }
                for event in events {
                    do { try await Task.sleep(for: delay) } catch {
                        await registry.cancel(id: request.id)
                        return
                    }
                    guard await registry.emit(event, id: request.id, token: token) else { return }
                }
                await registry.finish(id: request.id, token: token)
            }
        }
    }

    public func cancel(investigationID: UUID) async {
        await registry.cancel(id: investigationID)
    }

    private static func events(
        for scenario: RecordedAgentScenario,
        conversationID: String?
    ) -> [AgentEvent] {
        if let conversationID {
            guard case .success = scenario, conversationID == heroConversationID else {
                return [.accepted, .failed(unknownConversationFailure)]
            }
            return heroFollowUpEvents
        }
        let events: [AgentEvent] = switch scenario {
        case .success: successEvents
        case .retrieval: retrievalEvents
        case let .failure(failure): [.accepted, .inspectingSelection, .failed(failure)]
        case .invalidCoordinates:
            [.accepted, .inspectingSelection, .pinStarted(invalidPin), .pinCompleted(invalidPin)]
        }
        return validate(events)
    }

    private static func validate(_ events: [AgentEvent]) -> [AgentEvent] {
        var safe: [AgentEvent] = []
        for event in events {
            switch event {
            case let .pinStarted(draft), let .pinCompleted(draft):
                guard draft.target.isValid, draft.targetRegion?.isValid != false else {
                    return safe + [.failed(invalidCoordinateFailure)]
                }
            default: break
            }
            safe.append(event)
        }
        return safe
    }

    private static let pinID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    private static let followUpMessageID = UUID(uuidString: "70000000-0000-0000-0000-000000000006")!
    private static let retrievalPinID = UUID(uuidString: "70000000-0000-0000-0000-000000000003")!
    private static let heroConversationID = "recorded-hero"
    private static let completedBody = "The sign changes when the negative term moves across the equals sign."
    private static let followUpBody = "It does not change merely because the term moves. Adding 7 to both sides cancels -7 on the left, leaving +7 on the right."

    private static let basePin = PinDraft(
        id: pinID,
        target: CropPoint(x: 0.58, y: 0.46),
        kind: .issue,
        teaser: "Check this sign",
        body: ""
    )

    private static var completedPin: PinDraft {
        var pin = basePin
        pin.body = completedBody
        return pin
    }

    private static let retrievalPin = PinDraft(
        id: retrievalPinID,
        target: CropPoint(x: 0.42, y: 0.51),
        kind: .source,
        teaser: "Inverse operations",
        body: "Apply the same inverse operation to both sides of the equation.",
        citations: [Citation(
            id: UUID(uuidString: "82000000-0000-0000-0000-000000000001")!,
            title: "Algebra Essentials",
            pageNumber: 12,
            excerpt: "Moving a term is shorthand for applying the inverse operation to both sides."
        )]
    )

    private static let invalidPin = PinDraft(
        target: CropPoint(x: 1.2, y: 0.5),
        kind: .uncertainty,
        teaser: "Invalid location",
        body: "This draft must be rejected."
    )

    private static let placePins = ToolInvocationSummary(
        id: UUID(uuidString: "70000000-0000-0000-0000-000000000002")!,
        tool: .placePins,
        userVisibleStatus: "Placing a proposed Pin…"
    )
    private static let searchTextbook = ToolInvocationSummary(
        id: UUID(uuidString: "70000000-0000-0000-0000-000000000004")!,
        tool: .searchTextbook,
        userVisibleStatus: "Searching the textbook…"
    )

    private static let successEvents: [AgentEvent] = [
        .accepted, .inspectingSelection, .toolStarted(placePins), .pinStarted(basePin),
        .pinDelta(id: pinID, bodyDelta: completedBody), .pinCompleted(completedPin),
        .toolFinished(placePins), .completed(conversationID: heroConversationID)
    ]
    private static let heroFollowUpEvents: [AgentEvent] = [
        .accepted, .inspectingSelection, .messageStarted(id: followUpMessageID),
        .messageDelta(id: followUpMessageID, textDelta: "It does not change merely because the term moves. "),
        .messageDelta(id: followUpMessageID, textDelta: "Adding 7 to both sides cancels -7 on the left, leaving +7 on the right."),
        .messageCompleted(id: followUpMessageID, text: followUpBody),
        .completed(conversationID: heroConversationID)
    ]
    private static let retrievalEvents: [AgentEvent] = [
        .accepted, .inspectingSelection, .toolStarted(searchTextbook), .toolFinished(searchTextbook),
        .toolStarted(placePins), .pinStarted(retrievalPin), .pinCompleted(retrievalPin),
        .toolFinished(placePins), .completed(conversationID: "recorded-retrieval")
    ]
    private static let invalidCoordinateFailure = AgentFailure(
        code: .invalidResponse,
        userMessage: "The agent returned an invalid Pin location.",
        recoverable: true
    )
    private static let unknownConversationFailure = AgentFailure(
        code: .invalidResponse,
        userMessage: "The conversation could not be continued.",
        recoverable: true
    )
}

private actor RecordedInvestigationRegistry {
    typealias Continuation = AsyncThrowingStream<AgentEvent, Error>.Continuation
    private struct Active { let token: UUID; let continuation: Continuation }
    private var active: [UUID: Active] = [:]
    private var cancelled: Set<UUID> = []
    private var terminatedBeforeRegistration: Set<UUID> = []

    func register(id: UUID, token: UUID, continuation: Continuation) -> Bool {
        if terminatedBeforeRegistration.remove(token) != nil { continuation.finish(); return false }
        if cancelled.contains(id) { continuation.finish(); return false }
        active.removeValue(forKey: id)?.continuation.finish()
        active[id] = Active(token: token, continuation: continuation)
        return true
    }

    func emit(_ event: AgentEvent, id: UUID, token: UUID) -> Bool {
        guard let current = active[id], current.token == token else { return false }
        current.continuation.yield(event)
        return true
    }

    func finish(id: UUID, token: UUID) {
        guard let current = active[id], current.token == token else { return }
        active[id] = nil
        current.continuation.finish()
    }

    func cancel(id: UUID) {
        cancelled.insert(id)
        guard let current = active.removeValue(forKey: id) else { return }
        current.continuation.yield(.failed(AgentFailure(
            code: .cancelled,
            userMessage: "Investigation cancelled.",
            recoverable: true
        )))
        current.continuation.finish()
    }

    func terminate(id: UUID, token: UUID) {
        guard let current = active[id] else {
            terminatedBeforeRegistration.insert(token)
            return
        }
        guard current.token == token else { return }
        active[id] = nil
    }
}

// MARK: - Live Responses client

public struct LiveAgentConfiguration: Sendable {
    public let endpoint: URL
    public let bearerToken: String
    public let model: String
    public let additionalHeaders: [String: String]

    public init(
        endpoint: URL,
        bearerToken: String,
        model: String,
        additionalHeaders: [String: String] = [:]
    ) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.model = model
        self.additionalHeaders = additionalHeaders
    }
}

/// Opt-in live client. Credentials are injected by the host and are never persisted by the kit.
public final class LiveAgentClient: AgentClient, @unchecked Sendable {
    private let configuration: LiveAgentConfiguration
    private let session: URLSession
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(configuration: LiveAgentConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func investigate(_ request: InvestigationRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.accepted)
            continuation.yield(.inspectingSelection)
            let task = Task { [weak self] in
                guard let self else { return }
                defer { self.removeTask(request.id) }
                do {
                    let response = try await self.perform(request)
                    for event in response { continuation.yield(event) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(.init(code: .cancelled, userMessage: "Investigation cancelled.", recoverable: true)))
                    continuation.finish()
                } catch let failure as AgentFailure {
                    continuation.yield(.failed(failure))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(.init(code: .invalidResponse, userMessage: "The live agent returned an unusable response.", recoverable: true)))
                    continuation.finish()
                }
            }
            lock.withLock { tasks[request.id] = task }
            continuation.onTermination = { [weak self] _ in self?.cancelTask(request.id) }
        }
    }

    public func cancel(investigationID: UUID) async { cancelTask(investigationID) }

    private func perform(_ investigation: InvestigationRequest) async throws -> [AgentEvent] {
        guard investigation.conversationID == nil else {
            throw AgentFailure(code: .invalidResponse, userMessage: "This live provider does not expose conversation continuation.", recoverable: true)
        }
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        configuration.additionalHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body(for: investigation))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentFailure(code: .unavailable, userMessage: "The live agent is unavailable.", recoverable: true)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let code: AgentFailure.Code = [401, 403].contains(http.statusCode) ? .unauthorized : .unavailable
            throw AgentFailure(code: code, userMessage: "The live agent request failed.", recoverable: true)
        }
        return try LiveResponseDecoder.events(from: data)
    }

    private func body(for request: InvestigationRequest) -> [String: Any] {
        let crop = request.selection.crop
        let image = "data:\(crop.mediaType);base64,\(crop.imageData.base64EncodedString())"
        let intent: String = switch request.intent {
        case .explain: "Explain the selected work."
        case .check: "Check the selected work."
        case let .ask(question): question
        }
        return [
            "model": configuration.model,
            "stream": false,
            "store": false,
            "input": [["role": "user", "content": [
                ["type": "input_text", "text": "\(intent) Return crop-normalized Pins."],
                ["type": "input_image", "image_url": image]
            ]]],
            "tool_choice": ["type": "function", "name": "place_pins"],
            "tools": [[
                "type": "function", "name": "place_pins", "strict": true,
                "description": "Place concise Pins over the selection.",
                "parameters": [
                    "type": "object", "additionalProperties": false, "required": ["pins"],
                    "properties": ["pins": [
                        "type": "array", "minItems": 1, "maxItems": 8,
                        "items": [
                            "type": "object", "additionalProperties": false,
                            "required": ["x", "y", "kind", "teaser", "body"],
                            "properties": [
                                "x": ["type": "number", "minimum": 0, "maximum": 1],
                                "y": ["type": "number", "minimum": 0, "maximum": 1],
                                "kind": ["type": "string", "enum": AnnotationKind.allRawValues],
                                "teaser": ["type": "string"], "body": ["type": "string"]
                            ]
                        ]
                    ]]
                ]
            ]]
        ]
    }

    private func cancelTask(_ id: UUID) {
        lock.withLock { tasks.removeValue(forKey: id) }?.cancel()
    }

    private func removeTask(_ id: UUID) {
        lock.withLock { tasks[id] = nil }
    }
}

private extension AnnotationKind {
    static let allRawValues = ["confirmation", "issue", "explanation", "source", "uncertainty", "suggestion"]
}

private enum LiveResponseDecoder {
    static func events(from data: Data) throws -> [AgentEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]],
              let call = output.first(where: { $0["type"] as? String == "function_call" }),
              call["name"] as? String == "place_pins",
              let arguments = call["arguments"] as? String,
              let argumentData = arguments.data(using: .utf8) else {
            throw AgentFailure(code: .invalidResponse, userMessage: "The live agent omitted Pins.", recoverable: true)
        }
        let decoded = try JSONDecoder().decode(PlacePinsArguments.self, from: argumentData)
        guard (1 ... 8).contains(decoded.pins.count) else {
            throw AgentFailure(code: .invalidResponse, userMessage: "The live agent returned an invalid Pin count.", recoverable: true)
        }
        let tool = ToolInvocationSummary(tool: .placePins, userVisibleStatus: "Placing proposed Pins…")
        var events: [AgentEvent] = [.toolStarted(tool)]
        for value in decoded.pins {
            guard let kind = AnnotationKind(rawValue: value.kind) else {
                throw AgentFailure(code: .invalidResponse, userMessage: "The live agent returned an invalid Pin.", recoverable: true)
            }
            let draft = PinDraft(
                target: CropPoint(x: value.x, y: value.y),
                kind: kind,
                teaser: value.teaser,
                body: value.body
            )
            guard draft.target.isValid, !draft.teaser.isEmpty, !draft.body.isEmpty else {
                throw AgentFailure(code: .invalidResponse, userMessage: "The live agent returned an invalid Pin.", recoverable: true)
            }
            events += [.pinStarted(draft), .pinCompleted(draft)]
        }
        return events + [.toolFinished(tool), .completed(conversationID: root["id"] as? String)]
    }

    private struct PlacePinsArguments: Decodable {
        let pins: [Value]
        struct Value: Decodable { let x: Double; let y: Double; let kind: String; let teaser: String; let body: String }
    }
}
