import Foundation
import TNModel

/// What a renderer reads: asset bytes.
package protocol AssetReading: Sendable {
    func readAsset(_ ref: AssetRef) async throws(FormatFault) -> Data
}

/// What the notebook, its renderer and the library's sweep ask of a store.
/// A seam because the ink and durability proofs need a store that can be
/// held open or refuse on cue. `PackageStore` is the one production
/// conformer.
package protocol PackageStoring: AssetReading {
    func load() async throws(FormatFault) -> LoadedNotebook
    func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes
    func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport
    func writeAsset(_ data: Data, _ ref: AssetRef) async throws(FormatFault)
    func readView() async -> ViewState?
    func writeView(_ view: ViewState) async throws(FormatFault)
    func compact(now: Date, keeping: Set<AssetRef>) async throws(FormatFault) -> CompactReport
}

extension PackageStore: PackageStoring {}
