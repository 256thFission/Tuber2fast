import CoreGraphics
import Foundation

/// Frozen DEBUG scenario identifiers from SPEC.md §17.
enum DevelopmentScenario: String, CaseIterable {
    case blankCanvas = "blank-canvas"
    case fakePin = "fake-pin"
    case multiPin = "multi-pin"
    case pdfPages = "pdf-pages"
    case blankNotebook = "blank-notebook"
    case notebookPages = "notebook-pages"
    case inkPages = "ink-pages"
    case lassoCrop = "lasso-crop"
    case pinDrift = "pin-drift"
    case edgePins = "edge-pins"
    case persistenceRelaunch = "persistence-relaunch"
    case agentRecordedSuccess = "agent-recorded-success"
    case agentRecordedRetrieval = "agent-recorded-retrieval"
    case agentRecordedFailure = "agent-recorded-failure"
    case heroRecorded = "hero-recorded"

    static var current: Self {
#if DEBUG
        let process = ProcessInfo.processInfo
        if let value = process.environment["TUBER_SCENARIO"], let scenario = Self(rawValue: value) {
            recordSelection(scenario, source: "environment")
            return scenario
        }
        if let index = process.arguments.firstIndex(of: "--scenario"),
           process.arguments.indices.contains(index + 1),
           let scenario = Self(rawValue: process.arguments[index + 1]) {
            recordSelection(scenario, source: "argument")
            return scenario
        }
        recordSelection(.blankCanvas, source: "default")
#endif
        return .blankCanvas
    }

    static var isExplicitlySelected: Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["TUBER_SCENARIO"] != nil { return true }
        return ProcessInfo.processInfo.arguments.contains("--scenario")
#else
        return false
#endif
    }

    var displayName: String { rawValue }

    /// DeveloperSupport owns deterministic inputs. App owns wiring them into module APIs.
    var fixture: DevelopmentScenarioFixture {
        DevelopmentScenarioFixtures.fixture(for: self)
    }

    /// Compatibility for the disposable scaffold. Coordinator integration should consume
    /// `fixture.annotations` and remove this bridge once RootView uses PageAnnotation directly.
    var pins: [Pin] {
        fixture.annotations
    }

    var penFixture: PenFixture? {
#if DEBUG
        if let requested = PenFixtureStore.loadRequestedFixture() {
            return requested
        }
#endif
        guard let pageID = fixture.currentPageID else { return nil }
        return fixture.penFixturesByPageID[pageID]
    }

#if DEBUG
    private static func recordSelection(_ scenario: Self, source: String) {
        let fileManager = FileManager.default
        let verificationNonce = ProcessInfo.processInfo.environment["TUBER_VERIFY_NONCE"]
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let directory = documents.appendingPathComponent("developer-evidence", isDirectory: true)
        let url = directory.appendingPathComponent("scenario-selection.json")
        let runtimeURL = directory.appendingPathComponent("runtime-rendered.json")
        let fixture = scenario.fixture
        let currentPageIndex = fixture.currentPageID.flatMap { currentPageID in
            fixture.document?.pages.firstIndex(where: { $0.id == currentPageID })
        }
        let value: [String: Any] = [
            "scenario": scenario.rawValue,
            "source": source,
            "verificationNonce": (verificationNonce as Any?) ?? NSNull(),
            "fixtureFamily": fixture.family.rawValue,
            "integrationReadiness": fixture.integrationReadiness.rawValue,
            "expectedState": fixture.expectedState,
            "pageCount": fixture.document?.pages.count ?? 0,
            "currentPageID": (fixture.currentPageID?.uuidString as Any?) ?? NSNull(),
            "currentPageIndex": (currentPageIndex as Any?) ?? NSNull(),
            "penFixturePageIDs": fixture.penFixturesByPageID.keys.map(\.uuidString).sorted(),
            "annotationIDs": fixture.annotations.map(\.id.uuidString).sorted(),
            "expectsViewportTransition": fixture.expectsViewportTransition
        ]
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // A launch must produce fresh runtime evidence. Never let a prior launch's
        // rendered-state snapshot satisfy the verifier for a newly selected scenario.
        try? fileManager.removeItem(at: runtimeURL)
        try? data.write(to: url, options: .atomic)
    }
#endif
}

#if DEBUG
/// Writes what App actually supplied to the selected rendering branch after that
/// branch settled. This is deliberately separate from `scenario-selection.json`,
/// which describes fixture declarations and cannot prove App wiring.
enum DevelopmentRuntimeEvidence {
    enum SurfaceKind: String {
        case spatialCanvas = "spatial-canvas"
        case standalonePins = "standalone-pin-surface"
        /// The current recorded hero bypasses genuine SpatialCanvas lasso/crop work.
        case recordedHeroStub = "recorded-hero-stub"
    }

    static func record(
        scenario: DevelopmentScenario,
        surfaceKind: SurfaceKind,
        pageCount: Int,
        currentPageID: UUID?,
        currentPageIndex: Int?,
        renderedPenFixtureName: String?,
        renderedAnnotationIDs: [UUID],
        heroStatus: String? = nil,
        renderedInkReference: String? = nil,
        restoredFromPersistence: Bool = false
    ) {
        let verificationNonce = ProcessInfo.processInfo.environment["TUBER_VERIFY_NONCE"]
        let value: [String: Any] = [
            "schemaVersion": 1,
            "scenario": scenario.rawValue,
            "verificationNonce": (verificationNonce as Any?) ?? NSNull(),
            "surfaceKind": surfaceKind.rawValue,
            "pageCount": pageCount,
            "currentPageID": (currentPageID?.uuidString as Any?) ?? NSNull(),
            "currentPageIndex": (currentPageIndex as Any?) ?? NSNull(),
            "renderedPenFixtureName": (renderedPenFixtureName as Any?) ?? NSNull(),
            "renderedAnnotationIDs": renderedAnnotationIDs.map(\.uuidString).sorted(),
            "heroStatus": (heroStatus as Any?) ?? NSNull(),
            "renderedInkReference": (renderedInkReference as Any?) ?? NSNull(),
            "restoredFromPersistence": restoredFromPersistence,
            "recordedAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
              ).first else { return }
        let directory = documents.appendingPathComponent("developer-evidence", isDirectory: true)
        let url = directory.appendingPathComponent("runtime-rendered.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
#endif

struct DevelopmentScenarioFixture {
    enum Family: String {
        case baseline
        case pins
        case pdf
        case notebook
        case ink
        case spatial
        case selection
        case agent
        case hero
        case persistence
    }

    enum IntegrationReadiness: String {
        /// Rendered by the original disposable scaffold before M0 integration.
        case scaffoldRendered = "scaffold-rendered"
        /// Deterministic inputs are complete; coordinator App composition must wire them.
        case readyForAppWiring = "ready-for-app-wiring"
        /// A narrow demonstrator exists, but named product behavior is still missing.
        case partialStub = "partial-stub"
        /// The coordinator App renders the fixture through the owning product subsystem.
        case appWired = "app-wired"
        /// Frozen identifier belongs to a later milestone and has no fixture in this package.
        case laterMilestone = "later-milestone"
    }

    let family: Family
    let expectedState: String
    let integrationReadiness: IntegrationReadiness
    let document: NotebookDocument?
    let currentPageID: UUID?
    let penFixturesByPageID: [UUID: PenFixture]
    let annotations: [PageAnnotation]
    let expectsViewportTransition: Bool
}

private enum DevelopmentScenarioFixtures {
    private enum ID {
        static let blankDocument = uuid("10000000-0000-0000-0000-000000000001")
        static let blankPage = uuid("10000000-0000-0000-0000-000000000002")

        static let pdfDocument = uuid("20000000-0000-0000-0000-000000000001")
        static let pdfPage1 = uuid("20000000-0000-0000-0000-000000000011")
        static let pdfPage2 = uuid("20000000-0000-0000-0000-000000000012")
        static let pdfPage3 = uuid("20000000-0000-0000-0000-000000000013")

        static let notebookDocument = uuid("30000000-0000-0000-0000-000000000001")
        static let notebookPage1 = uuid("30000000-0000-0000-0000-000000000011")
        static let notebookPage2 = uuid("30000000-0000-0000-0000-000000000012")
        static let notebookPage3 = uuid("30000000-0000-0000-0000-000000000013")

        static let pinThread = uuid("40000000-0000-0000-0000-000000000001")
        static let fakePin = uuid("41111111-1111-1111-1111-111111111111")
        static let multiPin1 = uuid("42222222-2222-2222-2222-222222222222")
        static let multiPin2 = uuid("43333333-3333-3333-3333-333333333333")
        static let multiPin3 = uuid("44444444-4444-4444-4444-444444444444")
        static let driftPin = uuid("45555555-5555-5555-5555-555555555555")
        static let edgeTop = uuid("46666666-6666-6666-6666-666666666661")
        static let edgeRight = uuid("46666666-6666-6666-6666-666666666662")
        static let edgeBottom = uuid("46666666-6666-6666-6666-666666666663")
        static let edgeLeft = uuid("46666666-6666-6666-6666-666666666664")

        static let persistenceDocument = uuid("50000000-0000-0000-0000-000000000001")
        static let persistencePage = uuid("50000000-0000-0000-0000-000000000011")
        static let persistencePin = uuid("50000000-0000-0000-0000-000000000021")

        private static func uuid(_ value: String) -> UUID {
            guard let id = UUID(uuidString: value) else { preconditionFailure("Invalid fixture UUID: \(value)") }
            return id
        }
    }

    static func fixture(for scenario: DevelopmentScenario) -> DevelopmentScenarioFixture {
        switch scenario {
        case .blankCanvas:
            return make(
                family: .baseline,
                expectedState: "one blank canvas with no canned ink or Pins",
                readiness: .scaffoldRendered,
                document: blankDocument()
            )
        case .fakePin:
            return make(
                family: .pins,
                expectedState: "one deterministic Pin at page-normalized target (0.62, 0.34)",
                readiness: .scaffoldRendered,
                document: blankDocument(),
                annotations: [annotation(id: ID.fakePin, pageID: ID.blankPage, x: 0.62, y: 0.34, teaser: "Key idea", body: "This Pin is deterministic and page-normalized.")]
            )
        case .multiPin:
            return make(
                family: .pins,
                expectedState: "three deterministic Pins at distinct interior targets without catastrophic overlap",
                readiness: .scaffoldRendered,
                document: blankDocument(),
                annotations: [
                    annotation(id: ID.multiPin1, pageID: ID.blankPage, x: 0.24, y: 0.22, teaser: "Start here", body: "The first known spatial target."),
                    annotation(id: ID.multiPin2, pageID: ID.blankPage, x: 0.69, y: 0.49, teaser: "Check this", body: "The second known spatial target.", kind: .issue),
                    annotation(id: ID.multiPin3, pageID: ID.blankPage, x: 0.40, y: 0.76, teaser: "Related", body: "The third known spatial target.")
                ]
            )
        case .pdfPages:
            return make(
                family: .pdf,
                expectedState: "clean M0Demo PDF with three stable pages, showing page 2 of 3",
                readiness: .appWired,
                document: pdfDocument(currentPageID: ID.pdfPage2)
            )
        case .blankNotebook:
            return make(
                family: .notebook,
                expectedState: "new notebook with one branded TuberNotes dot-grid page and no ink",
                readiness: .appWired,
                document: notebookDocument(pageCount: 1, currentPageID: ID.notebookPage1)
            )
        case .notebookPages:
            let document = notebookDocument(pageCount: 3, currentPageID: ID.notebookPage3)
            return make(
                family: .notebook,
                expectedState: "three dot-grid pages, with distinct canned drawings on appended pages 2 and 3, showing page 3",
                readiness: .appWired,
                document: document,
                penFixtures: [
                    ID.notebookPage2: diagonalFixture(name: "notebook-page-2", descending: false),
                    ID.notebookPage3: diagonalFixture(name: "notebook-page-3", descending: true)
                ]
            )
        case .inkPages:
            let document = pdfDocument(currentPageID: ID.pdfPage3)
            return make(
                family: .ink,
                expectedState: "M0Demo PDF with distinct canned drawings on pages 1 and 3, showing page 3",
                readiness: .appWired,
                document: document,
                penFixtures: [
                    ID.pdfPage1: diagonalFixture(name: "pdf-page-1-ink", descending: false),
                    ID.pdfPage3: diagonalFixture(name: "pdf-page-3-ink", descending: true)
                ]
            )
        case .pinDrift:
            return make(
                family: .spatial,
                expectedState: "one stable Pin target at (0.58, 0.42), checked before and after a deterministic viewport transition",
                readiness: .appWired,
                document: pdfDocument(currentPageID: ID.pdfPage2),
                annotations: [annotation(id: ID.driftPin, pageID: ID.pdfPage2, x: 0.58, y: 0.42, teaser: "Stable anchor", body: "The target must not drift through zoom, pan, page turn, and return.")],
                expectsViewportTransition: true
            )
        case .edgePins:
            return make(
                family: .pins,
                expectedState: "four deterministic Pins near the top, right, bottom, and left edges with unclipped labels",
                readiness: .appWired,
                document: blankDocument(),
                annotations: [
                    annotation(id: ID.edgeTop, pageID: ID.blankPage, x: 0.50, y: 0.03, teaser: "Top", body: "Top-edge fixture."),
                    annotation(id: ID.edgeRight, pageID: ID.blankPage, x: 0.97, y: 0.50, teaser: "Right", body: "Right-edge fixture."),
                    annotation(id: ID.edgeBottom, pageID: ID.blankPage, x: 0.50, y: 0.97, teaser: "Bottom", body: "Bottom-edge fixture."),
                    annotation(id: ID.edgeLeft, pageID: ID.blankPage, x: 0.03, y: 0.50, teaser: "Left", body: "Left-edge fixture.")
                ]
            )
        case .persistenceRelaunch:
            let page = PageRecord(
                id: ID.persistencePage,
                index: 0,
                background: .blank(style: .tuberDotGrid, dimensions: .tuberPortrait),
                inkReference: nil,
                annotations: [
                    annotation(
                        id: ID.persistencePin,
                        pageID: ID.persistencePage,
                        x: 0.61,
                        y: 0.37,
                        teaser: "Persisted Pin",
                        body: "Stable page-normalized annotation restored across relaunch."
                    )
                ]
            )
            let document = NotebookDocument(
                id: ID.persistenceDocument,
                title: "Persistence Fixture",
                source: .notebook(defaultPaperStyle: .tuberDotGrid),
                pages: [page],
                currentPageID: ID.persistencePage
            )
            return make(
                family: .persistence,
                expectedState: "same page identity, ink reference, and annotation identity after relaunch",
                readiness: .appWired,
                document: document,
                penFixtures: [
                    ID.persistencePage: diagonalFixture(name: "persistence-page-ink", descending: false)
                ],
                annotations: page.annotations
            )
        case .lassoCrop:
            return later(family: .selection, expectedState: "known PDF and ink selection with an inspectable crop artifact")
        case .agentRecordedSuccess:
            return later(family: .agent, expectedState: "complete recorded agent event sequence")
        case .agentRecordedRetrieval:
            return later(family: .agent, expectedState: "recorded textbook retrieval tool sequence")
        case .agentRecordedFailure:
            return later(family: .agent, expectedState: "recoverable recorded provider failure")
        case .heroRecorded:
            return make(
                family: .hero,
                expectedState: "recorded agent-to-Pin stub; genuine lasso capture and crop remain pending",
                readiness: .partialStub,
                document: blankDocument()
            )
        }
    }

    private static func make(
        family: DevelopmentScenarioFixture.Family,
        expectedState: String,
        readiness: DevelopmentScenarioFixture.IntegrationReadiness,
        document: NotebookDocument,
        penFixtures: [UUID: PenFixture] = [:],
        annotations: [PageAnnotation] = [],
        expectsViewportTransition: Bool = false
    ) -> DevelopmentScenarioFixture {
        DevelopmentScenarioFixture(
            family: family,
            expectedState: expectedState,
            integrationReadiness: readiness,
            document: document,
            currentPageID: document.currentPageID,
            penFixturesByPageID: penFixtures,
            annotations: annotations,
            expectsViewportTransition: expectsViewportTransition
        )
    }

    private static func later(
        family: DevelopmentScenarioFixture.Family,
        expectedState: String
    ) -> DevelopmentScenarioFixture {
        DevelopmentScenarioFixture(
            family: family,
            expectedState: expectedState,
            integrationReadiness: .laterMilestone,
            document: nil,
            currentPageID: nil,
            penFixturesByPageID: [:],
            annotations: [],
            expectsViewportTransition: false
        )
    }

    private static func blankDocument() -> NotebookDocument {
        NotebookDocument(
            id: ID.blankDocument,
            title: "TuberNotes Fixture",
            source: .notebook(defaultPaperStyle: .tuberDotGrid),
            pages: [blankPage(id: ID.blankPage, index: 0)],
            currentPageID: ID.blankPage
        )
    }

    private static func pdfDocument(currentPageID: UUID) -> NotebookDocument {
        NotebookDocument(
            id: ID.pdfDocument,
            title: "M0 Demo PDF",
            source: .bundledPDF(resourceName: "M0Demo"),
            pages: [
                PageRecord(id: ID.pdfPage1, index: 0, background: .pdf(documentID: ID.pdfDocument, pageIndex: 0), inkReference: nil, annotations: []),
                PageRecord(id: ID.pdfPage2, index: 1, background: .pdf(documentID: ID.pdfDocument, pageIndex: 1), inkReference: nil, annotations: []),
                PageRecord(id: ID.pdfPage3, index: 2, background: .pdf(documentID: ID.pdfDocument, pageIndex: 2), inkReference: nil, annotations: [])
            ],
            currentPageID: currentPageID
        )
    }

    private static func notebookDocument(pageCount: Int, currentPageID: UUID) -> NotebookDocument {
        let ids = [ID.notebookPage1, ID.notebookPage2, ID.notebookPage3]
        precondition((1 ... ids.count).contains(pageCount))
        return NotebookDocument(
            id: ID.notebookDocument,
            title: "M0 Dot-Grid Notebook",
            source: .notebook(defaultPaperStyle: .tuberDotGrid),
            pages: Array(ids.prefix(pageCount).enumerated()).map { index, id in
                blankPage(id: id, index: index)
            },
            currentPageID: currentPageID
        )
    }

    private static func blankPage(id: UUID, index: Int) -> PageRecord {
        PageRecord(
            id: id,
            index: index,
            background: .blank(style: .tuberDotGrid, dimensions: .tuberPortrait),
            inkReference: nil,
            annotations: []
        )
    }

    private static func annotation(
        id: UUID,
        pageID: UUID,
        x: Double,
        y: Double,
        teaser: String,
        body: String,
        kind: AnnotationKind = .explanation
    ) -> PageAnnotation {
        PageAnnotation(
            id: id,
            pageID: pageID,
            threadID: ID.pinThread,
            target: PageNormalizedPoint(x: x, y: y),
            targetRegion: nil,
            kind: kind,
            teaser: teaser,
            body: body,
            citations: [],
            status: .complete
        )
    }

    private static func diagonalFixture(name: String, descending: Bool) -> PenFixture {
        let startY: CGFloat = descending ? 0.72 : 0.28
        let endY: CGFloat = descending ? 0.28 : 0.72
        return PenFixture(
            name: name,
            description: "Deterministic M0 page-specific diagonal",
            events: [
                .init(x: 0.24, y: startY, time: 0, phase: .began, pressure: 0.75, altitude: .pi / 3, azimuth: 0),
                .init(x: 0.40, y: (startY + endY) / 2, time: 0.08, phase: .moved, pressure: 0.8, altitude: .pi / 3, azimuth: 0),
                .init(x: 0.58, y: endY, time: 0.16, phase: .ended, pressure: 0.75, altitude: .pi / 3, azimuth: 0)
            ],
            requestID: nil,
            recordedAt: nil
        )
    }
}
