import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

private func recordedRequest(
    id: UUID = UUID(),
    intent: InvestigationIntent = .check,
    conversationID: String? = nil,
    selection: SelectionArtifact? = nil
) -> InvestigationRequest {
    let documentID = UUID(uuidString: "83000000-0000-0000-0000-000000000001")!
    let pageID = UUID(uuidString: "83000000-0000-0000-0000-000000000002")!
    let bounds = PageNormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
    return InvestigationRequest(
        id: id,
        intent: intent,
        selection: selection ?? SelectionArtifact(
            id: UUID(uuidString: "83000000-0000-0000-0000-000000000003")!,
            documentID: documentID,
            pageID: pageID,
            pageIndex: 0,
            lassoPath: [
                PageNormalizedPoint(x: 0.1, y: 0.2),
                PageNormalizedPoint(x: 0.6, y: 0.2),
                PageNormalizedPoint(x: 0.6, y: 0.6),
                PageNormalizedPoint(x: 0.1, y: 0.2)
            ],
            pageBounds: bounds,
            crop: SelectionCrop(
                imageData: Data([0x01]),
                mediaType: "image/png",
                pixelWidth: 500,
                pixelHeight: 400,
                pageBounds: bounds
            ),
            context: SelectionContext(
                documentTitle: "Fixture",
                sourceDocumentID: documentID,
                pageNumber: 1,
                nearbyText: "3x - 7 = 11"
            )
        ),
        conversationID: conversationID
    )
}

private func collect(
    _ client: RecordedAgentClient,
    request: InvestigationRequest = recordedRequest()
) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in client.investigate(request) {
        events.append(event)
    }
    return events
}

private func testRecordedSuccess() async throws {
    let client = RecordedAgentClient(eventDelay: .milliseconds(1))
    let events = try await collect(client)
    try check(events.count == 8, "recorded success should emit eight ordered events")
    try check(events.first == .accepted, "recorded success should begin with accepted")
    try check(events.last == .completed(conversationID: "recorded-hero"), "recorded success should complete")
}

private func testRecordedCancellation() async throws {
    let client = RecordedAgentClient(eventDelay: .milliseconds(20))
    let request = recordedRequest()
    var events: [AgentEvent] = []

    for try await event in client.investigate(request) {
        events.append(event)
        if event == .accepted {
            await client.cancel(investigationID: request.id)
            await client.cancel(investigationID: request.id)
        }
    }

    try check(events.count == 2, "cancellation should stop all late recorded events")
    try check(events.first == .accepted, "cancellation fixture should first be accepted")
    guard case let .failed(failure) = events.last else {
        throw CheckFailure.failed("cancellation should finish with a failure event")
    }
    try check(failure.code == .cancelled, "cancellation should use the cancelled failure code")
}

private func testRecordedConversationFollowUp() async throws {
    let client = RecordedAgentClient(eventDelay: .milliseconds(1))
    let checkRequest = recordedRequest()
    let checkEvents = try await collect(client, request: checkRequest)
    guard case let .completed(conversationID) = checkEvents.last,
          let conversationID else {
        throw CheckFailure.failed("hero Check should return a conversation ID")
    }

    let followUpRequest = recordedRequest(
        intent: .ask(question: "Why does the sign change?"),
        conversationID: conversationID,
        selection: checkRequest.selection
    )
    let events = try await collect(client, request: followUpRequest)

    try check(events.count == 7, "recorded follow-up should emit seven ordered events")
    try check(events[0] == .accepted, "recorded follow-up should begin with accepted")
    try check(events[1] == .inspectingSelection, "recorded follow-up should inspect the retained selection")

    guard case let .pinStarted(startedPin) = events[2] else {
        throw CheckFailure.failed("recorded follow-up should begin its threaded reply")
    }
    guard case let .pinDelta(firstDeltaID, firstDelta) = events[3],
          firstDeltaID == startedPin.id,
          !firstDelta.isEmpty else {
        throw CheckFailure.failed("recorded follow-up should stream its first reply delta in order")
    }
    guard case let .pinDelta(secondDeltaID, secondDelta) = events[4],
          secondDeltaID == startedPin.id,
          !secondDelta.isEmpty else {
        throw CheckFailure.failed("recorded follow-up should stream its second reply delta in order")
    }
    guard case let .pinCompleted(completedPin) = events[5],
          completedPin.id == startedPin.id,
          completedPin.body == firstDelta + secondDelta else {
        throw CheckFailure.failed("recorded follow-up should complete the streamed reply in order")
    }
    try check(
        events[6] == .completed(conversationID: conversationID),
        "recorded follow-up should preserve conversation ID continuity"
    )
    try check(
        followUpRequest.selection == checkRequest.selection,
        "recorded follow-up should reuse the hero Check selection"
    )
}

private func testRecordedConversationCancellation() async throws {
    let client = RecordedAgentClient(eventDelay: .milliseconds(20))
    let checkRequest = recordedRequest()
    let checkEvents = try await collect(client, request: checkRequest)
    guard case let .completed(conversationID) = checkEvents.last,
          let conversationID else {
        throw CheckFailure.failed("hero Check should return a conversation ID before cancellation test")
    }

    let followUpRequest = recordedRequest(
        intent: .ask(question: "Why does the sign change?"),
        conversationID: conversationID,
        selection: checkRequest.selection
    )
    var events: [AgentEvent] = []
    for try await event in client.investigate(followUpRequest) {
        events.append(event)
        if case .pinDelta = event {
            await client.cancel(investigationID: followUpRequest.id)
        }
    }

    try check(events.count == 5, "mid-turn cancellation should stop remaining follow-up events")
    try check(events[0] == .accepted, "cancelled follow-up should begin with accepted")
    try check(events[1] == .inspectingSelection, "cancelled follow-up should inspect the retained selection")
    guard case .pinStarted = events[2] else {
        throw CheckFailure.failed("cancelled follow-up should begin its threaded reply")
    }
    guard case .pinDelta = events[3] else {
        throw CheckFailure.failed("cancelled follow-up should emit one reply delta before cancellation")
    }
    guard case let .failed(failure) = events[4] else {
        throw CheckFailure.failed("cancelled follow-up should end with a failure event")
    }
    try check(failure.code == .cancelled, "mid-turn cancellation should use the cancelled failure code")
    try check(
        !events.contains { if case .pinCompleted = $0 { return true }; return false },
        "mid-turn cancellation must suppress reply completion"
    )
    try check(
        !events.contains { if case .completed = $0 { return true }; return false },
        "mid-turn cancellation must suppress conversation completion"
    )
}

private func testRecordedVariants() async throws {
    let retrieval = try await collect(
        RecordedAgentClient(scenario: .retrieval, eventDelay: .milliseconds(1))
    )
    try check(retrieval.contains { event in
        guard case let .toolStarted(tool) = event else { return false }
        return tool.tool == .searchTextbook
    }, "retrieval should expose a textbook tool phase")
    try check(retrieval.contains { event in
        guard case let .pinCompleted(pin) = event else { return false }
        return pin.citations.first?.pageNumber == 12
    }, "retrieval should complete a cited Pin")

    let expectedFailure = AgentFailure(
        code: .timedOut,
        userMessage: "Recorded timeout.",
        recoverable: true
    )
    let failure = try await collect(
        RecordedAgentClient(scenario: .failure(expectedFailure), eventDelay: .milliseconds(1))
    )
    try check(failure.last == .failed(expectedFailure), "failure fixture should preserve its typed failure")

    let invalid = try await collect(
        RecordedAgentClient(scenario: .invalidCoordinates, eventDelay: .milliseconds(1))
    )
    try check(!invalid.contains { event in
        if case .pinStarted = event { return true }
        if case .pinCompleted = event { return true }
        return false
    }, "invalid coordinates must never reach the Pin event boundary")
    guard case let .failed(invalidFailure) = invalid.last else {
        throw CheckFailure.failed("invalid coordinates should finish with a failure event")
    }
    try check(invalidFailure.code == .invalidResponse, "invalid coordinates should be rejected")
}

private func testOfflineKnowledgeSearch() async throws {
    let searcher = OfflineTextbookKnowledgeSearcher()
    let knownHits = try await searcher.searchTextbook(
        KnowledgeQuery(documentID: nil, text: "inverse operation both sides", limit: 5)
    )
    try check(knownHits.first?.documentTitle == "Algebra Essentials", "known query should find algebra")
    try check(knownHits.first?.pageNumber == 12, "known query should return the expected page")

    let filteredMiss = try await searcher.searchTextbook(
        KnowledgeQuery(
            documentID: OfflineTextbookKnowledgeSearcher.physicsDocumentID,
            text: "inverse operation",
            limit: 5
        )
    )
    try check(filteredMiss.isEmpty, "document filtering should exclude other textbooks")

    let limited = try await searcher.searchTextbook(
        KnowledgeQuery(documentID: nil, text: "term", limit: 1)
    )
    try check(limited.count == 1, "result limits should be honored")

    let empty = try await searcher.searchTextbook(
        KnowledgeQuery(documentID: nil, text: "  --  ", limit: 5)
    )
    try check(empty.isEmpty, "empty normalized queries should return no results")
}

private func testCorpusFailures() throws {
    do {
        _ = try OfflineTextbookKnowledgeSearcher(corpusData: nil)
        throw CheckFailure.failed("missing corpus should throw")
    } catch OfflineKnowledgeCorpusError.missingCorpus {
        // Expected.
    }

    do {
        _ = try OfflineTextbookKnowledgeSearcher(corpusData: Data("not-json".utf8))
        throw CheckFailure.failed("malformed corpus should throw")
    } catch OfflineKnowledgeCorpusError.malformedCorpus {
        // Expected.
    }

    // A present but empty imported corpus is valid and must resolve to zero hits.
    _ = try OfflineTextbookKnowledgeSearcher(corpusData: Data("[]".utf8))
}

@main
private struct AgentKnowledgeChecks {
    static func main() async throws {
        try await testRecordedSuccess()
        try await testRecordedCancellation()
        try await testRecordedConversationFollowUp()
        try await testRecordedConversationCancellation()
        try await testRecordedVariants()
        try await testOfflineKnowledgeSearch()
        try testCorpusFailures()
        print("AGENT_KNOWLEDGE_CHECKS: PASS")
    }
}
