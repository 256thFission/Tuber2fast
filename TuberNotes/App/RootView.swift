import PDFKit
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    let scenario: DevelopmentScenario
    private let documentStore: DocumentStore
    private let usesPersistentProductState: Bool
    @State private var displayedScenario: DevelopmentScenario
    @State private var document: NotebookDocument?
    @State private var currentPageID: UUID?
    @State private var initialDrawingData: [UUID: Data]
    @State private var importedPDFDocument: PDFDocument?
    @State private var restoredFromPersistence: Bool
    @State private var isImportingPDF = false
    @State private var importError: String?
    @State private var surfaceGeneration = 0
    @State private var selectionArtifact: SelectionArtifact?
#if DEBUG
    @StateObject private var agentSession = AgentInteractionSession()
    @StateObject private var feedbackSession = FeedbackThreadSession()
#endif

    init(scenario: DevelopmentScenario) {
        self.scenario = scenario
        let explicitFixture = DevelopmentScenario.isExplicitlySelected
        let persistenceScenario = explicitFixture && scenario == .persistenceRelaunch
        let store = DocumentStore(
            rootName: persistenceScenario ? "developer-persistence-scenario" : "documents"
        )
#if DEBUG
        if persistenceScenario,
           ProcessInfo.processInfo.environment["TUBER_PERSISTENCE_RESET"] == "1" {
            store.resetForDeterministicVerification()
        }
#endif
        let restored = (persistenceScenario || !explicitFixture) ? store.loadDocument() : nil
        var selectedDocument = restored ?? (explicitFixture ? scenario.fixture.document : nil)

        if persistenceScenario,
           restored == nil,
           var seededDocument = selectedDocument,
           let pageID = seededDocument.currentPageID,
           let fixture = scenario.fixture.penFixturesByPageID[pageID] {
            let drawing = fixture.makeDrawing(in: CGSize(width: 768, height: 1024))
            try? store.saveDrawing(
                drawing.dataRepresentation(),
                pageID: pageID,
                in: &seededDocument
            )
            selectedDocument = seededDocument
        }

        documentStore = store
        usesPersistentProductState = persistenceScenario || !explicitFixture
        _displayedScenario = State(initialValue: scenario)
        _document = State(initialValue: selectedDocument)
        _currentPageID = State(initialValue: selectedDocument?.currentPageID)
        _initialDrawingData = State(
            initialValue: selectedDocument.map(store.drawingData(for:)) ?? [:]
        )
        _importedPDFDocument = State(
            initialValue: selectedDocument.flatMap(store.pdfDocument(for:))
        )
        _restoredFromPersistence = State(initialValue: restored != nil)

        if persistenceScenario, restored == nil, let selectedDocument {
            try? store.saveDocument(selectedDocument)
        }
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
                if canManageDocuments {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(action: createBlankNotebook) {
                            Label("New Notebook", systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("create-notebook")
                        Button(action: { isImportingPDF = true }) {
                            Label("Import PDF", systemImage: "square.and.arrow.down")
                        }
                        .accessibilityIdentifier("import-pdf")
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text(displayedScenario.displayName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("scenario-label")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingPDF,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: importPDF
        )
        .alert("Couldn’t Import PDF", isPresented: importErrorPresented) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Unknown error")
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
            if agentSession.activeRequest != nil || feedbackSession.activeFeedbackThread != nil {
                bindScenarioToActiveRequest()
            }
#endif
        }
        .onChange(of: currentPageID) { _, newValue in
            guard usesPersistentProductState, var updated = document else { return }
            updated.currentPageID = newValue
            document = updated
            persist(updated)
        }
    }

    @ViewBuilder
    private var scenarioSurface: some View {
        if usesPersistentProductState, document == nil {
            ContentUnavailableView {
                Label("Start a TuberNotes Document", systemImage: "doc.badge.plus")
            } description: {
                Text("Create a dot-grid notebook or import a PDF.")
            } actions: {
                Button("New Notebook", action: createBlankNotebook)
                    .buttonStyle(.borderedProminent)
                Button("Import PDF") { isImportingPDF = true }
                    .buttonStyle(.bordered)
            }
        } else {
        switch displayedScenario {
        case .fakePin, .multiPin, .edgePins:
            standalonePinSurface
        case .blankCanvas, .pdfPages, .blankNotebook, .notebookPages, .inkPages, .pinDrift, .lassoCrop, .persistenceRelaunch:
            standaloneSpatialSurface
        case .heroRecorded, .agentRecordedSuccess, .agentRecordedRetrieval, .agentRecordedFailure:
            recordedInvestigationSurface
        default:
            ContentUnavailableView(
                "Later milestone",
                systemImage: "hammer",
                description: Text(scenario.fixture.expectedState)
            )
        }
        }
    }

    @ViewBuilder
    private var standaloneSpatialSurface: some View {
        if let document {
            SpatialCanvasView(
                document: document,
                currentPageID: $currentPageID,
                pdfDocument: pdfDocument(for: document),
                toolMode: displayedScenario == .lassoCrop ? .magicLasso : .ink,
                initialDrawingData: initialDrawingData,
                penFixturesByPageID: displayedScenario.fixture.penFixturesByPageID,
                initialLassoPathsByPageID: displayedScenario.fixture.lassoPathsByPageID,
                pageOverlay: { page, projection in
                    AnyView(
                        PinOverlayView(
                            annotations: spatialAnnotations(for: page),
                            projectAnchor: { projection($0) }
                        )
                    )
                },
                onDrawingChanged: drawingChangedHandler,
                onDrawingSnapshot: drawingSnapshotHandler,
                onSelectionChanged: handleSelectionChanged,
                allowsDeterministicViewportTransition: displayedScenario == .pinDrift
            )
        }
    }

    @ViewBuilder
    private var recordedInvestigationSurface: some View {
        if let document {
            RecordedInvestigationView(
                scenario: displayedScenario,
                document: document,
                currentPageID: $currentPageID,
                pdfDocument: pdfDocument(for: document),
                initialDrawingData: initialDrawingData,
                penFixturesByPageID: displayedScenario.fixture.penFixturesByPageID,
                initialLassoPathsByPageID: displayedScenario.fixture.lassoPathsByPageID,
                onDrawingChanged: drawingChangedHandler,
                onDrawingSnapshot: drawingSnapshotHandler
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

    private var canManageDocuments: Bool {
        usesPersistentProductState && displayedScenario != .persistenceRelaunch
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
        persist(document)
    }

    private func pdfDocument(for document: NotebookDocument) -> PDFDocument? {
        switch document.source {
        case .bundledPDF:
            return SpatialCanvasFixtures.makeM0DemoPDF()
        case .importedPDF:
            return importedPDFDocument ?? documentStore.pdfDocument(for: document)
        case .notebook:
            return nil
        }
    }

    private func createBlankNotebook() {
        let pageID = UUID()
        let newDocument = NotebookDocument(
            id: UUID(),
            title: "Untitled Notebook",
            source: .notebook(defaultPaperStyle: .tuberDotGrid),
            pages: [
                PageRecord(
                    id: pageID,
                    index: 0,
                    background: .blank(style: .tuberDotGrid, dimensions: .tuberPortrait),
                    inkReference: nil,
                    annotations: []
                )
            ],
            currentPageID: pageID
        )
        document = newDocument
        currentPageID = pageID
        initialDrawingData = [:]
        importedPDFDocument = nil
        restoredFromPersistence = false
        persist(newDocument)
        surfaceGeneration += 1
    }

    private func importPDF(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let imported = try documentStore.importPDF(from: url)
            document = imported.0
            currentPageID = imported.0.currentPageID
            initialDrawingData = [:]
            importedPDFDocument = imported.1
            restoredFromPersistence = false
            surfaceGeneration += 1
        } catch {
            importError = error.localizedDescription
        }
    }

    private var importErrorPresented: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    private func persist(_ document: NotebookDocument) {
        guard usesPersistentProductState else { return }
        try? documentStore.saveDocument(document)
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
        if usesPersistentProductState, let restored = documentStore.loadDocument() {
            document = restored
            currentPageID = restored.currentPageID
            initialDrawingData = documentStore.drawingData(for: restored)
            importedPDFDocument = documentStore.pdfDocument(for: restored)
            restoredFromPersistence = true
        } else {
            document = displayedScenario.fixture.document
            currentPageID = displayedScenario.fixture.currentPageID
            initialDrawingData = [:]
        }
        selectionArtifact = nil
        surfaceGeneration += 1
    }

#if DEBUG
    private var runtimeEvidenceFingerprint: String {
        [
            displayedScenario.rawValue,
            currentPageID?.uuidString ?? "none",
            String(document?.pages.count ?? 0),
            displayedScenario.fixture.annotations.map(\.id.uuidString).sorted().joined(separator: ","),
            selectionArtifact?.id.uuidString ?? "no-selection"
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
        case .pdfPages, .blankNotebook, .notebookPages, .inkPages, .pinDrift, .lassoCrop, .persistenceRelaunch:
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
                renderedAnnotationIDs: renderedAnnotations.map(\.id),
                selectionArtifact: selectionArtifact,
                renderedInkReference: currentPageID.flatMap { selectedID in
                    document.pages.first(where: { $0.id == selectedID })?.inkReference?.relativePath
                },
                restoredFromPersistence: restoredFromPersistence
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

    private func handleSelectionChanged(_ artifact: SelectionArtifact) {
        selectionArtifact = artifact
#if DEBUG
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let directory = documents.appendingPathComponent("developer-evidence", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? artifact.crop.imageData.write(
            to: directory.appendingPathComponent("lasso-selection-crop.png"),
            options: .atomic
        )
#endif
    }

    private var drawingChangedHandler: (UUID, Data) -> Void {
        { pageID, data in
            guard usesPersistentProductState, var updated = document else { return }
            do {
                try documentStore.saveDrawing(data, pageID: pageID, in: &updated)
                document = updated
                initialDrawingData[pageID] = data
            } catch {
                print("TuberNotes persistence drawing-save error=\(error.localizedDescription)")
            }
        }
    }
}

private struct RecordedInvestigationView: View {
    private let scenario: DevelopmentScenario
    private let document: NotebookDocument
    @Binding private var currentPageID: UUID?
    private let pdfDocument: PDFDocument?
    private let initialDrawingData: [UUID: Data]
    private let penFixturesByPageID: [UUID: PenFixture]
    private let initialLassoPathsByPageID: [UUID: [PageNormalizedPoint]]
    private let onDrawingChanged: (UUID, Data) -> Void
    private let onDrawingSnapshot: (UUID, PKDrawing, CGSize) -> Void
    private let agent: any AgentClient
    private let threadID = UUID(uuidString: "70000000-0000-0000-0000-000000000013")!

    @State private var lassoState = LassoState.idle
    @State private var selectionArtifact: SelectionArtifact?
    @State private var submittedIntent: InvestigationIntent?
    @State private var annotations: [PageAnnotation] = []
    @State private var status = "Draw a lasso to investigate"
    @State private var investigationTask: Task<Void, Never>?
    @State private var canvasGeneration = 0
    @State private var permitsDeterministicSelection = true

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
        agent = RecordedAgentClient(scenario: Self.recordedScenario(for: scenario))
    }

    var body: some View {
        SpatialCanvasView(
            document: document,
            currentPageID: $currentPageID,
            pdfDocument: pdfDocument,
            toolMode: .magicLasso,
            initialDrawingData: initialDrawingData,
            penFixturesByPageID: penFixturesByPageID,
            initialLassoPathsByPageID: seededLassoPathsByPageID,
            pageOverlay: { page, projection in
                AnyView(pageOverlay(for: page, projection: projection))
            },
            onDrawingChanged: onDrawingChanged,
            onDrawingSnapshot: onDrawingSnapshot,
            onSelectionChanged: receiveSelection
        )
        .id(canvasGeneration)
        .accessibilityIdentifier("recorded-investigation-surface")
        .onChange(of: currentPageID) { _, newPageID in
            guard selectionArtifact?.pageID != newPageID else { return }
            dismissSelection()
        }
        .onDisappear {
            investigationTask?.cancel()
        }
    }

    private func pageOverlay(
        for page: PageRecord,
        projection: PageAnchorProjection
    ) -> some View {
        ZStack {
            PinOverlayView(
                annotations: annotations.filter { $0.pageID == page.id },
                projectAnchor: { projection($0) },
                initiallyExpandedAnnotationID: annotations.first?.id
            )

            if selectionArtifact?.pageID == page.id {
                if case .selected = lassoState {
                    InvestigationActionStrip(
                        onInvestigate: submit,
                        onCancel: cancelSelection
                    )
                    .position(controlPosition(using: projection))
                } else if isInvestigationActive {
                    progressStatus
                        .position(controlPosition(using: projection))
                } else if case .failed(_, let recoverable) = lassoState {
                    terminalStatus(showRetry: recoverable)
                        .position(controlPosition(using: projection))
                } else if case .completed = lassoState {
                    terminalStatus(showRetry: true)
                        .position(controlPosition(using: projection))
                }
            }
        }
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
        guard let selectionArtifact,
              case let .selected(selectionID) = lassoState,
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
        selectionArtifact = nil
        lassoState = .idle
        status = "Selection cancelled"
        permitsDeterministicSelection = false
        canvasGeneration += 1
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
        if let selectionArtifact {
            lassoState = .selected(selectionID: selectionArtifact.id)
        } else {
            lassoState = .idle
        }
        recordRuntimeEvidence()
    }

    private func retryInvestigation() {
        guard let submittedIntent, let selectionArtifact else { return }
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

    private func run(_ request: InvestigationRequest) {
        investigationTask?.cancel()
        investigationTask = Task { @MainActor in
            do {
                for try await event in agent.investigate(request) {
                    guard !Task.isCancelled else { return }
                    consume(event, investigationID: request.id)
                }
            } catch {
                guard activeInvestigationID == request.id else { return }
                status = "Recorded investigation failed"
                lassoState = .failed(investigationID: request.id, recoverable: true)
                recordRuntimeEvidence()
            }
        }
    }

    private func consume(_ event: AgentEvent, investigationID: UUID) {
        guard activeInvestigationID == investigationID else { return }
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
            guard let annotation = annotation(from: draft, status: .complete) else {
                status = "The response contained an invalid Pin location."
                lassoState = .failed(investigationID: investigationID, recoverable: true)
                recordRuntimeEvidence()
                return
            }
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
        guard let selectionArtifact else { return nil }
        guard draft.target.isFiniteAndInUnitBounds else { return nil }
        let target = SpatialCoordinateTransform.cropPointToPage(
            draft.target,
            cropPageBounds: selectionArtifact.pageBounds
        )
        guard target.isFiniteAndInUnitBounds else { return nil }
        return PageAnnotation(
            id: draft.id,
            pageID: selectionArtifact.pageID,
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
        let currentIndex = currentPageID.flatMap { selectedID in
            document.pages.firstIndex(where: { $0.id == selectedID })
        }
        DevelopmentRuntimeEvidence.record(
            scenario: scenario,
            surfaceKind: .spatialCanvas,
            pageCount: document.pages.count,
            currentPageID: currentPageID,
            currentPageIndex: currentIndex,
            renderedPenFixtureName: currentPageID.flatMap { penFixturesByPageID[$0]?.name },
            renderedAnnotationIDs: annotations.map(\.id),
            heroStatus: status,
            selectionArtifact: selectionArtifact
        )
#endif
    }

    private func receiveSelection(_ artifact: SelectionArtifact) {
        guard artifact.pageID == currentPageID else { return }
        investigationTask?.cancel()
        selectionArtifact = artifact
        submittedIntent = nil
        lassoState = .selected(selectionID: artifact.id)
        status = "Selection ready"
        persistSelectionCrop(artifact)
        recordRuntimeEvidence()
        if shouldAutomateCheck {
            submit(.check)
        }
    }

    private func dismissSelection() {
        investigationTask?.cancel()
        selectionArtifact = nil
        submittedIntent = nil
        lassoState = .idle
        status = "Draw a lasso to investigate"
        permitsDeterministicSelection = false
    }

    private func persistSelectionCrop(_ artifact: SelectionArtifact) {
#if DEBUG
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let directory = documents.appendingPathComponent("developer-evidence", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? artifact.crop.imageData.write(
            to: directory.appendingPathComponent("lasso-selection-crop.png"),
            options: .atomic
        )
#endif
    }

    private var activeInvestigationID: UUID? {
        switch lassoState {
        case let .submitting(id), let .receiving(id): id
        default: nil
        }
    }

    private var seededLassoPathsByPageID: [UUID: [PageNormalizedPoint]] {
        permitsDeterministicSelection && shouldAutomateCheck
            ? initialLassoPathsByPageID
            : [:]
    }

    private var shouldAutomateCheck: Bool {
#if DEBUG
        scenario != .heroRecorded
            || ProcessInfo.processInfo.environment["TUBER_VERIFY_NONCE"] != nil
#else
        false
#endif
    }

    private func controlPosition(using projection: PageAnchorProjection) -> CGPoint {
        guard let bounds = selectionArtifact?.pageBounds else {
            return projection(PageNormalizedPoint(x: 0.5, y: 0.12))
        }
        let centerX = min(max(bounds.x + bounds.width / 2, 0.24), 0.76)
        let y = bounds.y >= 0.14
            ? bounds.y - 0.075
            : min(bounds.y + bounds.height + 0.075, 0.92)
        return projection(PageNormalizedPoint(x: centerX, y: y))
    }

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
