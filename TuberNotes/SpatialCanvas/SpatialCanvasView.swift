import PDFKit
import PencilKit
import SwiftUI
import UIKit

// MARK: - Named spatial values

struct PageCanvasSize: Equatable, Sendable {
    let width: Double
    let height: Double
}

struct PageCanvasPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct PageViewPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// Page-local projector supplied to overlay modules by SpatialCanvas.
/// The projector is transient and never becomes persisted spatial state.
struct PageAnchorProjection: Equatable, Sendable {
    let pageCanvasSize: PageCanvasSize

    func callAsFunction(_ point: PageNormalizedPoint) -> CGPoint {
        CGPoint(
            x: point.x * pageCanvasSize.width,
            y: point.y * pageCanvasSize.height
        )
    }
}

/// Pure projection from an unzoomed page canvas into the transient viewport.
/// Persistent state remains page-normalized; this value is never persisted.
struct PageViewportTransform: Equatable, Sendable {
    let pageCanvasSize: PageCanvasSize
    let zoomScale: Double
    let pageOriginInView: PageViewPoint

    func projectedViewPoint(for point: PageNormalizedPoint) -> PageViewPoint {
        PageViewPoint(
            x: pageOriginInView.x + point.x * pageCanvasSize.width * zoomScale,
            y: pageOriginInView.y + point.y * pageCanvasSize.height * zoomScale
        )
    }

    func pageNormalizedPoint(for point: PageViewPoint) -> PageNormalizedPoint {
        PageNormalizedPoint(
            x: (point.x - pageOriginInView.x) / (pageCanvasSize.width * zoomScale),
            y: (point.y - pageOriginInView.y) / (pageCanvasSize.height * zoomScale)
        )
    }
}

struct PageViewportState: Equatable, Sendable {
    let pageID: UUID
    let transform: PageViewportTransform
}

enum SpatialCoordinateTransform {
    static func pageCanvasPoint(
        for point: PageNormalizedPoint,
        pageSize: PageCanvasSize
    ) -> PageCanvasPoint {
        PageCanvasPoint(x: point.x * pageSize.width, y: point.y * pageSize.height)
    }

    static func pageNormalizedPoint(
        for point: PageCanvasPoint,
        pageSize: PageCanvasSize
    ) -> PageNormalizedPoint {
        PageNormalizedPoint(x: point.x / pageSize.width, y: point.y / pageSize.height)
    }

    static func cropPointToPage(
        _ point: CropNormalizedPoint,
        cropPageBounds: PageNormalizedRect
    ) -> PageNormalizedPoint {
        PageNormalizedPoint(
            x: cropPageBounds.x + point.x * cropPageBounds.width,
            y: cropPageBounds.y + point.y * cropPageBounds.height
        )
    }

    /// Returns the maximum per-axis round-trip error across corners, center, and
    /// a deliberately non-symmetric point used by the spatial-debugging skill.
    static func diagnosticMaximumRoundTripError() -> Double {
        let pageSize = PageCanvasSize(width: 768, height: 1024)
        let viewport = PageViewportTransform(
            pageCanvasSize: pageSize,
            zoomScale: 2.375,
            pageOriginInView: PageViewPoint(x: -183.25, y: 47.75)
        )
        let samples = [
            PageNormalizedPoint(x: 0, y: 0),
            PageNormalizedPoint(x: 1, y: 0),
            PageNormalizedPoint(x: 0, y: 1),
            PageNormalizedPoint(x: 1, y: 1),
            PageNormalizedPoint(x: 0.5, y: 0.5),
            PageNormalizedPoint(x: 0.69, y: 0.49)
        ]

        return samples.reduce(0) { maximum, sample in
            let canvas = pageCanvasPoint(for: sample, pageSize: pageSize)
            let canvasRoundTrip = pageNormalizedPoint(for: canvas, pageSize: pageSize)
            let viewRoundTrip = viewport.pageNormalizedPoint(for: viewport.projectedViewPoint(for: sample))
            return max(
                maximum,
                abs(canvasRoundTrip.x - sample.x),
                abs(canvasRoundTrip.y - sample.y),
                abs(viewRoundTrip.x - sample.x),
                abs(viewRoundTrip.y - sample.y)
            )
        }
    }
}

/// Content supplied by App/Pins while SpatialCanvas retains responsibility for
/// converting the persistent page-normalized target into page canvas position.
struct SpatialCanvasAnchor: Identifiable {
    let id: UUID
    let pageID: UUID
    let target: PageNormalizedPoint
    let content: AnyView

    init<Content: View>(
        id: UUID,
        pageID: UUID,
        target: PageNormalizedPoint,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.pageID = pageID
        self.target = target
        self.content = AnyView(content())
    }
}

// MARK: - Stable per-page ink

final class SpatialDrawingStore: ObservableObject {
    @Published private(set) var drawingDataByPageID: [UUID: Data]

    init(initialDrawingData: [UUID: Data] = [:]) {
        drawingDataByPageID = initialDrawingData
    }

    func drawingData(for pageID: UUID) -> Data? {
        drawingDataByPageID[pageID]
    }

    func setDrawingData(_ data: Data, for pageID: UUID) {
        guard drawingDataByPageID[pageID] != data else { return }
        drawingDataByPageID[pageID] = data
    }
}

// MARK: - Public spatial surface

struct SpatialCanvasView: View {
    let document: NotebookDocument
    @Binding private var currentPageID: UUID?
    let pdfDocument: PDFDocument?
    let toolMode: CanvasToolMode
    let penFixturesByPageID: [UUID: PenFixture]
    let anchors: [SpatialCanvasAnchor]
    let pageOverlay: (PageRecord, PageAnchorProjection) -> AnyView
    let onDrawingChanged: (UUID, Data) -> Void
    let onDrawingSnapshot: (UUID, PKDrawing, CGSize) -> Void
    let onViewportChanged: (PageViewportState) -> Void
    let allowsDeterministicViewportTransition: Bool

    @StateObject private var drawingStore: SpatialDrawingStore
    @State private var selectedPageID: UUID?
    @State private var viewportTransitionGenerationByPageID: [UUID: Int] = [:]

    init(
        document: NotebookDocument,
        currentPageID: Binding<UUID?>,
        pdfDocument: PDFDocument? = nil,
        toolMode: CanvasToolMode = .ink,
        initialDrawingData: [UUID: Data] = [:],
        penFixturesByPageID: [UUID: PenFixture] = [:],
        anchors: [SpatialCanvasAnchor] = [],
        pageOverlay: @escaping (PageRecord, PageAnchorProjection) -> AnyView = { _, _ in AnyView(EmptyView()) },
        onDrawingChanged: @escaping (UUID, Data) -> Void = { _, _ in },
        onDrawingSnapshot: @escaping (UUID, PKDrawing, CGSize) -> Void = { _, _, _ in },
        onViewportChanged: @escaping (PageViewportState) -> Void = { _ in },
        allowsDeterministicViewportTransition: Bool = false
    ) {
        self.document = document
        _currentPageID = currentPageID
        self.pdfDocument = pdfDocument
        self.toolMode = toolMode
        self.penFixturesByPageID = penFixturesByPageID
        self.anchors = anchors
        self.pageOverlay = pageOverlay
        self.onDrawingChanged = onDrawingChanged
        self.onDrawingSnapshot = onDrawingSnapshot
        self.onViewportChanged = onViewportChanged
        self.allowsDeterministicViewportTransition = allowsDeterministicViewportTransition
        _drawingStore = StateObject(wrappedValue: SpatialDrawingStore(initialDrawingData: initialDrawingData))

        let initialID = currentPageID.wrappedValue
            ?? document.currentPageID
            ?? document.pages.first?.id
        _selectedPageID = State(initialValue: initialID)
    }

    /// Compile-compatible migration initializer for the disposable scaffold.
    /// It intentionally ignores the old Pin model; App integration replaces this
    /// with normalized `SpatialCanvasAnchor` values from frozen PageAnnotations.
    init<LegacyPin>(pins: [LegacyPin], penFixture: PenFixture?) {
        let pageID = UUID(uuidString: "C011AB1E-0000-4000-8000-000000000001")!
        let documentID = UUID(uuidString: "C011AB1E-0000-4000-8000-000000000002")!
        let page = PageRecord(
            id: pageID,
            index: 0,
            background: .blank(style: .tuberDotGrid, dimensions: .tuberPortrait),
            inkReference: nil,
            annotations: []
        )
        let document = NotebookDocument(
            id: documentID,
            title: "TuberNotes",
            source: .notebook(defaultPaperStyle: .tuberDotGrid),
            pages: [page],
            currentPageID: pageID
        )

        self.document = document
        _currentPageID = .constant(pageID)
        pdfDocument = nil
        toolMode = .ink
        penFixturesByPageID = penFixture.map { [pageID: $0] } ?? [:]
        anchors = []
        pageOverlay = { _, _ in AnyView(EmptyView()) }
        onDrawingChanged = { _, _ in }
        onDrawingSnapshot = { _, _, _ in }
        onViewportChanged = { _ in }
        allowsDeterministicViewportTransition = false
        _drawingStore = StateObject(wrappedValue: SpatialDrawingStore())
        _selectedPageID = State(initialValue: pageID)
    }

    var body: some View {
        VStack(spacing: 8) {
            navigationBar

            if document.pages.isEmpty {
                ContentUnavailableView(
                    "No Pages",
                    systemImage: "doc",
                    description: Text("Add a page to this notebook to begin.")
                )
            } else {
                TabView(selection: $selectedPageID) {
                    ForEach(document.pages) { page in
                        ZoomableSpatialPage(
                            page: page,
                            pdfPage: pdfPage(for: page),
                            drawingData: drawingStore.drawingData(for: page.id),
                            toolMode: toolMode,
                            penFixture: penFixturesByPageID[page.id],
                            anchors: anchors.filter { $0.pageID == page.id },
                            pageOverlay: pageOverlay,
                            onDrawingChanged: handleDrawingChanged,
                            onDrawingSnapshot: onDrawingSnapshot,
                            onViewportChanged: onViewportChanged,
                            viewportTransitionGeneration: viewportTransitionGenerationByPageID[page.id] ?? 0
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .tag(Optional(page.id))
                        .accessibilityIdentifier("spatial-page-\(page.id.uuidString)")
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("spatial-canvas")
        .onAppear {
            normalizeSelection()
            let error = SpatialCoordinateTransform.diagnosticMaximumRoundTripError()
            print("SpatialCanvas coordinate-round-trip maxError=\(error)")
            assert(error <= 1e-6, "Spatial coordinate round-trip exceeded 1e-6")
        }
        .onChange(of: selectedPageID) { _, newValue in
            guard currentPageID != newValue else { return }
            currentPageID = newValue
        }
        .onChange(of: currentPageID) { _, newValue in
            guard newValue != selectedPageID,
                  document.pages.contains(where: { $0.id == newValue }) else { return }
            selectedPageID = newValue
        }
        .onChange(of: document.pages.map(\.id)) { _, _ in
            normalizeSelection()
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button(action: showPreviousPage) {
                Image(systemName: "chevron.left")
                    .frame(width: 34, height: 34)
            }
            .disabled(currentPageIndex <= 0)
            .accessibilityLabel("Previous page")
            .accessibilityIdentifier("previous-page")

            Spacer()

            Text(pagePositionLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("page-position")

            Spacer()

            Button(action: showNextPage) {
                Image(systemName: "chevron.right")
                    .frame(width: 34, height: 34)
            }
            .disabled(currentPageIndex < 0 || currentPageIndex >= document.pages.count - 1)
            .accessibilityLabel("Next page")
            .accessibilityIdentifier("next-page")

            if allowsDeterministicViewportTransition {
                Button(action: changeViewportDeterministically) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Change viewport")
                .accessibilityValue(currentViewportTransitionGeneration.isMultiple(of: 2) ? "Fit to page" : "Zoomed and panned")
                .accessibilityIdentifier("change-viewport")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
    }

    private var currentPageIndex: Int {
        guard let selectedPageID else { return -1 }
        return document.pages.firstIndex(where: { $0.id == selectedPageID }) ?? -1
    }

    private var pagePositionLabel: String {
        guard currentPageIndex >= 0 else { return "No page" }
        return "Page \(currentPageIndex + 1) of \(document.pages.count)"
    }

    private func showPreviousPage() {
        let target = currentPageIndex - 1
        guard document.pages.indices.contains(target) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            selectedPageID = document.pages[target].id
        }
    }

    private func showNextPage() {
        let target = currentPageIndex + 1
        guard document.pages.indices.contains(target) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            selectedPageID = document.pages[target].id
        }
    }

    private func changeViewportDeterministically() {
        guard let selectedPageID else { return }
        viewportTransitionGenerationByPageID[selectedPageID, default: 0] += 1
    }

    private var currentViewportTransitionGeneration: Int {
        guard let selectedPageID else { return 0 }
        return viewportTransitionGenerationByPageID[selectedPageID] ?? 0
    }

    private func normalizeSelection() {
        if let selectedPageID, document.pages.contains(where: { $0.id == selectedPageID }) {
            return
        }
        selectedPageID = currentPageID
            ?? document.currentPageID
            ?? document.pages.first?.id
    }

    private func handleDrawingChanged(pageID: UUID, data: Data) {
        drawingStore.setDrawingData(data, for: pageID)
        onDrawingChanged(pageID, data)
    }

    private func pdfPage(for page: PageRecord) -> PDFPage? {
        guard case let .pdf(_, pageIndex) = page.background else { return nil }
        return pdfDocument?.page(at: pageIndex)
    }
}

// MARK: - Zoom viewport

private struct ZoomableSpatialPage: UIViewRepresentable {
    let page: PageRecord
    let pdfPage: PDFPage?
    let drawingData: Data?
    let toolMode: CanvasToolMode
    let penFixture: PenFixture?
    let anchors: [SpatialCanvasAnchor]
    let pageOverlay: (PageRecord, PageAnchorProjection) -> AnyView
    let onDrawingChanged: (UUID, Data) -> Void
    let onDrawingSnapshot: (UUID, PKDrawing, CGSize) -> Void
    let onViewportChanged: (PageViewportState) -> Void
    let viewportTransitionGeneration: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> FittedPageScrollView {
        let scrollView = FittedPageScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.panGestureRecognizer.isEnabled = false

        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.layer.shadowColor = UIColor.black.cgColor
        host.view.layer.shadowOpacity = 0.16
        host.view.layer.shadowRadius = 12
        host.view.layer.shadowOffset = CGSize(width: 0, height: 5)
        scrollView.addSubview(host.view)

        context.coordinator.scrollView = scrollView
        context.coordinator.host = host
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.layoutPageIfNeeded()
        }
        return scrollView
    }

    func updateUIView(_ scrollView: FittedPageScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host?.rootView = content
        scrollView.setNeedsLayout()
        context.coordinator.applyViewportTransitionIfNeeded()
    }

    static func dismantleUIView(_ scrollView: FittedPageScrollView, coordinator: Coordinator) {
        scrollView.onLayout = nil
        coordinator.host?.view.removeFromSuperview()
    }

    private var content: SpatialPageContent {
        SpatialPageContent(
            page: page,
            pdfPage: pdfPage,
            drawingData: drawingData,
            toolMode: toolMode,
            penFixture: penFixture,
            anchors: anchors,
            pageOverlay: pageOverlay,
            onDrawingChanged: onDrawingChanged,
            onDrawingSnapshot: onDrawingSnapshot
        )
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableSpatialPage
        weak var scrollView: FittedPageScrollView?
        var host: UIHostingController<SpatialPageContent>?
        private var lastViewportSize = CGSize.zero
        private var appliedViewportTransitionGeneration = 0

        init(parent: ZoomableSpatialPage) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            host?.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerPage()
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.0001
            emitViewport()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            emitViewport()
        }

        func scrollViewDidEndZooming(
            _ scrollView: UIScrollView,
            with view: UIView?,
            atScale scale: CGFloat
        ) {
            if abs(scale - scrollView.minimumZoomScale) < 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                scrollView.panGestureRecognizer.isEnabled = false
            }
            emitViewport()
        }

        func layoutPageIfNeeded() {
            guard let scrollView, let pageView = host?.view, scrollView.bounds.size != .zero else { return }
            let viewportSize = scrollView.bounds.size
            guard viewportSize != lastViewportSize || pageView.bounds.size == .zero else {
                centerPage()
                emitViewport()
                return
            }

            lastViewportSize = viewportSize
            if scrollView.zoomScale != scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
            }

            let logicalSize = parent.logicalPageSize
            let inset: CGFloat = 8
            let available = CGSize(
                width: max(1, viewportSize.width - inset * 2),
                height: max(1, viewportSize.height - inset * 2)
            )
            let fit = min(
                available.width / max(1, logicalSize.width),
                available.height / max(1, logicalSize.height)
            )
            let fittedSize = CGSize(
                width: logicalSize.width * fit,
                height: logicalSize.height * fit
            )

            pageView.transform = .identity
            pageView.bounds = CGRect(origin: .zero, size: fittedSize)
            pageView.frame = CGRect(origin: .zero, size: fittedSize)
            scrollView.contentSize = fittedSize
            centerPage()
            scrollView.panGestureRecognizer.isEnabled = false
            emitViewport()
            // A geometry change refits UIKit's scroll view. Reapply the selected
            // page's deterministic state so the control and rendered viewport agree.
            appliedViewportTransitionGeneration = 0
            applyViewportTransitionIfNeeded()
        }

        func applyViewportTransitionIfNeeded() {
            guard let scrollView,
                  parent.viewportTransitionGeneration != appliedViewportTransitionGeneration,
                  scrollView.bounds.size != .zero,
                  host?.view.bounds.size != .zero else { return }

            appliedViewportTransitionGeneration = parent.viewportTransitionGeneration
            if parent.viewportTransitionGeneration.isMultiple(of: 2) {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                scrollView.contentOffset = .zero
            } else {
                scrollView.setZoomScale(1.75, animated: false)
                let maximumOffset = CGPoint(
                    x: max(0, scrollView.contentSize.width - scrollView.bounds.width),
                    y: max(0, scrollView.contentSize.height - scrollView.bounds.height)
                )
                scrollView.contentOffset = CGPoint(
                    x: maximumOffset.x * 0.37,
                    y: maximumOffset.y * 0.29
                )
            }
            centerPage()
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.0001
            emitViewport()
        }

        private func centerPage() {
            guard let scrollView, let pageView = host?.view else { return }
            let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            pageView.center = CGPoint(
                x: scrollView.contentSize.width / 2 + horizontal,
                y: scrollView.contentSize.height / 2 + vertical
            )
        }

        private func emitViewport() {
            guard let scrollView, let pageView = host?.view,
                  pageView.bounds.width > 0, pageView.bounds.height > 0 else { return }
            let origin = pageView.convert(CGPoint.zero, to: scrollView)
            let transform = PageViewportTransform(
                pageCanvasSize: PageCanvasSize(
                    width: Double(pageView.bounds.width),
                    height: Double(pageView.bounds.height)
                ),
                zoomScale: Double(scrollView.zoomScale),
                pageOriginInView: PageViewPoint(x: Double(origin.x), y: Double(origin.y))
            )
            parent.onViewportChanged(PageViewportState(pageID: parent.page.id, transform: transform))
        }
    }

    private var logicalPageSize: CGSize {
        switch page.background {
        case let .blank(_, dimensions):
            CGSize(width: dimensions.width, height: dimensions.height)
        case .pdf:
            pdfPage?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792)
        }
    }
}

private final class FittedPageScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// MARK: - Page content

private struct SpatialPageContent: View {
    let page: PageRecord
    let pdfPage: PDFPage?
    let drawingData: Data?
    let toolMode: CanvasToolMode
    let penFixture: PenFixture?
    let anchors: [SpatialCanvasAnchor]
    let pageOverlay: (PageRecord, PageAnchorProjection) -> AnyView
    let onDrawingChanged: (UUID, Data) -> Void
    let onDrawingSnapshot: (UUID, PKDrawing, CGSize) -> Void

    var body: some View {
        ZStack {
            SpatialPageBackground(background: page.background, pdfPage: pdfPage)

            PagePencilCanvas(
                pageID: page.id,
                drawingData: drawingData,
                toolMode: toolMode,
                penFixture: penFixture,
                onDrawingChanged: onDrawingChanged,
                onDrawingSnapshot: onDrawingSnapshot
            )

            GeometryReader { proxy in
                ForEach(anchors) { anchor in
                    if anchor.target.isFiniteAndInUnitBounds {
                        anchor.content
                            .position(
                                x: anchor.target.x * proxy.size.width,
                                y: anchor.target.y * proxy.size.height
                            )
                            .accessibilityIdentifier("spatial-anchor-\(anchor.id.uuidString)")
                    }
                }
            }

            GeometryReader { proxy in
                pageOverlay(
                    page,
                    PageAnchorProjection(
                        pageCanvasSize: PageCanvasSize(
                            width: proxy.size.width,
                            height: proxy.size.height
                        )
                    )
                )
            }
        }
        .clipShape(Rectangle())
        .background(.white)
    }
}

private struct SpatialPageBackground: UIViewRepresentable {
    let background: PageBackground
    let pdfPage: PDFPage?

    func makeUIView(context: Context) -> SpatialPageBackgroundView {
        let view = SpatialPageBackgroundView()
        view.isOpaque = true
        view.background = background
        view.pdfPage = pdfPage
        return view
    }

    func updateUIView(_ view: SpatialPageBackgroundView, context: Context) {
        view.background = background
        view.pdfPage = pdfPage
        view.setNeedsDisplay()
    }
}

private final class SpatialPageBackgroundView: UIView {
    var background: PageBackground = .blank(style: .tuberDotGrid, dimensions: .tuberPortrait)
    var pdfPage: PDFPage?

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        switch background {
        case let .blank(style, _):
            drawPaper(style: style, in: bounds, context: context)
        case .pdf:
            drawPDF(in: bounds, context: context)
        }
    }

    private func drawPaper(style: PaperStyle, in rect: CGRect, context: CGContext) {
        let paper = UIColor(red: 0.992, green: 0.978, blue: 0.936, alpha: 1)
        context.setFillColor(paper.cgColor)
        context.fill(rect)

        let margin = max(28, min(rect.width, rect.height) * 0.055)
        let spacing = max(18, min(rect.width, rect.height) / 27)
        let ink = UIColor(red: 0.20, green: 0.25, blue: 0.42, alpha: 0.17)
        context.setFillColor(ink.cgColor)
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(0.7)

        switch style {
        case .plain:
            break
        case .ruled:
            stride(from: margin + spacing, through: rect.height - margin, by: spacing).forEach { y in
                context.move(to: CGPoint(x: margin, y: y))
                context.addLine(to: CGPoint(x: rect.width - margin, y: y))
            }
            context.strokePath()
        case .grid:
            stride(from: margin, through: rect.width - margin, by: spacing).forEach { x in
                context.move(to: CGPoint(x: x, y: margin))
                context.addLine(to: CGPoint(x: x, y: rect.height - margin))
            }
            stride(from: margin, through: rect.height - margin, by: spacing).forEach { y in
                context.move(to: CGPoint(x: margin, y: y))
                context.addLine(to: CGPoint(x: rect.width - margin, y: y))
            }
            context.strokePath()
        case .tuberDotGrid:
            let radius = max(0.8, min(1.35, spacing * 0.055))
            stride(from: margin, through: rect.width - margin, by: spacing).forEach { x in
                stride(from: margin, through: rect.height - margin, by: spacing).forEach { y in
                    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                }
            }
            drawBrand(in: rect, margin: margin)
        }
    }

    private func drawBrand(in rect: CGRect, margin: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(9, rect.width * 0.018), weight: .semibold),
            .foregroundColor: UIColor(red: 0.36, green: 0.28, blue: 0.18, alpha: 0.42),
            .paragraphStyle: paragraph
        ]
        NSString(string: "TUBERNOTES  •  GROW IDEAS HERE").draw(
            in: CGRect(x: margin, y: rect.height - margin + 7, width: rect.width - margin * 2, height: margin - 8),
            withAttributes: attributes
        )
    }

    private func drawPDF(in rect: CGRect, context: CGContext) {
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)

        guard let pdfPage else {
            let text = "PDF page unavailable"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: .headline),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let size = NSString(string: text).size(withAttributes: attributes)
            NSString(string: text).draw(
                at: CGPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2),
                withAttributes: attributes
            )
            return
        }

        // Render once with headroom for the viewport's 4x maximum zoom. Preserve
        // aspect ratio when capping either dimension so PDF geometry never warps.
        let screenScale = max(window?.screen.scale ?? UIScreen.main.scale, 1)
        let desired = CGSize(width: rect.width * screenScale * 4, height: rect.height * screenScale * 4)
        let capScale = min(1, 4096 / max(desired.width, desired.height))
        let pixelSize = CGSize(width: desired.width * capScale, height: desired.height * capScale)
        let thumbnail = pdfPage.thumbnail(of: pixelSize, for: .mediaBox)
        thumbnail.draw(in: rect)
    }
}

// MARK: - Deterministic standalone fixture

enum SpatialCanvasFixtures {
    struct Configuration {
        let document: NotebookDocument
        let activePageID: UUID
        let pdfDocument: PDFDocument?
        let penFixturesByPageID: [UUID: PenFixture]
        let anchors: [SpatialCanvasAnchor]
    }

    /// Standalone fixture/config entry points for the M0 scenario names. App owns
    /// launch routing; this factory lets it host each state without inventing data.
    static func configuration(for scenario: String) -> Configuration? {
        let documentID = UUID(uuidString: "510A7100-0000-4000-8000-000000000001")!
        let pageIDs = (1 ... 3).map {
            UUID(uuidString: String(format: "510A7100-0000-4000-8000-%012d", $0 + 1))!
        }

        func pdfDocument(activeIndex: Int) -> NotebookDocument {
            NotebookDocument(
                id: documentID,
                title: "M0 Spatial PDF",
                source: .bundledPDF(resourceName: "M0Demo"),
                pages: pageIDs.enumerated().map { index, id in
                    PageRecord(
                        id: id,
                        index: index,
                        background: .pdf(documentID: documentID, pageIndex: index),
                        inkReference: nil,
                        annotations: []
                    )
                },
                currentPageID: pageIDs[activeIndex]
            )
        }

        func notebook(pageCount: Int, activeIndex: Int) -> NotebookDocument {
            NotebookDocument(
                id: documentID,
                title: "M0 Dot-Grid Notebook",
                source: .notebook(defaultPaperStyle: .tuberDotGrid),
                pages: pageIDs.prefix(pageCount).enumerated().map { index, id in
                    PageRecord(
                        id: id,
                        index: index,
                        background: .blank(style: .tuberDotGrid, dimensions: .tuberPortrait),
                        inkReference: nil,
                        annotations: []
                    )
                },
                currentPageID: pageIDs[activeIndex]
            )
        }

        switch scenario {
        case "pdf-pages":
            return Configuration(
                document: pdfDocument(activeIndex: 1),
                activePageID: pageIDs[1],
                pdfDocument: makeM0DemoPDF(),
                penFixturesByPageID: [:],
                anchors: []
            )
        case "blank-notebook":
            return Configuration(
                document: notebook(pageCount: 1, activeIndex: 0),
                activePageID: pageIDs[0],
                pdfDocument: nil,
                penFixturesByPageID: [:],
                anchors: []
            )
        case "notebook-pages":
            return Configuration(
                document: notebook(pageCount: 2, activeIndex: 1),
                activePageID: pageIDs[1],
                pdfDocument: nil,
                penFixturesByPageID: [
                    pageIDs[0]: pageFixture(name: "notebook-page-1", offset: 0.0),
                    pageIDs[1]: pageFixture(name: "notebook-page-2", offset: 0.16)
                ],
                anchors: []
            )
        case "ink-pages":
            return Configuration(
                document: pdfDocument(activeIndex: 1),
                activePageID: pageIDs[1],
                pdfDocument: makeM0DemoPDF(),
                penFixturesByPageID: [
                    pageIDs[0]: pageFixture(name: "pdf-page-1", offset: 0.0),
                    pageIDs[1]: pageFixture(name: "pdf-page-2", offset: 0.14)
                ],
                anchors: []
            )
        case "pin-drift":
            let anchorID = UUID(uuidString: "510A7100-0000-4000-8000-000000000099")!
            return Configuration(
                document: pdfDocument(activeIndex: 1),
                activePageID: pageIDs[1],
                pdfDocument: makeM0DemoPDF(),
                penFixturesByPageID: [:],
                anchors: [
                    SpatialCanvasAnchor(
                        id: anchorID,
                        pageID: pageIDs[1],
                        target: PageNormalizedPoint(x: 0.69, y: 0.49)
                    ) {
                        ZStack {
                            Circle().fill(.orange)
                            Circle().stroke(.white, lineWidth: 3)
                            Image(systemName: "scope")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)
                        .shadow(radius: 4, y: 2)
                    }
                ]
            )
        default:
            return nil
        }
    }

    /// A network-free, known three-page PDF suitable for `pdf-pages` and `pin-drift`.
    /// The coordinator may instead pass a bundled/imported `PDFDocument`.
    static func makeM0DemoPDF() -> PDFDocument {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { rendererContext in
            for page in 1 ... 3 {
                rendererContext.beginPage()
                UIColor.white.setFill()
                rendererContext.fill(bounds)

                let accent = [UIColor.systemOrange, .systemIndigo, .systemGreen][page - 1]
                accent.setFill()
                rendererContext.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: bounds.height))

                NSString(string: "TuberNotes M0 • Page \(page)").draw(
                    at: CGPoint(x: 56, y: 58),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 28, weight: .bold),
                        .foregroundColor: UIColor.label
                    ]
                )
                NSString(string: "Stable page \(page) • PDF background fixture").draw(
                    at: CGPoint(x: 58, y: 105),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 15, weight: .medium),
                        .foregroundColor: UIColor.secondaryLabel
                    ]
                )

                let equations = [
                    "f(x) = x² + 3x − 4",
                    "∫₀¹ 3x² dx = [x³]₀¹ = 1",
                    "E = mc²   •   Δy / Δx = m"
                ]
                NSString(string: equations[page - 1]).draw(
                    in: CGRect(x: 78, y: 210, width: 460, height: 60),
                    withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                        .foregroundColor: UIColor.label
                    ]
                )

                for row in 0 ..< 8 {
                    let y = CGFloat(330 + row * 42)
                    UIColor.systemGray5.setStroke()
                    rendererContext.cgContext.setLineWidth(1)
                    rendererContext.cgContext.move(to: CGPoint(x: 76, y: y))
                    rendererContext.cgContext.addLine(to: CGPoint(x: 536, y: y))
                    rendererContext.cgContext.strokePath()
                }
            }
        }
        return PDFDocument(data: data) ?? PDFDocument()
    }

    private static func pageFixture(name: String, offset: CGFloat) -> PenFixture {
        PenFixture(
            name: name,
            description: "Deterministic ink owned by a stable page ID",
            events: [
                .init(x: 0.18, y: 0.35 + offset, time: 0.00, phase: .began, pressure: 0.7, altitude: nil, azimuth: nil),
                .init(x: 0.30, y: 0.31 + offset, time: 0.06, phase: .moved, pressure: 0.8, altitude: nil, azimuth: nil),
                .init(x: 0.42, y: 0.37 + offset, time: 0.12, phase: .moved, pressure: 0.8, altitude: nil, azimuth: nil),
                .init(x: 0.56, y: 0.30 + offset, time: 0.18, phase: .moved, pressure: 0.8, altitude: nil, azimuth: nil),
                .init(x: 0.70, y: 0.36 + offset, time: 0.24, phase: .ended, pressure: 0.7, altitude: nil, azimuth: nil)
            ],
            requestID: nil,
            recordedAt: nil
        )
    }
}
