#if DEBUG
import Foundation

struct DebugCodexConfiguration: Sendable {
    static let defaultModel = "gpt-5.6-terra"

    let accessToken: String
    let accountID: String?
    let model: String
    let endpoint: URL
    let originator: String?
    let includesCodexOptions: Bool
    private let providerAccess: AgentProviderAccess?

    init(
        accessToken: String,
        accountID: String?,
        model: String,
        endpoint: URL = DebugCodexTransport.endpoint,
        originator: String? = "opencode",
        includesCodexOptions: Bool = true
    ) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.model = model
        self.endpoint = endpoint
        self.originator = originator
        self.includesCodexOptions = includesCodexOptions
        providerAccess = nil
    }

    init(access: AgentProviderAccess) {
        let route = access.provider.route(for: .pins)
        accessToken = access.credential
        accountID = nil
        model = access.model
        endpoint = route.endpoint
        originator = nil
        includesCodexOptions = access.provider == .rightCode
        providerAccess = access
    }

    static func processEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard environment["TUBER_AGENT_MODE"] == "codex",
              let token = environment["TUBER_CODEX_ACCESS_TOKEN"], !token.isEmpty else { return nil }
        let override = environment["TUBER_CODEX_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            accessToken: token,
            accountID: environment["TUBER_CODEX_ACCOUNT_ID"],
            model: override.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        )
    }

    func prepare(_ request: inout URLRequest) {
        if let providerAccess {
            providerAccess.prepare(&request)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
    }
}

struct DebugCodexTransport: Sendable {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    let configuration: DebugCodexConfiguration
    private let session: URLSession

    init(configuration: DebugCodexConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? AgentProviderNetworking.ephemeralSession()
    }

    func request(for investigation: InvestigationRequest) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        configuration.prepare(&request)
        if let originator = configuration.originator {
            request.setValue(originator, forHTTPHeaderField: "originator")
        }
        request.setValue(investigation.id.uuidString, forHTTPHeaderField: "session-id")
        request.setValue("TuberNotes-Debug/1", forHTTPHeaderField: "User-Agent")
        if let accountID = configuration.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body(for: investigation))
        return request
    }

    /// Opens the response as bytes and dispatches each SSE JSON payload before the connection closes.
    /// Returning true from `onPayload` terminates the HTTP task immediately after a typed terminal event.
    func send(
        _ request: URLRequest,
        onPayload: ([String: Any]) async throws -> Bool
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.prefersIncrementalDelivery = true
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw TransportError.unavailable }
        guard (200 ... 299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw TransportError.unauthorized
            case 408, 504: throw TransportError.timedOut
            case 400 ... 499: throw TransportError.invalidRequest
            default: throw TransportError.unavailable
            }
        }

        var decoder = ResponsesSSEDecoder()
        for try await byte in bytes {
            try Task.checkCancellation()
            for record in try decoder.feed(byte) {
                try Task.checkCancellation()
                switch record {
                case .done:
                    return
                case let .payload(payload):
                    if try await onPayload(payload) { return }
                }
            }
        }
        try decoder.finish()
    }

    private func body(for request: InvestigationRequest) -> [String: Any] {
        let crop = request.selection.crop
        let image = "data:\(crop.mediaType);base64,\(crop.imageData.base64EncodedString())"
        let context = request.selection.context.nearbyText ?? ""
        let intent: String = switch request.intent {
        case .explain: "explain"
        case .check: "check"
        case let .ask(question): "answer: \(question)"
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "stream": true,
            "store": false,
            "parallel_tool_calls": false,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "Intent: \(intent). Inspect the selected work. Nearby text: \(context). Place concise pins using crop-normalized coordinates where x=0 is left, x=1 is right, y=0 is top, and y=1 is bottom."],
                    ["type": "input_image", "image_url": image, "detail": "original"]
                ]
            ]],
            "tool_choice": ["type": "function", "name": "place_pins"],
            "tools": [[
                "type": "function", "name": "place_pins",
                "description": "Place proposed notes over the selected crop.",
                "strict": true,
                "parameters": Self.placePinsSchema()
            ]]
        ]
        if configuration.includesCodexOptions {
            body["reasoning"] = ["effort": "medium", "summary": "auto"]
            body["text"] = ["verbosity": "low"]
        }
        if let conversationID = request.conversationID, !conversationID.isEmpty {
            body["previous_response_id"] = conversationID
        }
        return body
    }

    private static func placePinsSchema() -> [String: Any] {
        [
            "type": "object", "additionalProperties": false, "required": ["pins"],
            "properties": ["pins": [
                "type": "array", "minItems": 1, "maxItems": 8,
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["x", "y", "kind", "teaser", "body"],
                    "properties": [
                        "x": ["type": "number", "minimum": 0, "maximum": 1],
                        "y": ["type": "number", "minimum": 0, "maximum": 1],
                        "kind": ["type": "string", "enum": ["confirmation", "issue", "explanation", "source", "uncertainty", "suggestion"]],
                        "teaser": ["type": "string"], "body": ["type": "string"]
                    ]
                ]
            ]]
        ]
    }

    enum TransportError: Error {
        case unauthorized
        case timedOut
        case invalidRequest
        case unavailable
    }
}
#endif
