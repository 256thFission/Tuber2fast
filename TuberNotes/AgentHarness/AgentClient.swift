import Foundation

/// Boundary for the AI agent shipped inside TuberNotes. Development agents and MCPs do not conform to this.
protocol AgentClient: Sendable {
    func investigate(_ request: InvestigationRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(investigationID: UUID) async
}

/// Deterministic product-runtime recordings used to exercise lifecycle behavior offline.
enum RecordedAgentScenario: Sendable {
    case success
    case retrieval
    case failure(AgentFailure)
    case invalidCoordinates
}

/// Offline adapter for deterministic agent scenarios. Events use the same paced, cancellable
/// stream boundary as a live provider without requiring credentials or network access.
struct RecordedAgentClient: AgentClient {
    private let scenario: RecordedAgentScenario
    private let eventDelay: Duration
    private let registry: RecordedInvestigationRegistry

    init(
        scenario: RecordedAgentScenario = .success,
        eventDelay: Duration = .milliseconds(60)
    ) {
        self.scenario = scenario
        self.eventDelay = eventDelay
        registry = RecordedInvestigationRegistry()
    }

    func investigate(_ request: InvestigationRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let events = Self.events(
            for: scenario,
            conversationID: request.conversationID
        )
        let registry = registry
        let eventDelay = eventDelay
        let streamToken = UUID()

        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                Task {
                    await registry.terminate(
                        investigationID: request.id,
                        streamToken: streamToken
                    )
                }
            }

            Task {
                guard await registry.register(
                    investigationID: request.id,
                    streamToken: streamToken,
                    continuation: continuation
                ) else { return }

                for event in events {
                    do {
                        try await Task.sleep(for: eventDelay)
                    } catch {
                        await registry.cancel(investigationID: request.id)
                        return
                    }

                    guard await registry.emit(
                        event,
                        investigationID: request.id,
                        streamToken: streamToken
                    ) else { return }
                }

                await registry.finish(
                    investigationID: request.id,
                    streamToken: streamToken
                )
            }
        }
    }

    func cancel(investigationID: UUID) async {
        await registry.cancel(investigationID: investigationID)
    }

    private static func events(
        for scenario: RecordedAgentScenario,
        conversationID: String?
    ) -> [AgentEvent] {
        if let conversationID {
            let followUpEvents: [AgentEvent]
            if case .success = scenario, conversationID == heroConversationID {
                followUpEvents = heroFollowUpEvents
            } else {
                followUpEvents = [
                    .accepted,
                    .failed(unknownConversationFailure)
                ]
            }
            return validated(followUpEvents)
        }

        let recordedEvents: [AgentEvent] = switch scenario {
        case .success:
            successEvents
        case .retrieval:
            retrievalEvents
        case let .failure(failure):
            [
                .accepted,
                .inspectingSelection,
                .failed(failure)
            ]
        case .invalidCoordinates:
            [
                .accepted,
                .inspectingSelection,
                .toolStarted(placePinsTool),
                .pinStarted(invalidCoordinatePin),
                .pinCompleted(invalidCoordinatePin),
                .toolFinished(placePinsTool),
                .completed(conversationID: "recorded-invalid-coordinate")
            ]
        }
        return validated(recordedEvents)
    }

    /// Recorded provider output still passes through the product boundary's spatial validation.
    /// The first invalid Pin ends the stream and no invalid draft is exposed to consumers.
    private static func validated(_ events: [AgentEvent]) -> [AgentEvent] {
        var safeEvents: [AgentEvent] = []
        for event in events {
            switch event {
            case let .pinStarted(draft), let .pinCompleted(draft):
                guard draft.target.isFiniteAndInUnitBounds,
                      draft.targetRegion?.isFiniteAndInUnitBounds != false else {
                    safeEvents.append(.failed(invalidCoordinateFailure))
                    return safeEvents
                }
            default:
                break
            }
            safeEvents.append(event)
        }
        return safeEvents
    }

    private static let successEvents: [AgentEvent] = [
        .accepted,
        .inspectingSelection,
        .toolStarted(placePinsTool),
        .pinStarted(proposedPin),
        .pinDelta(id: pinID, bodyDelta: completedBody),
        .pinCompleted(completedPin),
        .toolFinished(placePinsTool),
        .completed(conversationID: heroConversationID)
    ]

    private static let heroFollowUpEvents: [AgentEvent] = [
        .accepted,
        .inspectingSelection,
        .pinStarted(followUpPin),
        .pinDelta(id: followUpPinID, bodyDelta: followUpBodyFirstDelta),
        .pinDelta(id: followUpPinID, bodyDelta: followUpBodySecondDelta),
        .pinCompleted(completedFollowUpPin),
        .completed(conversationID: heroConversationID)
    ]

    private static let retrievalEvents: [AgentEvent] = [
        .accepted,
        .inspectingSelection,
        .toolStarted(searchTextbookTool),
        .toolFinished(searchTextbookTool),
        .toolStarted(placePinsTool),
        .pinStarted(retrievalPin),
        .pinCompleted(retrievalPin),
        .toolFinished(placePinsTool),
        .completed(conversationID: "recorded-retrieval")
    ]

    private static let pinID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    private static let followUpPinID = UUID(uuidString: "70000000-0000-0000-0000-000000000006")!
    private static let retrievalPinID = UUID(uuidString: "70000000-0000-0000-0000-000000000003")!
    private static let placePinsToolID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
    private static let searchTextbookToolID = UUID(uuidString: "70000000-0000-0000-0000-000000000004")!
    private static let citationID = UUID(uuidString: "82000000-0000-0000-0000-000000000001")!
    private static let heroConversationID = "recorded-hero"
    private static let completedBody = "The sign changes when the negative term moves across the equals sign."
    private static let followUpBodyFirstDelta = "It does not change merely because the term moves. "
    private static let followUpBodySecondDelta = "Adding 7 to both sides cancels -7 on the left, leaving +7 on the right."

    private static let proposedPin = PinDraft(
        id: pinID,
        target: CropNormalizedPoint(x: 0.58, y: 0.46),
        targetRegion: nil,
        kind: .issue,
        teaser: "Check this sign",
        body: "",
        citations: []
    )

    private static var completedPin: PinDraft {
        var draft = proposedPin
        draft.body = completedBody
        return draft
    }

    private static let followUpPin = PinDraft(
        id: followUpPinID,
        target: CropNormalizedPoint(x: 0.64, y: 0.54),
        targetRegion: nil,
        kind: .explanation,
        teaser: "Why the sign changes",
        body: "",
        citations: []
    )

    private static var completedFollowUpPin: PinDraft {
        var draft = followUpPin
        draft.body = followUpBodyFirstDelta + followUpBodySecondDelta
        return draft
    }

    private static let retrievalPin = PinDraft(
        id: retrievalPinID,
        target: CropNormalizedPoint(x: 0.42, y: 0.51),
        targetRegion: nil,
        kind: .source,
        teaser: "Inverse operations",
        body: "Apply the same inverse operation to both sides of the equation.",
        citations: [
            Citation(
                id: citationID,
                title: "Algebra Essentials",
                pageNumber: 12,
                url: nil,
                excerpt: "Moving a term is shorthand for applying the inverse operation to both sides."
            )
        ]
    )

    private static let invalidCoordinatePin = PinDraft(
        id: UUID(uuidString: "70000000-0000-0000-0000-000000000005")!,
        target: CropNormalizedPoint(x: 1.2, y: 0.5),
        targetRegion: nil,
        kind: .uncertainty,
        teaser: "Invalid recorded location",
        body: "This draft must be rejected before reaching the UI.",
        citations: []
    )

    private static let placePinsTool = ToolInvocationSummary(
        id: placePinsToolID,
        tool: .placePins,
        userVisibleStatus: "Placing a proposed Pin…"
    )

    private static let searchTextbookTool = ToolInvocationSummary(
        id: searchTextbookToolID,
        tool: .searchTextbook,
        userVisibleStatus: "Searching the textbook…"
    )

    private static let invalidCoordinateFailure = AgentFailure(
        code: .invalidResponse,
        userMessage: "The recorded response contained an invalid Pin location.",
        recoverable: true
    )

    private static let unknownConversationFailure = AgentFailure(
        code: .invalidResponse,
        userMessage: "The recorded conversation could not be continued.",
        recoverable: true
    )
}

private actor RecordedInvestigationRegistry {
    typealias Continuation = AsyncThrowingStream<AgentEvent, Error>.Continuation

    private struct ActiveInvestigation {
        let streamToken: UUID
        let continuation: Continuation
    }

    private var active: [UUID: ActiveInvestigation] = [:]
    private var cancelledInvestigationIDs: Set<UUID> = []
    private var finishedInvestigationIDs: Set<UUID> = []
    private var registeredStreamTokens: Set<UUID> = []
    private var terminatedBeforeRegistration: Set<UUID> = []

    func register(
        investigationID: UUID,
        streamToken: UUID,
        continuation: Continuation
    ) -> Bool {
        if terminatedBeforeRegistration.remove(streamToken) != nil {
            continuation.finish()
            return false
        }

        if cancelledInvestigationIDs.contains(investigationID) {
            continuation.yield(.failed(Self.cancelledFailure))
            continuation.finish()
            return false
        }

        if finishedInvestigationIDs.contains(investigationID) {
            continuation.finish()
            return false
        }

        if let superseded = active.removeValue(forKey: investigationID) {
            superseded.continuation.yield(.failed(Self.cancelledFailure))
            superseded.continuation.finish()
        }

        active[investigationID] = ActiveInvestigation(
            streamToken: streamToken,
            continuation: continuation
        )
        registeredStreamTokens.insert(streamToken)
        return true
    }

    func emit(
        _ event: AgentEvent,
        investigationID: UUID,
        streamToken: UUID
    ) -> Bool {
        guard let investigation = active[investigationID],
              investigation.streamToken == streamToken else { return false }
        investigation.continuation.yield(event)
        return true
    }

    func finish(investigationID: UUID, streamToken: UUID) {
        guard let investigation = active[investigationID],
              investigation.streamToken == streamToken else { return }
        active.removeValue(forKey: investigationID)
        finishedInvestigationIDs.insert(investigationID)
        investigation.continuation.finish()
    }

    func cancel(investigationID: UUID) {
        guard !cancelledInvestigationIDs.contains(investigationID),
              !finishedInvestigationIDs.contains(investigationID) else { return }
        cancelledInvestigationIDs.insert(investigationID)
        guard let investigation = active.removeValue(forKey: investigationID) else {
            return
        }
        investigation.continuation.yield(.failed(Self.cancelledFailure))
        investigation.continuation.finish()
    }

    func terminate(investigationID: UUID, streamToken: UUID) {
        guard let investigation = active[investigationID] else {
            if !registeredStreamTokens.contains(streamToken) {
                terminatedBeforeRegistration.insert(streamToken)
            }
            return
        }
        guard investigation.streamToken == streamToken else { return }
        active.removeValue(forKey: investigationID)
        finishedInvestigationIDs.insert(investigationID)
    }

    private static let cancelledFailure = AgentFailure(
        code: .cancelled,
        userMessage: "Investigation cancelled.",
        recoverable: true
    )
}
