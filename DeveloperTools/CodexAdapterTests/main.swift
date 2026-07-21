import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private func expectThrows(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError(message) } catch { }
}

private func expectThrows(_ message: String, _ operation: () async throws -> Void) async {
    do { try await operation(); fatalError(message) } catch { }
}

private func fixtureRequest() -> InvestigationRequest {
    let bounds = PageNormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
    return InvestigationRequest(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, intent: .check,
        selection: SelectionArtifact(
            id: UUID(), documentID: UUID(), pageID: UUID(), pageIndex: 0,
            lassoPath: [], pageBounds: bounds,
            crop: SelectionCrop(imageData: Data([1, 2, 3]), mediaType: "image/png", pixelWidth: 1, pixelHeight: 1, pageBounds: bounds),
            context: SelectionContext(documentTitle: nil, sourceDocumentID: nil, pageNumber: 1, nearbyText: "x = 6")
        ), conversationID: nil
    )
}

private let validArguments = #"{"pins":[{"x":0.25,"y":0.75,"kind":"issue","teaser":"Check","body":"Fix this."}]}"#

private func functionCall(arguments: String = validArguments) -> [String: Any] {
    [
        "type": "function_call", "id": "fc_1", "call_id": "call_1",
        "name": "place_pins", "arguments": arguments, "status": "completed"
    ]
}

private func canonicalPayloads(arguments: String = validArguments) -> [[String: Any]] {
    [
        ["type": "response.created"],
        [
            "type": "response.output_item.added", "output_index": 0,
            "item": ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "place_pins", "arguments": ""]
        ],
        ["type": "response.function_call_arguments.delta", "item_id": "fc_1", "output_index": 0, "delta": arguments],
        ["type": "response.function_call_arguments.done", "item_id": "fc_1", "output_index": 0, "arguments": arguments],
        [
            "type": "response.output_item.done", "output_index": 0,
            "item": functionCall(arguments: arguments)
        ],
        ["type": "response.completed", "response": ["id": "resp_1", "status": "completed", "output": [functionCall(arguments: arguments)]]]
    ]
}

private func decode(_ bytes: [UInt8]) throws -> [ResponsesSSEDecoder.Record] {
    var decoder = ResponsesSSEDecoder()
    var records: [ResponsesSSEDecoder.Record] = []
    for byte in bytes { records += try decoder.feed(byte) }
    try decoder.finish()
    return records
}

@main
private enum CodexAdapterChecks {
    static func main() async throws {
        try checkModelAndRequest()
        try checkCanonicalToolCall()
        try checkAdversarialToolCalls()
        try checkSSEFraming()
        try checkSSEBounds()
        try checkResponsesTextExtraction()
        try await checkMissingConfigurationFailure()
        try await checkIncrementalTransport()
        try await checkTransportCancellation()
        try await checkHTTPFailures()
        print("CODEX_ADAPTER_CHECKS: PASS")
    }

    private static func checkModelAndRequest() throws {
        let environment = ["TUBER_AGENT_MODE": "codex", "TUBER_CODEX_ACCESS_TOKEN": "synthetic-token"]
        let fromEnvironment = DebugCodexConfiguration.processEnvironment(environment)
        require(DebugCodexConfiguration.defaultModel == "gpt-5.6-terra", "wrong exposed default")
        require(fromEnvironment?.model == "gpt-5.6-terra", "environment did not use Terra")
        require(DebugCodexConfiguration.processEnvironment(environment.merging(["TUBER_CODEX_MODEL": "  "]) { _, new in new })?.model == "gpt-5.6-terra", "empty model override was accepted")

        let config = DebugCodexConfiguration(accessToken: "synthetic-token", accountID: "synthetic-account", model: DebugCodexConfiguration.defaultModel)
        let request = try DebugCodexTransport(configuration: config).request(for: fixtureRequest())
        require(request.url == DebugCodexTransport.endpoint, "wrong endpoint")
        require(request.httpMethod == "POST", "wrong method")
        require(request.value(forHTTPHeaderField: "Authorization") == "Bear" + "er synthetic-token", "missing bearer")
        require(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "synthetic-account", "missing account")
        require(request.cachePolicy == .reloadIgnoringLocalCacheData, "request may use local cache")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        require(body["model"] as? String == "gpt-5.6-terra", "wrong wire model")
        require(body["store"] as? Bool == false, "store must be false")
        require(body["stream"] as? Bool == true, "stream must be true")
        require(body["parallel_tool_calls"] as? Bool == false, "parallel calls must be disabled")
        let toolChoice = body["tool_choice"] as! [String: Any]
        require(toolChoice["name"] as? String == "place_pins", "place_pins not forced")
        let tools = body["tools"] as! [[String: Any]]
        require(tools.count == 1 && tools[0]["strict"] as? Bool == true, "tool must be singular and strict")

        require(AgentProvider.openAI.defaultModel == "gpt-4o-mini", "wrong OpenAI default")
        require(AgentProvider.rightCode.defaultModel == "gpt-5.5", "wrong gateway default")
        require(AgentProvider.openAI.route(for: .insight).wireAPI == .chatCompletions, "wrong OpenAI insight wire API")
        require(AgentProvider.rightCode.route(for: .insight).wireAPI == .responses, "wrong gateway insight wire API")
        require(AgentProviderAccess(provider: .rightCode, credential: "   ") == nil, "empty credential was accepted")
        let access = AgentProviderAccess(
            provider: .rightCode,
            credential: "synthetic-provider-token",
            model: "gpt-5.6-terra"
        )!
        let providerRequest = try DebugCodexTransport(
            configuration: DebugCodexConfiguration(access: access)
        ).request(for: fixtureRequest())
        require(
            providerRequest.url == AgentProvider.rightCode.route(for: .pins).endpoint,
            "shared access selected the wrong gateway endpoint"
        )
        require(
            providerRequest.value(forHTTPHeaderField: "Authorization") == "Bear" + "er synthetic-provider-token",
            "shared access did not authorize the provider request"
        )
        require(providerRequest.value(forHTTPHeaderField: "originator") == nil, "provider request inherited a ChatGPT-only header")
        let providerBody = try JSONSerialization.jsonObject(with: providerRequest.httpBody!) as! [String: Any]
        require(providerBody["model"] as? String == "gpt-5.6-terra", "shared model did not reach Pin request")
        require(providerBody["reasoning"] != nil, "Codex gateway lost its supported request options")

        let openAIAccess = AgentProviderAccess(
            provider: .openAI,
            credential: "synthetic-openai-token"
        )!
        let openAIRequest = try DebugCodexTransport(
            configuration: DebugCodexConfiguration(access: openAIAccess)
        ).request(for: fixtureRequest())
        let openAIBody = try JSONSerialization.jsonObject(with: openAIRequest.httpBody!) as! [String: Any]
        require(openAIRequest.url == AgentProvider.openAI.route(for: .pins).endpoint, "wrong OpenAI Pin endpoint")
        require(openAIBody["reasoning"] == nil && openAIBody["text"] == nil, "OpenAI request received Codex-only options")

        var continuationRequest = fixtureRequest()
        continuationRequest = InvestigationRequest(
            id: continuationRequest.id,
            intent: continuationRequest.intent,
            selection: continuationRequest.selection,
            conversationID: "previous-response-id"
        )
        let continuedRequest = try DebugCodexTransport(
            configuration: DebugCodexConfiguration(access: access)
        ).request(for: continuationRequest)
        let continuedBody = try JSONSerialization.jsonObject(with: continuedRequest.httpBody!) as! [String: Any]
        require(continuedBody["previous_response_id"] as? String == "previous-response-id", "conversation context was dropped")
    }

    private static func checkCanonicalToolCall() throws {
        let events = try DebugCodexAgentClient.translate(canonicalPayloads())
        require(events.count == 5, "unexpected canonical event count")
        guard case let .pinCompleted(pin) = events[2] else { fatalError("missing completed pin") }
        require(pin.target == CropNormalizedPoint(x: 0.25, y: 0.75), "wrong coordinates")
        guard case let .completed(conversationID) = events[4] else { fatalError("missing completion") }
        require(conversationID == "resp_1", "provider conversation ID was dropped")
    }

    private static func checkAdversarialToolCalls() throws {
        var wrongItem = canonicalPayloads()
        wrongItem[2]["item_id"] = "fc_other"
        expectThrows("accepted cross-call delta") { _ = try DebugCodexAgentClient.translate(wrongItem) }

        var terminalFirst = canonicalPayloads()
        terminalFirst.swapAt(4, 5)
        expectThrows("accepted completion before canonical tool item") { _ = try DebugCodexAgentClient.translate(terminalFirst) }

        let booleanArguments = #"{"pins":[{"x":true,"y":false,"kind":"issue","teaser":"Bad","body":"Bad."}]}"#
        expectThrows("accepted boolean coordinates") { _ = try DebugCodexAgentClient.translate(canonicalPayloads(arguments: booleanArguments)) }

        let outOfBounds = #"{"pins":[{"x":1.2,"y":0.5,"kind":"issue","teaser":"Bad","body":"Bad."}]}"#
        expectThrows("accepted out-of-range coordinates") { _ = try DebugCodexAgentClient.translate(canonicalPayloads(arguments: outOfBounds)) }

        var duplicated = canonicalPayloads()
        duplicated.insert(duplicated[1], at: 2)
        expectThrows("accepted duplicate place_pins calls") { _ = try DebugCodexAgentClient.translate(duplicated) }

        var incompleteItem = canonicalPayloads()
        var incomplete = incompleteItem[4]["item"] as! [String: Any]
        incomplete["status"] = "incomplete"
        incompleteItem[4]["item"] = incomplete
        expectThrows("accepted an incomplete output item") { _ = try DebugCodexAgentClient.translate(incompleteItem) }

        var missingTerminalCall = canonicalPayloads()
        var missingResponse = missingTerminalCall[5]["response"] as! [String: Any]
        missingResponse["output"] = []
        missingTerminalCall[5]["response"] = missingResponse
        expectThrows("accepted a missing terminal function call") { _ = try DebugCodexAgentClient.translate(missingTerminalCall) }

        var mismatchedTerminalCall = canonicalPayloads()
        var otherCall = functionCall()
        otherCall["call_id"] = "call_other"
        var mismatchedResponse = mismatchedTerminalCall[5]["response"] as! [String: Any]
        mismatchedResponse["output"] = [otherCall]
        mismatchedTerminalCall[5]["response"] = mismatchedResponse
        expectThrows("accepted a mismatched terminal function call") { _ = try DebugCodexAgentClient.translate(mismatchedTerminalCall) }

        var duplicateTerminalCall = canonicalPayloads()
        var duplicateResponse = duplicateTerminalCall[5]["response"] as! [String: Any]
        duplicateResponse["output"] = [functionCall(), functionCall()]
        duplicateTerminalCall[5]["response"] = duplicateResponse
        expectThrows("accepted multiple terminal function calls") { _ = try DebugCodexAgentClient.translate(duplicateTerminalCall) }

        let reasoningItem: [String: Any] = ["type": "reasoning", "id": "rs_1", "summary": []]
        var withReasoning = canonicalPayloads()
        withReasoning.insert(["type": "response.output_item.added", "output_index": 0, "item": reasoningItem], at: 1)
        withReasoning.insert(["type": "response.output_item.done", "output_index": 0, "item": reasoningItem], at: 2)
        for index in 3 ... 6 { withReasoning[index]["output_index"] = 1 }
        var reasoningResponse = withReasoning[7]["response"] as! [String: Any]
        reasoningResponse["output"] = [reasoningItem, functionCall()]
        withReasoning[7]["response"] = reasoningResponse
        let reasoningEvents = try DebugCodexAgentClient.translate(withReasoning)
        require(reasoningEvents.count == 5, "reasoning output disrupted the forced tool call")
    }

    private static func checkSSEFraming() throws {
        for separator in ["\n", "\r\n", "\r"] {
            let stream = "data: {\"type\":\(separator)data: \"response.created\"}\(separator)\(separator)"
            let records = try decode(Array(stream.utf8))
            require(records.count == 1, "failed SSE separator \(separator.debugDescription)")
        }

        let withBOMAndComment = [UInt8(0xEF), 0xBB, 0xBF] + Array(": keepalive\ndata: {\"type\":\"response.created\"}\n\n".utf8)
        let bomRecords = try decode(withBOMAndComment)
        require(bomRecords.count == 1, "BOM/comment framing failed")

        let unfinished = Array("data: {\"type\":\"response.created\"}".utf8)
        let unfinishedRecords = try decode(unfinished)
        require(unfinishedRecords.isEmpty, "dispatched unfinished EOF event")

        let multiline = Array("data:{\"type\":\ndata: \"response.created\"}\n: middle comment\n\n".utf8)
        let multilineRecords = try decode(multiline)
        require(multilineRecords.count == 1, "first-colon/no-space/multiline framing failed")

        expectThrows("accepted malformed UTF-8") {
            _ = try decode(Array("data: ".utf8) + [0xFF] + Array("\n\n".utf8))
        }

        var decoder = ResponsesSSEDecoder()
        var records: [ResponsesSSEDecoder.Record] = []
        for byte in "data: [DONE]\n\ndata: {\"type\":\"response.completed\"}\n\n".utf8 {
            records += try decoder.feed(byte)
        }
        require(records.count == 1, "accepted records after DONE")
        guard case .done = records[0] else { fatalError("missing DONE sentinel") }
    }

    private static func checkSSEBounds() throws {
        var exactLine = ResponsesSSEDecoder(maximumLineBytes: 5)
        for byte in "data:".utf8 { _ = try exactLine.feed(byte) }
        expectThrows("line limit did not reject limit plus one") { _ = try exactLine.feed(0x20) }

        var exactEvent = ResponsesSSEDecoder(maximumEventBytes: 3)
        var eventRecords: [ResponsesSSEDecoder.Record] = []
        for byte in "data: {}\n\n".utf8 { eventRecords += try exactEvent.feed(byte) }
        require(eventRecords.count == 1, "event exact limit was rejected")
        var oversizedEvent = ResponsesSSEDecoder(maximumEventBytes: 2)
        expectThrows("event limit did not reject limit plus one") {
            for byte in "data: {}\n".utf8 { _ = try oversizedEvent.feed(byte) }
        }

        var exactStream = ResponsesSSEDecoder(maximumStreamBytes: 3)
        for byte in [UInt8(0x61), 0x62, 0x63] { _ = try exactStream.feed(byte) }
        expectThrows("stream limit did not reject limit plus one") { _ = try exactStream.feed(0x64) }

        var exactRecords = ResponsesSSEDecoder(maximumRecords: 1)
        var records: [ResponsesSSEDecoder.Record] = []
        for byte in "data: {}\n\n".utf8 { records += try exactRecords.feed(byte) }
        require(records.count == 1, "record exact limit was rejected")
        expectThrows("record limit did not reject limit plus one") {
            for byte in "data: {}\n\n".utf8 { _ = try exactRecords.feed(byte) }
        }
    }

    private static func checkResponsesTextExtraction() throws {
        let chatCompletion = Data(#"{"choices":[{"message":{"content":"OpenAI summary\n- Detail"}}]}"#.utf8)
        require(
            try ResponsesTextExtractor.text(from: chatCompletion) == "OpenAI summary\n- Detail",
            "Chat Completions text was not extracted"
        )

        let plain = Data(#"{"output":[{"content":[{"type":"output_text","text":"Summary\n- Detail"}]}]}"#.utf8)
        require(try ResponsesTextExtractor.text(from: plain) == "Summary\n- Detail", "plain Responses text was not extracted")

        let stream = Data("""
        data: {"type":"response.output_text.delta","delta":"Summary"}

        data: {"type":"response.output_text.delta","delta":"\\n- Detail"}

        data: [DONE]

        """.utf8)
        require(try ResponsesTextExtractor.text(from: stream) == "Summary\n- Detail", "SSE Responses text was not reassembled")
    }

    private static func checkMissingConfigurationFailure() async throws {
        let client = AgentClientFactory.make(
            access: nil,
            environment: ["TUBER_AGENT_MODE": "provider"]
        )
        var events: [AgentEvent] = []
        for try await event in client.investigate(fixtureRequest()) {
            events.append(event)
        }
        require(events.count == 2, "missing provider access silently selected a recording")
        guard case let .failed(failure) = events[1] else {
            fatalError("missing provider access did not fail")
        }
        require(failure.code == .unauthorized && failure.recoverable, "provider configuration failure was not recoverable")
    }

    private static func checkIncrementalTransport() async throws {
        NeverFinishingStreamProtocol.observation.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [NeverFinishingStreamProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let configuration = DebugCodexConfiguration(
            accessToken: "synthetic-token",
            accountID: nil,
            model: DebugCodexConfiguration.defaultModel
        )
        let transport = DebugCodexTransport(configuration: configuration, session: session)
        let request = try transport.request(for: fixtureRequest())

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await transport.send(request) { payload in
                    require(payload["type"] as? String == "response.created", "wrong incremental payload")
                    return true
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw CheckError.incrementalTransportTimedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
        try await waitForStop("terminal callback did not cancel the URLSession task")
    }

    private static func checkTransportCancellation() async throws {
        NeverFinishingStreamProtocol.observation.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [NeverFinishingStreamProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let configuration = DebugCodexConfiguration(accessToken: "synthetic-token", accountID: nil, model: DebugCodexConfiguration.defaultModel)
        let transport = DebugCodexTransport(configuration: configuration, session: session)
        var request = try transport.request(for: fixtureRequest())
        request.setValue("true", forHTTPHeaderField: "X-Test-Silent")
        let task = Task {
            try await transport.send(request) { _ in
                fatalError("silent response delivered a payload")
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await expectThrows("cancelled transport returned successfully") { try await task.value }
        try await waitForStop("external cancellation did not stop the URLSession task")
    }

    private static func checkHTTPFailures() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StatusResponseProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let configuration = DebugCodexConfiguration(accessToken: "synthetic-token", accountID: nil, model: DebugCodexConfiguration.defaultModel)
        let transport = DebugCodexTransport(configuration: configuration, session: session)

        for path in ["401", "408", "422", "500", "non-http"] {
            let request = URLRequest(url: URL(string: "https://status.invalid/\(path)")!)
            await expectThrows("accepted HTTP failure \(path)") {
                try await transport.send(request) { _ in false }
            }
        }
    }

    private static func waitForStop(_ message: String) async throws {
        for _ in 0 ..< 100 {
            if NeverFinishingStreamProtocol.observation.wasStopped { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError(message)
    }

    enum CheckError: Error { case incrementalTransportTimedOut }
}

private final class NeverFinishingStreamProtocol: URLProtocol {
    static let observation = StopObservation()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.value(forHTTPHeaderField: "X-Test-Silent") != "true" {
            client?.urlProtocol(self, didLoad: Data("data: {\"type\":\"response.created\"}\n\n".utf8))
        }
        // Intentionally never calls urlProtocolDidFinishLoading. The transport must return
        // because its payload callback requested terminal cancellation, not because of EOF.
    }

    override func stopLoading() { Self.observation.markStopped() }
}

private final class StopObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var wasStopped: Bool { lock.withLock { stopped } }
    func reset() { lock.withLock { stopped = false } }
    func markStopped() { lock.withLock { stopped = true } }
}

private final class StatusResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.lastPathComponent == "non-http" {
            client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        } else {
            let status = Int(request.url?.lastPathComponent ?? "") ?? 500
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
