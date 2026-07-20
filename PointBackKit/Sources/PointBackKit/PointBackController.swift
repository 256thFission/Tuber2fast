import Combine
import CoreGraphics
import Foundation

@MainActor
public final class PointBackController: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case capturing
        case selected(UUID)
        case submitting(UUID)
        case receiving(UUID)
        case completed(UUID)
        case failed(UUID, recoverable: Bool)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var selection: SelectionArtifact?
    @Published public private(set) var pins: [Pin] = []
    @Published public private(set) var status = "Draw a lasso to investigate"
    @Published public private(set) var expandedPinID: UUID?
    @Published public private(set) var presentedConversationID: UUID?
    @Published public private(set) var conversations: [UUID: PinConversation] = [:]
    @Published public private(set) var conversationStatus: [UUID: String] = [:]
    @Published public private(set) var hostRevision = 0

    private let host: any CanvasHost
    private let agent: any AgentClient
    private let eventHandler: @MainActor (PointBackEvent) -> Void
    private let threadID: UUID
    private var retainedConversationID: String?
    private var investigationTask: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?
    private var hostTask: Task<Void, Never>?
    private var submittedIntent: InvestigationIntent?
    private var liveSelectionsByThread: [UUID: SelectionArtifact] = [:]
    private var activeConversationRequestIDs: [UUID: UUID] = [:]
    private var lastQuestions: [UUID: String] = [:]

    public init(
        host: any CanvasHost,
        agent: any AgentClient,
        threadID: UUID = UUID(),
        onEvent: @escaping @MainActor (PointBackEvent) -> Void = { _ in }
    ) {
        self.host = host
        self.agent = agent
        self.threadID = threadID
        eventHandler = onEvent
        observeHost()
    }

    deinit {
        hostTask?.cancel()
        investigationTask?.cancel()
        conversationTask?.cancel()
    }

    public var snapshot: PointBackSnapshot {
        let conversation = presentedConversationID.flatMap { conversations[$0] }
        return PointBackSnapshot(
            status: status,
            selection: selection,
            pins: pins,
            conversationPanelOpen: conversation != nil,
            conversationID: conversation?.conversationID,
            conversationTurnCount: conversation?.turns.count,
            conversationReplyStatus: presentedConversationID.flatMap { conversationStatus[$0] },
            conversationSourcePinID: conversation?.sourcePinID,
            archive: PointBackArchive(
                pins: pins,
                conversations: conversations.values.sorted { $0.id.uuidString < $1.id.uuidString }
            )
        )
    }

    public func restore(_ archive: PointBackArchive) {
        guard pins.isEmpty, conversations.isEmpty else { return }
        pins = archive.pins
        conversations = Dictionary(uniqueKeysWithValues: archive.conversations.map { ($0.id, $0) })
        for conversation in archive.conversations {
            conversationStatus[conversation.id] = "Ask a follow-up about this Pin"
        }
        publishState()
    }

    public func receiveWindowPath(_ windowPoints: [CGPoint]) async {
        let converted = windowPoints.compactMap(host.unprojectFromWindow)
        guard converted.count == windowPoints.count,
              let pageID = converted.first?.pageID,
              converted.allSatisfy({ $0.pageID == pageID }) else {
            rejectSelection()
            return
        }
        await receiveNormalizedPath(converted.map(\.point), on: pageID)
    }

    public func receiveNormalizedPath(_ path: [PagePoint], on pageID: UUID? = nil) async {
        guard let pageID = pageID ?? host.currentPageID,
              let closed = LassoGeometry.closedPath(from: path),
              let bounds = LassoGeometry.pageBounds(of: closed),
              let page = host.pageDescriptor(id: pageID),
              let crop = await host.snapshot(bounds, on: pageID), crop.isValid else {
            rejectSelection()
            return
        }

        investigationTask?.cancel()
        conversationTask?.cancel()
        let context = host.selectionContext(on: pageID)
        let artifact = SelectionArtifact(
            documentID: context.sourceDocumentID ?? host.documentID,
            pageID: pageID,
            pageIndex: page.index,
            lassoPath: closed,
            pageBounds: bounds,
            crop: crop,
            context: context
        )
        selection = artifact
        phase = .selected(artifact.id)
        status = "Selection ready"
        retainedConversationID = nil
        expandedPinID = nil
        presentedConversationID = nil
        publish(.selectionCreated(artifact))
    }

    public func submit(_ intent: InvestigationIntent) {
        guard let selection, case .selected(selection.id) = phase else { return }
        let request = InvestigationRequest(intent: intent, selection: selection)
        submittedIntent = intent
        phase = .submitting(request.id)
        status = intent.submissionLabel
        run(request)
    }

    public func cancelSelection() {
        investigationTask?.cancel()
        conversationTask?.cancel()
        selection = nil
        retainedConversationID = nil
        phase = .idle
        status = "Selection cancelled"
        expandedPinID = nil
        presentedConversationID = nil
        publishState()
    }

    public func cancelInvestigation() {
        guard let id = activeInvestigationID else { return }
        investigationTask?.cancel()
        Task { await agent.cancel(investigationID: id) }
        if let selection {
            phase = .selected(selection.id)
        } else {
            phase = .idle
        }
        status = "Investigation cancelled"
        publishState()
    }

    public func retryInvestigation() {
        guard let intent = submittedIntent, let selection else { return }
        phase = .selected(selection.id)
        submit(intent)
    }

    public func togglePin(_ pinID: UUID) {
        expandedPinID = expandedPinID == pinID ? nil : pinID
        publishState()
    }

    public func openConversation(for pinID: UUID) {
        guard let pin = pins.first(where: { $0.id == pinID && $0.status == .complete }),
              let selection, let retainedConversationID else { return }
        if conversations[pin.threadID] == nil {
            conversations[pin.threadID] = PinConversation(
                id: pin.threadID,
                sourcePinID: pin.id,
                selection: SelectionArtifactRecord(selection),
                conversationID: retainedConversationID,
                turns: [ConversationTurn(role: .assistant, text: pin.body)]
            )
            liveSelectionsByThread[pin.threadID] = selection
            conversationStatus[pin.threadID] = "Ask a follow-up about this Pin"
        } else if liveSelectionsByThread[pin.threadID] == nil,
                  let record = conversations[pin.threadID]?.selection {
            rehydrateSelection(record, threadID: pin.threadID)
        }
        presentedConversationID = pin.threadID
        expandedPinID = nil
        publish(.conversationOpened(pinID: pin.id))
    }

    private func rehydrateSelection(_ record: SelectionArtifactRecord, threadID: UUID) {
        Task { @MainActor [weak self] in
            guard let self,
                  let crop = await host.snapshot(record.pageBounds, on: record.pageID),
                  crop.isValid else { return }
            liveSelectionsByThread[threadID] = SelectionArtifact(
                documentID: record.documentID,
                pageID: record.pageID,
                pageIndex: record.pageIndex,
                lassoPath: record.lassoPath,
                pageBounds: record.pageBounds,
                crop: crop,
                context: record.context
            )
        }
    }

    public func dismissConversation() {
        presentedConversationID = nil
        publishState()
    }

    public func submitFollowUp(_ question: String, threadID: UUID) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty,
              var conversation = conversations[threadID],
              activeConversationRequestIDs[threadID] == nil,
              let selection = liveSelectionsByThread[threadID] else { return }
        let request = InvestigationRequest(
            intent: .ask(question: question),
            selection: selection,
            conversationID: conversation.conversationID
        )
        conversation.turns.append(ConversationTurn(role: .user, text: question))
        conversations[threadID] = conversation
        activeConversationRequestIDs[threadID] = request.id
        lastQuestions[threadID] = question
        conversationStatus[threadID] = "Sending follow-up…"
        runFollowUp(request, threadID: threadID)
        publishState()
    }

    public func cancelFollowUp(threadID: UUID) {
        guard let requestID = activeConversationRequestIDs[threadID] else { return }
        conversationTask?.cancel()
        Task { await agent.cancel(investigationID: requestID) }
        activeConversationRequestIDs[threadID] = nil
        conversationStatus[threadID] = "Follow-up cancelled"
        publishState()
    }

    public func retryFollowUp(threadID: UUID) {
        guard let question = lastQuestions[threadID] else { return }
        submitFollowUp(question, threadID: threadID)
    }

    private func observeHost() {
        hostTask = Task { @MainActor [weak self, host] in
            for await _ in host.changes {
                guard let self, !Task.isCancelled else { return }
                self.hostRevision &+= 1
                self.publishState()
            }
        }
    }

    private func rejectSelection() {
        phase = .idle
        status = "Close the lasso around a visible part of one page"
        publish(.selectionRejected)
    }

    private var activeInvestigationID: UUID? {
        switch phase {
        case let .submitting(id), let .receiving(id): id
        default: nil
        }
    }

    private func run(_ request: InvestigationRequest) {
        investigationTask?.cancel()
        investigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in agent.investigate(request) {
                    guard !Task.isCancelled, activeInvestigationID == request.id else { return }
                    consume(event, investigationID: request.id)
                }
            } catch {
                guard activeInvestigationID == request.id else { return }
                phase = .failed(request.id, recoverable: true)
                status = "Investigation failed"
                publishState()
            }
        }
    }

    private func consume(_ event: AgentEvent, investigationID: UUID) {
        guard activeInvestigationID == investigationID else { return }
        switch event {
        case .accepted:
            phase = .receiving(investigationID)
            status = "Request accepted"
        case .inspectingSelection: status = "Inspecting selection…"
        case let .toolStarted(tool): status = tool.userVisibleStatus
        case .toolFinished: break
        case let .pinStarted(draft): upsert(draft, status: .streaming)
        case let .pinDelta(id, delta):
            if let index = pins.firstIndex(where: { $0.id == id }) { pins[index].body += delta }
        case let .pinCompleted(draft): upsert(draft, status: .complete)
        case let .completed(conversationID):
            retainedConversationID = conversationID
            phase = .completed(investigationID)
            status = "Proposed Pin ready"
        case let .failed(failure):
            phase = .failed(investigationID, recoverable: failure.recoverable)
            status = failure.userMessage
        }
        publishState()
    }

    private func upsert(_ draft: PinDraft, status pinStatus: AnnotationStatus) {
        guard let selection, let pin = makePin(from: draft, selection: selection, status: pinStatus) else {
            if let id = activeInvestigationID {
                phase = .failed(id, recoverable: true)
                status = "The agent returned an invalid Pin location."
            }
            return
        }
        pins.removeAll { $0.id == pin.id }
        pins.append(pin)
        status = pinStatus == .complete ? "Proposed Pin ready" : "Receiving a proposed Pin…"
        eventHandler(.pinChanged(pin))
    }

    private func makePin(
        from draft: PinDraft,
        selection: SelectionArtifact,
        status: AnnotationStatus
    ) -> Pin? {
        guard draft.target.isValid else { return nil }
        let target = LassoGeometry.cropPointToPage(draft.target, cropBounds: selection.pageBounds)
        guard target.isValid else { return nil }
        let region = draft.targetRegion.map {
            LassoGeometry.cropRectToPage($0, cropBounds: selection.pageBounds)
        }
        return Pin(
            id: draft.id,
            pageID: selection.pageID,
            threadID: threadID,
            target: target,
            targetRegion: region,
            kind: draft.kind,
            teaser: draft.teaser,
            body: draft.body,
            citations: draft.citations,
            status: status
        )
    }

    private func runFollowUp(_ request: InvestigationRequest, threadID: UUID) {
        conversationTask?.cancel()
        conversationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in agent.investigate(request) {
                    guard !Task.isCancelled,
                          activeConversationRequestIDs[threadID] == request.id else { return }
                    consumeFollowUp(event, requestID: request.id, threadID: threadID)
                }
            } catch {
                failFollowUp(threadID: threadID, message: "Follow-up failed")
            }
        }
    }

    private func consumeFollowUp(_ event: AgentEvent, requestID: UUID, threadID: UUID) {
        guard var conversation = conversations[threadID],
              activeConversationRequestIDs[threadID] == requestID,
              let selection = liveSelectionsByThread[threadID] else { return }
        switch event {
        case .accepted: conversationStatus[threadID] = "Follow-up accepted"
        case .inspectingSelection: conversationStatus[threadID] = "Re-reading the selection…"
        case let .toolStarted(tool): conversationStatus[threadID] = tool.userVisibleStatus
        case .toolFinished: break
        case let .pinStarted(draft):
            guard let pin = makePin(from: draft, selection: selection, status: .streaming) else {
                failFollowUp(threadID: threadID, message: "The follow-up returned an invalid Pin.")
                return
            }
            pins.removeAll { $0.id == pin.id }
            pins.append(pin)
            conversation.turns.append(ConversationTurn(role: .assistant, text: draft.body, isStreaming: true))
            conversationStatus[threadID] = "Streaming reply…"
        case let .pinDelta(id, delta):
            if let index = pins.firstIndex(where: { $0.id == id }) { pins[index].body += delta }
            if let index = conversation.turns.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                conversation.turns[index].text += delta
            }
        case let .pinCompleted(draft):
            guard let pin = makePin(from: draft, selection: selection, status: .complete) else {
                failFollowUp(threadID: threadID, message: "The follow-up returned an invalid Pin.")
                return
            }
            pins.removeAll { $0.id == pin.id }
            pins.append(pin)
            if let index = conversation.turns.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                conversation.turns[index].text = draft.body
                conversation.turns[index].isStreaming = false
            }
        case let .completed(conversationID):
            conversation.conversationID = conversationID ?? conversation.conversationID
            activeConversationRequestIDs[threadID] = nil
            conversationStatus[threadID] = "Follow-up reply ready"
        case let .failed(failure):
            activeConversationRequestIDs[threadID] = nil
            conversationStatus[threadID] = failure.userMessage
        }
        conversations[threadID] = conversation
        publishState()
    }

    private func failFollowUp(threadID: UUID, message: String) {
        activeConversationRequestIDs[threadID] = nil
        conversationStatus[threadID] = message
        publishState()
    }

    private func publish(_ event: PointBackEvent) {
        eventHandler(event)
        if case .stateChanged = event { return }
        eventHandler(.stateChanged(snapshot))
    }

    private func publishState() {
        eventHandler(.stateChanged(snapshot))
    }
}

private extension InvestigationIntent {
    var submissionLabel: String {
        switch self {
        case .explain: "Submitting Explain"
        case .check: "Submitting Check"
        case let .ask(question): "Submitting Ask: \(question)"
        }
    }
}
