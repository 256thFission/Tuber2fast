import Foundation
import PencilKit
import TNCore
import TNFormat
import TNModel
import TNRender

/// The timing constants of the save engine, carried as values so a test
/// can run the engine at speed. The defaults carry the spec's numbers.
package struct SaveSchedule: Sendable {
    /// The idle debounce is `factor × lastSerialize`, clamped; before the
    /// first pass has timed a serialize, `firstSerializeEstimate` stands in.
    package var idleFloor: Duration = .milliseconds(500)
    package var idleCeiling: Duration = .seconds(2)
    package var serializeFactor: Double = 4
    package var firstSerializeEstimate: Duration = .milliseconds(100)
    /// No page stays dirty longer than this without a pass starting.
    package var dirtyCeiling: Duration = .seconds(5)
    package var backoffCap: Duration = .seconds(5)
    package var retryBufferBytes: Int = 64 * 1024 * 1024
    /// How long the current page must stay current before `view.json` is
    /// rewritten to name it.
    package var viewWriteDelay: Duration = .seconds(1)

    package init() {}
}

extension Notebook {
    // MARK: The save engine

    /// Recounts the mirror and arms the debounce unless a pass is running
    /// or the notebook is closed; the running pass re-arms at its exit, the
    /// single owner of re-arming. A report after the close arms nothing and
    /// is not a trap: it is late, not invalid.
    func markDirty() {
        dirtyPageCount = states.values.count(where: \.isDirty)
        if firstDirtyAt == nil { firstDirtyAt = .now }
        guard !isClosed, currentSave == nil, debounce == nil else { return }
        let interval = nextInterval()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.debounce = nil
            self.beginSave()
        }
    }

    private func nextInterval() -> Duration {
        if let backoff { return backoff }
        if let firstDirtyAt, firstDirtyAt.duration(to: .now) >= schedule.dirtyCeiling { return .zero }
        let scaled = lastSerialize * schedule.serializeFactor
        return min(max(scaled, schedule.idleFloor), schedule.idleCeiling)
    }

    private struct Captured: Sendable {
        let page: PageID
        let file: PageFile
        /// The ink to write, or nil when the container is unchanged.
        let ink: PKDrawing?
        let editSeq: UInt64
        let inkSeq: UInt64
        let layerFiles: [Layer]
    }

    /// Capture is synchronous and total; the write is a task.
    private func beginSave() {
        guard !isClosed, currentSave == nil else { return }
        var captured: [Captured] = []
        for page in index.pageIDs {
            guard case .ready(let content) = states[page], content.isDirty else { continue }
            let file = PageFile(pageID: page, hasInk: content.hasInk, layers: content.layers.map(\.id))
            captured.append(Captured(
                page: page, file: file,
                ink: content.hasInk && content.inkIsDirty ? content.ink : nil,
                editSeq: content.editSeq, inkSeq: content.inkSeq,
                layerFiles: content.layers.filter { content.pendingLayerFiles.contains($0.id) }
            ))
        }
        let intended = index
        let indexChanged = indexSeq > savedIndexSeq
        let capturedIndexSeq = indexSeq
        guard !captured.isEmpty || indexChanged else { firstDirtyAt = nil; return }

        let retry = retryBuffer
        currentSave = Task { [weak self] in
            await self?.performSave(captured: captured, intended: intended, indexChanged: indexChanged, capturedIndexSeq: capturedIndexSeq, retry: retry)
        }
    }

    private func performSave(captured: [Captured], intended: NotebookIndex, indexChanged: Bool, capturedIndexSeq: UInt64, retry: [PageID: (seq: UInt64, bytes: Data)]) async {
        // One hop off the main actor serializes every drawing this pass
        // writes; a buffered archive from a failed pass is reused as long
        // as the ink has not changed since.
        var serialized: [PageID: (seq: UInt64, bytes: Data)] = [:]
        var toSerialize: [(PageID, UInt64, PKDrawing)] = []
        for item in captured {
            guard let ink = item.ink else { continue }
            if let buffered = retry[item.page], buffered.seq == item.inkSeq {
                serialized[item.page] = buffered
            } else {
                toSerialize.append((item.page, item.inkSeq, ink))
            }
        }
        if !toSerialize.isEmpty {
            let clock = ContinuousClock()
            let started = clock.now
            let encoded = await Task.detached(priority: .utility) {
                toSerialize.map { ($0.0, $0.1, $0.2.dataRepresentation()) }
            }.value
            lastSerialize = started.duration(to: clock.now)
            for (page, seq, bytes) in encoded { serialized[page] = (seq, bytes) }
        }
        let writes = captured.map { item in
            PageWrite(file: item.file, ink: serialized[item.page].map { .archive($0.bytes) } ?? .unchanged, layerFiles: item.layerFiles)
        }

        let batch = SaveBatch(index: intended, indexChanged: indexChanged, pages: writes)
        do {
            let report = try await store.save(batch)
            for item in captured where report.committed.contains(item.page) && report.refusals[item.page] == nil {
                withContent(item.page) { content in
                    content.savedSeq = max(content.savedSeq, item.editSeq)
                    content.savedInkSeq = max(content.savedInkSeq, item.inkSeq)
                    // A restore that landed while this pass was writing
                    // re-pends a layer it wrote; un-pending by id alone would
                    // drop that value from the next page file and close clean
                    // with the undone one on disk. Layers have no sequence,
                    // so the value is the check.
                    for written in item.layerFiles {
                        let held = content.layers.first { $0.id == written.id }
                        if held == nil || held == written { content.pendingLayerFiles.remove(written.id) }
                    }
                }
                retryBuffer[item.page] = nil
            }
            // A refused page stays dirty and every pass captures it again.
            // One the store will refuse again keeps its bytes, so those
            // passes do not re-encode the drawing.
            var kept = 0
            for (page, refusal) in report.refusals {
                TNLog.event(.notebook, "page \(page) refused: \(refusal)")
                guard !refusal.isTransient, let entry = serialized[page] else { continue }
                kept += entry.bytes.count
                if kept <= schedule.retryBufferBytes { retryBuffer[page] = entry }
            }
            // An index that left out a page this pass captured stays owed, so
            // the pass that lands the page's file rewrites the index to name
            // it. A placeholder is never captured, so it never holds it
            // (`Docs/Contract.md` — One save).
            if report.indexWritten, report.omitted.isDisjoint(with: captured.map(\.page)) {
                savedIndexSeq = max(savedIndexSeq, capturedIndexSeq)
            }
            if report.indexWithheld {
                lastSaveError = .indexWithheld
            } else if !report.refusals.isEmpty {
                lastSaveError = .pagesRefused(report.refusals)
            } else {
                lastSaveError = nil
            }
            backoff = nil
        } catch {
            if case .insufficientSpace(let needed, let available) = error {
                lastSaveError = .insufficientSpace(needed: needed, available: available)
            } else {
                lastSaveError = .io(error)
            }
            var total = 0
            for (page, entry) in serialized {
                total += entry.bytes.count
                if total <= schedule.retryBufferBytes { retryBuffer[page] = entry }
            }
            backoff = min((backoff ?? schedule.idleFloor) * 2, schedule.backoffCap)
            TNLog.event(.notebook, "save failed: \(error); backoff \(String(describing: backoff))")
        }
        currentSave = nil
        firstDirtyAt = nil
        dirtyPageCount = states.values.count(where: \.isDirty)
        if isDirty { markDirty() }
    }

    /// Runs a pass now and waits for it, and for any pass already running.
    /// Every pending revision is in custody first, so the pass writes it.
    /// A closed notebook runs and waits for nothing.
    package func flush() async {
        guard !isClosed else { return }
        await settlePendingRestores()
        debounce?.cancel()
        debounce = nil
        if let running = currentSave { await running.value }
        if isDirty {
            beginSave()
            if let running = currentSave { await running.value }
        }
    }

    /// A revision parked for a page not in custody moves no counter, so
    /// until it is adopted the notebook reports clean with an undo unsaved.
    /// The page is read here rather than waited for, because a scroll can
    /// cancel the window's load and then nothing would adopt the revision.
    /// A load still in flight when the read lands is cancelled; one that
    /// landed first adopted the revision itself. A page that cannot be read
    /// keeps its revision parked, and its own load refuses it as before.
    private func settlePendingRestores() async {
        var settled = false
        for page in Array(pendingRestores.keys) {
            guard var content = await unloadedContent(of: page),
                  pendingRestores.removeValue(forKey: page) != nil
            else { continue }
            loads[page]?.cancel()
            loads[page] = nil
            // A page outside the window is held as an import's page is:
            // retired, unpushed and without a composite, until the window
            // pushes it on entry or `prune` frees it once saved.
            let shown = wanted.contains(page)
            content.retired = !shown
            states[page] = .ready(content)
            if shown {
                emitContent(page)
                rerenderComposite(of: page)
            }
            settled = true
        }
        guard settled else { return }
        markDirty()
        onAsyncChange?()
    }

    /// The final pass. A clean answer means nothing more is armed or started.
    package func close() async -> CloseOutcome {
        guard !isClosed else { return .clean }
        await flush()
        // A discard, or a second close, can latch during the flush.
        guard !isClosed else { return .clean }
        viewWrite?.cancel()
        try? await store.writeView(ViewState(currentPageID: currentPageID))
        // A dirty close leaves the notebook open: the checkout stays, the
        // banner shows, and the next flush retries. Only a clean close ends it.
        if isDirty { return .dirty(pages: dirtyPages, indexUnsaved: indexSeq > savedIndexSeq) }
        isClosed = true
        return .clean
    }

    /// The close without its final pass: the unsaved pages are abandoned on
    /// purpose. A pass already running cannot be called back, so it is waited
    /// for: the checkout ends with no pass running and nothing armed. A write
    /// already in the store still lands.
    package func discard() async {
        debounce?.cancel()
        debounce = nil
        for load in loads.values { load.cancel() }
        loads.removeAll()
        viewWrite?.cancel()
        isClosed = true
        if let running = currentSave { await running.value }
    }
}
