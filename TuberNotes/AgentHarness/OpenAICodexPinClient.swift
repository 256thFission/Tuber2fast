import Foundation

/// Bounded normal-app client for one evidence-bearing intervention decision.
/// Notebook owns state freshness, crop-to-page conversion, and persistence.
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

    func intervene(
        for selection: SelectionArtifact,
        intent: InvestigationIntent
    ) async throws -> InterventionOutcome {
        guard !selection.crop.imageData.isEmpty,
              selection.crop.mediaType == "image/png",
              selection.crop.imageData.count <= 4 * 1_024 * 1_024,
              selection.crop.pixelWidth > 0, selection.crop.pixelHeight > 0,
              selection.crop.pageBounds.isFiniteAndInUnitBounds else {
            throw AgentError.parse
        }

        let intentInstruction: String
        switch intent {
        case .check:
            intentInstruction = "Check the selected calculus work. Verify a correctness claim only from the required calculus evidence."
        case .explain:
            intentInstruction = "Explain the selected organic-chemistry electron flow. Explain only when every required reaction fact is visible."
        case .ask:
            throw AgentError.parse
        }
        let instruction = """
        \(intentInstruction)
        Return exactly one schema-v1 outcome. The supported affirmative set is narrow: a missing one-half substitution factor, an omitted integration constant, a corrected substitution result, a correct elementary power-rule result, a complete canonical SN2 explanation, or a complete basic proton-transfer explanation. Correct work uses transient_confirmation. Missing or unreadable evidence uses needs_input. Unsupported or instructionally empty content uses no_action.
        Copy visible mathematical and chemical notation faithfully. Do not guess missing superscripts, charges, arrow endpoints, reagents, products, or steps. Coordinates are normalized within the supplied selection crop; make no atom-level or glyph-level placement claim.
        """
        let dataURL = "data:\(selection.crop.mediaType);base64,\(selection.crop.imageData.base64EncodedString())"
        var content: [[String: Any]] = [
            ["type": "input_text", "text": instruction + "\nImage 1 is the authoritative tight evidence crop and the only coordinate-bearing image."],
            ["type": "input_image", "image_url": dataURL, "detail": "original"]
        ]
        if let contextCrop = selection.contextCrop,
           !contextCrop.imageData.isEmpty,
           contextCrop.mediaType == "image/png",
           contextCrop.imageData.count <= 4 * 1_024 * 1_024,
           selection.crop.imageData.count + contextCrop.imageData.count <= 6 * 1_024 * 1_024,
           contextCrop.pixelWidth > 0, contextCrop.pixelHeight > 0,
           contextCrop.pageBounds.isFiniteAndInUnitBounds,
           Self.contains(selection.crop.pageBounds, in: contextCrop.pageBounds) {
            let contextURL = "data:\(contextCrop.mediaType);base64,\(contextCrop.imageData.base64EncodedString())"
            content.append([
                "type": "input_text",
                "text": "Image 2 is non-coordinate page context. Use it only to understand relationships; never target within it."
            ])
            content.append(["type": "input_image", "image_url": contextURL, "detail": "original"])
        }
        let body: [String: Any] = [
            "model": route.model,
            "stream": true,
            "store": false,
            "input": [[
                "role": "user",
                "content": content
            ]],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "intervention_decision_v1",
                    "strict": true,
                    "schema": Self.responseSchema
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
            return try ResponsesInterventionTranslator.outcome(
                fromCompleteResponse: response,
                intent: intent
            )
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

    /// Temporary source-compatibility bridge for the coordinator-owned Notebook seam.
    /// PC-18 integration must call `intervene(for:intent:)` so non-Pin successes
    /// remain distinguishable instead of being represented by this empty array.
    func placePins(for selection: SelectionArtifact, question: String?) async throws -> [PinDraft] {
        let outcome = try await intervene(for: selection, intent: .explain)
        guard case let .spatialGuidance(value, _) = outcome else { return [] }
        return [PinDraft(
            id: UUID(),
            target: value.target,
            targetRegion: nil,
            kind: value.kind,
            teaser: value.teaser,
            body: value.body,
            citations: []
        )]
    }

    private static var nullableShortString: [String: Any] { [
        "type": ["string", "null"], "minLength": 1, "maxLength": 120
    ] }

    private static var calculusBasis: [String: Any] { [
        "type": "object", "additionalProperties": false,
        "required": [
            "subject", "integrand", "observed_substitution", "observed_student_result",
            "expected_relationship", "expected_result", "verification", "blocking_ambiguity"
        ],
        "properties": [
            "subject": ["type": "string", "const": "calculus"],
            "integrand": ["type": "string", "minLength": 1, "maxLength": 120],
            "observed_substitution": nullableShortString,
            "observed_student_result": nullableShortString,
            "expected_relationship": nullableShortString,
            "expected_result": nullableShortString,
            "verification": [
                "anyOf": [
                    ["type": "null"],
                    [
                        "type": "object", "additionalProperties": false,
                        "required": ["method", "candidate", "derivative", "matches_integrand"],
                        "properties": [
                            "method": ["type": "string", "enum": ["differentiate_candidate"]],
                            "candidate": ["type": "string", "minLength": 1, "maxLength": 120],
                            "derivative": ["type": "string", "minLength": 1, "maxLength": 120],
                            "matches_integrand": ["type": "boolean"]
                        ]
                    ]
                ]
            ],
            "blocking_ambiguity": nullableShortString
        ]
    ] }

    private static var chemistryBasis: [String: Any] { [
        "type": "object", "additionalProperties": false,
        "required": [
            "subject", "reaction_family", "electron_source", "electrophilic_center",
            "leaving_group", "bonds_formed", "bonds_broken", "observed_arrow_flow",
            "blocking_ambiguity"
        ],
        "properties": [
            "subject": ["type": "string", "const": "organic_chemistry"],
            "reaction_family": nullableShortString,
            "electron_source": nullableShortString,
            "electrophilic_center": nullableShortString,
            "leaving_group": nullableShortString,
            "bonds_formed": shortStringArray,
            "bonds_broken": shortStringArray,
            "observed_arrow_flow": [
                "type": "array", "maxItems": 2,
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["source", "destination"],
                    "properties": [
                        "source": ["type": "string", "minLength": 1, "maxLength": 120],
                        "destination": ["type": "string", "minLength": 1, "maxLength": 120]
                    ]
                ]
            ],
            "blocking_ambiguity": nullableShortString
        ]
    ] }

    private static var shortStringArray: [String: Any] { [
        "type": "array", "maxItems": 2, "uniqueItems": true,
        "items": ["type": "string", "minLength": 1, "maxLength": 120]
    ] }

    private static var intervention: [String: Any] { [
        "type": "object", "additionalProperties": false,
        "required": ["kind", "teaser", "body", "study_cue", "target"],
        "properties": [
            "kind": ["type": "string", "enum": ["issue", "explanation"]],
            "teaser": ["type": "string", "minLength": 3, "maxLength": 44],
            "body": ["type": "string", "minLength": 18, "maxLength": 280],
            "study_cue": ["type": ["string", "null"], "minLength": 8, "maxLength": 160],
            "target": [
                "type": "object", "additionalProperties": false,
                "required": ["x", "y"],
                "properties": [
                    "x": ["type": "number", "minimum": 0, "maximum": 1],
                    "y": ["type": "number", "minimum": 0, "maximum": 1]
                ]
            ]
        ]
    ] }

    private static var responseSchema: [String: Any] { [
        "type": "object",
        "oneOf": [
            closedOutcome(
                "spatial_guidance",
                payload: ["basis": ["oneOf": [calculusBasis, chemistryBasis]], "intervention": intervention]
            ),
            closedOutcome(
                "transient_confirmation",
                payload: [
                    "basis": calculusBasis,
                    "confirmation": closedObject([
                        "message": ["type": "string", "minLength": 8, "maxLength": 180]
                    ])
                ]
            ),
            closedOutcome(
                "needs_input",
                payload: [
                    "needs_input": closedObject([
                        "reason": [
                            "type": "string",
                            "enum": [
                                "unreadable_selection", "missing_math_step",
                                "missing_reaction_context", "unsupported_content"
                            ]
                        ],
                        "message": ["type": "string", "minLength": 8, "maxLength": 180]
                    ])
                ]
            ),
            closedOutcome(
                "no_action",
                payload: [
                    "no_action": closedObject([
                        "reason": [
                            "type": "string",
                            "enum": ["no_relevant_content", "unsupported_intent", "unsupported_content"]
                        ]
                    ])
                ]
            )
        ]
    ] }

    private static func closedObject(_ properties: [String: Any]) -> [String: Any] {
        [
            "type": "object", "additionalProperties": false,
            "required": Array(properties.keys).sorted(), "properties": properties
        ]
    }

    private static func contains(_ inner: PageNormalizedRect, in outer: PageNormalizedRect) -> Bool {
        inner.x >= outer.x && inner.y >= outer.y
            && inner.x + inner.width <= outer.x + outer.width
            && inner.y + inner.height <= outer.y + outer.height
    }

    private static func closedOutcome(_ name: String, payload: [String: Any]) -> [String: Any] {
        var properties = payload
        properties["schema_version"] = ["type": "integer", "const": 1]
        properties["outcome"] = ["type": "string", "const": name]
        return closedObject(properties)
    }
}

enum ResponsesInterventionTranslator {
    static func outcome(
        fromCompleteResponse data: Data,
        intent: InvestigationIntent
    ) throws -> InterventionOutcome {
        guard data.count <= 2 * 1_024 * 1_024,
              let root = try responseObject(from: data),
              let output = root["output"] as? [[String: Any]] else {
            throw AgentError.parse
        }
        let calls = output.filter { $0["type"] as? String == "function_call" }
        let json: String
        if calls.count == 1,
           let call = calls.first,
           call["name"] as? String == "intervention_decision_v1",
           (call["status"] == nil || call["status"] as? String == "completed"),
           let arguments = call["arguments"] as? String {
            json = arguments
        } else {
            guard calls.isEmpty,
                  let text = try ResponsesTextExtractor.text(from: data) else {
                throw AgentError.parse
            }
            json = text
        }
        return try InterventionResponseDecoder.decode(json, intent: intent)
    }

    private static func responseObject(from data: Data) throws -> [String: Any]? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["output"] != nil { return root }

        let payloads = try ResponsesSSEDecoder.payloads(from: data)
        let terminal = payloads.filter { $0["type"] as? String == "response.completed" }
        if terminal.count == 1,
           let response = terminal[0]["response"] as? [String: Any],
           response["status"] as? String == "completed" {
            return response
        }
        let completedItems = payloads.compactMap { payload -> [String: Any]? in
            guard payload["type"] as? String == "response.output_item.done" else { return nil }
            return payload["item"] as? [String: Any]
        }
        guard !completedItems.isEmpty else { return nil }
        return ["output": completedItems]
    }
}
