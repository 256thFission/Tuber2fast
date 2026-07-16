import Combine
import PencilKit
import SwiftUI

#if DEBUG
@MainActor
final class FeedbackThreadSession: ObservableObject {
    struct PendingCapture {
        let feedbackThreadID: String
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
    @Published var statusMessage: String?

    private var pollTask: Task<Void, Never>?
    private var resetFeedbackTask: Task<Void, Never>?

    init() {
        reload()
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

    var reopenCandidate: FeedbackThread? {
        feedbackThreads
            .filter { $0.state == .blocked || $0.state == .resolved }
            .max { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
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

    func reload() {
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
    }

    func sendReply(_ body: String) {
        appendHumanMessage(body: body, selectedOptionID: nil, answering: activeQuestion?.interaction?.kind == .freeText ? activeQuestion?.id : nil)
    }

    func answer(_ questionMessage: FeedbackMessage, optionID: String, comment: String) {
        guard questionMessage.interaction?.kind == .singleChoice, activeQuestion?.id == questionMessage.id else { return }
        appendHumanMessage(body: comment, selectedOptionID: optionID, answering: questionMessage.id)
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

    func reopen(_ feedbackThread: FeedbackThread) {
        guard feedbackThread.state == .blocked || feedbackThread.state == .resolved else { return }
        var value = feedbackThread
        let hasActive = feedbackThreads.contains(where: { $0.state.ownsDeviceSlot })
        value.state = hasActive ? .queued : .open
        value.queueSequence = (feedbackThreads.map(\.queueSequence).min() ?? 0) - 1
        value.lastConsumedSequence = value.lastSequence
        value.updatedAt = Date()
        value.revision += 1
        do {
            try FeedbackThreadStore.save(value)
            FeedbackThreadStore.appendEvent(
                "thread-reopened",
                feedbackThreadID: value.id,
                values: ["actor": "human", "priority": "true", "state": value.state.rawValue]
            )
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
        appendHumanMessage(body: body, selectedOptionID: preference.id, answering: activeQuestion?.id)
        FeedbackThreadStore.appendEvent("comparison-preference", feedbackThreadID: id, values: ["comparisonID": "pin-presentation-01", "preference": preference.id])
    }

    func requestCapture() {
        guard activeFeedbackThread != nil else { return }
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
        pendingCapture = PendingCapture(feedbackThreadID: value.id, cleanImage: cleanImage, annotatedImage: annotated)
        capturedImage = nil
        statusMessage = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.isPresentingFullThread = true
        }
    }

    func removePendingCapture() {
        pendingCapture = nil
    }

    private func appendHumanMessage(body: String, selectedOptionID: String?, answering questionID: String?) {
        guard var value = activeFeedbackThread else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let capture = pendingCapture.flatMap { $0.feedbackThreadID == value.id ? $0 : nil }
        guard !trimmed.isEmpty || selectedOptionID != nil || capture != nil else { return }
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
                    return
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
        } catch {
            if let cleanURL { try? FileManager.default.removeItem(at: cleanURL) }
            if let annotatedURL { try? FileManager.default.removeItem(at: annotatedURL) }
            statusMessage = error.localizedDescription
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
