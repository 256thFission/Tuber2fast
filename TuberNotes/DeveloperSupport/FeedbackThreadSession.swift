import Combine
import PencilKit
import SwiftUI

#if DEBUG
@MainActor
final class FeedbackThreadSession: ObservableObject {
    private struct ComposerDraft {
        var reply = ""
        var selectedOptionID: String?
        var choiceComment = ""
        var preference = Preference.none
        var preferenceComment = ""
    }

    struct PendingCapture {
        let feedbackThreadID: String
        let reviewStepID: String?
        let cleanImage: UIImage
        let annotatedImage: UIImage
    }

    enum Preference: String, CaseIterable, Identifiable {
        case a = "Prefer A", b = "Prefer B", neither = "Neither", none = "No preference"
        var id: String { rawValue }
    }

    @Published private(set) var feedbackThreads: [FeedbackThread] = []
    @Published private(set) var activeFeedbackThread: FeedbackThread?
    @Published private(set) var resetGeneration = 0
    @Published private(set) var captureRequestGeneration = 0
    @Published private(set) var isCapturing = false
    @Published private(set) var isResettingComparison = false
    @Published var isPresentingFullThread = false
    @Published var capturedImage: UIImage?
    @Published private(set) var pendingCapture: PendingCapture?
    @Published var selectedReviewStepID: String?
    @Published var statusMessage: String?
    @Published private var composerDrafts: [String: ComposerDraft] = [:]

    private var pollTask: Task<Void, Never>?
    private var resetFeedbackTask: Task<Void, Never>?
    private var lifecycleCancellables: Set<AnyCancellable> = []

    init() {
        reload()
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.isPresentingFullThread = false
            }
            .store(in: &lifecycleCancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &lifecycleCancellables)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
    }

    deinit {
        pollTask?.cancel()
        resetFeedbackTask?.cancel()
    }

    var activeQuestion: FeedbackMessage? {
        guard let value = activeFeedbackThread else { return nil }
        let answeredIDs = Set(value.messages.compactMap(\.inReplyTo))
        return value.messages.reversed().first {
            $0.interaction?.state == .awaitingHuman && !answeredIDs.contains($0.id)
        }
    }

    var currentTurn: FeedbackMessage? {
        activeQuestion ?? activeFeedbackThread?.messages.reversed().first(where: { $0.author == .model })
    }

    var queuedCandidate: FeedbackThread? {
        feedbackThreads
            .filter { $0.state == .queued }
            .min { ($0.queueSequence, $0.id) < ($1.queueSequence, $1.id) }
    }

    var comparisonID: String? {
        activeFeedbackThread?.activeComparisonID
            ?? activeFeedbackThread?.messages.reversed().compactMap { $0.surfaceDirective?.comparisonID ?? $0.interaction?.comparisonID }.first
    }

    var isLiveComparison: Bool { comparisonID == "pin-presentation-01" }
    var activeVariant: String { activeFeedbackThread?.activeVariantID ?? "a" }

    var activeReviewRun: ReviewRun? { activeFeedbackThread?.reviewRun }

    var selectedReviewStep: ReviewStep? {
        guard let run = activeReviewRun else { return nil }
        if let selectedReviewStepID, let selected = run.steps.first(where: { $0.id == selectedReviewStepID }) {
            return selected
        }
        return run.steps.first(where: { !$0.isTerminal }) ?? run.steps.first
    }

    var reviewProgress: String {
        guard let run = activeReviewRun else { return "" }
        return "\(run.steps.filter(\.isTerminal).count) of \(run.steps.count) complete"
    }

    var canFinishReview: Bool {
        guard let run = activeReviewRun else { return false }
        return run.state == .active && run.steps.allSatisfy(\.isTerminal)
    }

    var draftReply: String {
        get { activeDraft.reply }
        set { updateActiveDraft { $0.reply = newValue } }
    }

    var draftSelectedOptionID: String? {
        get { activeDraft.selectedOptionID }
        set { updateActiveDraft { $0.selectedOptionID = newValue } }
    }

    var draftChoiceComment: String {
        get { activeDraft.choiceComment }
        set { updateActiveDraft { $0.choiceComment = newValue } }
    }

    var draftPreference: Preference {
        get { activeDraft.preference }
        set { updateActiveDraft { $0.preference = newValue } }
    }

    var draftPreferenceComment: String {
        get { activeDraft.preferenceComment }
        set { updateActiveDraft { $0.preferenceComment = newValue } }
    }

    func reload() {
        let previouslyPresentedThreadID = isPresentingFullThread ? activeFeedbackThread?.id : nil
        var loaded = FeedbackThreadStore.loadAll()
        if !loaded.contains(where: { $0.state.ownsDeviceSlot }),
           let index = loaded.firstIndex(where: { $0.state == .queued }) {
            loaded[index].state = .open
            loaded[index].updatedAt = Date()
            loaded[index].revision += 1
            try? FeedbackThreadStore.save(loaded[index])
            FeedbackThreadStore.appendEvent("thread-activated", feedbackThreadID: loaded[index].id)
        }
        feedbackThreads = loaded
        activeFeedbackThread = loaded.filter { $0.state.ownsDeviceSlot }
            .sorted { ($0.queueSequence, $0.id) < ($1.queueSequence, $1.id) }.first
        if let run = activeFeedbackThread?.reviewRun,
           selectedReviewStepID == nil || !run.steps.contains(where: { $0.id == selectedReviewStepID }) {
            selectedReviewStepID = run.steps.first(where: { !$0.isTerminal })?.id ?? run.steps.first?.id
        }
        if previouslyPresentedThreadID != nil,
           previouslyPresentedThreadID != activeFeedbackThread?.id || activeFeedbackThread?.state != .open {
            isPresentingFullThread = false
        }
    }

    func sendReply(_ body: String) {
        if appendHumanMessage(body: body, selectedOptionID: nil, answering: activeQuestion?.interaction?.kind == .freeText ? activeQuestion?.id : nil) {
            draftReply = ""
        }
    }

    func answer(_ questionMessage: FeedbackMessage, optionID: String, comment: String) {
        guard questionMessage.interaction?.kind == .singleChoice, activeQuestion?.id == questionMessage.id else { return }
        if appendHumanMessage(body: comment, selectedOptionID: optionID, answering: questionMessage.id) {
            draftSelectedOptionID = nil
            draftChoiceComment = ""
        }
    }

    func setState(_ state: FeedbackThreadState) {
        guard var value = activeFeedbackThread else { return }
        value.state = state
        value.lastConsumedSequence = value.lastSequence
        value.updatedAt = Date()
        value.revision += 1
        do {
            try FeedbackThreadStore.save(value)
            FeedbackThreadStore.appendEvent("thread-\(state.rawValue)", feedbackThreadID: value.id, values: ["actor": "human", "lastConsumedSequence": "\(value.lastSequence)"])
            reload()
        } catch { statusMessage = error.localizedDescription }
    }

    func skipForward() {
        guard var current = activeFeedbackThread, var next = queuedCandidate else { return }
        current.state = .queued
        current.queueSequence = (feedbackThreads.map(\.queueSequence).max() ?? 0) + 1
        current.updatedAt = Date()
        current.revision += 1
        next.state = .open
        next.updatedAt = Date()
        next.revision += 1
        do {
            try FeedbackThreadStore.save(current)
            try FeedbackThreadStore.save(next)
            FeedbackThreadStore.appendEvent(
                "thread-skipped-forward",
                feedbackThreadID: current.id,
                values: ["actor": "human", "nextFeedbackThreadID": next.id]
            )
            reload()
        } catch { statusMessage = error.localizedDescription }
    }

    func selectVariant(_ variant: String) {
        guard var value = activeFeedbackThread, isLiveComparison, variant == "a" || variant == "b" else { return }
        value.activeComparisonID = "pin-presentation-01"
        value.activeVariantID = variant
        value.updatedAt = Date()
        value.revision += 1
        do {
            try FeedbackThreadStore.save(value)
            activeFeedbackThread = value
            showComparisonResetFeedback()
            FeedbackThreadStore.appendEvent("variant-exposed", feedbackThreadID: value.id, values: ["comparisonID": "pin-presentation-01", "variantID": variant])
        } catch { statusMessage = error.localizedDescription }
    }

    func resetComparison() {
        guard let id = activeFeedbackThread?.id, isLiveComparison else { return }
        showComparisonResetFeedback()
        FeedbackThreadStore.appendEvent("comparison-reset", feedbackThreadID: id, values: ["comparisonID": "pin-presentation-01"])
    }

    private func showComparisonResetFeedback() {
        resetFeedbackTask?.cancel()
        isResettingComparison = true
        resetGeneration += 1
        resetFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.isResettingComparison = false
        }
    }

    func submitPreference(_ preference: Preference, comment: String) {
        guard let id = activeFeedbackThread?.id, isLiveComparison else { return }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? preference.rawValue : "\(preference.rawValue): \(trimmed)"
        if appendHumanMessage(body: body, selectedOptionID: preference.id, answering: activeQuestion?.id) {
            draftPreference = .none
            draftPreferenceComment = ""
            FeedbackThreadStore.appendEvent("comparison-preference", feedbackThreadID: id, values: ["comparisonID": "pin-presentation-01", "preference": preference.id])
        }
    }

    func requestCapture(reviewStepID: String? = nil) {
        guard activeFeedbackThread != nil else { return }
        selectedReviewStepID = reviewStepID ?? selectedReviewStepID
        isCapturing = true
        captureRequestGeneration += 1
    }

    func receiveCapturedImage(_ image: UIImage?) {
        isCapturing = false
        capturedImage = image
        if image == nil { statusMessage = "Viewport capture failed." }
    }

    func cancelCapture() {
        capturedImage = nil
        statusMessage = nil
    }

    func attachCapture(drawing: PKDrawing) {
        guard let value = activeFeedbackThread, let cleanImage = capturedImage else { return }
        let annotated = UIGraphicsImageRenderer(size: cleanImage.size).image { _ in
            cleanImage.draw(in: CGRect(origin: .zero, size: cleanImage.size))
            drawing.image(from: CGRect(origin: .zero, size: cleanImage.size), scale: cleanImage.scale)
                .draw(in: CGRect(origin: .zero, size: cleanImage.size))
        }
        pendingCapture = PendingCapture(
            feedbackThreadID: value.id,
            reviewStepID: value.reviewRun == nil ? nil : selectedReviewStepID,
            cleanImage: cleanImage,
            annotatedImage: annotated
        )
        capturedImage = nil
        statusMessage = nil
        if value.reviewRun != nil { persistReviewCapture() }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.isPresentingFullThread = true
        }
    }

    func removePendingCapture() {
        pendingCapture = nil
    }

    func selectReviewStep(_ stepID: String) {
        guard var value = activeFeedbackThread,
              let step = value.reviewRun?.steps.first(where: { $0.id == stepID }) else { return }
        selectedReviewStepID = stepID
        if value.scenario != step.scenario {
            value.scenario = step.scenario
            value.updatedAt = Date()
            value.revision += 1
            do {
                try FeedbackThreadStore.save(value)
                activeFeedbackThread = value
                resetGeneration += 1
                FeedbackThreadStore.appendEvent("review-step-scenario-selected", feedbackThreadID: value.id)
            } catch { statusMessage = error.localizedDescription }
        }
    }

    func updateReviewComment(_ comment: String) {
        updateSelectedReviewStep { step in
            step.comment = comment
            if step.state == .ready { step.state = .inProgress }
        }
    }

    func selectReviewOption(_ optionID: String) {
        updateSelectedReviewStep { step in
            guard step.options.contains(where: { $0.id == optionID }) else { return }
            step.selectedOptionID = optionID
            if step.state == .ready { step.state = .inProgress }
        }
    }

    func completeReviewStep(_ outcome: ReviewStepState) {
        guard [.passed, .failed, .skipped, .blocked].contains(outcome) else { return }
        updateSelectedReviewStep { step in
            guard step.state == .ready || step.state == .inProgress else { return }
            if step.responseKind == "choice" && outcome == .passed && step.selectedOptionID == nil { return }
            step.state = outcome
            step.verdict = outcome.rawValue
            step.completedAt = Date()
        }
        selectNextReadyReviewStep()
    }

    func removeReviewAttachment(_ attachmentID: String) {
        guard let value = activeFeedbackThread else { return }
        updateSelectedReviewStep { step in
            guard let attachment = step.attachments.first(where: { $0.id == attachmentID }) else { return }
            let directory = FeedbackThreadStore.rootURL.appendingPathComponent(value.id, isDirectory: true)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(attachment.cleanPath))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(attachment.annotatedPath))
            step.attachments.removeAll { $0.id == attachmentID }
        }
    }

    func submitReviewRun() {
        guard var value = activeFeedbackThread, var run = value.reviewRun,
              run.state == .active, run.steps.allSatisfy(\.isTerminal) else { return }
        let messageID = "feedback-message-\(UUID().uuidString.lowercased())"
        for stepIndex in run.steps.indices {
            for attachmentIndex in run.steps[stepIndex].attachments.indices {
                run.steps[stepIndex].attachments[attachmentIndex].messageID = messageID
            }
        }
        let lines = run.steps.map { step -> String in
            let choice = step.selectedOptionID.map { " [\($0)]" } ?? ""
            let comment = step.comment.nilIfBlank.map { ": \($0)" } ?? ""
            return "\(step.id) — \(step.title): \(step.verdict ?? step.state.rawValue)\(choice)\(comment)"
        }
        run.state = .submitted
        run.submittedAt = Date()
        value.reviewRun = run
        value.state = .awaitingModel
        let message = FeedbackMessage(
            id: messageID,
            feedbackThreadID: value.id,
            sequence: value.lastSequence + 1,
            author: .human,
            body: lines.joined(separator: "\n"),
            createdAt: Date(),
            interaction: nil,
            attachments: run.steps.flatMap(\.attachments),
            surfaceDirective: nil,
            inReplyTo: nil,
            idempotencyKey: "review-run-submit-\(run.id)",
            selectedOptionID: nil
        )
        do {
            try FeedbackThreadStore.appendMessage(message, to: &value)
            FeedbackThreadStore.appendEvent("review-run-submitted", feedbackThreadID: value.id, values: ["reviewRunID": run.id, "messageID": messageID])
            reload()
        } catch { statusMessage = error.localizedDescription }
    }

    private func updateSelectedReviewStep(_ update: (inout ReviewStep) -> Void) {
        guard var value = activeFeedbackThread, var run = value.reviewRun,
              run.state == .active,
              let stepID = selectedReviewStep?.id,
              let index = run.steps.firstIndex(where: { $0.id == stepID }) else { return }
        update(&run.steps[index])
        reconcileReviewDependencies(&run)
        value.reviewRun = run
        value.updatedAt = Date()
        value.revision += 1
        do {
            try FeedbackThreadStore.save(value)
            activeFeedbackThread = value
            FeedbackThreadStore.appendEvent("review-step-updated", feedbackThreadID: value.id, values: ["reviewRunID": run.id, "reviewStepID": stepID])
        } catch { statusMessage = error.localizedDescription }
    }

    private func reconcileReviewDependencies(_ run: inout ReviewRun) {
        var changed = true
        while changed {
            changed = false
            let states = Dictionary(uniqueKeysWithValues: run.steps.map { ($0.id, $0.state) })
            for index in run.steps.indices where run.steps[index].state == .locked {
                let prerequisiteStates = run.steps[index].prerequisiteIDs.compactMap { states[$0] }
                if prerequisiteStates.contains(where: { [.failed, .skipped, .blocked].contains($0) }) {
                    run.steps[index].state = .blocked
                    run.steps[index].verdict = ReviewStepState.blocked.rawValue
                    run.steps[index].blockedReason = "A prerequisite was not accepted."
                    run.steps[index].completedAt = Date()
                    changed = true
                } else if prerequisiteStates.count == run.steps[index].prerequisiteIDs.count,
                          prerequisiteStates.allSatisfy({ $0 == .passed }) {
                    run.steps[index].state = .ready
                    changed = true
                }
            }
        }
    }

    private func selectNextReadyReviewStep() {
        guard let run = activeReviewRun else { return }
        if let next = run.steps.first(where: { $0.state == .ready || $0.state == .inProgress }) {
            selectReviewStep(next.id)
        }
    }

    private func persistReviewCapture() {
        guard var value = activeFeedbackThread, var run = value.reviewRun,
              let capture = pendingCapture, capture.feedbackThreadID == value.id,
              let stepID = capture.reviewStepID,
              let index = run.steps.firstIndex(where: { $0.id == stepID }) else { return }
        let attachmentID = "feedback-attachment-\(UUID().uuidString.lowercased())"
        let directory = FeedbackThreadStore.attachmentDirectory(feedbackThreadID: value.id)
        let cleanURL = directory.appendingPathComponent("\(attachmentID)-clean.png")
        let annotatedURL = directory.appendingPathComponent("\(attachmentID)-annotated.png")
        let attachment = FeedbackAttachment(
            id: attachmentID,
            messageID: "review-run-draft",
            kind: "annotated-screenshot",
            cleanPath: "attachments/\(cleanURL.lastPathComponent)",
            annotatedPath: "attachments/\(annotatedURL.lastPathComponent)",
            caption: stepID,
            pixelWidth: capture.cleanImage.cgImage?.width ?? Int(capture.cleanImage.size.width * capture.cleanImage.scale),
            pixelHeight: capture.cleanImage.cgImage?.height ?? Int(capture.cleanImage.size.height * capture.cleanImage.scale),
            orientation: capture.cleanImage.size.width >= capture.cleanImage.size.height ? "landscape" : "portrait",
            scenario: run.steps[index].scenario,
            surfaceRevision: value.surfaceRevision,
            createdAt: Date()
        )
        do {
            guard let cleanData = capture.cleanImage.pngData(), let annotatedData = capture.annotatedImage.pngData() else {
                statusMessage = "Could not encode viewport capture."
                return
            }
            try cleanData.write(to: cleanURL, options: .atomic)
            try annotatedData.write(to: annotatedURL, options: .atomic)
            run.steps[index].attachments.append(attachment)
            if run.steps[index].state == .ready { run.steps[index].state = .inProgress }
            value.reviewRun = run
            value.updatedAt = Date()
            value.revision += 1
            try FeedbackThreadStore.save(value)
            activeFeedbackThread = value
            pendingCapture = nil
            FeedbackThreadStore.appendEvent("review-step-annotation-attached", feedbackThreadID: value.id, values: ["reviewRunID": run.id, "reviewStepID": stepID, "attachmentID": attachmentID])
        } catch {
            try? FileManager.default.removeItem(at: cleanURL)
            try? FileManager.default.removeItem(at: annotatedURL)
            statusMessage = error.localizedDescription
        }
    }

    private var activeDraft: ComposerDraft {
        guard let id = activeFeedbackThread?.id else { return ComposerDraft() }
        return composerDrafts[id] ?? ComposerDraft()
    }

    private func updateActiveDraft(_ update: (inout ComposerDraft) -> Void) {
        guard let id = activeFeedbackThread?.id else { return }
        var draft = composerDrafts[id] ?? ComposerDraft()
        update(&draft)
        composerDrafts[id] = draft
    }

    @discardableResult
    private func appendHumanMessage(body: String, selectedOptionID: String?, answering questionID: String?) -> Bool {
        guard var value = activeFeedbackThread else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let capture = pendingCapture.flatMap { $0.feedbackThreadID == value.id ? $0 : nil }
        guard !trimmed.isEmpty || selectedOptionID != nil || capture != nil else { return false }
        let messageID = "feedback-message-\(UUID().uuidString.lowercased())"
        let attachmentID = capture.map { _ in "feedback-attachment-\(UUID().uuidString.lowercased())" }
        let directory = FeedbackThreadStore.attachmentDirectory(feedbackThreadID: value.id)
        let cleanURL = attachmentID.map { directory.appendingPathComponent("\($0)-clean.png") }
        let annotatedURL = attachmentID.map { directory.appendingPathComponent("\($0)-annotated.png") }
        let attachment: FeedbackAttachment? = capture.flatMap { capture in
            guard let attachmentID, let cleanURL, let annotatedURL else { return nil }
            return FeedbackAttachment(
                id: attachmentID,
                messageID: messageID,
                kind: "annotated-screenshot",
                cleanPath: "attachments/\(cleanURL.lastPathComponent)",
                annotatedPath: "attachments/\(annotatedURL.lastPathComponent)",
                caption: nil,
                pixelWidth: capture.cleanImage.cgImage?.width ?? Int(capture.cleanImage.size.width * capture.cleanImage.scale),
                pixelHeight: capture.cleanImage.cgImage?.height ?? Int(capture.cleanImage.size.height * capture.cleanImage.scale),
                orientation: capture.cleanImage.size.width >= capture.cleanImage.size.height ? "landscape" : "portrait",
                scenario: value.scenario,
                surfaceRevision: value.surfaceRevision,
                createdAt: Date()
            )
        }
        let idempotencyKey = "human-reply-\(UUID().uuidString.lowercased())"
        let message = FeedbackMessage(
            id: messageID,
            feedbackThreadID: value.id,
            sequence: value.lastSequence + 1,
            author: .human,
            body: trimmed.nilIfBlank,
            createdAt: Date(),
            interaction: nil,
            attachments: attachment.map { [$0] } ?? [],
            surfaceDirective: nil,
            inReplyTo: questionID,
            idempotencyKey: idempotencyKey,
            selectedOptionID: selectedOptionID
        )
        value.state = .awaitingModel
        do {
            if let capture, let cleanURL, let annotatedURL {
                guard let cleanData = capture.cleanImage.pngData(), let annotatedData = capture.annotatedImage.pngData() else {
                    statusMessage = "Could not encode viewport capture."
                    return false
                }
                try cleanData.write(to: cleanURL, options: .atomic)
                try annotatedData.write(to: annotatedURL, options: .atomic)
            }
            try FeedbackThreadStore.appendMessage(message, to: &value)
            FeedbackThreadStore.appendEvent("message-posted", feedbackThreadID: value.id, values: ["messageID": message.id, "author": "human"])
            if let attachmentID {
                FeedbackThreadStore.appendEvent("annotated-screenshot-sent", feedbackThreadID: value.id, values: ["attachmentID": attachmentID, "messageID": messageID])
                pendingCapture = nil
            }
            reload()
            return true
        } catch {
            if let cleanURL { try? FileManager.default.removeItem(at: cleanURL) }
            if let annotatedURL { try? FileManager.default.removeItem(at: annotatedURL) }
            statusMessage = error.localizedDescription
            return false
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
