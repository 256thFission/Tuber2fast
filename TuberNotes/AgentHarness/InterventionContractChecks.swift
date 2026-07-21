import Foundation

/// Host-safe focused checks callable by development tooling after project integration.
/// They use no provider, notebook content, UI, or persistent state.
enum InterventionContractChecks {
    static func failures() -> [String] {
        var failures: [String] = []
        expectAccepted("C1 missing half", intent: .check, object: c1, failures: &failures)
        expectAccepted("C2 corrected result", intent: .check, object: c2, failures: &failures)
        expectAccepted("C3 missing constant", intent: .check, object: c3, failures: &failures)
        expectAccepted("C4 power rule", intent: .check, object: c4, failures: &failures)
        expectAccepted("O5 proton transfer", intent: .explain, object: o5, failures: &failures)
        expectAccepted("O1 SN2", intent: .explain, object: o1, failures: &failures)
        expectAccepted("O4 no content", intent: .explain, object: o4, failures: &failures)

        var malformed = c3
        malformed["extra"] = true
        expectRejected("extra root key", intent: .check, object: malformed, failures: &failures)

        var unsupportedClaim = o5
        if var intervention = unsupportedClaim["intervention"] as? [String: Any] {
            intervention["body"] = "The carbon electrophile undergoes substitution while bromide leaves."
            unsupportedClaim["intervention"] = intervention
        }
        expectRejected("O5 substitution prose", intent: .explain, object: unsupportedClaim, failures: &failures)

        var doubledIntegrand = c1
        if var basis = doubledIntegrand["basis"] as? [String: Any] {
            basis["integrand"] = "2x e^(x²)"
            doubledIntegrand["basis"] = basis
        }
        expectRejected("C1 doubled integrand", intent: .check, object: doubledIntegrand, failures: &failures)

        do {
            let outcome = try InterventionResponseDecoder.decode(json(o1), intent: .explain)
            guard case let .spatialGuidance(value, _) = outcome,
                  value.body.contains("C—O bond forms"),
                  value.body.contains("same step"),
                  value.studyCue?.contains("electron source") == true else {
                failures.append("O1 app-owned causal copy: missing required content")
                return failures
            }
        } catch {
            failures.append("O1 app-owned causal copy: unexpectedly rejected")
        }
        return failures
    }

    private static func expectAccepted(
        _ name: String,
        intent: InvestigationIntent,
        object: [String: Any],
        failures: inout [String]
    ) {
        do {
            _ = try InterventionResponseDecoder.decode(json(object), intent: intent)
        } catch {
            failures.append("\(name): unexpectedly rejected")
        }
    }

    private static func expectRejected(
        _ name: String,
        intent: InvestigationIntent,
        object: [String: Any],
        failures: inout [String]
    ) {
        do {
            _ = try InterventionResponseDecoder.decode(json(object), intent: intent)
            failures.append("\(name): unexpectedly accepted")
        } catch { }
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static var c3: [String: Any] { spatial(
        basis: calculus(
            integrand: "x e^(x²)",
            substitution: "u = x²; du = 2x dx",
            observed: "½e^(x²)",
            relationship: "An indefinite integral requires + C",
            expected: "½e^(x²) + C",
            verification: derivative(candidate: "½e^(x²)", result: "x e^(x²)")
        ),
        kind: "issue",
        body: "An indefinite antiderivative requires + C: ½e^(x²) + C."
    ) }

    private static var c1: [String: Any] { spatial(
        basis: calculus(
            integrand: "x e^(x²)",
            substitution: "u = x²; du = 2x dx",
            observed: "e^(x²) + C",
            relationship: "x dx = ½du",
            expected: "½e^(x²) + C",
            verification: NSNull()
        ),
        kind: "issue",
        body: "Since x dx = ½du, the result is ½e^(x²) + C."
    ) }

    private static var c2: [String: Any] { [
        "schema_version": 1,
        "outcome": "transient_confirmation",
        "basis": calculus(
            integrand: "x e^(x²)",
            substitution: "u = x²; du = 2x dx",
            observed: "½e^(x²) + C",
            relationship: "x dx = ½du",
            expected: "½e^(x²) + C",
            verification: derivative(candidate: "½e^(x²) + C", result: "x e^(x²)")
        ),
        "confirmation": ["message": "Differentiating this returns x e^(x²)."]
    ] }

    private static var c4: [String: Any] { [
        "schema_version": 1,
        "outcome": "transient_confirmation",
        "basis": calculus(
            integrand: "x³",
            observed: "x⁴/4 + C",
            relationship: "power rule",
            expected: "x⁴/4 + C",
            verification: derivative(candidate: "x⁴/4 + C", result: "x³")
        ),
        "confirmation": ["message": "Differentiating the result returns x³."]
    ] }

    private static var o5: [String: Any] { spatial(
        basis: [
            "subject": "organic_chemistry",
            "reaction_family": "proton transfer",
            "electron_source": "B⁻ lone pair",
            "electrophilic_center": "proton in H–A",
            "leaving_group": NSNull(),
            "bonds_formed": ["B–H"],
            "bonds_broken": ["H–A"],
            "observed_arrow_flow": [
                ["source": "B⁻ lone pair", "destination": "proton in H–A"],
                ["source": "H–A bond", "destination": "A⁻"]
            ],
            "blocking_ambiguity": NSNull()
        ],
        kind: "explanation",
        body: "The B⁻ lone pair attacks the proton as the H–A bond breaks and the B–H bond forms."
    ) }

    private static var o1: [String: Any] { spatial(
        basis: [
            "subject": "organic_chemistry",
            "reaction_family": "SN2",
            "electron_source": "hydroxide lone pair",
            "electrophilic_center": "carbon bonded to bromine",
            "leaving_group": "bromide",
            "bonds_formed": ["C—O"],
            "bonds_broken": ["C—Br"],
            "observed_arrow_flow": [
                ["source": "hydroxide lone pair", "destination": "carbon bonded to bromine"],
                ["source": "C—Br bond", "destination": "bromide"]
            ],
            "blocking_ambiguity": NSNull()
        ],
        kind: "explanation",
        body: "Hydroxide donates a lone pair while the C—Br bond breaks and bromide leaves."
    ) }

    private static var o4: [String: Any] { [
        "schema_version": 1,
        "outcome": "no_action",
        "no_action": ["reason": "no_relevant_content"]
    ] }

    private static func spatial(
        basis: [String: Any],
        kind: String,
        body: String
    ) -> [String: Any] {
        [
            "schema_version": 1,
            "outcome": "spatial_guidance",
            "basis": basis,
            "intervention": [
                "kind": kind,
                "teaser": kind == "issue" ? "Add the constant" : "Concerted proton transfer",
                "body": body,
                "study_cue": NSNull(),
                "target": ["x": 0.5, "y": 0.5]
            ]
        ]
    }

    private static func calculus(
        integrand: String,
        substitution: Any = NSNull(),
        observed: String,
        relationship: String,
        expected: String,
        verification: Any
    ) -> [String: Any] {
        [
            "subject": "calculus",
            "integrand": integrand,
            "observed_substitution": substitution,
            "observed_student_result": observed,
            "expected_relationship": relationship,
            "expected_result": expected,
            "verification": verification,
            "blocking_ambiguity": NSNull()
        ]
    }

    private static func derivative(candidate: String, result: String) -> [String: Any] {
        [
            "method": "differentiate_candidate",
            "candidate": candidate,
            "derivative": result,
            "matches_integrand": true
        ]
    }
}
