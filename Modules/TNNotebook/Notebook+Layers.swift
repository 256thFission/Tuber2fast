import Foundation
import PencilKit
import TNCore
import TNFormat
import TNModel
import TNRender

extension Notebook {
    // MARK: Layers

    /// Validates and inserts a layer beneath the ink, synchronously: the tap
    /// that makes a text box gets its layer in the same pass. `recording`
    /// is false for a text box, whose session records the insert as part
    /// of one step at its end. A recorded insert under an open session is
    /// refused: the session's entry restores the revision it opened on, so
    /// one undo would take the insert with the box.
    package func insertLayer(_ layer: Layer, on page: PageID, recording: Bool = true) throws(FormatFault) {
        guard case .ready(var content) = states[page] else { throw .invalidWrite("page \(page) is not ready") }
        if recording, content.textEditing != nil { throw .invalidWrite("page \(page) has a text box open") }
        do { _ = try layer.validated() } catch { throw .invalidWrite("layer invalid: \(error)") }
        content.layers.append(layer)
        content.pendingLayerFiles.insert(layer.id)
        content.edited()
        commitLayerEdit(content, on: page, recording: recording)
    }

    /// Adds a layer beneath the ink. The asset, if any, is published first,
    /// and an open text box is refused before it is, so that refusal leaves
    /// no asset behind; `insertLayer` asks again after the write, because a
    /// box can open while it runs.
    package func addLayer(_ layer: Layer, assetData: Data?, on page: PageID) async throws(FormatFault) {
        guard case .ready(let content) = states[page] else { throw .invalidWrite("page \(page) is not ready") }
        guard content.textEditing == nil else { throw .invalidWrite("page \(page) has a text box open") }
        do { _ = try layer.validated() } catch { throw .invalidWrite("layer invalid: \(error)") }
        if let asset = layer.payload.asset {
            guard let assetData else { throw .invalidWrite("layer names an asset with no bytes") }
            try await writeAsset(assetData, asset)
        }
        try insertLayer(layer, on: page)
    }

    /// An image, normalized to HEIC, placed centered at up to 60% of each
    /// page edge, beneath the ink.
    package func importImage(_ data: Data, on page: PageID) async throws(FormatFault) {
        let fraction = 0.6
        guard let normalized = await Task.detached(priority: .userInitiated, operation: { ImageImport.normalize(data) }).value else {
            throw .invalidWrite("image could not be decoded")
        }
        guard let record = index.record(of: page) else { throw .invalidWrite("no such page") }
        let fit = min(record.geometry.width * fraction / Double(normalized.size.width), record.geometry.height * fraction / Double(normalized.size.height))
        let width = Double(normalized.size.width) * fit, height = Double(normalized.size.height) * fit
        let transform = PageSpaceTransform.placing(
            sourceWidth: Double(normalized.size.width), sourceHeight: Double(normalized.size.height),
            at: ((record.geometry.width - width) / 2, (record.geometry.height - height) / 2), scale: fit)
        let layer = Layer(id: LayerID(), transform: transform, payload: .image(ImageLayer(asset: AssetRef(id: AssetID(), format: .heic), naturalSize: normalized.size)))
        try await addLayer(layer, assetData: normalized.heic, on: page)
    }

    package func addLinkLayer(on page: PageID, rect: PageRect, target: LinkTarget) throws(FormatFault) {
        let layer = Layer(id: LayerID(), transform: .identity, payload: .link(LinkLayer(rect: rect, target: target)))
        try insertLayer(layer, on: page)
    }

    // MARK: Text editing

    /// An empty text box at `point`, and a session opened on it. The style
    /// rides with the request for the runtime's sake; an empty layer stores
    /// none, and the runtime types with its tool's. The session's `before`
    /// is captured ahead of the insert, so the box and what is typed in it
    /// undo as one step.
    package func createTextBox(on page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment) {
        guard case .ready(let content) = states[page] else {
            TNPrecondition.fail("a text box was requested on page \(page) which is not ready: \(String(describing: states[page]))")
        }
        let before = content.revision
        let layer = Layer(
            id: LayerID(), transform: .identity,
            payload: .text(TextLayer(rect: TextLayer.newBox.moved(to: point), runs: [], alignment: alignment))
        )
        do {
            try insertLayer(layer, on: page, recording: false)
        } catch {
            TNPrecondition.fail("a text box was requested on page \(page), which refused it: \(error)")
        }
        openTextSession(on: page, layer: layer.id, before: before)
    }

    /// A session on a box the page already holds; the revision it records
    /// against is the one it opens on.
    package func beginTextEditing(on page: PageID, layer: LayerID) {
        guard case .ready(let content) = states[page] else {
            TNPrecondition.fail("text editing began on page \(page) which is not ready: \(String(describing: states[page]))")
        }
        openTextSession(on: page, layer: layer, before: content.revision)
    }

    /// The composite leaves the layer out from the next render on, and the
    /// runtime is told to raise its view once that picture has landed.
    private func openTextSession(on page: PageID, layer: LayerID, before: PageRevision) {
        guard case .ready(var content) = states[page] else {
            TNPrecondition.fail("text editing began on page \(page) which is not ready: \(String(describing: states[page]))")
        }
        TNPrecondition.require(content.textEditing == nil, "text editing began on page \(page) while layer \(String(describing: content.textEditing?.layer)) was open")
        guard let found = content.layers.first(where: { $0.id == layer }), case .text(let text) = found.payload else {
            // Hit rects are one render stale between a restore and the
            // composite it queued, so a tap there can ask for a box the
            // restore removed. The runtime is waiting in `.opening`; the end
            // is what releases it, as it is for a begin the runtime cannot
            // honour.
            TNLog.event(.notebook, "text editing was requested on page \(page) for layer \(layer), which is not a text layer it holds")
            changes.append(.textEditingEnded(page, layer))
            return
        }
        guard !found.locked else {
            // The canvas does not open a locked box, but its lock flags are
            // one render stale too: an undo that relocks a box reaches the
            // canvas only with the composite it queued, so a tap before that
            // lands can ask for the box. Released the same way.
            TNLog.event(.notebook, "text editing was requested on page \(page) for layer \(layer), which is locked")
            changes.append(.textEditingEnded(page, layer))
            return
        }
        content.textEditing = TextSession(layer: layer, before: before)
        content.afterRender.append(.textEditingBegan(page, TextEditStart(layer: layer, text: text)))
        states[page] = .ready(content)
        rerenderComposite(of: page)
    }

    /// The session is the edit: one entry from the revision the session
    /// opened on to the one its commit leaves, and none when they are equal.
    /// An abandoned empty box is equal by construction, since its insert
    /// was not recorded and its removal returns the page to `before`.
    package func endTextEditing(on page: PageID, layer: LayerID, _ text: TextLayer) {
        guard case .ready(var content) = states[page] else {
            TNPrecondition.fail("text editing ended on page \(page) which is not ready: \(String(describing: states[page]))")
        }
        guard let session = content.textEditing, session.layer == layer else {
            TNPrecondition.fail("text editing ended on page \(page) for layer \(layer), which is not the open one (\(String(describing: content.textEditing?.layer)))")
        }
        guard let position = content.layers.firstIndex(where: { $0.id == layer }) else {
            TNPrecondition.fail("text editing ended on page \(page) for layer \(layer), which it no longer holds")
        }
        content.textEditing = nil
        let merged = TextLayer(rect: text.rect, runs: TextRun.merging(text.runs), alignment: text.alignment)
        let committed = Layer(id: layer, transform: .identity, payload: .text(merged), locked: content.layers[position].locked)
        // The overlay's gesture math cannot produce an invalid rect, and a
        // clamp is forbidden.
        do { _ = try committed.validated() } catch { TNPrecondition.fail("a committed text layer is invalid: \(error)") }
        if merged.runs.allSatisfy(\.string.isEmpty) {
            content.removeLayer(at: position)
        } else {
            content.replaceLayer(at: position, with: committed)
        }
        // Two questions, not one. Whether the session moved the revision is
        // what the stack needs, and an abandoned empty box did not, so it is
        // recorded from where the session opened. Whether this commit moved
        // the page is what the save and the thumbnail need, and that box moved
        // it twice, once to insert and once to remove; the tail asks that one.
        recordEdit(on: page, from: session.before, to: content.revision, rebuilt: false)
        content.afterRender.append(.textEditingEnded(page, layer))
        commitLayerEdit(content, on: page, recording: false)
    }

    /// Where every layer edit ends, and so the one place a layer edit bumps
    /// the content version. `content` is the page after the edit, and the
    /// page held until this stores it is the page before, which the entry
    /// runs from; `recording` is false for a text box, whose session records
    /// for itself. Only an edit that moved the page's sequence is saved and
    /// re-thumbnailed, so a layer set to the value it had writes nothing. The
    /// render runs either way: a commit's end rides behind it.
    private func commitLayerEdit(_ content: PageContent, on page: PageID, recording: Bool = true) {
        guard let before = states[page]?.content else {
            TNPrecondition.fail("a layer edit landed on page \(page), which is not ready: \(String(describing: states[page]))")
        }
        if recording { recordEdit(on: page, from: before.revision, to: content.revision, rebuilt: false) }
        states[page] = .ready(content)
        if content.editSeq != before.editSeq {
            bumpContentVersion(of: page)
            markDirty()
        }
        rerenderComposite(of: page)
    }

    /// A locked layer refuses a transform, a move and a delete, and says so.
    /// Not a trap: the runtime is told the lock through the composite's layer
    /// list, but an undo can relock a layer while a drag on it is in
    /// flight, and the drag's end reports anyway. The refusal is answered
    /// like any other, by restating the placement the notebook holds.
    package func transformLayer(on page: PageID, layer layerID: LayerID, to transform: PageSpaceTransform) -> TransformOutcome {
        guard case .ready(var content) = states[page] else { return .refused(reason: "page is not ready") }
        guard let position = content.layers.firstIndex(where: { $0.id == layerID }) else { return .refused(reason: "no such layer") }
        guard !content.layers[position].locked else { return .refused(reason: "layer \(layerID) is locked") }
        let moved = content.layers[position].withTransform(transform)
        do { _ = try moved.validated() } catch { return .refused(reason: "\(error)") }
        content.replaceLayer(at: position, with: moved)
        commitLayerEdit(content, on: page)
        return .accepted
    }

    /// Moves a link or a text box to `origin`, at the size it had. Its
    /// placement is its rect and its transform is the identity —
    /// `validated()` refuses any other — so a move is a rect edit and
    /// `transformLayer` refuses every one of them. This is that method's body
    /// with a new origin in place of a new transform, recorded through the
    /// revision like any other layer edit, and rerendered so the hit rects
    /// follow the picture. There is no size to pass: the frame only moves
    /// one, and a text box's size changes only in its text session.
    ///
    /// It answers a `TransformOutcome` so the frame's report can be answered
    /// the way `layerTransformed` is.
    package func moveRectLayer(on page: PageID, layer layerID: LayerID, to origin: PagePoint) -> TransformOutcome {
        guard case .ready(var content) = states[page] else { return .refused(reason: "page is not ready") }
        guard let position = content.layers.firstIndex(where: { $0.id == layerID }) else { return .refused(reason: "no such layer") }
        let layer = content.layers[position]
        let payload: LayerPayload
        switch layer.payload {
        case .link(let link): payload = .link(LinkLayer(rect: link.rect.moved(to: origin), target: link.target))
        case .text(let text): payload = .text(TextLayer(rect: text.rect.moved(to: origin), runs: text.runs, alignment: text.alignment))
        case .image, .pdf: return .refused(reason: "layer \(layerID) is placed by its transform")
        }
        guard !layer.locked else { return .refused(reason: "layer \(layerID) is locked") }
        let moved = Layer(id: layerID, transform: layer.transform, payload: payload, locked: layer.locked)
        do { _ = try moved.validated() } catch { return .refused(reason: "\(error)") }
        content.replaceLayer(at: position, with: moved)
        commitLayerEdit(content, on: page)
        return .accepted
    }

    /// Locks or unlocks a layer. One entry on the stack, like a transform,
    /// and answered the same way: the composite that follows carries the
    /// layer list with the flag, which is how the runtime learns it.
    package func setLayerLock(_ layerID: LayerID, on page: PageID, locked: Bool) -> TransformOutcome {
        guard case .ready(var content) = states[page] else { return .refused(reason: "page is not ready") }
        guard let position = content.layers.firstIndex(where: { $0.id == layerID }) else { return .refused(reason: "no such layer") }
        content.replaceLayer(at: position, with: content.layers[position].withLock(locked))
        commitLayerEdit(content, on: page)
        return .accepted
    }

    /// A delete is answered by the composite that omits the layer, so it
    /// had nothing to say back until a lock could refuse it. It says so the
    /// way a transform does; the binding has nothing to do with the answer
    /// but a test does.
    @discardableResult
    package func deleteLayer(_ layerID: LayerID, on page: PageID) -> TransformOutcome {
        guard case .ready(var content) = states[page] else { return .refused(reason: "page is not ready") }
        guard let position = content.layers.firstIndex(where: { $0.id == layerID }) else { return .refused(reason: "no such layer") }
        guard !content.layers[position].locked else { return .refused(reason: "layer \(layerID) is locked") }
        content.removeLayer(at: position)
        commitLayerEdit(content, on: page)
        return .accepted
    }
}
