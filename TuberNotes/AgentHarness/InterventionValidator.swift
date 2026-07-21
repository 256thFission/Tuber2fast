import Foundation

enum InterventionResponseDecoder {
    static func decode(_ json: String, intent: InvestigationIntent) throws -> InterventionOutcome {
        guard json.utf8.count <= 256 * 1_024,
              let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(root["schema_version"]) == 1,
              let outcome = root["outcome"] as? String else {
            throw AgentError.parse
        }

        let decoded: InterventionOutcome
        switch outcome {
        case "spatial_guidance":
            guard exactKeys(root, ["schema_version", "outcome", "basis", "intervention"]),
                  let rawBasis = root["basis"] as? [String: Any],
                  let rawIntervention = root["intervention"] as? [String: Any] else {
                throw AgentError.parse
            }
            decoded = .spatialGuidance(
                try intervention(rawIntervention),
                basis: try basis(rawBasis)
            )
        case "transient_confirmation":
            guard exactKeys(root, ["schema_version", "outcome", "basis", "confirmation"]),
                  let rawBasis = root["basis"] as? [String: Any],
                  case let .calculus(calculus) = try basis(rawBasis),
                  let rawConfirmation = root["confirmation"] as? [String: Any],
                  exactKeys(rawConfirmation, ["message"]),
                  let message = boundedString(rawConfirmation["message"], 8 ... 180) else {
                throw AgentError.parse
            }
            decoded = .transientConfirmation(
                TransientConfirmation(message: message), basis: calculus
            )
        case "needs_input":
            guard exactKeys(root, ["schema_version", "outcome", "needs_input"]),
                  let raw = root["needs_input"] as? [String: Any],
                  exactKeys(raw, ["reason", "message"]),
                  let reasonRaw = raw["reason"] as? String,
                  let reason = NeedsInputReason(rawValue: reasonRaw),
                  let message = boundedString(raw["message"], 8 ... 180) else {
                throw AgentError.parse
            }
            decoded = .needsInput(NeedsInput(reason: reason, message: message))
        case "no_action":
            guard exactKeys(root, ["schema_version", "outcome", "no_action"]),
                  let raw = root["no_action"] as? [String: Any],
                  exactKeys(raw, ["reason"]),
                  let reasonRaw = raw["reason"] as? String,
                  let reason = NoActionReason(rawValue: reasonRaw) else {
                throw AgentError.parse
            }
            decoded = .noAction(NoAction(reason: reason))
        default:
            throw AgentError.parse
        }

        guard InterventionSemanticValidator.accepts(decoded, for: intent) else {
            throw AgentError.parse
        }
        return InterventionVisibleCopy.normalized(decoded)
    }

    private static func basis(_ raw: [String: Any]) throws -> InterventionBasis {
        guard let subject = raw["subject"] as? String else { throw AgentError.parse }
        switch subject {
        case "calculus":
            let keys = [
                "subject", "integrand", "observed_substitution", "observed_student_result",
                "expected_relationship", "expected_result", "verification", "blocking_ambiguity"
            ]
            guard exactKeys(raw, keys),
                  let integrand = boundedString(raw["integrand"], 1 ... 120),
                  let observedSubstitution = nullableString(raw["observed_substitution"]),
                  let observedStudentResult = nullableString(raw["observed_student_result"]),
                  let expectedRelationship = nullableString(raw["expected_relationship"]),
                  let expectedResult = nullableString(raw["expected_result"]),
                  let blockingAmbiguity = nullableString(raw["blocking_ambiguity"]) else {
                throw AgentError.parse
            }
            let verification: CalculusVerification?
            if raw["verification"] is NSNull {
                verification = nil
            } else if let value = raw["verification"] as? [String: Any] {
                guard exactKeys(value, ["method", "candidate", "derivative", "matches_integrand"]),
                      let methodRaw = value["method"] as? String,
                      let method = CalculusVerification.Method(rawValue: methodRaw),
                      let candidate = boundedString(value["candidate"], 1 ... 120),
                      let derivative = boundedString(value["derivative"], 1 ... 120),
                      let matches = value["matches_integrand"] as? Bool else {
                    throw AgentError.parse
                }
                verification = CalculusVerification(
                    method: method, candidate: candidate, derivative: derivative,
                    matchesIntegrand: matches
                )
            } else {
                throw AgentError.parse
            }
            return .calculus(CalculusBasis(
                integrand: integrand,
                observedSubstitution: observedSubstitution,
                observedStudentResult: observedStudentResult,
                expectedRelationship: expectedRelationship,
                expectedResult: expectedResult,
                verification: verification,
                blockingAmbiguity: blockingAmbiguity
            ))
        case "organic_chemistry":
            let keys = [
                "subject", "reaction_family", "electron_source", "electrophilic_center",
                "leaving_group", "bonds_formed", "bonds_broken", "observed_arrow_flow",
                "blocking_ambiguity"
            ]
            guard exactKeys(raw, keys),
                  let reactionFamily = nullableString(raw["reaction_family"]),
                  let electronSource = nullableString(raw["electron_source"]),
                  let electrophilicCenter = nullableString(raw["electrophilic_center"]),
                  let leavingGroup = nullableString(raw["leaving_group"]),
                  let bondsFormed = stringArray(raw["bonds_formed"], maximum: 2),
                  let bondsBroken = stringArray(raw["bonds_broken"], maximum: 2),
                  let rawFlow = raw["observed_arrow_flow"] as? [[String: Any]],
                  rawFlow.count <= 2,
                  let blockingAmbiguity = nullableString(raw["blocking_ambiguity"]) else {
                throw AgentError.parse
            }
            let flow = try rawFlow.map { value -> ElectronFlow in
                guard exactKeys(value, ["source", "destination"]),
                      let source = boundedString(value["source"], 1 ... 120),
                      let destination = boundedString(value["destination"], 1 ... 120) else {
                    throw AgentError.parse
                }
                return ElectronFlow(source: source, destination: destination)
            }
            return .organicChemistry(OrganicChemistryBasis(
                reactionFamily: reactionFamily,
                electronSource: electronSource,
                electrophilicCenter: electrophilicCenter,
                leavingGroup: leavingGroup,
                bondsFormed: bondsFormed,
                bondsBroken: bondsBroken,
                observedArrowFlow: flow,
                blockingAmbiguity: blockingAmbiguity
            ))
        default:
            throw AgentError.parse
        }
    }

    private static func intervention(_ raw: [String: Any]) throws -> GroundedIntervention {
        guard exactKeys(raw, ["kind", "teaser", "body", "study_cue", "target"]),
              let kindRaw = raw["kind"] as? String,
              let kind = AnnotationKind(rawValue: kindRaw),
              [.issue, .explanation].contains(kind),
              let teaser = boundedString(raw["teaser"], 3 ... 44),
              let body = boundedString(raw["body"], 18 ... 280),
              let studyCue = nullableString(raw["study_cue"], range: 8 ... 160),
              let target = raw["target"] as? [String: Any],
              exactKeys(target, ["x", "y"]),
              let x = number(target["x"]), let y = number(target["y"]),
              CropNormalizedPoint(x: x, y: y).isFiniteAndInUnitBounds else {
            throw AgentError.parse
        }
        return GroundedIntervention(
            kind: kind, teaser: teaser, body: body, studyCue: studyCue,
            target: CropNormalizedPoint(x: x, y: y)
        )
    }

    private static func exactKeys(_ value: [String: Any], _ keys: [String]) -> Bool {
        Set(value.keys) == Set(keys)
    }

    private static func boundedString(_ value: Any?, _ range: ClosedRange<Int>) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed, range.contains(value.count) else { return nil }
        return value
    }

    private static func nullableString(
        _ value: Any?, range: ClosedRange<Int> = 1 ... 120
    ) -> String?? {
        if value is NSNull { return .some(nil) }
        guard let value = boundedString(value, range) else { return nil }
        return .some(.some(value))
    }

    private static func stringArray(_ value: Any?, maximum: Int) -> [String]? {
        guard let values = value as? [Any], values.count <= maximum else { return nil }
        let strings = values.compactMap { boundedString($0, 1 ... 120) }
        guard strings.count == values.count,
              Set(strings.map(InterventionSemanticValidator.canonical)).count == strings.count else {
            return nil
        }
        return strings
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

enum InterventionSemanticValidator {
    static func accepts(_ outcome: InterventionOutcome, for intent: InvestigationIntent) -> Bool {
        switch outcome {
        case let .spatialGuidance(intervention, basis):
            switch (intent, basis) {
            case let (.check, .calculus(calculus)):
                return intervention.kind == .issue
                    && validGoldenCalculusIssue(calculus, intervention: intervention)
            case let (.explain, .organicChemistry(chemistry)):
                return intervention.kind == .explanation
                    && validGoldenSN2(chemistry, intervention: intervention)
            default:
                return false
            }
        case let .transientConfirmation(confirmation, basis):
            guard case .check = intent else { return false }
            return validGoldenCalculusConfirmation(basis, confirmation: confirmation)
        case let .needsInput(value):
            switch (intent, value.reason) {
            case (.check, .unreadableSelection), (.check, .missingMathStep),
                 (.check, .unsupportedContent), (.explain, .missingReactionContext),
                 (.explain, .unreadableSelection), (.explain, .unsupportedContent),
                 (.ask, .unsupportedContent):
                return true
            default:
                return false
            }
        case let .noAction(value):
            if case .ask = intent { return value.reason == .unsupportedIntent }
            return value.reason != .unsupportedIntent
        }
    }

    static func canonical(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "²", with: "^2")
            .replacingOccurrences(of: "³", with: "^3")
            .replacingOccurrences(of: "⁴", with: "^4")
            .replacingOccurrences(of: "½", with: "1/2")
            .replacingOccurrences(of: "⁻", with: "-")
            .filter { !$0.isWhitespace && !"{}()[]*·".contains($0) }
    }

    private static func validGoldenCalculusIssue(
        _ value: CalculusBasis,
        intervention: GroundedIntervention
    ) -> Bool {
        guard value.blockingAmbiguity == nil,
              let substitution = value.observedSubstitution,
              let observed = value.observedStudentResult,
              let relationship = value.expectedRelationship,
              let expected = value.expectedResult else { return false }
        guard isGoldenIntegrand(value.integrand),
              containsAll(substitution, ["u=x^2", "du=2xdx"]) else { return false }

        let missingHalf = value.verification == nil
            && equivalent(observed, "e^x^2+c")
            && equivalent(relationship, "xdx=1/2du")
            && equivalent(expected, "1/2e^x^2+c")
            && containsAll(intervention.body, ["xdx=1/2du", "1/2e^x^2+c"])

        let missingConstant = validDerivativeEvidence(
            value.verification,
            candidate: observed,
            derivative: value.integrand
        )
            && equivalent(observed, "1/2e^x^2")
            && containsAny(relationship, ["constantofintegration", "indefiniteintegralrequires+c"])
            && equivalent(expected, "1/2e^x^2+c")
            && containsAll(intervention.body, ["+c", "1/2e^x^2+c"])
        return missingHalf || missingConstant
    }

    private static func validGoldenCalculusConfirmation(
        _ value: CalculusBasis,
        confirmation: TransientConfirmation
    ) -> Bool {
        guard value.blockingAmbiguity == nil,
              let observed = value.observedStudentResult,
              let expected = value.expectedResult,
              let verification = value.verification,
              verification.matchesIntegrand else { return false }
        let correctedSubstitution = isGoldenIntegrand(value.integrand)
            && equivalent(observed, "1/2e^x^2+c")
            && equivalent(expected, "1/2e^x^2+c")
            && equivalent(verification.candidate, observed)
            && isGoldenIntegrand(verification.derivative)

        let correctPowerRule = equivalent(value.integrand, "x^3")
            && equivalent(observed, "x^4/4+c")
            && equivalent(expected, "x^4/4+c")
            && value.expectedRelationship.map {
                containsAny($0, ["powerrule", "∫x^ndx=x^n+1/n+1+c"])
            } == true
            && equivalent(verification.candidate, observed)
            && equivalent(verification.derivative, "x^3")

        return (correctedSubstitution || correctPowerRule)
            && containsAny(confirmation.message, ["differentiat", "derivative"])
            && containsAny(
                confirmation.message,
                correctedSubstitution ? ["xe^x^2", "xexp x^2"] : ["x^3"]
            )
    }

    private static func validGoldenSN2(
        _ value: OrganicChemistryBasis,
        intervention: GroundedIntervention
    ) -> Bool {
        guard value.blockingAmbiguity == nil,
              let family = value.reactionFamily.map(canonical),
              let electronSource = value.electronSource,
              let center = value.electrophilicCenter else { return false }

        if family == "protontransfer" {
            return validProtonTransfer(
                value,
                electronSource: electronSource,
                center: center,
                intervention: intervention
            )
        }
        guard let leavingGroup = value.leavingGroup,
              family == "sn2",
              containsAny(electronSource, ["hydroxide", "ho-lonepair", "oxygenlonepair"]),
              containsAny(center, ["carbonbondedtobromine", "electrophiliccarbon", "ethylcarbon"]),
              containsAny(leavingGroup, ["bromide", "br-"]),
              value.bondsFormed.contains(where: { equivalent($0, "c-o") }),
              value.bondsBroken.contains(where: { equivalent($0, "c-br") }) else { return false }

        let flow = value.observedArrowFlow.map { (canonical($0.source), canonical($0.destination)) }
        let attack = flow.contains { source, destination in
            containsAny(source, ["hydroxide", "ho-lonepair", "oxygenlonepair"])
                && containsAny(destination, ["carbonbondedtobromine", "electrophiliccarbon", "ethylcarbon"])
        }
        let departure = flow.contains { source, destination in
            containsAny(source, ["c-brbond", "carbon-brominebond"])
                && containsAny(destination, ["bromine", "bromide", "br-"])
        }
        let bodyHasCausalMovement = containsAny(intervention.body, ["donates", "lonepair"])
            && containsAny(intervention.body, ["c-brbondbreak", "c-brbondbreaks", "bromideleav"])
        let cueTracksElectronFlow = intervention.studyCue.map {
            containsAny($0, ["electronsource", "electronorigin"])
                && containsAny($0, ["destination", "endpoint"])
        } ?? true
        return attack && departure && bodyHasCausalMovement && cueTracksElectronFlow
    }

    private static func validProtonTransfer(
        _ value: OrganicChemistryBasis,
        electronSource: String,
        center: String,
        intervention: GroundedIntervention
    ) -> Bool {
        guard containsAny(electronSource, ["b-lonepair", "b-lonepair", "baseblonepair"]),
              containsAny(center, ["proton", "hydrogeninh-a", "hinh-a"]),
              value.leavingGroup == nil,
              value.bondsFormed.contains(where: { equivalent($0, "b-h") }),
              value.bondsBroken.contains(where: { equivalent($0, "h-a") }) else { return false }

        let flow = value.observedArrowFlow.map { (canonical($0.source), canonical($0.destination)) }
        let protonation = flow.contains { source, destination in
            containsAny(source, ["b-lonepair", "baseblonepair"])
                && containsAny(destination, ["proton", "hydrogeninh-a", "hinh-a"])
        }
        let bondDeparture = flow.contains { source, destination in
            containsAny(source, ["h-abond", "hydrogen-abond"])
                && isOneOf(destination, ["a", "a-", "conjugatebasea"])
        }
        let bodyHasCausalMovement = containsAny(intervention.body, ["lonepair", "donates"])
            && containsAny(intervention.body, ["proton", "hydrogen"])
            && containsAny(intervention.body, ["h-abondbreak", "h-abondbreaks"])
            && containsAny(intervention.body, ["b-hbondform", "b-hbondforms"])
        return protonation && bondDeparture && bodyHasCausalMovement
    }

    private static func validDerivativeEvidence(
        _ verification: CalculusVerification?,
        candidate: String,
        derivative: String
    ) -> Bool {
        guard let verification, verification.matchesIntegrand else { return false }
        return equivalent(verification.candidate, candidate)
            && equivalent(verification.derivative, derivative)
    }

    private static func isGoldenIntegrand(_ value: String) -> Bool {
        ["xe^x^2", "xex^2", "xexpx^2"].contains(canonical(value))
    }

    private static func containsAll(_ value: String, _ required: [String]) -> Bool {
        let normalized = canonical(value)
        return required.allSatisfy { normalized.contains(canonical($0)) }
    }

    private static func containsAny(_ value: String, _ allowed: [String]) -> Bool {
        let normalized = canonical(value)
        return allowed.contains { normalized.contains(canonical($0)) }
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    private static func isOneOf(_ value: String, _ allowed: [String]) -> Bool {
        allowed.contains { equivalent(value, $0) }
    }
}

/// Provider prose is untrusted. Once the narrow typed facts validate, visible
/// copy is app-owned so a fluent contradiction cannot hitchhike on valid fields.
private enum InterventionVisibleCopy {
    static func normalized(_ outcome: InterventionOutcome) -> InterventionOutcome {
        switch outcome {
        case let .spatialGuidance(value, basis):
            switch basis {
            case let .calculus(calculus):
                let missingConstant = calculus.observedStudentResult.map {
                    InterventionSemanticValidator.canonical($0) == "1/2e^x^2"
                } == true
                let copy = GroundedIntervention(
                    kind: .issue,
                    teaser: missingConstant ? "Include the constant" : "Missing one-half",
                    body: missingConstant
                        ? "This derivative is correct, but an indefinite integral represents a family. Write ½e^(x²) + C."
                        : "Since du = 2x dx, x dx = ½du. The antiderivative is ½e^(x²) + C.",
                    studyCue: nil,
                    target: value.target
                )
                return .spatialGuidance(copy, basis: basis)
            case let .organicChemistry(chemistry):
                let protonTransfer = chemistry.reactionFamily.map {
                    InterventionSemanticValidator.canonical($0) == "protontransfer"
                } == true
                let copy = GroundedIntervention(
                    kind: .explanation,
                    teaser: protonTransfer ? "One proton-transfer step" : "One concerted step",
                    body: protonTransfer
                        ? "The base donates its lone pair to H as the H—A bond breaks. The B—H bond forms while the bonding pair moves to A."
                        : "Hydroxide donates a lone pair to the carbon as the C—O bond forms and the C—Br bond breaks in the same step. Bromide leaves with the bonding pair.",
                    studyCue: "Follow curved arrows from the electron source to the electron destination.",
                    target: value.target
                )
                return .spatialGuidance(copy, basis: basis)
            }
        case let .transientConfirmation(_, basis):
            let powerRule = InterventionSemanticValidator.canonical(basis.integrand) == "x^3"
            return .transientConfirmation(
                TransientConfirmation(message: powerRule
                    ? "Checks out — differentiating x⁴/4 + C returns x³."
                    : "Checks out — differentiating this result returns x e^(x²)."),
                basis: basis
            )
        case let .needsInput(value):
            let message: String
            switch value.reason {
            case .unreadableSelection:
                message = "Select the expression again so the exponent and symbols are readable."
            case .missingMathStep:
                message = "Select the original expression and the missing intermediate step together."
            case .missingReactionContext:
                message = "Select a wider area containing the reactants, products, leaving group, and complete arrow endpoints."
            case .unsupportedContent:
                message = "This selection is outside the supported substitution, power-rule, and basic electron-flow examples."
            }
            return .needsInput(NeedsInput(reason: value.reason, message: message))
        case .noAction:
            return outcome
        }
    }
}
