import Foundation
import TNModel

/// What the notebook asks of its store. A seam because the ink and
/// durability proofs need a store that can be held open, refuse on cue, or
/// count its calls, and a real store cannot be asked to do any of that.
/// `PackageStore` is the one production conformer.
package protocol PackageStoring: Sendable {
    var layout: PackageLayout { get }
    func load() async throws(FormatFault) -> LoadedNotebook
    func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes
    func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport
    func writeAsset(_ data: Data, _ ref: AssetRef) async throws(FormatFault)
    func readAsset(_ ref: AssetRef) async throws(FormatFault) -> Data
    func readView() async -> ViewState?
    func writeView(_ view: ViewState) async throws(FormatFault)
    func compact(now: Date) async throws(FormatFault) -> CompactReport
}

extension PackageStore: PackageStoring {}
