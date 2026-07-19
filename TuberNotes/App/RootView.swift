import PDFKit
import PencilKit
import SwiftUI

struct RootView: View {
    let scenario: DevelopmentScenario
    @State private var displayedScenario: DevelopmentScenario
    @State private var document: NotebookDocument?
    @State private var currentPageID: UUID?
    @State private var surfaceGeneration = 0
#if DEBUG
    @StateObject private var agentSession = AgentInteractionSession()
    @StateObject private var feedbackSession = FeedbackThreadSession()
#endif

    init(scenario: DevelopmentScenario) {
        self.scenario = scenario
        _displayedScenario = State(initialValue: scenario)
        _document = State(initialValue: scenario.fixture.document)
        _currentPageID = State(initialValue: scenario.fixture.currentPageID)
    }

    var body: some View {
        NavigationStack {
            scenarioSurface
#if DEBUG
                .id(surfaceGeneration)
                .environmentObject(agentSession)
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 8) {
                        FeedbackThreadBar(session: feedbackSession)
                        AgentRequestBanner(session: agentSession)
                    }
                    .opacity(feedbackSession.isCapturing ? 0 : 1)
                    .padding(.trailing, 20)
                    .padding(.top, 8)
                }
                .onChange(of: agentSession.resetGeneration) { _, _ in
                    resetScenarioSurface()
                }
                .onChange(of: agentSession.activeRequest?.id) { _, _ in
                    bindScenarioToActiveRequest()
                }
                .onChange(of: feedbackSession.activeFeedbackThread?.id) { _, _ in
                    bindScenarioToActiveRequest()
                }
                .onChange(of: feedbackSession.activeFeedbackThread?.scenario) { _, _ in
                    bindScenarioToActiveRequest()
                }
                .onChange(of: feedbackSession.resetGeneration) { _, _ in
                    resetScenarioSurface()
                }
                .onChange(of: feedbackSession.captureRequestGeneration) { _, _ in
                    captureViewportAfterOverlayDismissal()
                }
                .fullScreenCover(isPresented: annotationPresented) {
                    FeedbackAnnotationView(session: feedbackSession)
                }
#endif
            .navigationTitle("TuberNotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canAppendPage {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: appendNotebookPage) {
                            Label("Add Page", systemImage: "doc.badge.plus")
                        }
                        .accessibilityIdentifier("append-page")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(displayedScenario.displayName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("scenario-label")
                }
            }
        }
#if DEBUG
        .task(id: runtimeEvidenceFingerprint) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            recordRuntimeEvidence()
        }
#endif
        .onAppear {
            print("TuberNotes scenario=\(scenario.rawValue) pins=\(scenario.pins.count)")
#if DEBUG
            agentSession.reload()
            feedbackSession.reload()
            bindScenarioToActiveRequest()
#endif
        }
    }

    @ViewBuilder
    private var scenarioSurface: some View {
        switch displayedScenario {
        case .fakePin, .multiPin, .edgePins:
            standalonePinSurface
        case .blankCanvas, .pdfPages, .blankNotebook, .notebookPages, .inkPages, .pinDrift:
            standaloneSpatialSurface
        case .heroRecorded, .agentRecordedSuccess, .agentRecordedRetrieval, .agentRecordedFailure:
            RecordedHeroView(scenario: displayedScenario)
        case .lassoCrop:
            ContentUnavailableView(
                "Later milestone",
                systemImage: "hammer",
                description: Text(scenario.fixture.expectedState)
            )
        }
    }

    @ViewBuilder
    private var standaloneSpatialSurface: some View {
        if let document {
            SpatialCanvasView(
                document: document,
                currentPageID: $currentPageID,
                pdfDocument: pdfDocument(for: document),
                penFixturesByPageID: displayedScenario.fixture.penFixturesByPageID,
                pageOverlay: { page, projection in
                    AnyView(
                        PinOverlayView(
                            annotations: spatialAnnotations(for: page),
                            projectAnchor: { projection($0) }
                        )
                    )
                },
                onDrawingSnapshot: drawingSnapshotHandler,
                allowsDeterministicViewportTransition: displayedScenario == .pinDrift
            )
        }
    }

    private var standalonePinSurface: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: pinComparisonCornerRadius)
                    .fill(pinComparisonBackground)
                PinOverlayView(
                    annotations: standalonePinAnnotations,
                    projectAnchor: { point in
                        CGPoint(
                            x: point.x * proxy.size.width,
                            y: point.y * proxy.size.height
                        )
                    },
                    initiallyExpandedAnnotationID: displayedScenario == .fakePin
                        ? standalonePinAnnotations.first?.id
                        : nil
                )
            }
            // Keep fixed edge targets visible. Pins clamps labels, but never moves anchors;
            // clipping the entire overlay could cut a target marker at a rounded corner.
            .overlay {
                RoundedRectangle(cornerRadius: pinComparisonCornerRadius)
                    .stroke(pinComparisonBorder, lineWidth: pinComparisonBorderWidth)
            }
        }
        .padding(20)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("standalone-pin-surface")
    }

    private var standalonePinAnnotations: [PageAnnotation] {
        switch displayedScenario {
        case .fakePin: PinFixtures.fakePin
        case .multiPin: PinFixtures.multiPin
        case .edgePins: displayedScenario.fixture.annotations
        default: []
        }
    }

    private var canAppendPage: Bool {
        guard let document else { return false }
        if case .notebook = document.source { return true }
        return false
    }

    private func spatialAnnotations(for page: PageRecord) -> [PageAnnotation] {
        let fixtureAnnotations = displayedScenario.fixture.annotations.filter { $0.pageID == page.id }
        let fixtureIDs = Set(fixtureAnnotations.map(\.id))
        return page.annotations.filter { !fixtureIDs.contains($0.id) } + fixtureAnnotations
    }

    private func appendNotebookPage() {
        guard var document,
              case let .notebook(defaultPaperStyle) = document.source else { return }
        let pageID = UUID()
        document.pages.append(
            PageRecord(
                id: pageID,
                index: document.pages.count,
                background: .blank(style: defaultPaperStyle, dimensions: .tuberPortrait),
                inkReference: nil,
                annotations: []
            )
        )
        document.currentPageID = pageID
        self.document = document
        currentPageID = pageID
    }

    private func pdfDocument(for document: NotebookDocument) -> PDFDocument? {
        guard case .bundledPDF = document.source else { return nil }
        return SpatialCanvasFixtures.makeM0DemoPDF()
    }

#if DEBUG
    private func bindScenarioToActiveRequest() {
        let feedbackScenario = feedbackSession.activeFeedbackThread
            .flatMap { DevelopmentScenario(rawValue: $0.scenario) }
        let legacyScenario = agentSession.activeRequest?.scenario
            .flatMap { DevelopmentScenario(rawValue: $0) }
        let requestedScenario = feedbackScenario ?? legacyScenario ?? scenario
        displayedScenario = requestedScenario
        resetScenarioSurface()
    }

    private var annotationPresented: Binding<Bool> {
        Binding(
            get: { feedbackSession.capturedImage != nil },
            set: { if !$0 { feedbackSession.cancelCapture() } }
        )
    }

    private func captureViewportAfterOverlayDismissal() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: { $0.isKeyWindow }) else {
                feedbackSession.receiveCapturedImage(nil)
                return
            }
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            feedbackSession.receiveCapturedImage(image)
        }
    }
#endif

    private var pinComparisonBackground: Color {
#if DEBUG
        if feedbackSession.isLiveComparison && feedbackSession.activeVariant == "b" {
            return Color(red: 0.955, green: 0.975, blue: 1.0)
        }
#endif
        return Color(red: 0.992, green: 0.978, blue: 0.936)
    }

    private var pinComparisonCornerRadius: CGFloat {
#if DEBUG
        if feedbackSession.isLiveComparison && feedbackSession.activeVariant == "b" { return 8 }
#endif
        return 18
    }

    private var pinComparisonBorder: Color {
#if DEBUG
        if feedbackSession.isLiveComparison && feedbackSession.activeVariant == "b" { return .blue.opacity(0.32) }
#endif
        return .black.opacity(0.08)
    }

    private var pinComparisonBorderWidth: CGFloat {
#if DEBUG
        if feedbackSession.isLiveComparison && feedbackSession.activeVariant == "b" { return 2 }
#endif
        return 1
    }

    private func resetScenarioSurface() {
        document = displayedScenario.fixture.document
        currentPageID = displayedScenario.fixture.currentPageID
        surfaceGeneration += 1
    }

#if DEBUG
    private var runtimeEvidenceFingerprint: String {
        [
            displayedScenario.rawValue,
            currentPageID?.uuidString ?? "none",
            String(document?.pages.count ?? 0),
            displayedScenario.fixture.annotations.map(\.id.uuidString).sorted().joined(separator: ",")
        ].joined(separator: "|")
    }

    private func recordRuntimeEvidence() {
        guard let document else { return }
        let currentIndex = currentPageID.flatMap { selectedID in
            document.pages.firstIndex(where: { $0.id == selectedID })
        }
        let penFixtureName = currentPageID.flatMap {
            displayedScenario.fixture.penFixturesByPageID[$0]?.name
        }

        switch displayedScenario {
        case .pdfPages, .blankNotebook, .notebookPages, .inkPages, .pinDrift:
            let renderedAnnotations = currentPageID
                .flatMap { selectedID in document.pages.first(where: { $0.id == selectedID }) }
                .map(spatialAnnotations(for:)) ?? []
            DevelopmentRuntimeEvidence.record(
                scenario: displayedScenario,
                surfaceKind: .spatialCanvas,
                pageCount: document.pages.count,
                currentPageID: currentPageID,
                currentPageIndex: currentIndex,
                renderedPenFixtureName: penFixtureName,
                renderedAnnotationIDs: renderedAnnotations.map(\.id)
            )
        case .edgePins:
            DevelopmentRuntimeEvidence.record(
                scenario: displayedScenario,
                surfaceKind: .standalonePins,
                pageCount: document.pages.count,
                currentPageID: currentPageID,
                currentPageIndex: currentIndex,
                renderedPenFixtureName: nil,
                renderedAnnotationIDs: standalonePinAnnotations.map(\.id)
            )
        default:
            break
        }
    }
#endif

    private var drawingSnapshotHandler: (UUID, PKDrawing, CGSize) -> Void {
#if DEBUG
        { _, drawing, size in
            agentSession.handleDrawingChange(drawing: drawing, canvasSize: size)
        }
#else
        { _, _, _ in }
#endif
    }
}

private struct RecordedHeroView: View {
    private let scenario: DevelopmentScenario
    private let agent: any AgentClient
    private let documentID = UUID(uuidString: "70000000-0000-0000-0000-000000000010")!
    private let pageID = UUID(uuidString: "70000000-0000-0000-0000-000000000011")!
    private let threadID = UUID(uuidString: "70000000-0000-0000-0000-000000000013")!
    private let selectionBounds = PageNormalizedRect(x: 0.18, y: 0.24, width: 0.58, height: 0.38)

    @State private var lassoState: LassoState
    @State private var submittedIntent: InvestigationIntent?
    @State private var annotations: [PageAnnotation] = []
    @State private var status = "Selection ready"
    @State private var investigationTask: Task<Void, Never>?

    init(scenario: DevelopmentScenario) {
        self.scenario = scenario
        agent = RecordedAgentClient(scenario: Self.recordedScenario(for: scenario))
        _lassoState = State(initialValue: .selected(selectionID: Self.selectionID))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.992, green: 0.978, blue: 0.936)
                recordedWork
                selectionGlow

                PinOverlayView(
                    annotations: annotations,
                    projectAnchor: { point in
                        CGPoint(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                    },
                    initiallyExpandedAnnotationID: annotations.first?.id
                )

                if case .selected = lassoState {
                    InvestigationActionStrip(
                        onInvestigate: submit,
                        onCancel: cancelSelection
                    )
                    .position(
                        x: proxy.size.width / 2,
                        y: max(42, selectionBounds.y * proxy.size.height - 34)
                    )
                } else if isInvestigationActive {
                    progressStatus
                } else if case .failed(_, let recoverable) = lassoState {
                    terminalStatus(showRetry: recoverable)
                } else if case .completed = lassoState {
                    terminalStatus(showRetry: true)
                }

                if case .idle = lassoState {
                    Button("Restore fixture selection", action: restoreSelection)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("restore-fixture-selection")
                }
            }
            .accessibilityIdentifier("recorded-hero-surface")
        }
        .padding(20)
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear(perform: startRecordedScenarioIfNeeded)
        .onDisappear { investigationTask?.cancel() }
    }

    private var recordedWork: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Check the first incorrect step")
                .font(.title2.bold())
            Text("3x − 7 = 11")
            Text("3x = 11 − 7")
            Text("x = 6")
        }
        .font(.title.monospaced())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.primary)
    }

    private var selectionGlow: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 18)
                .stroke(.indigo, style: StrokeStyle(lineWidth: 4, dash: [10, 7]))
                .shadow(color: .indigo.opacity(0.5), radius: 8)
                .frame(
                    width: selectionBounds.width * proxy.size.width,
                    height: selectionBounds.height * proxy.size.height
                )
                .position(
                    x: (selectionBounds.x + selectionBounds.width / 2) * proxy.size.width,
                    y: (selectionBounds.y + selectionBounds.height / 2) * proxy.size.height
                )
                .accessibilityLabel("Recorded lasso selection")
                .accessibilityIdentifier("recorded-lasso-selection")
        }
        .allowsHitTesting(false)
    }

    private var isInvestigationActive: Bool {
        if case .submitting = lassoState { return true }
        if case .receiving = lassoState { return true }
        return false
    }

    private var progressStatus: some View {
        VStack(spacing: 12) {
            Label(status, systemImage: "sparkles")
                .font(.headline)
            Button("Cancel", role: .cancel, action: cancelInvestigation)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("investigation-submitting")
    }

    private func terminalStatus(showRetry: Bool) -> some View {
        VStack(spacing: 12) {
            Text(status).font(.headline)
            if showRetry {
                Button("Retry", action: retryInvestigation)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("investigation-retry")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("investigation-terminal")
    }

    private func submit(_ intent: InvestigationIntent) {
        guard case let .selected(selectionID) = lassoState,
              selectionID == selectionArtifact.id else { return }
        let request = InvestigationRequest(
            id: UUID(),
            intent: intent,
            selection: selectionArtifact,
            conversationID: nil
        )
        submittedIntent = request.intent
        lassoState = .submitting(investigationID: request.id)
        status = intentLabel(intent)
        run(request)
    }

    private func cancelSelection() {
        guard case .selected = lassoState else { return }
        submittedIntent = nil
        lassoState = .idle
    }

    private func cancelInvestigation() {
        let investigationID: UUID
        switch lassoState {
        case let .submitting(id), let .receiving(id): investigationID = id
        default: return
        }
        investigationTask?.cancel()
        Task { await agent.cancel(investigationID: investigationID) }
        status = "Investigation cancelled"
        lassoState = .selected(selectionID: selectionArtifact.id)
    }

    private func restoreSelection() {
        lassoState = .selected(selectionID: selectionArtifact.id)
        status = "Selection ready"
    }

    private func retryInvestigation() {
        guard let submittedIntent else { return }
        lassoState = .selected(selectionID: selectionArtifact.id)
        submit(submittedIntent)
    }

    private func intentLabel(_ intent: InvestigationIntent) -> String {
        switch intent {
        case .explain: "Submitting Explain"
        case .check: "Submitting Check"
        case let .ask(question): "Submitting Ask: \(question)"
        }
    }

    private func startRecordedScenarioIfNeeded() {
        guard scenario != .heroRecorded else {
            recordRuntimeEvidence()
            return
        }
        submit(.check)
    }

    private func run(_ request: InvestigationRequest) {
        investigationTask?.cancel()
        investigationTask = Task { @MainActor in
            do {
                for try await event in agent.investigate(request) {
                    guard !Task.isCancelled else { return }
                    consume(event, investigationID: request.id)
                }
            } catch {
                status = "Recorded investigation failed"
                lassoState = .failed(investigationID: request.id, recoverable: true)
                recordRuntimeEvidence()
            }
        }
    }

    private func consume(_ event: AgentEvent, investigationID: UUID) {
        switch event {
        case .accepted:
            status = "Request accepted"
            lassoState = .receiving(investigationID: investigationID)
        case .inspectingSelection:
            status = "Inspecting selection…"
        case let .toolStarted(tool):
            status = tool.userVisibleStatus
        case .toolFinished:
            break
        case let .pinStarted(draft):
            guard let annotation = annotation(from: draft, status: .streaming) else {
                status = "The response contained an invalid Pin location."
                lassoState = .failed(investigationID: investigationID, recoverable: true)
                recordRuntimeEvidence()
                return
            }
            annotations.removeAll { $0.id == annotation.id }
            annotations.append(annotation)
            status = "Receiving a proposed Pin…"
        case let .pinDelta(id, bodyDelta):
            guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
            annotations[index].body += bodyDelta
        case let .pinCompleted(draft):
            guard let annotation = annotation(from: draft, status: .complete) else { return }
            annotations.removeAll { $0.id == annotation.id }
            annotations.append(annotation)
            status = "Proposed Pin ready"
        case .completed:
            status = "Proposed Pin ready"
            lassoState = .completed(investigationID: investigationID)
            recordRuntimeEvidence()
        case let .failed(failure):
            status = failure.userMessage
            lassoState = .failed(investigationID: investigationID, recoverable: failure.recoverable)
            recordRuntimeEvidence()
        }
    }

    private func annotation(from draft: PinDraft, status: AnnotationStatus) -> PageAnnotation? {
        guard draft.target.isFiniteAndInUnitBounds else { return nil }
        let target = SpatialCoordinateTransform.cropPointToPage(
            draft.target,
            cropPageBounds: selectionBounds
        )
        guard target.isFiniteAndInUnitBounds else { return nil }
        return PageAnnotation(
            id: draft.id,
            pageID: pageID,
            threadID: threadID,
            target: target,
            targetRegion: nil,
            kind: draft.kind,
            teaser: draft.teaser,
            body: draft.body,
            citations: draft.citations,
            status: status
        )
    }

    private func recordRuntimeEvidence() {
#if DEBUG
        DevelopmentRuntimeEvidence.record(
            scenario: scenario,
            surfaceKind: .recordedHeroStub,
            pageCount: 1,
            currentPageID: pageID,
            currentPageIndex: 0,
            renderedPenFixtureName: nil,
            renderedAnnotationIDs: annotations.map(\.id),
            heroStatus: status
        )
#endif
    }

    private var selectionArtifact: SelectionArtifact {
        let crop = Self.makeSelectionCrop(pageBounds: selectionBounds)
        return SelectionArtifact(
            id: Self.selectionID,
            documentID: documentID,
            pageID: pageID,
            pageIndex: 0,
            lassoPath: [
                PageNormalizedPoint(x: 0.18, y: 0.24),
                PageNormalizedPoint(x: 0.76, y: 0.24),
                PageNormalizedPoint(x: 0.76, y: 0.62),
                PageNormalizedPoint(x: 0.18, y: 0.62),
                PageNormalizedPoint(x: 0.18, y: 0.24)
            ],
            pageBounds: selectionBounds,
            crop: crop,
            context: SelectionContext(
                documentTitle: "Recorded algebra check",
                sourceDocumentID: documentID,
                pageNumber: 1,
                nearbyText: "3x − 7 = 11; 3x = 11 − 7; x = 6"
            )
        )
    }

    private static let selectionID = UUID(uuidString: "70000000-0000-0000-0000-000000000014")!

    private static func recordedScenario(for scenario: DevelopmentScenario) -> RecordedAgentScenario {
        switch scenario {
        case .agentRecordedRetrieval:
            return .retrieval
        case .agentRecordedFailure:
            return .failure(AgentFailure(
                code: .unavailable,
                userMessage: "The recorded provider is temporarily unavailable.",
                recoverable: true
            ))
        default:
            return .success
        }
    }

    private static func makeSelectionCrop(pageBounds: PageNormalizedRect) -> SelectionCrop {
        let size = CGSize(width: 580, height: 380)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(UIColor(red: 0.992, green: 0.978, blue: 0.936, alpha: 1).cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            let heading = "Check the first incorrect step" as NSString
            heading.draw(
                at: CGPoint(x: 34, y: 28),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 27, weight: .bold),
                    .foregroundColor: UIColor.label
                ]
            )
            let work = "3x − 7 = 11\n\n3x = 11 − 7\n\nx = 6" as NSString
            work.draw(
                in: CGRect(x: 70, y: 100, width: 440, height: 250),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 32, weight: .regular),
                    .foregroundColor: UIColor.label
                ]
            )
        }
        guard let data = image.pngData() else { preconditionFailure("Failed to encode the fixed hero selection") }
        return SelectionCrop(
            imageData: data,
            mediaType: "image/png",
            pixelWidth: Int(size.width),
            pixelHeight: Int(size.height),
            pageBounds: pageBounds
        )
    }
}

private struct InvestigationActionStrip: View {
    let onInvestigate: (InvestigationIntent) -> Void
    let onCancel: () -> Void

    @State private var isAsking = false
    @State private var question = ""
    @FocusState private var questionIsFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isAsking {
                TextField("Ask about this selection", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .focused($questionIsFocused)
                    .onSubmit(submitQuestion)
                    .accessibilityIdentifier("investigation-ask-field")
                Button("Send", action: submitQuestion)
                    .disabled(trimmedQuestion.isEmpty)
                    .accessibilityIdentifier("investigation-ask-send")
            } else {
                Button("Explain") { onInvestigate(.explain) }
                    .accessibilityIdentifier("investigation-explain")
                Button("Check") { onInvestigate(.check) }
                    .accessibilityIdentifier("investigation-check")
                Button("Ask") {
                    isAsking = true
                    questionIsFocused = true
                }
                .accessibilityIdentifier("investigation-ask")
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .accessibilityIdentifier("investigation-cancel")
        }
        .buttonStyle(.bordered)
        .padding(10)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("investigation-action-strip")
    }

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitQuestion() {
        guard !trimmedQuestion.isEmpty else { return }
        onInvestigate(.ask(question: trimmedQuestion))
    }
}
