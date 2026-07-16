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
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        FeedbackThreadBar(session: feedbackSession)
                        AgentRequestBanner(session: agentSession)
                    }
                    .opacity(feedbackSession.isCapturing ? 0 : 1)
                    .padding(.leading, 20)
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
        case .lassoCrop, .agentRecordedSuccess, .agentRecordedRetrieval, .agentRecordedFailure, .heroRecorded:
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
                onDrawingSnapshot: drawingSnapshotHandler
            )
        }
    }

    private var standalonePinSurface: some View {
        GeometryReader { proxy in
            ZStack {
                pinComparisonBackground
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
            .clipShape(RoundedRectangle(cornerRadius: pinComparisonCornerRadius))
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
        case .edgePins: PinFixtures.edgePins
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
