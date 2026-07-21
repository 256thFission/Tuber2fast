import Foundation

enum InterventionOutcome: Equatable, Sendable {
    case spatialGuidance(GroundedIntervention, basis: InterventionBasis)
    case transientConfirmation(TransientConfirmation, basis: CalculusBasis)
    case needsInput(NeedsInput)
    case noAction(NoAction)
}

enum InterventionBasis: Equatable, Sendable {
    case calculus(CalculusBasis)
    case organicChemistry(OrganicChemistryBasis)
}

struct CalculusBasis: Equatable, Sendable {
    let integrand: String
    let observedSubstitution: String?
    let observedStudentResult: String?
    let expectedRelationship: String?
    let expectedResult: String?
    let verification: CalculusVerification?
    let blockingAmbiguity: String?
}

struct CalculusVerification: Equatable, Sendable {
    enum Method: String, Equatable, Sendable {
        case differentiateCandidate = "differentiate_candidate"
    }

    let method: Method
    let candidate: String
    let derivative: String
    let matchesIntegrand: Bool
}

struct OrganicChemistryBasis: Equatable, Sendable {
    let reactionFamily: String?
    let electronSource: String?
    let electrophilicCenter: String?
    let leavingGroup: String?
    let bondsFormed: [String]
    let bondsBroken: [String]
    let observedArrowFlow: [ElectronFlow]
    let blockingAmbiguity: String?
}

struct ElectronFlow: Equatable, Sendable {
    let source: String
    let destination: String
}

struct GroundedIntervention: Equatable, Sendable {
    let kind: AnnotationKind
    let teaser: String
    let body: String
    let studyCue: String?
    let target: CropNormalizedPoint
}

struct TransientConfirmation: Equatable, Sendable {
    let message: String
}

struct NeedsInput: Equatable, Sendable {
    let reason: NeedsInputReason
    let message: String
}

enum NeedsInputReason: String, Equatable, Sendable {
    case unreadableSelection = "unreadable_selection"
    case missingMathStep = "missing_math_step"
    case missingReactionContext = "missing_reaction_context"
    case unsupportedContent = "unsupported_content"
}

struct NoAction: Equatable, Sendable {
    let reason: NoActionReason
}

enum NoActionReason: String, Equatable, Sendable {
    case noRelevantContent = "no_relevant_content"
    case unsupportedIntent = "unsupported_intent"
    case unsupportedContent = "unsupported_content"
}
