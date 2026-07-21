import Foundation

/// Bounded normal-app client for lasso guidance. It accepts a page crop and
/// returns only validated crop-normalized Pin drafts; Notebook owns the
/// conversion to page coordinates and persistence.
struct OpenAICodexPinClient: Sendable {
    private static let maximumResponseBytes = 2 * 1_024 * 1_024
    private let route: AgentResponseRoute
    private let transport: OpenAICodexResponsesTransport

    var generation: UUID { route.generation }

    init(
        route: AgentResponseRoute,
        transport: OpenAICodexResponsesTransport = OpenAICodexResponsesTransport()
    ) {
        self.route = route
        self.transport = transport
    }

    func placePins(for selection: SelectionArtifact, question: String?) async throws -> [PinDraft] {
        guard !selection.crop.imageData.isEmpty,
              selection.crop.imageData.count <= 8 * 1_024 * 1_024 else {
            throw AgentError.parse
        }
        let questionText = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = """
        Inspect this cropped notebook selection. Return JSON matching the supplied schema with 1 to 8 useful guidance Pins for the original selected region.
        Every x/y coordinate is normalized within this crop, not the full page. Use concise, specific guidance grounded in visible content.
        \(questionText?.isEmpty == false ? "User focus: \(questionText!)" : "")
        """
        let dataURL = "data:\(selection.crop.mediaType);base64,\(selection.crop.imageData.base64EncodedString())"
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["pins"],
            "properties": [
                "pins": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 8,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["x", "y", "kind", "teaser", "body"],
                        "properties": [
                            "x": ["type": "number", "minimum": 0, "maximum": 1],
                            "y": ["type": "number", "minimum": 0, "maximum": 1],
                            "kind": ["type": "string", "enum": ["confirmation", "issue", "explanation", "source", "uncertainty", "suggestion"]],
                            "teaser": ["type": "string", "maxLength": 120],
                            "body": ["type": "string", "maxLength": 2000]
                        ]
                    ]
                ]
            ]
        ]
        let body: [String: Any] = [
            "model": route.model,
            "stream": true,
            "store": false,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": instruction],
                    ["type": "input_image", "image_url": dataURL, "detail": "original"]
                ]
            ]],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "place_pins",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]

        do {
            let request = try JSONSerialization.data(withJSONObject: body)
            let response = try await transport.send(
                body: request,
                route: route,
                capability: .structuredPins,
                maximumResponseBytes: Self.maximumResponseBytes
            )
            return try ResponsesPinTranslator.pins(fromCompleteResponse: response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenAICodexTransportError {
            switch error {
            case .unauthorized(let generation): throw AgentError.openAISignInRequired(generation: generation)
            case .invalidResponse: throw AgentError.parse
            case .unsupported, .unavailable: throw AgentError.unavailable
            }
        } catch let error as AgentError {
            throw error
        } catch {
            throw AgentError.parse
        }
    }
}

/// Strict translator for a schema-constrained Pin response. It prefers the
/// assistant's structured JSON text and retains one-call decoding for older
/// Codex-compatible response shapes.
enum ResponsesPinTranslator {
    static func pins(fromCompleteResponse data: Data) throws -> [PinDraft] {
        guard data.count <= 2 * 1_024 * 1_024,
              let root = try responseObject(from: data),
              let output = root["output"] as? [[String: Any]] else {
            throw AgentError.parse
        }
        let calls = output.filter { $0["type"] as? String == "function_call" }
        if calls.count == 1,
           let call = calls.first,
           call["name"] as? String == "place_pins",
           (call["status"] == nil || call["status"] as? String == "completed"),
           let arguments = call["arguments"] as? String {
            return try pins(fromJSON: arguments)
        }
        guard calls.isEmpty,
              let text = try ResponsesTextExtractor.text(from: data) else {
            throw AgentError.parse
        }
        return try pins(fromJSON: text)
    }

    private static func pins(fromJSON json: String) throws -> [PinDraft] {
        guard json.utf8.count <= 256 * 1_024,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["pins"],
              let rawPins = object["pins"] as? [[String: Any]],
              (1...8).contains(rawPins.count),
              rawPins.allSatisfy({ Set($0.keys) == ["x", "y", "kind", "teaser", "body"] })
        else { throw AgentError.parse }

        return try rawPins.map { raw in
            guard let x = number(raw["x"]), let y = number(raw["y"]),
                  let kindRaw = raw["kind"] as? String, let kind = AnnotationKind(rawValue: kindRaw),
                  let teaser = raw["teaser"] as? String, let body = raw["body"] as? String,
                  !teaser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  teaser.count <= 120, body.count <= 2_000,
                  CropNormalizedPoint(x: x, y: y).isFiniteAndInUnitBounds
            else { throw AgentError.parse }
            return PinDraft(
                id: UUID(),
                target: CropNormalizedPoint(x: x, y: y),
                targetRegion: nil,
                kind: kind,
                teaser: teaser,
                body: body,
                citations: []
            )
        }
    }

    private static func responseObject(from data: Data) throws -> [String: Any]? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["output"] != nil {
            return root
        }
        let payloads = try ResponsesSSEDecoder.payloads(from: data)
        let terminal = payloads.filter { $0["type"] as? String == "response.completed" }
        if terminal.count == 1,
           let response = terminal[0]["response"] as? [String: Any],
           response["status"] as? String == "completed" {
            return response
        }

        // Some Codex-compatible streams finish the output item but omit the
        // aggregate response body. Preserve the same one-call validation while
        // accepting that wire shape.
        let completedItems = payloads.compactMap { payload -> [String: Any]? in
            guard payload["type"] as? String == "response.output_item.done" else { return nil }
            return payload["item"] as? [String: Any]
        }
        guard !completedItems.isEmpty else { return nil }
        return ["output": completedItems]
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }
}
