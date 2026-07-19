#if DEBUG
import CoreFoundation
import Foundation

final class DebugCodexAgentClient: AgentClient, @unchecked Sendable {
    private struct ActiveTask {
        let token: UUID
        var task: Task<Void, Never>?
    }

    private let transport: DebugCodexTransport
    private let lock = NSLock()
    private var tasks: [UUID: ActiveTask] = [:]

    init(configuration: DebugCodexConfiguration) {
        transport = DebugCodexTransport(configuration: configuration)
    }

    func investigate(_ request: InvestigationRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamToken = UUID()
            reserveTask(for: request.id, token: streamToken)
            continuation.yield(.accepted)
            continuation.yield(.inspectingSelection)

            let task = Task { [weak self] in
                guard let self else { return }
                defer { self.removeTask(request.id, token: streamToken) }
                do {
                    let urlRequest = try self.transport.request(for: request)
                    var state = ResponsesStreamState()
                    try await self.transport.send(urlRequest) { payload in
                        let events = try state.consume(payload)
                        for event in events {
                            try Task.checkCancellation()
                            if case .terminated = continuation.yield(event) { throw CancellationError() }
                        }
                        return state.isTerminal
                    }
                    try state.requireSuccessfulTerminal()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(Self.failure(.cancelled, "Investigation cancelled.", recoverable: true)))
                    continuation.finish()
                } catch DebugCodexTransport.TransportError.unauthorized {
                    continuation.yield(.failed(Self.failure(.unauthorized, "Sign in again to use the live agent.", recoverable: true)))
                    continuation.finish()
                } catch DebugCodexTransport.TransportError.timedOut {
                    continuation.yield(.failed(Self.failure(.timedOut, "The live agent timed out.", recoverable: true)))
                    continuation.finish()
                } catch DebugCodexTransport.TransportError.invalidRequest {
                    continuation.yield(.failed(Self.failure(.invalidResponse, "The live agent request was rejected.", recoverable: true)))
                    continuation.finish()
                } catch DebugCodexTransport.TransportError.unavailable {
                    continuation.yield(.failed(Self.failure(.unavailable, "The live agent is unavailable.", recoverable: true)))
                    continuation.finish()
                } catch let error as URLError where error.code == .timedOut {
                    continuation.yield(.failed(Self.failure(.timedOut, "The live agent timed out.", recoverable: true)))
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.yield(.failed(Self.failure(.cancelled, "Investigation cancelled.", recoverable: true)))
                    continuation.finish()
                } catch let error as URLError where [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost].contains(error.code) {
                    continuation.yield(.failed(Self.failure(.unavailable, "The live agent is unavailable.", recoverable: true)))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(Self.failure(.invalidResponse, "The live agent returned an unusable response.", recoverable: true)))
                    continuation.finish()
                }
            }
            installTask(task, for: request.id, token: streamToken)
            continuation.onTermination = { [weak self] _ in
                self?.cancelTask(request.id, token: streamToken)
            }
        }
    }

    func cancel(investigationID: UUID) async { cancelTask(investigationID) }

    private func reserveTask(for id: UUID, token: UUID) {
        let previous = lock.withLock { () -> Task<Void, Never>? in
            let previous = tasks[id]?.task
            tasks[id] = ActiveTask(token: token, task: nil)
            return previous
        }
        previous?.cancel()
    }

    private func installTask(_ task: Task<Void, Never>, for id: UUID, token: UUID) {
        let installed = lock.withLock { () -> Bool in
            guard tasks[id]?.token == token else { return false }
            tasks[id]?.task = task
            return true
        }
        if !installed { task.cancel() }
    }

    private func removeTask(_ id: UUID, token: UUID) {
        lock.withLock {
            guard tasks[id]?.token == token else { return }
            tasks[id] = nil
        }
    }

    private func cancelTask(_ id: UUID, token: UUID? = nil) {
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard token == nil || tasks[id]?.token == token else { return nil }
            let task = tasks[id]?.task
            tasks[id] = nil
            return task
        }
        task?.cancel()
    }

    static func translate(_ payloads: [[String: Any]]) throws -> [AgentEvent] {
        var state = ResponsesStreamState()
        let events = try payloads.flatMap { try state.consume($0) }
        try state.requireSuccessfulTerminal()
        return events
    }

    private static func failure(_ code: AgentFailure.Code, _ message: String, recoverable: Bool) -> AgentFailure {
        AgentFailure(code: code, userMessage: message, recoverable: recoverable)
    }
}

private struct ResponsesStreamState {
    private struct CallState {
        let itemID: String
        let outputIndex: Int
        let callID: String
        let tool: ToolInvocationSummary
        var streamedArguments: String
        var doneArguments: String?
        var canonicalArguments: String?
    }

    private var call: CallState?
    private(set) var isTerminal = false
    private var completedSuccessfully = false
    private static let maximumArgumentBytes = 256 * 1_024

    mutating func consume(_ payload: [String: Any]) throws -> [AgentEvent] {
        guard !isTerminal else { throw StreamError.eventAfterTerminal }
        guard let type = payload["type"] as? String else { throw StreamError.schema }
        switch type {
        case "response.created", "response.in_progress":
            return []
        case "response.output_item.added":
            return try beginOutputItem(payload)
        case "response.function_call_arguments.delta":
            try appendArguments(payload)
            return []
        case "response.function_call_arguments.done":
            try finishArguments(payload)
            return []
        case "response.output_item.done":
            try finishOutputItem(payload)
            return []
        case "response.completed":
            return try completeResponse(payload)
        case "response.failed", "response.incomplete", "error":
            isTerminal = true
            throw StreamError.providerFailure
        default:
            return []
        }
    }

    func requireSuccessfulTerminal() throws {
        guard isTerminal, completedSuccessfully else { throw StreamError.truncated }
    }

    private mutating func beginOutputItem(_ payload: [String: Any]) throws -> [AgentEvent] {
        guard let outputIndex = Self.integer(payload["output_index"]),
              let item = payload["item"] as? [String: Any],
              let itemType = item["type"] as? String else { throw StreamError.schema }
        guard itemType == "function_call" else { return [] }
        guard call == nil,
              let itemID = item["id"] as? String, !itemID.isEmpty,
              let callID = item["call_id"] as? String, !callID.isEmpty,
              item["name"] as? String == "place_pins" else { throw StreamError.callIdentity }
        let tool = ToolInvocationSummary(id: UUID(), tool: .placePins, userVisibleStatus: "Placing proposed Pins…")
        call = CallState(
            itemID: itemID,
            outputIndex: outputIndex,
            callID: callID,
            tool: tool,
            streamedArguments: item["arguments"] as? String ?? "",
            doneArguments: nil,
            canonicalArguments: nil
        )
        return [.toolStarted(tool)]
    }

    private mutating func appendArguments(_ payload: [String: Any]) throws {
        guard var current = call,
              current.canonicalArguments == nil,
              payload["item_id"] as? String == current.itemID,
              Self.integer(payload["output_index"]) == current.outputIndex,
              let delta = payload["delta"] as? String else { throw StreamError.callIdentity }
        current.streamedArguments += delta
        guard current.streamedArguments.utf8.count <= Self.maximumArgumentBytes else { throw StreamError.argumentsTooLarge }
        call = current
    }

    private mutating func finishArguments(_ payload: [String: Any]) throws {
        guard var current = call,
              current.canonicalArguments == nil,
              payload["item_id"] as? String == current.itemID,
              Self.integer(payload["output_index"]) == current.outputIndex,
              let arguments = payload["arguments"] as? String,
              arguments.utf8.count <= Self.maximumArgumentBytes else { throw StreamError.callIdentity }
        current.doneArguments = arguments
        call = current
    }

    private mutating func finishOutputItem(_ payload: [String: Any]) throws {
        guard let item = payload["item"] as? [String: Any],
              let itemType = item["type"] as? String else { throw StreamError.schema }
        guard itemType == "function_call" else { return }
        guard var current = call,
              current.canonicalArguments == nil,
              Self.integer(payload["output_index"]) == current.outputIndex,
              item["id"] as? String == current.itemID,
              item["call_id"] as? String == current.callID,
              item["name"] as? String == "place_pins",
              item["status"] as? String == "completed",
              let arguments = item["arguments"] as? String,
              arguments.utf8.count <= Self.maximumArgumentBytes,
              current.doneArguments == nil || current.doneArguments == arguments else { throw StreamError.callIdentity }
        current.canonicalArguments = arguments
        call = current
    }

    private mutating func completeResponse(_ payload: [String: Any]) throws -> [AgentEvent] {
        guard let current = call, let arguments = current.canonicalArguments,
              let response = payload["response"] as? [String: Any],
              response["status"] as? String == "completed",
              let output = response["output"] as? [[String: Any]],
              current.outputIndex >= 0, current.outputIndex < output.count else { throw StreamError.truncated }
        let functionCalls = output.enumerated().filter { $0.element["type"] as? String == "function_call" }
        guard functionCalls.count == 1,
              functionCalls[0].offset == current.outputIndex,
              functionCalls[0].element["id"] as? String == current.itemID,
              functionCalls[0].element["call_id"] as? String == current.callID,
              functionCalls[0].element["name"] as? String == "place_pins",
              functionCalls[0].element["status"] as? String == "completed",
              functionCalls[0].element["arguments"] as? String == arguments else { throw StreamError.callIdentity }
        let pins = try Self.decodePins(arguments)
        isTerminal = true
        completedSuccessfully = true
        return pins.flatMap { [.pinStarted($0), .pinCompleted($0)] }
            + [.toolFinished(current.tool), .completed(conversationID: nil)]
    }

    private static func decodePins(_ arguments: String) throws -> [PinDraft] {
        guard let data = arguments.data(using: .utf8),
              let rawRoot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(rawRoot.keys) == ["pins"],
              let rawPins = rawRoot["pins"] as? [[String: Any]],
              (1 ... 8).contains(rawPins.count),
              rawPins.allSatisfy({ Set($0.keys) == ["x", "y", "kind", "teaser", "body"] }) else {
            throw StreamError.schema
        }
        let decoded = try JSONDecoder().decode(PlacePinsArguments.self, from: data)
        return try decoded.pins.map { pin in
            let target = CropNormalizedPoint(x: pin.x, y: pin.y)
            guard target.isFiniteAndInUnitBounds,
                  !pin.teaser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !pin.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  pin.teaser.count <= 120,
                  pin.body.count <= 2_000,
                  let kind = AnnotationKind(rawValue: pin.kind) else { throw StreamError.schema }
            return PinDraft(id: UUID(), target: target, targetRegion: nil, kind: kind, teaser: pin.teaser, body: pin.body, citations: [])
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.intValue
        return number.doubleValue == Double(result) ? result : nil
    }

    private struct PlacePinsArguments: Decodable {
        let pins: [PlacePin]
    }

    private struct PlacePin: Decodable {
        let x: Double
        let y: Double
        let kind: String
        let teaser: String
        let body: String
    }

    enum StreamError: Error {
        case schema
        case callIdentity
        case argumentsTooLarge
        case providerFailure
        case eventAfterTerminal
        case truncated
    }
}
#endif
