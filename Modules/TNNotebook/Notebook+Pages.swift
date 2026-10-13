import Foundation
import PencilKit
import TNCore
import TNFormat
import TNModel
import TNRender

extension Notebook {
    // MARK: Structure

    package func pageBecameCurrent(_ page: PageID) {
        guard index.record(of: page) != nil, page != currentPageID else { return }
        currentPageID = page
        scheduleViewWrite()
    }

    private func scheduleViewWrite() {
        guard !isClosed else { return }
        viewWrite?.cancel()
        let store = self.store
        let page = currentPageID
        let delay = schedule.viewWriteDelay
        viewWrite = Task {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            try? await store.writeView(ViewState(currentPageID: page))
        }
    }

    /// A new page after `after` (or at the end), copying the current page's
    /// geometry and paper. Returns its identity.
    ///
    /// Synchronous, and it must stay so: `EditorBinding.endBoundaryReached`
    /// answers a report in the same turn and cannot await.
    @discardableResult
    package func appendPage(after: PageID? = nil, answering: ReportSeq? = nil) -> PageID {
        let record = PageRecord(id: PageID(), geometry: currentRecord.geometry, paper: inheritedPaper())
        return insertPages([(record, .empty)], after: after, answering: answering)[0]
    }

    /// `currentPageID` always names a page the index holds.
    package var currentRecord: PageRecord {
        guard let record = index.record(of: currentPageID) else {
            TNPrecondition.fail("the current page \(currentPageID) has no record")
        }
        return record
    }

    /// The current page's drawn paper. Asset paper is not copied: it
    /// belongs to the page it was applied to, whose geometry it set.
    private func inheritedPaper() -> Paper {
        .drawn(currentRecord.paper.drawn ?? .blank)
    }

    /// A new page after `after` (or at the end), at a stated size and with a
    /// stated paper. Asset paper is measured before anything is inserted, so
    /// a refused append creates nothing.
    @discardableResult
    package func appendPage(after: PageID?, geometry: PageGeometry, paper: NewPagePaper) async throws(NewPageRefusal) -> PageID {
        guard geometry.isWithinBounds else {
            throw .geometryOutOfBounds(width: geometry.width, height: geometry.height)
        }
        let sized: PageGeometry
        let resolved: Paper
        switch paper {
        case .inheritTemplate:
            sized = geometry
            resolved = inheritedPaper()
        case .drawn(let drawn):
            sized = geometry
            resolved = .drawn(drawn)
        case .asset(let asset):
            guard let ref = asset.asset else {
                TNPrecondition.fail("appendPage: .asset carries drawn paper \(asset)")
            }
            guard let aspect = await renderer.aspect(of: asset) else { throw .assetUnreadable(ref) }
            let measured = PageGeometry.fitting(width: geometry.width, aspect: aspect)
            guard measured.isWithinBounds else {
                throw .geometryOutOfBounds(width: measured.width, height: measured.height)
            }
            sized = measured
            resolved = asset
        }
        // Measuring the asset suspends, and the page `after` names can be
        // deleted meanwhile.
        if let after, index.record(of: after) == nil { throw .pageGone(after) }
        let record = PageRecord(id: PageID(), geometry: sized, paper: resolved)
        return insertPages([(record, .empty)], after: after, answering: nil)[0]
    }

    /// The one place pages are inserted, so anything every new page must do
    /// is written once, and a run of them is one structure change. They go
    /// in together and in order after `after`, or at the end when it is nil;
    /// a caller that suspended since it chose `after` refuses for itself
    /// when that page is gone. Each starts with its own content: empty for
    /// every caller but a duplicate, which starts with the source's.
    ///
    /// An import's pages are not pushed (`pushing` false). They start
    /// retired, as if the runtime had let them go, and the window report
    /// that answers the structure push names the ones it shows, which
    /// `windowChanged(to:)` pushes. The rest hold no composite, and once
    /// saved they are pruned like any page outside the window: a 100-page
    /// lecture PDF would otherwise hold a full-page bitmap per page.
    private func insertPages(_ pages: [(record: PageRecord, content: PageContent)], after: PageID?, answering: ReportSeq?, pushing: Bool = true) -> [PageID] {
        var records = index.pages
        var position = records.endIndex
        if let after {
            guard let found = records.firstIndex(where: { $0.id == after }) else {
                TNPrecondition.fail("pages were inserted after page \(after), which the notebook does not hold")
            }
            position = found + 1
        }
        records.insert(contentsOf: pages.map(\.record), at: position)
        index = index.withPages(records)
        for (record, content) in pages {
            var content = content
            // A page that has just been inserted owes the disk its page file
            // whatever is on it.
            content.edited()
            content.retired = !pushing
            states[record.id] = .ready(content)
            if pushing { wanted.insert(record.id) }
            bumpContentVersion(of: record.id)
        }
        indexSeq += 1
        emitStructure(answering: answering)
        for (record, _) in pages where pushing {
            emitContent(record.id)
            rerenderComposite(of: record.id)
        }
        markDirty()
        return pages.map(\.record.id)
    }

    /// Deleting a page is navigation, not an edit, and is not itself
    /// undoable: the entries and any pending restore that name the page go
    /// with it, so no entry on either stack names a page the notebook does
    /// not hold.
    package func deletePage(_ page: PageID) {
        guard index.pages.count > 1, let position = index.pageIDs.firstIndex(of: page) else { return }
        index = index.withPages(index.pages.filter { $0.id != page })
        loads[page]?.cancel(); loads[page] = nil
        states[page] = nil
        contentVersions[page] = nil
        wanted.remove(page)
        pendingRestores[page] = nil
        history.forget(page)
        // The successor at the same position, clamped when the last page goes:
        // the page the runtime shows after the delete (`PagedCanvasController.setPages`),
        // so the notebook's current page and the viewport agree.
        if currentPageID == page {
            currentPageID = index.pageIDs[min(position, index.pageIDs.count - 1)]
            scheduleViewWrite()
        }
        indexSeq += 1
        emitStructure(answering: nil)
        markDirty()
    }

    /// A new page straight after `source`: the same geometry and paper, the
    /// same ink, and the same layers under new identities, naming the same
    /// assets.
    ///
    /// Navigation, like every other insert: it records nothing, so the undo
    /// stack is where it was. The layers are given new `LayerID`s because a
    /// layer file is one file per id — sharing them would make a transform on
    /// either page rewrite the file for both — while the assets are shared by
    /// name, which is safe because an asset is immutable and `compact()`
    /// keeps any a reachable layer names.
    ///
    /// A source that is not loaded is read from its files, so every cell in
    /// the navigator can be duplicated and not only the two or three the
    /// window happens to hold. A source with a text box open is refused: the
    /// typing is not in the revision yet.
    @discardableResult
    package func duplicatePage(_ source: PageID) async throws(FormatFault) -> PageID {
        guard let record = index.record(of: source) else { throw .invalidWrite("no such page \(source)") }
        let copied: PageContent
        switch states[source] {
        case .ready(let content):
            guard content.textEditing == nil else { throw .invalidWrite("page \(source) has a text box open") }
            copied = content
        case .unloaded, .loading:
            guard let read = await unloadedContent(of: source) else {
                throw .invalidWrite("page \(source) could not be read")
            }
            // The page can be deleted while its files are read.
            guard index.record(of: source) != nil else {
                throw .invalidWrite("page \(source) was deleted while it was read")
            }
            copied = read
        case .unreadable(let faults):
            throw .invalidWrite("page \(source) is unreadable: \(faults)")
        case nil:
            throw .invalidWrite("no such page \(source)")
        }

        let layers = copied.layers.map { Layer(id: LayerID(), transform: $0.transform, payload: $0.payload, locked: $0.locked) }
        var content = PageContent(ink: copied.ink, layers: layers, hasInk: false)
        content.pendingLayerFiles = Set(layers.map(\.id))
        // `setInk` rather than the initializer's flag, so the durable flag and
        // the ink sequence agree and the first save writes the container.
        if copied.hasInk { content.setInk(copied.ink) }
        let copy = PageRecord(id: PageID(), geometry: record.geometry, paper: record.paper)
        return insertPages([(copy, content)], after: source, answering: nil)[0]
    }

    // MARK: Bookmarks

    /// Marks `page`, or renames a mark it already has. An empty title is a
    /// mark nobody named, which is a mark all the same: presence is the flag.
    ///
    /// Not undoable, and it queues no change. Undo belongs to ink
    /// (`Docs/Contract.md` — Undo) and `PageRevision` is the ink and the
    /// layers, so there is no shape for a mark to be recorded in; and
    /// `EditorBinding.intention` refreshes the mirrors whether or not the
    /// mutation queued anything, so the navigator sees this without a
    /// structure change. Deleting, duplicating and moving pages are equally
    /// not undoable.
    ///
    /// A page the notebook does not hold is the programmer's error: the
    /// index is what the outline is read from, and a mark on nothing would
    /// be an index this build's own `validated()` refuses.
    package func bookmark(_ page: PageID, titled title: String) {
        guard index.record(of: page) != nil else {
            TNPrecondition.fail("a bookmark was set on page \(page), which the notebook does not hold")
        }
        // An unchanged mark writes nothing: an index rewritten for no change
        // is a bug (`Docs/Contract.md` — One save).
        guard index.bookmarks.first(where: { $0.page == page })?.title != title else { return }
        var bookmarks = index.bookmarks.filter { $0.page != page }
        bookmarks.append(PageBookmark(page: page, title: title))
        index = index.withBookmarks(bookmarks)
        indexSeq += 1
        markDirty()
    }

    /// Unmarks `page`. A page that carries no mark is not an error and
    /// writes nothing.
    package func removeBookmark(_ page: PageID) {
        guard index.bookmarks.contains(where: { $0.page == page }) else { return }
        index = index.withBookmarks(index.bookmarks.filter { $0.page != page })
        indexSeq += 1
        markDirty()
    }

    package func movePage(_ page: PageID, before target: PageID?) {
        var pages = index.pages
        guard let from = pages.firstIndex(where: { $0.id == page }) else { return }
        let record = pages.remove(at: from)
        if let target, let to = pages.firstIndex(where: { $0.id == target }) {
            pages.insert(record, at: to)
        } else {
            pages.append(record)
        }
        index = index.withPages(pages)
        indexSeq += 1
        emitStructure(answering: nil)
        markDirty()
    }

    /// Drawn paper applies to any page whose paper is drawn. Asset paper
    /// applies only to a page that is loaded and empty, and takes the page's
    /// geometry with it: the asset fills the page rectangle, so the rectangle
    /// is the asset's shape. A page whose paper is an asset keeps it: a paper
    /// change records no history, so Undo could not bring the PDF page or
    /// the photo back.
    package func setPaper(_ paper: Paper, on page: PageID) async throws(PaperRefusal) {
        guard let record = index.record(of: page) else { throw .pageNotLoaded }
        // An unchanged paper writes nothing: an index rewritten for no change
        // is a bug (`Docs/Contract.md` — One save).
        guard record.paper != paper else { return }
        guard !record.paper.isAsset else { throw .pageHasAssetPaper }
        var geometry = record.geometry
        if paper.isAsset {
            try checkAssetPaperTarget(page)
            guard let aspect = await renderer.aspect(of: paper) else { throw .assetUnreadable }
            // The page may have changed while the asset was being measured.
            try checkAssetPaperTarget(page)
            let sized = PageGeometry.fitting(width: record.geometry.width, aspect: aspect)
            guard sized.isWithinBounds else { throw .geometryOutOfBounds }
            geometry = sized
        }
        index = index.withPages(index.pages.map { $0.id == page ? $0.with(paper: paper, geometry: geometry) : $0 })
        bumpContentVersion(of: page)
        indexSeq += 1
        emitStructure(answering: nil)
        markDirty()
        rerenderComposite(of: page)
    }

    /// Asset paper covers the whole page, so a page with anything on it
    /// would lose it behind the paper, and a PDF page or a photo would lose
    /// its own.
    private func checkAssetPaperTarget(_ page: PageID) throws(PaperRefusal) {
        guard paper(of: page)?.isAsset != true else { throw .pageHasAssetPaper }
        guard case .ready(let content) = states[page] else { throw .pageNotLoaded }
        guard content.ink.strokes.isEmpty, content.layers.isEmpty else { throw .pageNotEmpty }
    }

    package func paper(of page: PageID) -> Paper? { index.record(of: page)?.paper }

    /// One new page per PDF page, inserted after the current page, each
    /// sized to its source extent with that PDF page as its paper. The asset
    /// is written once. No layer: the `pdf` layer kind is for a clipping
    /// placed on a page, not for a page that *is* the PDF. Returns the pages
    /// it made, in source order.
    ///
    /// Every page is measured before anything is written, and a page with no
    /// page box or outside the bounds refuses the whole import, naming it:
    /// a worksheet handed in a page short is worse than a refusal, and a
    /// refusal leaves no page and no asset behind.
    ///
    /// A notebook whose only page has nothing on it takes the PDF in that
    /// page's place (decided R2-07).
    @discardableResult
    package func importPDF(_ data: Data) async throws(FormatFault) -> [PageID] {
        guard let source = PDFSource(data: data), source.pageCount > 0 else { throw .invalidWrite("PDF could not be opened") }
        let asset = AssetRef(id: AssetID(), format: .pdf)
        var pages: [(record: PageRecord, content: PageContent)] = []
        for pageIndex in 0..<source.pageCount {
            guard let page = source.page(at: pageIndex), let extent = PDFSource.displayExtent(of: page) else {
                throw .invalidWrite("PDF page \(pageIndex + 1) has no page box")
            }
            let geometry = PageGeometry(width: extent.width, height: extent.height)
            guard geometry.isWithinBounds else { throw .invalidWrite("PDF page \(pageIndex + 1) is outside the page bounds") }
            pages.append((PageRecord(id: PageID(), geometry: geometry, paper: .pdf(asset, sourcePageIndex: pageIndex)), .empty))
        }
        try await writeAsset(data, asset)
        let replaced = untouchedOnlyPage()
        let created = insertPages(pages, after: currentPageID, answering: nil, pushing: false)
        if let replaced { deletePage(replaced) }
        return created
    }

    /// The notebook's only page when it has drawn paper and nothing on it:
    /// no ink and no layer, so no text box either. What was drawn there and
    /// undone does not count (decided R3-03); `deletePage` takes its history
    /// with it. A page that is not loaded is not known to be blank, and stays.
    private func untouchedOnlyPage() -> PageID? {
        guard index.pages.count == 1, let record = index.pages.first, record.paper.drawn != nil,
              case .ready(let content) = states[record.id],
              content.ink.strokes.isEmpty, content.layers.isEmpty
        else { return nil }
        return record.id
    }

    /// One new page per scanned page, after the current page and in scan
    /// order, each keeping the current page's width and taking the scan's
    /// aspect the way `appendPage` measures asset paper. Returns what it made.
    ///
    /// Here rather than in `TNEditor` because page order is the notebook's
    /// (`Docs/Contract.md`, Custody), and inserted as one run: one
    /// `emitStructure` and one `markDirty`, not the per-page storm N calls to
    /// `appendPage` would kick, each restating the whole page list to the
    /// canvas.
    ///
    /// A page that cannot be stored or measured stops the run, and what was
    /// made before it is inserted before the error is thrown. The pages go in
    /// once, after the last suspension, so the page the run follows is
    /// checked once, there: if it was deleted while the scan was stored, the
    /// end of the notebook is the only answer left, and a default is what the
    /// contract forbids, so nothing is inserted.
    package func importScan(_ images: [Data]) async throws(FormatFault) -> [PageID] {
        guard !images.isEmpty else { return [] }
        // The width is the current page's, read once: every page of one scan
        // is the same width, whatever the reader does while it runs.
        let width = currentRecord.geometry.width
        let after = currentPageID
        var made: [(record: PageRecord, content: PageContent)] = []
        var stopped: FormatFault?
        for (offset, data) in images.enumerated() {
            let number = offset + 1
            let asset: AssetRef
            do {
                asset = try await storeImageAsset(data)
            } catch {
                stopped = .invalidWrite("scanned page \(number) could not be stored: \(error.description)")
                break
            }
            guard let aspect = await renderer.aspect(of: .image(asset)) else {
                stopped = .invalidWrite("scanned page \(number) could not be measured")
                break
            }
            let geometry = PageGeometry.fitting(width: width, aspect: aspect)
            guard geometry.isWithinBounds else {
                stopped = .invalidWrite("scanned page \(number) is outside the page bounds")
                break
            }
            made.append((PageRecord(id: PageID(), geometry: geometry, paper: .image(asset)), .empty))
        }
        guard index.record(of: after) != nil else { throw .invalidWrite("the page the scan would follow is gone") }
        let created = made.isEmpty ? [] : insertPages(made, after: after, answering: nil, pushing: false)
        if let stopped { throw stopped }
        return created
    }

    /// A photo normalized to HEIC and published as an asset, ready to be a
    /// page's paper.
    package func storeImageAsset(_ data: Data) async throws(FormatFault) -> AssetRef {
        guard let normalized = await Task.detached(priority: .userInitiated, operation: { ImageImport.normalize(data) }).value else {
            throw .invalidWrite("image could not be decoded")
        }
        guard normalized.size.isValid else { throw .invalidWrite("image is outside the asset bounds") }
        let asset = AssetRef(id: AssetID(), format: .heic)
        try await writeAsset(normalized.heic, asset)
        return asset
    }

    /// A photo as a page's paper: normalized to HEIC, published, applied.
    package func importImageAsPaper(_ data: Data, on page: PageID) async throws(FormatFault) {
        do { try checkAssetPaperTarget(page) } catch { throw .invalidWrite("paper refused: \(error)") }
        let asset = try await storeImageAsset(data)
        do { try await setPaper(.image(asset), on: page) } catch { throw .invalidWrite("paper refused: \(error)") }
    }

    /// A page's composite and ink rendered to one asset at asset resolution.
    /// The source page is untouched; the caller decides which empty page the
    /// result becomes the paper of. A page with a text box open is refused,
    /// as a duplicate is: the typing is not in custody yet.
    package func flatten(_ page: PageID) async throws(FormatFault) -> AssetRef {
        guard let record = index.record(of: page) else { throw .invalidWrite("no such page") }
        guard case .ready(let content) = states[page] else { throw .invalidWrite("page \(page) is not ready") }
        guard content.textEditing == nil else { throw .invalidWrite("page \(page) has a text box open") }
        guard let heic = await renderer.flattened(
            geometry: record.geometry, paper: record.paper, layers: content.layers, ink: content.ink, as: "public.heic" as CFString
        ) else { throw .invalidWrite("page \(page) could not be flattened") }
        let asset = AssetRef(id: AssetID(), format: .heic)
        try await writeAsset(heic, asset)
        return asset
    }

    /// An import resumes after its awaits whether or not the notebook closed
    /// meanwhile, so its asset write asks the latch, as a save does.
    func writeAsset(_ data: Data, _ asset: AssetRef) async throws(FormatFault) {
        guard !isClosed else { throw .invalidWrite("the notebook is closed") }
        try await store.writeAsset(data, asset)
    }
}

/// A new page's paper.
package enum NewPagePaper: Sendable, Equatable {
    /// The existing rule: the current page's drawn paper, asset becomes
    /// `blank`. Named for what it does, not for which page: `after:` may not
    /// be the current page.
    case inheritTemplate
    case drawn(DrawnPaper)
    /// An asset already in the package. The page keeps the chosen width and
    /// takes the asset's aspect, the rule `setPaper` applies to an empty page.
    case asset(Paper)
}

/// Why a new page was refused. Each is decided before anything is
/// inserted, so a refusal leaves nothing behind.
package enum NewPageRefusal: Error, Sendable, Equatable {
    case geometryOutOfBounds(width: Double, height: Double)
    case assetUnreadable(AssetRef)
    /// The page the new one was to follow was deleted while its asset paper
    /// was measured.
    case pageGone(PageID)
}

/// Why a paper change was refused. Drawn paper is refused only on a page
/// the notebook does not hold (`pageNotLoaded`) or one whose paper is an
/// asset; the rest are about asset paper.
package enum PaperRefusal: Error, Sendable, Equatable {
    case pageNotLoaded
    case pageHasAssetPaper
    case pageNotEmpty
    case geometryOutOfBounds
    case assetUnreadable
}
