import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import TNFormat
@testable import TNLibrary
@testable import TNModel
@testable import TNNotebook
@testable import TNRender

@Suite("Library covers: the first page, rendered small, keyed by the package's time")
@MainActor
struct LibraryCoverTests {
    func makeLibrary(_ name: String) throws -> (Scratch, Library) {
        let scratch = try Scratch(name)
        return (scratch, Library(store: try LibraryStore(base: scratch.root)))
    }

    func listed(_ library: Library, _ path: String) async throws -> TNLibrary.LibraryItem {
        try #require(try await library.store.list(folder: "").first { $0.relativePath == path })
    }

    @Test("A closed notebook's cover is thumbnail-sized, cached on the second ask, and gone after a purge")
    func closedCover() async throws {
        let (scratch, library) = try makeLibrary("cover-closed")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Plain", in: "")
        let cover = try #require(await library.cover(of: item))
        let (width, height) = Renderer.thumbnailPixels(for: .letter)
        #expect(cover.width == width && cover.height == height)
        let again = try #require(await library.cover(of: item))
        #expect(again === cover)
        library.purge()
        let rebuilt = try #require(await library.cover(of: item))
        #expect(rebuilt !== cover)
        #expect(await library.cover(of: try await library.store.createFolder(named: "F", in: "")) == nil)
    }

    @Test("A save moves the version, and the new cover carries the stroke")
    func saveMovesTheCover() async throws {
        let (scratch, library) = try makeLibrary("cover-save")
        defer { withExtendedLifetime(scratch) {} }
        let created = try await library.store.createNotebook(named: "Inked", in: "")
        let blank = try #require(await library.cover(of: created))
        let source = try await library.store.coverSource(of: created.relativePath)
        #expect(source.version == CoverSource.version(at: created.modifiedAt))

        guard case .opened(let notebook) = await library.checkout(created.relativePath, schedule: fast) else { Issue.record("open failed"); return }
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        let open = try #require(await library.cover(of: created))
        #expect(open === (await notebook.thumbnail(of: page)))
        _ = await library.release(created.relativePath)

        let saved = try await listed(library, created.relativePath)
        #expect(saved.modifiedAt > created.modifiedAt)
        let inked = try #require(await library.cover(of: saved))
        #expect(inked !== blank)
        let scale = Double(Renderer.thumbnailPixels(for: .letter).height) / PageGeometry.letter.height
        let onStroke = luminance(of: inked, x: Int(40 * scale), y: Int(10 * scale))
        let offStroke = luminance(of: inked, x: inked.width / 2, y: inked.height / 2)
        #expect(onStroke < offStroke)
        #expect(luminance(of: blank, x: Int(40 * scale), y: Int(10 * scale)) == offStroke)
    }
}
