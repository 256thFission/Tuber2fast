import Foundation
import PencilKit
import Testing

@testable import TuberNotes

/// Behavior of the editor's save policy and page extension.
///
/// Each test builds its own session, so each builds its own canvas controller.
/// That is not the hazard the contract guards against — a *hosted* second canvas
/// is, and hosting is what registers liveness.
@Suite("Editor session", .serialized)
@MainActor
struct EditorSessionTests {
    // MARK: - Launch

    @Test("First launch creates and saves one valid document")
    func firstLaunchCreatesDocument() async throws {
        let scratch = Scratch()
        let session = scratch.session()

        await session.start()

        #expect(session.phase == .ready)
        #expect(session.pageHeight == PageGeometry.initialHeight)

        let saved = try await scratch.store.load()
        #expect(saved != nil)
        #expect(saved?.pageWidth == PageGeometry.width)
        #expect(saved?.pageHeight == PageGeometry.initialHeight)
    }

    @Test("A later launch restores the saved drawing and page height")
    func relaunchRestoresDocument() async throws {
        let scratch = Scratch()

        let first = scratch.session()
        await first.start()
        first.extendPage()
        first.canvas.canvasView.drawing = strokeAcrossPage()
        await first.saveIfNeeded()

        let second = scratch.session()
        await second.start()

        #expect(second.phase == .ready)
        #expect(second.pageHeight == PageGeometry.initialHeight * 2)
        #expect(second.canvas.canvasView.drawing.strokes.count == 1)
        #expect(second.canvas.canvasView.drawing.bounds == strokeAcrossPage().bounds)
    }

    @Test("Invalid stored data fails loudly and leaves the file untouched")
    func invalidDocumentFailsWithoutOverwriting() async throws {
        let scratch = Scratch()
        let garbage = Data("not a canvas".utf8)
        try garbage.write(to: scratch.fileURL)

        let session = scratch.session()
        await session.start()

        guard case .failed = session.phase else {
            Issue.record("expected a failed phase, got \(session.phase)")
            return
        }
        #expect(try Data(contentsOf: scratch.fileURL) == garbage)
    }

    @Test("Loading a document does not mark it dirty")
    func loadingDoesNotDirtyTheDocument() async throws {
        let scratch = Scratch()
        let first = scratch.session()
        await first.start()
        first.canvas.canvasView.drawing = strokeAcrossPage()
        await first.saveIfNeeded()

        let second = scratch.session()
        await second.start()

        // Installing the loaded drawing fires PencilKit's change callback. If
        // that were treated as an edit, this save would rewrite the file.
        let before = try Data(contentsOf: scratch.fileURL)
        await second.saveIfNeeded()
        #expect(try Data(contentsOf: scratch.fileURL) == before)
    }

    // MARK: - Page extension

    @Test("Extending raises the height by exactly one increment and persists it")
    func extensionRaisesHeight() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()

        session.extendPage()
        #expect(session.pageHeight == PageGeometry.initialHeight * 2)
        #expect(session.canvas.pageHeight == PageGeometry.initialHeight * 2)

        await session.saveIfNeeded()
        #expect(try await scratch.store.load()?.pageHeight == PageGeometry.initialHeight * 2)
    }

    @Test("Extension is refused at the maximum height and changes nothing")
    func extensionRefusedAtMaximum() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()

        for _ in 0..<(PageGeometry.maximumExtents - 1) {
            session.extendPage()
        }
        #expect(session.pageHeight == PageGeometry.maximumHeight)
        #expect(session.canExtend == false)

        await session.saveIfNeeded()
        let atMaximum = try await scratch.store.load()

        session.extendPage()

        #expect(session.pageHeight == PageGeometry.maximumHeight)
        #expect(session.canvas.pageHeight == PageGeometry.maximumHeight)
        await session.saveIfNeeded()
        #expect(try await scratch.store.load() == atMaximum)
    }

    @Test("Extending leaves existing ink at the same page coordinates")
    func extensionDoesNotMoveInk() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()

        let root = session.canvas.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        session.canvas.canvasView.drawing = strokeAcrossPage()
        let authored = session.canvas.canvasView.drawing.bounds
        let zoom = session.canvas.canvasView.zoomScale
        let offset = session.canvas.canvasView.contentOffset

        session.extendPage()
        root.layoutIfNeeded()

        #expect(session.canvas.canvasView.drawing.bounds == authored)
        #expect(session.canvas.canvasView.zoomScale == zoom)
        #expect(session.canvas.canvasView.contentOffset == offset)
    }

    @Test("The zoom floor does not move as the page grows")
    func extensionDoesNotChangeZoomFloor() async {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()

        let root = session.canvas.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let floor = session.canvas.canvasView.minimumZoomScale
        session.extendPage()
        session.extendPage()
        root.layoutIfNeeded()

        // A whole-page floor would shrink here; a width floor cannot.
        #expect(session.canvas.canvasView.minimumZoomScale == floor)
    }

    // MARK: - Autosave

    @Test("A drawing change is debounced and then saved")
    func drawingChangeIsDebouncedAndSaved() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()
        let initial = try await scratch.store.load()

        session.canvas.canvasView.drawing = strokeAcrossPage()
        // The change callback comes from PencilKit's delegate on the real
        // device; assigning `drawing` fires the same path here.
        try await Task.sleep(for: .milliseconds(120))

        let saved = try await scratch.store.load()
        #expect(saved != initial)
        try expectSavedStroke(in: saved)
    }

    @Test("A failed save leaves the document dirty and retryable")
    func failedSaveStaysDirty() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()

        // Make the destination unwritable by replacing the directory with a file.
        try FileManager.default.removeItem(at: scratch.directory)
        try Data().write(to: scratch.directory)

        session.canvas.canvasView.drawing = strokeAcrossPage()
        await session.saveIfNeeded()
        #expect(session.lastSaveError != nil)

        // Restore the directory; the retry must succeed with the live ink.
        try FileManager.default.removeItem(at: scratch.directory)
        try FileManager.default.createDirectory(
            at: scratch.directory,
            withIntermediateDirectories: true
        )
        await session.saveIfNeeded()

        #expect(session.lastSaveError == nil)
        try expectSavedStroke(in: await scratch.store.load())
    }

    @Test("Backgrounding flushes pending ink")
    func backgroundFlushSaves() async throws {
        let scratch = Scratch()
        let session = scratch.session(debounce: .seconds(30))
        await session.start()

        session.canvas.canvasView.drawing = strokeAcrossPage()
        // The debounce is far in the future; only the flush can save this.
        await session.flushForBackground()

        try expectSavedStroke(in: await scratch.store.load())
    }

    // MARK: - Fixtures

    /// Asserts the saved bytes reconstruct the fixture stroke.
    ///
    /// Compared by reconstructed geometry rather than by serialized bytes:
    /// `PKDrawing.dataRepresentation()` is not byte-stable across separately
    /// constructed but equal drawings, so a byte comparison would test the
    /// encoder's determinism rather than the durability the contract promises.
    private func expectSavedStroke(in file: CanvasFile?) throws {
        let file = try #require(file)
        let restored = try PKDrawing(data: file.drawingData)
        #expect(restored.strokes.count == 1)
        #expect(restored.bounds == strokeAcrossPage().bounds)
    }

    private func strokeAcrossPage() -> PKDrawing {
        let locations = [
            CGPoint(x: 100, y: 150),
            CGPoint(x: 300, y: 400),
            CGPoint(x: 500, y: 650),
        ]
        let points = locations.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: Double(index) * 0.01,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }

    private final class Scratch {
        let directory: URL
        let store: DocumentStore

        var fileURL: URL { directory.appendingPathComponent("JustACanvas.canvas") }

        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-session-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            store = DocumentStore(fileURL: directory.appendingPathComponent("JustACanvas.canvas"))
        }

        /// A short debounce by default: these tests assert the debounce fires,
        /// not that it waits 500 ms.
        @MainActor
        func session(debounce: Duration = .milliseconds(20)) -> EditorSession {
            EditorSession(store: store, debounce: debounce)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
