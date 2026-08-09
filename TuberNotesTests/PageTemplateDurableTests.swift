import Foundation
import Testing
@testable import TuberCanvas
@testable import TuberModel
@testable import TuberNotes
@testable import TuberStore
import UIKit

/// The document's paper as a durable value: what it survives, what it refuses,
/// and what choosing it writes.
///
/// Nothing here renders. A template is a name in the index at this point, and
/// these are the properties that have to hold before anything draws from it.
@Suite("The document's paper")
@MainActor
struct PageTemplateDurableTests {
    // MARK: - The value on disk

    @Test("Every template round trips through the index unchanged")
    func everyTemplateRoundTrips() throws {
        for template in PageTemplate.allCases {
            let original = sample(template: template)
            let decoded = try PropertyListDecoder().decode(
                DocumentIndex.self,
                from: try TestScratch.binaryEncoder().encode(original)
            )

            #expect(decoded == original)
            #expect(decoded.template == template)
            #expect(throws: Never.self) { try decoded.validated() }
        }
    }

    @Test("The template is one key on the index, and no page record carries one")
    func theTemplateIsAnIndexKey() throws {
        let bytes = try TestScratch.binaryEncoder().encode(sample(template: .grid))
        let raw = try #require(
            try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
                as? [String: Any]
        )

        #expect(raw["template"] as? String == "grid")
        // The claim `PageRecord` is untouched, in the only form bytes can hold
        // it: a page record is an ID and a geometry, and paper is not a page's.
        let pages = try #require(raw["pages"] as? [[String: Any]])
        #expect(pages.allSatisfy { Set($0.keys) == ["id", "geometry"] })
    }

    /// The absent key is **not** a compatibility path. No build has ever
    /// written a version-1 index without it, and this build writes it in every
    /// index it writes; what an absent key gets here is what an absent key
    /// already gets for `pages` and `zoomCapPagePointsPerPixel` — enough of a
    /// value that a file written by a *newer* build decodes far enough to be
    /// refused by number rather than reported as corrupt.
    @Test("An index with no template key decodes as blank paper rather than failing")
    func anAbsentTemplateKeyDecodesBlank() throws {
        let decoded = try PropertyListDecoder().decode(
            DocumentIndex.self,
            from: try indexBytes(replacingTemplateWith: nil)
        )

        #expect(decoded.template == .blank)
        #expect(throws: Never.self) { try decoded.validated() }
    }

    @Test("An unknown template name refuses the document, naming the paper it found")
    func anUnknownTemplateRefusesTheDocument() throws {
        let decoded = try PropertyListDecoder().decode(
            DocumentIndex.self,
            from: try indexBytes(replacingTemplateWith: "hexgrid")
        )

        // Decoded, then refused — the same shape the version check has, so the
        // failure says "this names paper I do not have" rather than "this file
        // is corrupt".
        #expect(throws: DocumentIndexError.unknownTemplate("hexgrid")) {
            try decoded.validated()
        }
    }

    @Test("A document on paper this build does not have will not open")
    func anUnknownTemplateRefusesTheDocumentAtLoad() async throws {
        let scratch = try TestScratch("template")
        try FileManager.default.createDirectory(
            at: scratch.documentURL,
            withIntermediateDirectories: true
        )
        // The page the sample index names, on disk and perfectly readable, so
        // the template is the only thing wrong with this document.
        try scratch.writePageFileOnly(Self.samplePageID, layerIDs: [])
        try indexBytes(replacingTemplateWith: "hexgrid").write(to: scratch.indexURL)

        // The scope is the document, and it is the whole document: the page
        // file is fine, and a page is never refused for paper.
        await #expect(throws: DocumentIndexError.unknownTemplate("hexgrid")) {
            try await scratch.freshStore().load()
        }
    }

    // MARK: - Choosing paper

    @Test("Choosing paper rewrites the index and no page file")
    func choosingPaperWritesTheIndexAlone() async throws {
        let scratch = try TestScratch("template")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        await session.saveIfNeeded()
        #expect(session.lastSaveError == nil)
        #expect(session.template == .blank)

        // Backdated rather than waited out, and compared by bytes as well as
        // by date, so neither a rewrite inside the filesystem's timestamp
        // resolution nor a rewrite of identical bytes can hide.
        try scratch.freezeTimestamps()
        let before = try scratch.snapshot()

        try await session.setTemplate(.lined)
        #expect(session.lastSaveError == nil)

        let after = try scratch.snapshot()
        #expect(Set(after.keys) == Set(before.keys), "no file was created or removed")
        let rewritten = after.filter { name, entry in before[name] != entry }.keys.sorted()
        #expect(
            rewritten == ["document.plist"],
            """
            choosing paper rewrote \(rewritten.joined(separator: ", ")); it may \
            rewrite only the index. A page file here is the whole-document \
            rewrite the split format exists to prevent — no page's content \
            changed.
            """
        )

        #expect(session.template == .lined)
        let saved = try #require(await scratch.freshStore().load())
        #expect(saved.template == .lined)
    }

    /// Edge case 8, pinned rather than stated. The template is the index's, so
    /// choosing paper while standing on a page that will not persist neither
    /// persists that page nor loses the choice. Were the template a layer,
    /// setting one would clear `neverWritten` and the overswept page would
    /// become durable.
    @Test("Paper chosen on a withheld trailing page survives, and the page still does not")
    func paperChosenOnAWithheldPageSurvivesWithoutMakingItDurable() async throws {
        let scratch = try TestScratch("template")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        host(session)
        let firstPage = session.currentPageID

        pullPastTheEnd(session)
        let withheld = session.currentPageID
        #expect(withheld != firstPage)
        #expect(session.pageCount == 2)

        try await session.setTemplate(.dotted)
        #expect(session.lastSaveError == nil)

        let saved = try #require(await scratch.freshStore().load())
        #expect(saved.template == .dotted)
        #expect(saved.pageIDs == [firstPage], "the trailing run is still withheld")
        #expect(!FileManager.default.fileExists(atPath: scratch.pageURL(withheld).path))

        #expect(await session.close() == .clean)

        let reopened = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await reopened.start()
        #expect(reopened.template == .dotted, "the choice outlives the page it was made on")
        #expect(reopened.pageCount == 1)
        _ = await reopened.close()
    }

    // MARK: - What the picker reads

    /// The picker's whole state is these two reads, and this is as close to it
    /// as anything mechanical gets: there is no view test in this project, and
    /// `.disabled(session.currentPageCarriesPDF)` is a claim about SwiftUI.
    /// What is checkable is that the property it is attached to answers
    /// correctly on every page a document can be showing.
    @Test("The picker's disabled condition follows the visible page onto a PDF and off it")
    func theDisabledConditionFollowsTheVisiblePage() async throws {
        let scratch = try TestScratch("template")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()

        // Page 0 is the document's own blank page: paper, and the picker is
        // live on it.
        #expect(!session.currentPageCarriesPDF)

        // The import appends without navigating, so the visible page is still
        // paper even though the document now contains a PDF page.
        let appended = try await session.importPDF(PDFFixture.quadrantPDF(rotate: 0, scale: 2))
        let pdfPage = try #require(appended.first)
        #expect(!session.currentPageCarriesPDF, "the picker is per visible page, not per document")

        turn(session, to: 1)
        #expect(session.currentPageID == pdfPage)
        #expect(session.currentPageCarriesPDF, "a PDF page is a PDF, not paper")

        // Throwing the worksheet away hands the page back to paper, in the same
        // main-actor stretch that deleted the layer.
        #expect(try await session.deletePDFLayers() == 1)
        #expect(!session.currentPageCarriesPDF)

        turn(session, to: 0)
        #expect(!session.currentPageCarriesPDF)
        _ = await session.close()
    }

    /// The durable value is untouched while the picker is disabled — which is
    /// the whole of §c4's payoff: a PDF thrown away reveals the paper the
    /// document already said it had, because nothing ever overwrote it.
    @Test("Paper chosen before an import is still the document's paper under a deleted PDF")
    func paperSurvivesUnderneathAPDF() async throws {
        let scratch = try TestScratch("template")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        try await session.setTemplate(.grid)

        let appended = try await session.importPDF(PDFFixture.quadrantPDF(rotate: 0, scale: 2))
        let pdfPage = try #require(appended.first)
        turn(session, to: 1)
        #expect(session.currentPageCarriesPDF)
        #expect(session.template == .grid, "the value the picker would show is unchanged")

        #expect(try await session.deletePDFLayers(onPage: pdfPage) == 1)
        #expect(!session.currentPageCarriesPDF)
        #expect(session.template == .grid)

        let saved = try #require(await scratch.freshStore().load())
        #expect(saved.template == .grid)
        _ = await session.close()
    }

    /// The picker's action is `async throws`, and the view has an alert behind
    /// it rather than a `try?`. This is the refusal that alert exists for.
    @Test("Choosing paper before the session is ready is refused rather than swallowed")
    func choosingPaperOnAnUnstartedSessionThrows() async throws {
        let scratch = try TestScratch("template")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))

        await #expect(throws: PageEditError.sessionNotReady) {
            try await session.setTemplate(.lined)
        }
        #expect(session.template == .blank, "a refused choice changes nothing")
        // No visible page, so nothing is a PDF page and the chrome is not
        // rendering a picker anyway.
        #expect(!session.currentPageCarriesPDF)
    }

    // MARK: - Fixtures

    private static let samplePageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func sample(template: PageTemplate) -> DocumentIndex {
        DocumentIndex(
            formatVersion: DocumentIndex.currentFormatVersion,
            documentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            pages: [PageRecord(id: Self.samplePageID, geometry: .canonical)],
            currentPageIndex: 0,
            template: template
        )
    }

    /// The bytes this build writes, with the template key replaced or removed
    /// — built by editing a real encoding rather than by hand, so the rest of
    /// the file is exactly the form the decoder meets in the wild.
    private func indexBytes(replacingTemplateWith name: String?) throws -> Data {
        let encoded = try TestScratch.binaryEncoder().encode(sample(template: .blank))
        var raw = try #require(
            try PropertyListSerialization.propertyList(from: encoded, options: [], format: nil)
                as? [String: Any]
        )
        if let name {
            raw["template"] = name
        } else {
            raw.removeValue(forKey: "template")
        }
        return try PropertyListSerialization.data(
            fromPropertyList: raw,
            format: .binary,
            options: 0
        )
    }

    /// Lays the runtime out, which is what builds page canvases and gives the
    /// scroll view a width for the overswipe below to work in.
    private func host(_ session: EditorSession) {
        let root = session.pages.view!
        if root.frame.isEmpty {
            root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        }
        root.layoutIfNeeded()
    }

    /// The paging runtime settles on a page the way a finished scroll does.
    private func turn(_ session: EditorSession, to page: Int) {
        host(session)
        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * CGFloat(page), y: 0)
        session.pages.scrollViewDidEndDecelerating(scroll)
        session.pages.view.layoutIfNeeded()
    }

    /// Drives the append gesture: a deliberate pull past the last page, which
    /// is how a withheld trailing page comes to exist.
    private func pullPastTheEnd(_ session: EditorSession) {
        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(
            x: scroll.bounds.width * (CGFloat(session.pageCount) - 0.5),
            y: 0
        )
        session.pages.scrollViewDidEndDragging(scroll, willDecelerate: false)
        session.pages.view.layoutIfNeeded()
    }
}
