import Foundation
import PencilKit
import Testing
@testable import TuberCanvas
@testable import TuberModel
@testable import TuberNotes
@testable import TuberStore

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
        let scratch = try TestScratch("session")
        let session = scratch.session()

        await session.start()

        #expect(session.phase == .ready)

        #expect(try await savedDrawing(scratch.store) != nil)

        let index = try #require(await scratch.store.load())
        #expect(index.formatVersion == DocumentIndex.currentFormatVersion)
        #expect(index.pages.map(\.geometry) == [PageGeometry.canonical])
        #expect(index.zoomCapPagePointsPerPixel
            == DocumentIndex.canonicalZoomCapPagePointsPerPixel)
        #expect(index.pageIDs == [session.currentPageID])
        #expect(index.currentPageIndex == 0)
    }

    @Test("A later launch restores the saved drawing")
    func relaunchRestoresDocument() async throws {
        let scratch = try TestScratch("session")

        let first = scratch.session()
        await first.start()
        try await canvas(of: first).drawing = strokeAcrossPage()
        await first.saveIfNeeded()

        let second = scratch.session()
        await second.start()

        #expect(second.phase == .ready)
        #expect(try await canvas(of: second).drawing.strokes.count == 1)
        #expect(try await canvas(of: second).drawing.bounds == strokeAcrossPage().bounds)
    }

    @Test("Invalid stored data fails loudly and leaves the file untouched")
    func invalidDocumentFailsWithoutOverwriting() async throws {
        let scratch = try TestScratch("session")
        let garbage = Data("not a canvas".utf8)
        try scratch.writeGarbageIndex(garbage)

        let session = scratch.session()
        await session.start()

        guard case .failed = session.phase else {
            Issue.record("expected a failed phase, got \(session.phase)")
            return
        }
        #expect(try Data(contentsOf: scratch.indexURL) == garbage)
    }

    @Test("Loading a document does not mark it dirty")
    func loadingDoesNotDirtyTheDocument() async throws {
        let scratch = try TestScratch("session")
        let first = scratch.session()
        await first.start()
        try await canvas(of: first).drawing = strokeAcrossPage()
        await first.saveIfNeeded()

        let second = scratch.session()
        await second.start()

        // Laying out is what builds the pages and installs their ink, and
        // installing is what fires PencilKit's change callback. Without this
        // line the runtime never loads, no canvas is ever built, and the test
        // asserts that a file nothing touched is unchanged — which is what it
        // used to do.
        _ = try await canvas(of: second)

        // Deleting the page file makes a rewrite unmissable: a session that
        // believes the loaded page is dirty recreates it, and a clean one leaves
        // it absent. Comparing bytes would not do, because re-serializing the
        // same drawing can reproduce them exactly.
        let pageURL = scratch.currentPageURL(of: second)
        try FileManager.default.removeItem(at: pageURL)
        await second.saveIfNeeded()
        #expect(!FileManager.default.fileExists(atPath: pageURL.path))
    }

    @Test("A page that retires with unsaved ink keeps it, on screen and on disk")
    func retiredPageKeepsItsInk() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session()
        await session.start()
        _ = try await canvas(of: session)
        let firstPageID = session.currentPageID

        // Three pages, so page 0 leaves the live window once page 2 is visible.
        pullPastTheEnd(session)
        pullPastTheEnd(session)
        await session.saveIfNeeded()

        turn(session, to: 0)
        try await canvas(of: session).drawing = twoStrokesAcrossPage()
        // Away before the debounce fires: page 0's canvas is released here, and
        // its ink survives only if retirement handed the value over rather than
        // promising to serialize it later.
        turn(session, to: 2)
        turn(session, to: 0)

        #expect(try await canvas(of: session).drawing.strokes.count == 2)

        await session.saveIfNeeded()
        #expect(try PKDrawing(data: await scratch.store.loadPage(firstPageID).inkData).strokes.count == 2)
    }

    @Test("Restarting the view task does not reload over live ink")
    func repeatedStartIsIdempotent() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session()
        await session.start()
        try await canvas(of: session).drawing = strokeAcrossPage()

        await session.start()

        #expect(session.phase == .ready)
        #expect(try await canvas(of: session).drawing.strokes.count == 1)
    }

    // MARK: - Pages

    @Test("Pulling past the last page appends one and turns to it")
    func appendPastTheEndAddsAPage() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session()
        await session.start()
        _ = try await canvas(of: session)
        #expect(session.pageCount == 1)

        pullPastTheEnd(session)

        #expect(session.pageCount == 2)
        #expect(session.pages.currentPageIndex == 1)
    }

    @Test("An accidental swipe past the end does not grow the saved document")
    func unwrittenAppendedPageIsNotDurable() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session()
        await session.start()
        _ = try await canvas(of: session)

        // Three flicks past the end, exactly as a thumb does by accident, and
        // then everything the app would ever do to write: the debounced pass
        // the append arms, and an explicit flush on top of it.
        for _ in 0..<3 { pullPastTheEnd(session) }
        #expect(session.pageCount == 4)
        await session.saveIfNeeded()

        // On screen there are four pages; in the file there is one, and it is
        // the one the user actually wrote. Nothing has to reclaim anything.
        let saved = try #require(await scratch.store.load())
        #expect(saved.pageIDs.count == 1)
        #expect(saved.currentPageIndex == 0)

        // And a relaunch agrees: the blank pages were never there.
        let second = scratch.session()
        await second.start()
        #expect(second.pageCount == 1)
    }

    @Test("An appended page becomes durable the moment it takes ink")
    func inkedAppendedPageIsDurable() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session()
        await session.start()
        _ = try await canvas(of: session)
        let firstPageID = session.currentPageID

        // Two overswipes, and ink on only the second page. The page between
        // them is written on, so it is a page of the document; the one after
        // it is not.
        pullPastTheEnd(session)
        let inkedPageID = session.currentPageID
        try await canvas(of: session).drawing = strokeAcrossPage()
        pullPastTheEnd(session)
        await session.saveIfNeeded()

        let saved = try #require(await scratch.store.load())
        #expect(saved.pageIDs == [firstPageID, inkedPageID])
        #expect(saved.currentPageIndex == 1)
        #expect(try PKDrawing(data: await scratch.store.loadPage(inkedPageID).inkData)
            .strokes.count == 1)

        let second = scratch.session()
        await second.start()
        #expect(second.pageCount == 2)
        #expect(second.pages.currentPageIndex == 1)
    }

    @Test("Ink on each page is saved to that page and restored there")
    func inkStaysOnItsOwnPage() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session()
        await session.start()

        try await canvas(of: session).drawing = strokeAcrossPage()
        let firstPageID = session.currentPageID

        pullPastTheEnd(session)
        try await canvas(of: session).drawing = twoStrokesAcrossPage()
        let secondPageID = session.currentPageID
        #expect(firstPageID != secondPageID)

        await session.saveIfNeeded()

        // Read the pages back by identity, not by whatever is on screen.
        #expect(try PKDrawing(data: await scratch.store.loadPage(firstPageID).inkData).strokes.count == 1)
        #expect(try PKDrawing(data: await scratch.store.loadPage(secondPageID).inkData).strokes.count == 2)
    }

    @Test("A relaunch restores the page list and the page the user left on")
    func relaunchRestoresPagesAndPosition() async throws {
        let scratch = try TestScratch("session")
        let first = scratch.session()
        await first.start()
        try await canvas(of: first).drawing = strokeAcrossPage()
        pullPastTheEnd(first)
        try await canvas(of: first).drawing = twoStrokesAcrossPage()
        await first.saveIfNeeded()

        let second = scratch.session()
        await second.start()
        let restored = try await canvas(of: second)

        #expect(second.pageCount == 2)
        #expect(second.pages.currentPageIndex == 1)
        #expect(restored.drawing.strokes.count == 2)
    }

    @Test("Editing one page rewrites that page's file alone")
    func savingOnePageDoesNotRewriteTheOther() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session()
        await session.start()
        try await canvas(of: session).drawing = strokeAcrossPage()
        let firstPageID = session.currentPageID

        pullPastTheEnd(session)
        try await canvas(of: session).drawing = twoStrokesAcrossPage()
        await session.saveIfNeeded()

        // Backdated rather than waited out: a rewrite cannot hide inside a
        // timestamp resolution it is twenty-five years away from.
        try scratch.freezeTimestamps()
        try await canvas(of: session).drawing = strokeAcrossPage()
        await session.saveIfNeeded()

        // The whole point of the format: page one was not touched. Since the
        // layer split the page file alone proves less than it used to — an ink
        // save never rewrites a page file — so the ink layer's own file is
        // checked, which is where page one's bytes actually are.
        #expect(try scratch.modificationDate(ofPage: firstPageID) == TestScratch.frozen)
        #expect(try scratch.inkWrittenAt(ofPage: firstPageID) == TestScratch.frozen)
    }

    @Test("Turning away from a page and back does not rewrite its file")
    func turningAwayAndBackDoesNotRewriteThePage() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session()
        await session.start()
        try await canvas(of: session).drawing = strokeAcrossPage()
        let firstPageID = session.currentPageID

        // Enough pages that page 0 is evicted from the live window *and* its
        // held bytes are pruned, so turning back rebuilds it from disk. This is
        // `savingOnePageDoesNotRewriteTheOther` with enough pages to evict:
        // with only two pages the first never leaves the window and the rebuild
        // path is never exercised.
        for _ in 0..<4 { pullPastTheEnd(session) }
        await session.saveIfNeeded()
        // Backdated rather than waited out, as above.
        try scratch.freezeTimestamps()

        // Back to page 0 — its ink is re-installed into a fresh canvas — and
        // away again, so the rebuilt page also retires once more. The bytes
        // were pruned when the window moved on, so the rebuild waits on the
        // refetch landing.
        turn(session, to: 0)
        try await waitUntil("page 0's ink is reloaded into its rebuilt canvas") {
            session.currentCanvas?.canvasView.drawing.strokes.count == 1
        }
        turn(session, to: 4)
        await session.saveIfNeeded()

        // Installing ink is never reported as an edit (`Contract.md` —
        // Lifecycle): a turn that changed nothing writes nothing — neither the
        // page file nor the layer file its ink actually lives in.
        #expect(try scratch.modificationDate(ofPage: firstPageID) == TestScratch.frozen)
        #expect(try scratch.inkWrittenAt(ofPage: firstPageID) == TestScratch.frozen)
    }

    @Test("Ink drawn on a page that then scrolls out of the window is still saved")
    func inkSurvivesItsPageLeavingTheWindow() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session(debounce: .seconds(30))
        await session.start()

        try await canvas(of: session).drawing = strokeAcrossPage()
        let inkedPageID = session.currentPageID

        // Four appends put the inked page well outside the live window, so its
        // canvas is released before any save has run. Retirement hands the
        // drawing over synchronously, so there is nothing to wait for here — a
        // sleep at this point would be stepping over the exact race this test
        // exists to catch.
        for _ in 0..<4 { pullPastTheEnd(session) }
        #expect(session.pages.livePage(at: 0) == nil)

        await session.saveIfNeeded()

        #expect(try PKDrawing(data: await scratch.store.loadPage(inkedPageID).inkData).strokes.count == 1)
    }

    @Test("Pulling past the last page during an in-flight save appends immediately")
    func appendDuringAnInFlightSaveGrowsTheDocument() async throws {
        let scratch = try TestScratch("session")
        let held = HeldSaveStore(scratch.store)
        let session = scratch.session(debounce: .seconds(30), store: held)
        await session.start()
        try await canvas(of: session).drawing = strokeAcrossPage()

        // Hold a save genuinely in flight — the store does not return until
        // this test says so, so nothing below is racing a timer.
        await held.hold()
        let save = Task { await session.saveIfNeeded() }
        await Task.yield()

        // Navigation says "immediately" — not "unless a save happens to be
        // running". The append is safe during the save: the pass holds its
        // captured index by value and the store validates against that capture.
        pullPastTheEnd(session)
        #expect(session.pageCount == 2)
        #expect(session.pages.currentPageIndex == 1)

        // Written on, so the page is one the document keeps — an unwritten one
        // would prove nothing about the append here, only about the withholding
        // `unwrittenAppendedPageIsNotDurable` pins.
        try await canvas(of: session).drawing = twoStrokesAcrossPage()

        await held.release()
        await save.value
        await session.saveIfNeeded()
        let saved = try #require(await scratch.store.load())
        #expect(saved.pageIDs.count == 2)
        #expect(saved.currentPageIndex == 1)
    }

    @Test("Work arriving during a background flush is saved with no user action")
    func workDuringAFlushIsRearmed() async throws {
        let scratch = try TestScratch("session")
        let held = HeldSaveStore(scratch.store)
        let session = scratch.session(store: held)
        await session.start()
        try await canvas(of: session).drawing = strokeAcrossPage()

        await held.hold()
        let flush = Task { await session.flushForBackground() }
        await Task.yield()

        // The user returns and draws while the flush's save is still writing.
        // Under the old saveInFlight early-returns this stroke ended up dirty
        // with no timer, no flush, and no error — parked until the user
        // happened to draw again.
        session.resumeForForeground()
        try await canvas(of: session).drawing = twoStrokesAcrossPage()
        await held.release()
        await flush.value

        // No Retry tap, no further drawing, no scene transition: the newer
        // ink must reach disk by itself, on the fresh debounce the save's
        // exit armed.
        try await waitUntil("the re-armed debounce saves the newer ink") {
            guard let data = try await savedDrawing(scratch.store) else { return false }
            return (try? PKDrawing(data: data))?.strokes.count == 2
        }
    }

    @Test("A page that retires during a save that then fails keeps its ink")
    func retirementDuringAFailedSaveKeepsInk() async throws {
        let scratch = try TestScratch("session")
        let held = HeldSaveStore(scratch.store)
        let session = scratch.session(debounce: .seconds(30), store: held)
        await session.start()
        _ = try await canvas(of: session)

        // Five pages, all saved, then back to page 0 for the edit under test.
        // Five rather than three because retirement is what this test needs and
        // the live window is two pages either side (`PagedCanvasController`);
        // page 0 must be able to leave it.
        pullPastTheEnd(session)
        pullPastTheEnd(session)
        pullPastTheEnd(session)
        pullPastTheEnd(session)
        await session.saveIfNeeded()
        turn(session, to: 0)
        try await canvas(of: session).drawing = strokeAcrossPage()
        let inkedPageID = session.currentPageID

        // Hold the save open, and make it fail: the directory becomes a file
        // while the store is held, so the write throws when it is let go.
        await held.hold()
        try FileManager.default.removeItem(at: scratch.root)
        try Data().write(to: scratch.root)

        let save = Task { await session.saveIfNeeded() }
        // One yield lets the save capture its generation and suspend. The
        // inked page is now in the save's batch, unacknowledged.
        await Task.yield()

        // While the save is in flight, the page leaves the live window and its
        // canvas is released. The old code dropped the handover here — the
        // page was not in the dirty set, so retirement surrendered nothing —
        // and the failed save's retry then wrote the pre-edit bytes and
        // acknowledged the page clean.
        turn(session, to: 4)
        #expect(session.pages.livePage(at: 0) == nil)

        await held.release()
        await save.value
        #expect(session.lastSaveError != nil)

        // The store starts working again; the retry must write the real ink.
        try FileManager.default.removeItem(at: scratch.root)
        try FileManager.default.createDirectory(
            at: scratch.root,
            withIntermediateDirectories: true
        )
        await session.saveIfNeeded()

        #expect(session.lastSaveError == nil)
        #expect(try PKDrawing(data: await scratch.store.loadPage(inkedPageID).inkData).strokes.count == 1)
    }

    @Test("One unreadable page neither fails the launch nor stalls its neighbours")
    func oneUnreadablePageDoesNotStallTheWindow() async throws {
        let scratch = try TestScratch("session")
        let first = scratch.session()
        await first.start()
        _ = try await canvas(of: first)
        pullPastTheEnd(first)
        pullPastTheEnd(first)
        try await canvas(of: first).drawing = strokeAcrossPage()
        await first.saveIfNeeded()

        // Corrupt the middle page's file on disk. The file exists — a missing
        // file is a dangling reference and fatal by contract — but its bytes
        // cannot be read.
        let corruptedID = try #require(await scratch.store.load()).pageIDs[1]
        try scratch.corruptPageFile(pageID: corruptedID)

        // Relaunch onto page 2. The opening window covers the corrupt page:
        // it must refuse itself without taking the launch down with it, and
        // the pages after it in the fetch loop must still load.
        let second = scratch.session()
        await second.start()
        #expect(second.phase == .ready)
        #expect(try await canvas(of: second).drawing.strokes.count == 1)

        // The document stays editable and savable around the refused page,
        // and saving does not touch it.
        try await canvas(of: second).drawing = twoStrokesAcrossPage()
        await second.saveIfNeeded()
        #expect(second.lastSaveError == nil)
        do {
            _ = try await scratch.store.loadPage(corruptedID)
            Issue.record("the corrupt page file was unexpectedly readable")
        } catch {
            // Still refusing, which is the point: nothing wrote over it.
        }

        // The refused page is a placeholder, not a canvas: there is nothing to
        // draw on, so no ink can exist for a save to misaccount.
        turn(second, to: 1)
        #expect(second.pages.livePage(at: 1) == nil)
    }

    // MARK: - Autosave

    @Test("A drawing change is debounced and then saved")
    func drawingChangeIsDebouncedAndSaved() async throws {
        let scratch = try TestScratch("session")
        let clock = TestClock()
        let session = scratch.session(clock: clock)
        await session.start()
        let initial = try await savedDrawing(scratch.store)

        try await canvas(of: session).drawing = strokeAcrossPage()
        // The change callback comes from PencilKit's delegate on the real
        // device; assigning `drawing` fires the same path here. The debounce
        // is then armed, and nothing but the clock can fire it.
        await clock.waitUntilSleeping("the debounce to be armed by the drawing change")
        // Past the first interval of the session, whatever sets it: with
        // nothing serialized yet that is `coldSerializeEstimate`'s back-off
        // rather than the injected 20 ms. The clock is virtual, so overshooting
        // costs nothing and asserts nothing about the interval's length —
        // `debounceFloorHolds` and `firstSaveOfASessionBacksOffWhileCold` own
        // that.
        await clock.advance(by: .seconds(1))

        try await waitUntil("the debounced save lands") {
            try await savedDrawing(scratch.store) != initial
        }
        let saved = try await savedDrawing(scratch.store)
        #expect(saved != initial)
        try expectSavedStroke(in: saved)
    }

    @Test("A failed save leaves the document dirty and retryable")
    func failedSaveStaysDirty() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session()
        await session.start()

        // Make the destination unwritable by replacing the directory with a file.
        try FileManager.default.removeItem(at: scratch.root)
        try Data().write(to: scratch.root)

        try await canvas(of: session).drawing = strokeAcrossPage()
        await session.saveIfNeeded()
        #expect(session.lastSaveError != nil)

        // Restore the directory; the retry must succeed with the live ink.
        try FileManager.default.removeItem(at: scratch.root)
        try FileManager.default.createDirectory(
            at: scratch.root,
            withIntermediateDirectories: true
        )
        await session.saveIfNeeded()

        #expect(session.lastSaveError == nil)
        try expectSavedStroke(in: await savedDrawing(scratch.store))
    }

    @Test("A transient save failure retries itself with no user action")
    func failedSaveRetriesItself() async throws {
        let scratch = try TestScratch("session")
        let clock = TestClock()
        let session = scratch.session(clock: clock)
        await session.start()

        // Break the destination the way `failedSaveStaysDirty` does: the
        // containing directory becomes a file, so every save throws.
        try FileManager.default.removeItem(at: scratch.root)
        try Data().write(to: scratch.root)

        try await canvas(of: session).drawing = strokeAcrossPage()
        await clock.waitUntilSleeping("the debounce to be armed")
        // Past the session's first interval, which the cold estimate sets, not
        // the injected 20 ms. Overshooting a virtual clock is free.
        await clock.advance(by: .seconds(1))
        try await waitUntil("the first autosave fails") { session.lastSaveError != nil }

        // Four backed-off retries, each one armed by the failure before it and
        // fired by nothing but this loop. Counted rather than slept past: the
        // old form waited 300 ms and hoped several retries had happened inside
        // it, which under load proved nothing in either direction.
        //
        // The next armed sleep is the evidence, not `lastSaveError` — that
        // string is set by the first failure and never cleared while the store
        // is broken, so it cannot distinguish a fourth retry from the first.
        // A timer exists only because `performOneSave` reached its exit still
        // dirty, so waiting for one proves the retry before it ran and failed.
        // `advance` overshoots the five-second cap deliberately: what is
        // asserted here is that a retry was armed at all.
        for attempt in 1...4 {
            await clock.waitUntilSleeping("retry \(attempt) to be armed by the failure before it")
            await clock.advance(by: .seconds(6))
        }
        await clock.waitUntilSleeping("the fifth retry, armed by the fourth failing")
        #expect(session.lastSaveError != nil)

        // Nothing below touches the session: no Retry tap, no further drawing,
        // no scene transition. Only the store starts working again — with the
        // retry already armed and waiting on a clock only this test moves.
        try FileManager.default.removeItem(at: scratch.root)
        try FileManager.default.createDirectory(
            at: scratch.root,
            withIntermediateDirectories: true
        )

        await clock.advance(by: .seconds(6))
        try await waitUntil("the retry succeeds by itself") {
            guard session.lastSaveError == nil else { return false }
            return try await savedDrawing(scratch.store) != nil
        }
        try expectSavedStroke(in: await savedDrawing(scratch.store))
    }

    @Test("Backgrounding flushes pending ink")
    func backgroundFlushSaves() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session(debounce: .seconds(30))
        await session.start()

        try await canvas(of: session).drawing = strokeAcrossPage()
        // The debounce is far in the future; only the flush can save this.
        await session.flushForBackground()

        try expectSavedStroke(in: await savedDrawing(scratch.store))
    }

    @Test("Backgrounding performs one save pass, never a loop")
    func backgroundFlushIsASinglePass() async throws {
        let scratch = try TestScratch("session")
        // A far-future debounce, so a timer cannot account for any save observed
        // here and the flush is the only thing that can write.
        let session = scratch.session(debounce: .seconds(30))
        await session.start()

        try await canvas(of: session).drawing = strokeAcrossPage()

        let flush = Task { await session.flushForBackground() }
        // One yield hands the main actor to the flush, which runs as far as its
        // first suspension — inside serialization, with one generation captured
        // and the save in flight. It cannot proceed past that without the main
        // actor, which this test holds again from here.
        await Task.yield()
        try await canvas(of: session).drawing = twoStrokesAcrossPage()
        await flush.value

        // Exactly one save reached the store: the generation captured when the
        // flush began. The loop this used to be would have saved the second one
        // as well, on a lease that cannot be relied on to survive it.
        let flushed = try #require(try await savedDrawing(scratch.store))
        #expect(try PKDrawing(data: flushed).strokes.count == 1)

        // The newer ink is still dirty rather than dropped, which is what
        // `resumeForForeground` retries (`Contract.md` — Lifecycle).
        await session.saveIfNeeded()
        let resumed = try #require(try await savedDrawing(scratch.store))
        #expect(try PKDrawing(data: resumed).strokes.count == 2)
    }

    @Test("The debounce never drops below the default 500 ms floor")
    func debounceFloorHolds() async throws {
        let scratch = try TestScratch("session")
        let clock = TestClock()
        // The interval the app itself uses, not the tests' short one.
        let session = scratch.session(debounce: .milliseconds(500), clock: clock)
        await session.start()

        // One save first, so the interval under test is a measured one. A
        // session that has serialized nothing yet assumes
        // `coldSerializeEstimate` and lands four milliseconds *above* the
        // floor; the floor is what decides from the first real measurement
        // onwards, and that is what this test is about.
        try await canvas(of: session).drawing = strokeAcrossPage()
        await session.saveIfNeeded()
        let initial = try await savedDrawing(scratch.store)

        try await canvas(of: session).drawing = twoStrokesAcrossPage()

        // A three-stroke document serializes in microseconds, so the adaptive
        // term is ~0 and the floor is the whole interval. An interval shorter
        // than the floor fails here twice over: `waitUntilSleeping` finds no
        // armed sleep if the debounce was skipped outright, and the save lands
        // inside the 499 ms if it was merely short.
        await clock.waitUntilSleeping("the 500 ms floor to be armed")
        await clock.advance(by: .milliseconds(499))
        #expect(try await savedDrawing(scratch.store) == initial, "a save beat the 500 ms floor")

        await clock.advance(by: .milliseconds(1))
        try await waitUntil("the floor elapses and the save lands") {
            (try await savedDrawing(scratch.store)) != initial
        }
        let saved = try PKDrawing(data: try #require(await savedDrawing(scratch.store)))
        #expect(saved.strokes.count == 2)
    }

    /// The other side of `debounceFloorHolds`: before any measurement exists,
    /// the interval is the cold estimate's back-off and not the floor.
    @Test("The first save of a session backs off for a cold serialization")
    func firstSaveOfASessionBacksOffWhileCold() async throws {
        let scratch = try TestScratch("session")
        let clock = TestClock()
        let session = scratch.session(debounce: .milliseconds(500), clock: clock)
        await session.start()
        let initial = try await savedDrawing(scratch.store)

        try await canvas(of: session).drawing = strokeAcrossPage()
        await clock.waitUntilSleeping("the session's first interval to be armed")

        // 504 ms — four times 126 ms — rather than the 500 ms floor. The first
        // serialization of a session is the expensive one and used to be the
        // one estimated at zero.
        await clock.advance(by: .milliseconds(500))
        #expect(
            try await savedDrawing(scratch.store) == initial,
            "the first save of a session took the floor rather than the cold estimate"
        )

        await clock.advance(by: EditorSession.coldSerializeEstimate * 4 - .milliseconds(500))
        try await waitUntil("the cold interval elapses and the save lands") {
            (try await savedDrawing(scratch.store)) != initial
        }
        try expectSavedStroke(in: await savedDrawing(scratch.store))
    }

    @Test("The serialize measurement is one page's cost, never the pass's total")
    func serializeMeasurementIsPerPage() async throws {
        let scratch = try TestScratch("session")
        // Far-future debounce: every save here is an explicit one, so no timer
        // can slip a third pass in between the two being compared.
        let session = scratch.session(debounce: .seconds(30))
        await session.start()

        try await canvas(of: session).drawing = manyStrokes(count: 20_000)
        await session.saveIfNeeded()
        let onePage = session.lastSerializeDuration
        #expect(
            onePage > .milliseconds(20),
            "fixture serializes in \(onePage), too cheap to tell a maximum from a sum"
        )

        // Two pages dirty in one pass, each a freshly built drawing of the same
        // size, so each pays the same first-traversal cost the pass above paid.
        // Summed, the measurement would be about twice `onePage`; as a maximum
        // it is about `onePage`.
        try await canvas(of: session).drawing = manyStrokes(count: 20_000)
        pullPastTheEnd(session)
        try await canvas(of: session).drawing = manyStrokes(count: 20_000)
        await session.saveIfNeeded()

        #expect(
            session.lastSerializeDuration < onePage * 3 / 2,
            "two pages measured \(session.lastSerializeDuration) against one page's \(onePage)"
        )
    }

    @Test("A pass that serialized nothing keeps the last real measurement")
    func aPassThatEncodesNothingKeepsTheMeasurement() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session(debounce: .seconds(30))
        await session.start()

        // Break the destination the way `failedSaveStaysDirty` does. The pass
        // still serializes — the encode happens before the write — so it
        // measures, and then fails holding the bytes it paid for.
        try FileManager.default.removeItem(at: scratch.root)
        try Data().write(to: scratch.root)

        try await canvas(of: session).drawing = manyStrokes(count: 20_000)
        await session.saveIfNeeded()
        #expect(session.lastSaveError != nil)
        let measured = session.lastSerializeDuration
        #expect(measured > .milliseconds(20))

        try FileManager.default.removeItem(at: scratch.root)
        try FileManager.default.createDirectory(
            at: scratch.root,
            withIntermediateDirectories: true
        )
        await session.saveIfNeeded()
        #expect(session.lastSaveError == nil)

        // The retry never encodes twice (`Contract.md` — Saving), so it
        // measured nothing — and a pass that measured nothing must not report
        // an expensive document as free.
        #expect(session.lastSerializeDuration == measured)
    }

    @Test("An expensive document widens the debounce above the floor")
    func debounceWidensWithSerializeCost() async throws {
        let scratch = try TestScratch("session")
        // A negligible floor, so what is measured here is the adaptive term and
        // nothing else.
        let session = scratch.session(debounce: .milliseconds(1))
        await session.start()

        let expensive = manyStrokes(count: 20_000)

        // The yardstick, measured warm. A freshly built drawing pays one-time
        // cost on its first traversal that it never pays again — 126 ms against
        // 48 ms when this was written — and the session's own measurement is
        // always a warm one. The cold number would overstate the expected
        // interval by more than the interval itself.
        let snapshot = DrawingSnapshot(drawing: expensive)
        _ = await snapshot.serialized()
        let serializeCost = await snapshot.serialized().duration
        #expect(
            serializeCost > .milliseconds(20),
            "fixture serializes in \(serializeCost), too cheap to exercise back-off"
        )

        // One save of the expensive document, which is what teaches the session
        // how much a serialization of it costs. Called directly so that this
        // step's own timing is not part of the measurement below.
        try await canvas(of: session).drawing = expensive
        await session.saveIfNeeded()
        let taught = scratch.savedAt

        // Now make a cheap change. Its own save costs almost nothing, so what is
        // being timed is the scheduled interval and not the work: four times the
        // serialization the session just measured, rather than the 1 ms floor.
        //
        // Timing the two *expensive* saves against each other instead does not
        // work — the first assignment of a 20,000-stroke drawing carries one-time
        // PencilKit cost larger than the interval under test, which made an
        // earlier version of this test pass on a fixed debounce.
        let clock = ContinuousClock()
        let started = clock.now
        try await canvas(of: session).drawing = strokeAcrossPage()
        try await waitUntil("the debounced save lands") { scratch.savedAt != taught }
        let scheduled = started.duration(to: clock.now)

        // Expected is four serializations; asserting two leaves room for machine
        // variance while still being far above the floor a fixed debounce would
        // have used (~1 ms, verified by breaking the adaptive term).
        #expect(
            scheduled > serializeCost * 2,
            "interval \(scheduled) did not back off for a document that serializes in \(serializeCost)"
        )
    }

    // MARK: - Shape tool

    /// What the chrome lights a button from is the runtime's tool, read
    /// through, and never a copy the root or the session keeps.
    ///
    /// The last step is the whole point: the tool is changed on the runtime
    /// *directly*, with no intention passing through the session, and the
    /// session still reports it. A stored mirror anywhere above
    /// `PagedCanvasController` would have gone stale there.
    @Test("The shape tool the chrome renders is the runtime's, not a copy")
    func shapeToolIsReadThroughFromTheRuntime() async throws {
        let scratch = try TestScratch("session")
        let session = scratch.session()

        // Before the runtime exists there is no tool, and reading it must not
        // be what builds a canvas.
        #expect(session.shapeTool == nil)

        session.setShapeTool(.rectangle)
        #expect(session.pages.shapeTool == .rectangle)
        #expect(session.shapeTool == .rectangle)

        session.pages.setShapeTool(.line)
        #expect(session.shapeTool == .line)
    }

    // MARK: - Fixtures

    /// Polls until `condition` holds. Autosave, its retries, and the debounce are
    /// timers, so a test that asserts one fires has to wait for wall time; the
    /// alternative is a fixed sleep long enough to be slow and short enough to be
    /// flaky.
    private func waitUntil(
        _ what: String,
        within timeout: Duration = .seconds(10),
        _ condition: () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record(Comment(rawValue: "timed out waiting for: \(what)"))
    }

    /// Asserts the saved bytes reconstruct the fixture stroke.
    ///
    /// Compared by reconstructed geometry rather than by serialized bytes:
    /// `PKDrawing.dataRepresentation()` is not byte-stable across separately
    /// constructed but equal drawings, so a byte comparison would test the
    /// encoder's determinism rather than the durability the contract promises.
    /// Drives the append gesture: a deliberate pull past the last page.
    @MainActor
    private func pullPastTheEnd(_ session: EditorSession) {
        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(
            x: scroll.bounds.width * (CGFloat(session.pageCount) - 0.5),
            y: 0
        )
        session.pages.scrollViewDidEndDragging(scroll, willDecelerate: false)
        session.pages.view.layoutIfNeeded()
    }

    /// Turns to a page the way a settled scroll does, without a gesture: the
    /// offset comes to rest on the page and the settle callback fires.
    @MainActor
    private func turn(_ session: EditorSession, to page: Int) {
        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * CGFloat(page), y: 0)
        session.pages.scrollViewDidEndDecelerating(scroll)
        session.pages.view.layoutIfNeeded()
    }

    /// The live canvas of the session's current page.
    ///
    /// The paged runtime builds page canvases during layout, so a session that
    /// has never been laid out has none. Tests that touch ink go through here so
    /// that hosting is one decision in one place rather than a setup step each
    /// test can forget.
    ///
    /// `async` since the settle path stopped decoding ink on main: a page with
    /// saved ink is a placeholder for as long as its decode takes, so the
    /// canvas has to be waited for rather than read. A page with no saved ink
    /// is still a canvas the moment it is laid out, and the wait costs it one
    /// predicate evaluation.
    @MainActor
    private func canvas(of session: EditorSession) async throws -> PKCanvasView {
        let root = session.pages.view!
        if root.frame.isEmpty {
            root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        }
        root.layoutIfNeeded()
        for _ in 0..<200 {
            if let page = session.currentCanvas { return page.canvasView }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("the paged runtime built no canvas for the current page")
    }

    /// The saved ink of the current page, or `nil` if nothing is saved yet.
    ///
    /// A free function over the store rather than a method on `Scratch`: the
    /// store is an actor and therefore `Sendable`, while `Scratch` is not, and
    /// awaiting a method on it from a `@MainActor` test would send it across an
    /// isolation boundary.
    private func savedDrawing(_ store: DocumentStore) async throws -> Data? {
        guard let index = try await store.load() else { return nil }
        return try await store.loadPage(index.pageIDs[index.currentPageIndex]).inkData
    }

    private func expectSavedStroke(in drawingData: Data?) throws {
        let restored = try PKDrawing(data: try #require(drawingData))
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

    /// A second, distinguishable generation. Stroke count is what the single-pass
    /// test reads back, so the two fixtures differ in exactly that.
    private func twoStrokesAcrossPage() -> PKDrawing {
        let stroke = strokeAcrossPage().strokes[0]
        return PKDrawing(strokes: [stroke, stroke])
    }

    /// A document expensive enough to serialize that the debounce must adapt to
    /// it. Real handwriting reaches these stroke counts, which is the situation
    /// a fixed 500 ms interval was measured against and lost.
    private func manyStrokes(count: Int) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let strokes = (0..<count).map { index in
            let y = Double(index % 700) + 40
            let points = (0..<8).map { step in
                PKStrokePoint(
                    location: CGPoint(x: 40 + Double(step) * 8, y: y),
                    timeOffset: Double(step) * 0.01,
                    size: CGSize(width: 3, height: 3),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                )
            }
            return PKStroke(
                ink: ink,
                path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
            )
        }
        return PKDrawing(strokes: strokes)
    }
}

/// What only this suite does to a document: break it, and ask which page file
/// the editor is on.
private extension TestScratch {
    /// A short debounce by default: these tests assert the debounce fires, not
    /// that it waits 500 ms.
    @MainActor
    func session(
        debounce: Duration = .milliseconds(20),
        clock: any Clock<Duration> = ContinuousClock(),
        store: (any DocumentStoring)? = nil
    ) -> EditorSession {
        EditorSession(store: store ?? self.store, debounce: debounce, clock: clock)
    }

    /// Overwrites one page's file with bytes that cannot decode. The file still
    /// exists — a missing file is a dangling reference and fatal — but reading
    /// it fails.
    func corruptPageFile(pageID: UUID) throws {
        try Data("not a page".utf8).write(to: pageURL(pageID))
    }

    func writeGarbageIndex(_ data: Data) throws {
        try createDirectories()
        try data.write(to: indexURL)
    }

    /// The page file backing whatever page the editor currently shows.
    @MainActor
    func currentPageURL(of session: EditorSession) -> URL {
        pageURL(session.currentPageID)
    }
}
