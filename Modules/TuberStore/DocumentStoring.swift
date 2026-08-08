import Foundation
import TuberModel

/// The saved document as its consumers use it.
///
/// `DocumentStore` is the one writer of durable state (`Contract.md` — Owners,
/// golden rule 3) and stays the one writer: this protocol is a *seam*, not a
/// second authority. It is exactly the surface `EditorSession` and
/// `StaticLayerRenderer` actually call, and nothing else — the store's other
/// members (`assetExists`, the `changedPages` convenience `save`, the format
/// machinery) are not here because no consumer of this protocol reaches for
/// them, and a capability nobody uses is a capability a substitute has to
/// implement for nothing.
///
/// Why it exists: every declaration used to be the concrete actor, so a test
/// could only ever exercise the real file system. That single missing seam is
/// what made the suite reach for temp directories, wall-clock sleeps, and
/// `…ForTesting` members on production types. With the seam, a test that needs
/// a save to fail, or to be held open while it looks at the session, writes a
/// substitute instead of asking the session to suspend itself.
///
/// Every requirement is `async throws` because the implementation is an actor:
/// a synchronous `actor` method satisfies an `async` requirement, and a
/// substitute that needs to suspend — a save held open, a load that fails on
/// the third call — can do so without the real store paying for the
/// possibility.
///
/// Construction is deliberately absent. `EditorLifecycle` builds the one
/// `DocumentStore` over the one document directory; a protocol that could
/// build one would be inviting a second.
package protocol DocumentStoring: Sendable {
    /// The document index, or `nil` when no document exists. An invalid file
    /// throws — `nil` means absent, never unreadable (`Contract.md` — Durable
    /// form).
    func load() async throws -> DocumentIndex?

    /// One page's layers as this build can act on them: its ink, its static
    /// layers in order, and any layer it must refuse.
    func loadPage(_ pageID: UUID) async throws -> LoadedPage

    /// Writes the named pages and, only if it changed, the index. Throws
    /// `PageSaveRefusal` when some pages were refused and the rest were
    /// written — the caller acknowledges per page.
    func save(index: DocumentIndex, pages: [PageWrite]) async throws

    /// Writes an imported original. Assets are written before the layer that
    /// names them, so an interrupted import leaves an unreferenced asset and
    /// never a layer naming bytes that are not there.
    func writeAsset(_ bytes: Data, assetID: UUID, format: AssetFormat) async throws

    /// An imported original's bytes, for decoding off-main.
    func loadAsset(assetID: UUID, format: AssetFormat) async throws -> Data

    /// Removes a layer's file if no page still names it. Reclamation is
    /// root-to-leaf and each step is optional: what it costs to skip is an
    /// orphan, which *Durable form* rules inert.
    @discardableResult
    func deleteLayerFileIfUnreferenced(layerID: UUID) async throws -> Bool

    /// Removes an asset if no layer file still names it. The last step of the
    /// same reclamation.
    @discardableResult
    func deleteAssetIfUnreferenced(assetID: UUID, format: AssetFormat) async throws -> Bool
}

extension DocumentStoring {
    /// Every page written whole: a convenience for the first save of a document
    /// and for tests, whose subject is validation rather than granularity. It
    /// is the ordinary path's opposite — "every layer changed" is exactly what
    /// an ink edit is not — so the autosave path does not use it.
    ///
    /// It lives here rather than on the store because it is not a capability:
    /// it is one line of shorthand over the single primitive, so a substitute
    /// inherits it already correct and cannot implement it inconsistently.
    package func save(index: DocumentIndex, changedPages: [UUID: [LayerEnvelope]]) async throws {
        try await save(
            index: index,
            pages: changedPages.map { PageWrite(pageID: $0.key, layers: $0.value) }
        )
    }
}

/// One page the store refused to save, and why — carried as text because the
/// caller's use is reporting, and the repair is a later edit, not a branch on
/// the cause.
package struct PageRefusal: Sendable, Equatable {
    package let pageID: UUID
    package let reason: String

    package init(pageID: UUID, reason: String) {
        self.pageID = pageID
        self.reason = reason
    }
}

/// Thrown by `save` when at least one page refused its plan. **Every page not
/// named here was written and is durable** — the caller acknowledges those
/// pages and keeps only the refused ones dirty. `indexWritten` says whether the
/// index landed; it is withheld when a refused page has no page file on disk
/// yet.
///
/// It lives beside `DocumentStoring` rather than nested in `DocumentStore`
/// because it is the *protocol's* vocabulary: `save`'s doc comment promises it,
/// `EditorSession` catches it by type, and a substitute store has to be able to
/// throw it. Nested, naming the refusal meant naming the one implementation —
/// which is exactly the coupling the seam exists to remove, and which would
/// have made the app target import the store module for a type the protocol
/// already speaks.
package struct PageSaveRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    package let refusedPages: [PageRefusal]
    package let indexWritten: Bool

    package init(refusedPages: [PageRefusal], indexWritten: Bool) {
        self.refusedPages = refusedPages
        self.indexWritten = indexWritten
    }

    package var description: String {
        "save refused for \(refusedPages.count) page(s): "
            + refusedPages
                .map { "\($0.pageID) (\($0.reason))" }
                .joined(separator: "; ")
    }
}

extension DocumentStore: DocumentStoring {}
