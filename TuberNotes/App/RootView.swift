import PDFKit
import PencilKit
import SwiftUI

struct RootView: View {
    let scenario: DevelopmentScenario
    @State private var document: NotebookDocument?
    @State private var currentPageID: UUID?
#if DEBUG
    @StateObject private var agentSession = AgentInteractionSession()
#endif

    init(scenario: DevelopmentScenario) {
        self.scenario = scenario
        _document = State(initialValue: scenario.fixture.document)
        _currentPageID = State(initialValue: scenario.fixture.currentPageID)
    }

    var body: some View {
        NavigationStack {
            scenarioSurface
#if DEBUG
                .id(agentSession.resetGeneration)
                .environmentObject(agentSession)
                .overlay(alignment: .top) {
                    AgentRequestBanner(session: agentSession)
                }
                .onChange(of: agentSession.resetGeneration) { _, _ in
                    document = scenario.fixture.document
                    currentPageID = scenario.fixture.currentPageID
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
                    Text(scenario.displayName)
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
#endif
        }
    }

    @ViewBuilder
    private var scenarioSurface: some View {
        switch scenario {
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
                penFixturesByPageID: scenario.fixture.penFixturesByPageID,
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
                Color(red: 0.992, green: 0.978, blue: 0.936)
                PinOverlayView(
                    annotations: standalonePinAnnotations,
                    projectAnchor: { point in
                        CGPoint(
                            x: point.x * proxy.size.width,
                            y: point.y * proxy.size.height
                        )
                    },
                    initiallyExpandedAnnotationID: scenario == .fakePin
                        ? standalonePinAnnotations.first?.id
                        : nil
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.black.opacity(0.08), lineWidth: 1)
            }
        }
        .padding(20)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("standalone-pin-surface")
    }

    private var standalonePinAnnotations: [PageAnnotation] {
        switch scenario {
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
        let fixtureAnnotations = scenario.fixture.annotations.filter { $0.pageID == page.id }
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
