import Foundation
import TNModel

/// What the notebook asks of its store, and nothing more. A seam because
/// the ink and durability proofs need a store that can be held open or
/// refuse on cue. `PackageStore` is the one production conformer; compact
/// and asset reads are the library's and renderer's business on the
/// concrete type.
package protocol PackageStoring: Sendable {
    func load() async throws(FormatFault) -> LoadedNotebook
    func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes
    func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport
    func writeAsset(_ data: Data, _ ref: AssetRef) async throws(FormatFault)
    func readView() async -> ViewState?
    func writeView(_ view: ViewState) async throws(FormatFault)
}

extension PackageStore: PackageStoring {}
