import SwiftUI

#if REVIEW_HARNESS
/// Grafts the human-in-the-loop review surface onto the modern UI without
/// replacing the root. The `FeedbackThreadBar` floats over `LibraryView` /
/// `NotebookView`; when no thread is active it renders nothing and does not
/// intercept touches. The live MCP verifier (`DeveloperTools/PencilFixtureMCP`)
/// drives this by writing thread files that `FeedbackThreadSession` watches;
/// the debug button seeds a canned "Your turn" thread for a reliable demo take.
struct ReviewHarnessOverlay: View {
    @StateObject private var session = FeedbackThreadSession()

    var body: some View {
        VStack(spacing: 0) {
            FeedbackThreadBar(session: session)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(session.activeFeedbackThread != nil)
        .overlay(alignment: .bottomTrailing) { seedButton }
    }

    /// Demo trigger: drops one open thread on disk so the bar animates in even
    /// without a live Codex/MCP round-trip. Safe to leave in — DEBUG-only build.
    @ViewBuilder
    private var seedButton: some View {
        if session.activeFeedbackThread == nil {
            Button {
                ReviewHarnessDemo.seed()
                session.reload()
            } label: {
                Image(systemName: "person.badge.shield.checkmark")
                    .padding(12)
                    .background(.orange, in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(20)
            .accessibilityIdentifier("review-harness-seed")
        }
    }
}

/// Manufactures a self-contained "Codex is asking a human" review case: an open
/// thread plus one model message carrying a single-choice question. Because the
/// message's interaction is `awaiting-human`, the bar renders the prompt with
/// tappable choices and a comment field — exactly what a live MCP verifier round
/// would produce, but with no server running.
enum ReviewHarnessDemo {
    static func seed() {
        let now = Date()
        let id = "demo-\(Int(now.timeIntervalSince1970))"
        var thread = FeedbackThread(
            schemaVersion: 1,
            id: id,
            title: "Pin overlay spacing — does it read better?",
            objective: "Taste call Codex can't unit-test: verify a visual change.",
            state: .open,
            createdAt: now,
            updatedAt: now,
            requester: .init(id: "codex"),
            owner: .init(tokenHash: "", tokenRequired: false),
            scenario: "pin-overlay-demo",
            surfaceRevision: 1,
            queueSequence: 1,
            lastSequence: 0,
            lastHumanSequence: 0,
            lastConsumedSequence: 0,
            revision: 1,
            eventSequence: 0,
            messageIDs: [],
            messageIdempotency: [:],
            delivery: .init(target: .init(kind: "app", id: "library"), pinnedAt: now),
            activeComparisonID: nil,
            activeVariantID: nil,
            reviewRun: nil
        )

        let question = FeedbackMessage(
            id: "\(id)-q1",
            feedbackThreadID: id,
            sequence: 1,
            author: .model,
            body: """
            I widened the pin overlay's internal padding (8pt → 14pt) and lowered \
            its max width so long notes wrap sooner. There's no test for "looks \
            less cramped" — can you eyeball it and tell me which way it went?
            """,
            createdAt: now,
            interaction: FeedbackInteraction(
                kind: .singleChoice,
                state: .awaitingHuman,
                options: [
                    .init(id: "better", label: "Better"),
                    .init(id: "same", label: "About the same"),
                    .init(id: "worse", label: "Worse"),
                ],
                allowsComment: true,
                allowsAttachment: false,
                comparisonID: nil
            ),
            attachments: [],
            surfaceDirective: nil,
            inReplyTo: nil,
            idempotencyKey: "\(id)-q1",
            selectedOptionID: nil
        )

        do {
            try FeedbackThreadStore.save(thread)
            try FeedbackThreadStore.appendMessage(question, to: &thread)
            FeedbackThreadStore.appendEvent("demo-review-requested", feedbackThreadID: id)
        } catch {
            print("ReviewHarnessDemo seed failed: \(error)")
        }
    }
}
#endif
