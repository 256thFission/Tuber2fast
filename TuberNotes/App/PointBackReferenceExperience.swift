import PDFKit
import PencilKit
import PointBackKit
import SwiftUI

/// Thin reference-host composition. All selection, agent, Pin, and conversation behavior is in
/// PointBackKit; this view only supplies SpatialCanvas and verifier evidence plumbing.
struct PointBackReferenceExperience: View {
    let scenario: DevelopmentScenario
    let document: NotebookDocument
    @Binding var currentPageID: UUID?
    let pdfDocument: PDFDocument?
    let initialDrawingData: [UUID: Data]
    let penFixturesByPageID: [UUID: PenFixture]
    let initialLassoPathsByPageID: [UUID: [PageNormalizedPoint]]
    let onDrawingChanged: (UUID, Data) -> Void
    let onDrawingSnapshot: (UUID, PKDrawing, CGSize) -> Void

    @StateObject private var host: ReferenceCanvasHost
    @State private var kitSnapshot: PointBackKit.PointBackSnapshot?
    @State private var pageReturnTask: Task<Void, Never>?
    @State private var conversationPageReturnVerified = false

    init(
        scenario: DevelopmentScenario,
        document: NotebookDocument,
        currentPageID: Binding<UUID?>,
        pdfDocument: PDFDocument?,
        initialDrawingData: [UUID: Data],
        penFixturesByPageID: [UUID: PenFixture],
        initialLassoPathsByPageID: [UUID: [PageNormalizedPoint]],
        onDrawingChanged: @escaping (UUID, Data) -> Void,
        onDrawingSnapshot: @escaping (UUID, PKDrawing, CGSize) -> Void
    ) {
        self.scenario = scenario
        self.document = document
        _currentPageID = currentPageID
        self.pdfDocument = pdfDocument
        self.initialDrawingData = initialDrawingData
        self.penFixturesByPageID = penFixturesByPageID
        self.initialLassoPathsByPageID = initialLassoPathsByPageID
        self.onDrawingChanged = onDrawingChanged
        self.onDrawingSnapshot = onDrawingSnapshot
        _host = StateObject(wrappedValue: ReferenceCanvasHost(
            document: document,
            currentPageID: currentPageID.wrappedValue,
            pdfDocument: pdfDocument
        ))
    }

    var body: some View {
        SpatialCanvasView(
            document: document,
            currentPageID: $currentPageID,
            pdfDocument: pdfDocument,
            toolMode: .ink,
            initialDrawingData: initialDrawingData,
            penFixturesByPageID: penFixturesByPageID,
            initialLassoPathsByPageID: [:],
            onDrawingChanged: onDrawingChanged,
            onDrawingSnapshot: { pageID, drawing, size in
                onDrawingSnapshot(pageID, drawing, size)
                host.updateDrawing(pageID: pageID, drawing: drawing, size: size)
            },
            onViewportChanged: host.updateViewport
        )
        .pointBack(
            host: host,
            agent: PointBackKit.RecordedAgentClient(scenario: recordedScenario),
            configuration: configuration,
            onEvent: receive
        )
        .accessibilityIdentifier("pointback-reference-experience")
        .onAppear {
            host.update(document: document, pdfDocument: pdfDocument)
            host.updateCurrentPage(currentPageID)
        }
        .onChange(of: currentPageID) { _, pageID in
            host.updateCurrentPage(pageID)
            recordRuntimeEvidence()
        }
        .onDisappear { pageReturnTask?.cancel() }
    }

    private var configuration: PointBackConfiguration {
        PointBackConfiguration(
            seededLassoPath: shouldAutomate
                ? currentPageID.flatMap { initialLassoPathsByPageID[$0] }?.map {
                    PointBackKit.PagePoint(x: $0.x, y: $0.y)
                }
                : nil,
            automaticIntent: shouldAutomate ? .check : nil,
            automaticFollowUpQuestion: scenario == .pinConversation && shouldAutomate
                ? "Why does the sign change?"
                : nil
        )
    }

    private var shouldAutomate: Bool {
#if DEBUG
        scenario != .heroRecorded
            || ProcessInfo.processInfo.environment["TUBER_VERIFY_NONCE"] != nil
#else
        false
#endif
    }

    private var recordedScenario: PointBackKit.RecordedAgentScenario {
        switch scenario {
        case .agentRecordedRetrieval: .retrieval
        case .agentRecordedFailure:
            .failure(.init(
                code: .unavailable,
                userMessage: "The recorded provider is temporarily unavailable.",
                recoverable: true
            ))
        default: .success
        }
    }

    private func receive(_ event: PointBackKit.PointBackEvent) {
        switch event {
        case let .selectionCreated(artifact): persistSelectionCrop(artifact)
        case let .stateChanged(snapshot):
            kitSnapshot = snapshot
            automatePageReturnIfNeeded(snapshot)
            recordRuntimeEvidence(snapshot)
        default: break
        }
    }

    private func automatePageReturnIfNeeded(_ snapshot: PointBackKit.PointBackSnapshot) {
#if DEBUG
        guard scenario == .pinConversation,
              shouldAutomate,
              !conversationPageReturnVerified,
              pageReturnTask == nil,
              snapshot.conversationReplyStatus == "Follow-up reply ready",
              let selectedPageID = snapshot.selection?.pageID,
              let awayPageID = document.pages.first(where: { $0.id != selectedPageID })?.id else { return }
        pageReturnTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            currentPageID = awayPageID
            try? await Task.sleep(for: .milliseconds(120))
            currentPageID = selectedPageID
            try? await Task.sleep(for: .milliseconds(120))
            conversationPageReturnVerified = kitSnapshot?.conversationPanelOpen == true
                && kitSnapshot?.conversationReplyStatus == "Follow-up reply ready"
            recordRuntimeEvidence()
        }
#endif
    }

    private func persistSelectionCrop(_ artifact: PointBackKit.SelectionArtifact) {
#if DEBUG
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let directory = documents.appendingPathComponent("developer-evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? artifact.crop.imageData.write(
            to: directory.appendingPathComponent("lasso-selection-crop.png"),
            options: .atomic
        )
#endif
    }

    private func recordRuntimeEvidence(_ snapshot: PointBackKit.PointBackSnapshot? = nil) {
#if DEBUG
        let snapshot = snapshot ?? kitSnapshot
        let currentIndex = currentPageID.flatMap { selectedID in
            document.pages.firstIndex(where: { $0.id == selectedID })
        }
        DevelopmentRuntimeEvidence.record(
            scenario: scenario,
            surfaceKind: .pointBackKit,
            pageCount: document.pages.count,
            currentPageID: currentPageID,
            currentPageIndex: currentIndex,
            renderedPenFixtureName: currentPageID.flatMap { penFixturesByPageID[$0]?.name },
            renderedAnnotationIDs: snapshot?.pins.map(\.id) ?? [],
            heroStatus: snapshot?.status,
            selectionArtifact: snapshot?.selection.map(legacySelection),
            conversationPanelOpen: snapshot?.conversationPanelOpen ?? false,
            conversationID: snapshot?.conversationID,
            conversationTurnCount: snapshot?.conversationTurnCount,
            conversationReplyStatus: snapshot?.conversationReplyStatus,
            conversationPageReturnVerified: conversationPageReturnVerified,
            conversationSourcePinID: snapshot?.conversationSourcePinID
        )
#endif
    }

    private func legacySelection(_ artifact: PointBackKit.SelectionArtifact) -> SelectionArtifact {
        SelectionArtifact(
            id: artifact.id,
            documentID: artifact.documentID,
            pageID: artifact.pageID,
            pageIndex: artifact.pageIndex,
            lassoPath: artifact.lassoPath.map { PageNormalizedPoint(x: $0.x, y: $0.y) },
            pageBounds: PageNormalizedRect(
                x: artifact.pageBounds.x,
                y: artifact.pageBounds.y,
                width: artifact.pageBounds.width,
                height: artifact.pageBounds.height
            ),
            crop: SelectionCrop(
                imageData: artifact.crop.imageData,
                mediaType: artifact.crop.mediaType,
                pixelWidth: artifact.crop.pixelWidth,
                pixelHeight: artifact.crop.pixelHeight,
                pageBounds: PageNormalizedRect(
                    x: artifact.crop.pageBounds.x,
                    y: artifact.crop.pageBounds.y,
                    width: artifact.crop.pageBounds.width,
                    height: artifact.crop.pageBounds.height
                )
            ),
            context: SelectionContext(
                documentTitle: artifact.context.documentTitle,
                sourceDocumentID: artifact.context.sourceDocumentID,
                pageNumber: artifact.context.pageNumber,
                nearbyText: artifact.context.nearbyText
            )
        )
    }
}
