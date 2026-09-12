import Foundation
import Testing
@testable import TNLibrary
@testable import TNModel
@testable import TNNotebook

@Suite("Library browser: where you are, what is shown, what an intention does")
@MainActor
struct LibraryBrowserTests {
    private func makeBrowser(_ name: String) throws -> (Scratch, LibraryBrowser) {
        let scratch = try Scratch(name)
        let library = Library(store: try LibraryStore(base: scratch.root))
        return (scratch, LibraryBrowser(library: library, optionsStore: MemoryViewOptionsStore()))
    }

    @Test("The filter narrows to one kind and All brings the rest back")
    func filtering() async throws {
        let (scratch, browser) = try makeBrowser("browser-filter")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Term", in: "")
        _ = try await browser.library.store.createNotebook(named: "Essay", in: "")
        await browser.reload()
        #expect(browser.displayed.count == 2)

        browser.filter = .notebooks
        #expect(browser.displayed.map(\.name) == ["Essay"])
        browser.filter = .folders
        #expect(browser.displayed.map(\.name) == ["Term"])
        browser.filter = .all
        #expect(browser.displayed.count == 2)
    }

    @Test("Search ignores case and accents, and a new place clears it")
    func searching() async throws {
        let (scratch, browser) = try makeBrowser("browser-search")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Café", in: "")
        _ = try await browser.library.store.createNotebook(named: "Essay", in: "")
        await browser.reload()

        browser.searchText = "cafe"
        #expect(browser.displayed.map(\.name) == ["Café"])
        browser.searchText = "ESS"
        #expect(browser.displayed.map(\.name) == ["Essay"])

        browser.searchText = "cafe"
        browser.enter(try #require(browser.displayed.first))
        #expect(browser.searchText.isEmpty)
        browser.searchText = "x"
        browser.back()
        #expect(browser.searchText.isEmpty)
        browser.searchText = "x"
        browser.section = .trash
        #expect(browser.searchText.isEmpty)
    }

    @Test("A search reads the whole library, wherever the reader is standing")
    func searchingTheWholeTree() async throws {
        let (scratch, browser) = try makeBrowser("browser-search-tree")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Term", in: "")
        _ = try await browser.library.store.createFolder(named: "Week 1", in: "Term")
        _ = try await browser.library.store.createNotebook(named: "Deep", in: "Term/Week 1")
        _ = try await browser.library.store.createNotebook(named: "Essay", in: "")

        // From the root.
        browser.searchText = "deep"
        await browser.reload()
        #expect(browser.displayed.map(\.name) == ["Deep"])
        #expect(browser.displayed.first?.parentPath == "Term/Week 1")

        // And from a folder that does not contain it.
        browser.searchText = ""
        await browser.reload()
        browser.enter(try #require(browser.displayed.first { $0.name == "Term" }))
        browser.searchText = "deep"
        await browser.reload()
        #expect(browser.displayed.map(\.name) == ["Deep"])

        // Clearing it puts the folder's own listing back.
        browser.searchText = ""
        await browser.reload()
        #expect(browser.displayed.map(\.name) == ["Week 1"])
    }

    @Test("Creating a notebook remembers its size and paper; a refused one does not")
    func theNewNotebookSheetOpensOnTheLastChoice() async throws {
        let (scratch, browser) = try makeBrowser("browser-new-notebook")
        defer { withExtendedLifetime(scratch) {} }
        #expect(browser.options.newNotebook == nil, "nothing has been created here yet")

        let a5 = PageGeometry(width: 420, height: 595)
        await browser.createNotebook(named: "Essay", geometry: a5, paper: .lined)
        #expect(browser.refusal == nil)
        #expect(browser.options.newNotebook == NotebookSetup(geometry: a5, paper: .lined))

        // A name that already exists is refused, and a notebook that was not
        // made is not a choice.
        await browser.createNotebook(named: "Essay", geometry: .letter, paper: .grid)
        #expect(browser.refusal != nil)
        #expect(browser.options.newNotebook == NotebookSetup(geometry: a5, paper: .lined))
    }

    @Test("Entering and leaving a folder walks the path")
    func walkingTheTree() async throws {
        let (scratch, browser) = try makeBrowser("browser-walk")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Term", in: "")
        _ = try await browser.library.store.createFolder(named: "Week 1", in: "Term")
        _ = try await browser.library.store.createNotebook(named: "Notes", in: "Term/Week 1")
        await browser.reload()

        browser.enter(try #require(browser.displayed.first))
        #expect(browser.folder == "Term")
        await browser.reload()
        browser.enter(try #require(browser.displayed.first))
        #expect(browser.folder == "Term/Week 1")
        await browser.reload()
        #expect(browser.displayed.map(\.name) == ["Notes"])

        browser.back()
        #expect(browser.folder == "Term")
        browser.back()
        #expect(browser.folder == "")
        browser.back()
        #expect(browser.folder == "")
    }

    @Test("Selection begins empty, toggles, takes all of what is displayed, and ends with the section")
    func selecting() async throws {
        let (scratch, browser) = try makeBrowser("browser-select")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createNotebook(named: "One", in: "")
        _ = try await browser.library.store.createNotebook(named: "Two", in: "")
        await browser.reload()
        #expect(browser.selection == nil)

        browser.beginSelecting()
        #expect(browser.selection == [])
        let first = try #require(browser.displayed.first)
        browser.toggleSelected(first)
        #expect(browser.selection == [first.relativePath])
        browser.toggleSelected(first)
        #expect(browser.selection == [])

        browser.filter = .notebooks
        browser.selectAll()
        #expect(browser.selection == Set(browser.displayed.map(\.relativePath)))
        browser.section = .favorites
        #expect(browser.selection == nil)
    }

    @Test("Moving a selection lands every item and the listing reloads")
    func movingASelection() async throws {
        let (scratch, browser) = try makeBrowser("browser-move")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Done", in: "")
        _ = try await browser.library.store.createNotebook(named: "One", in: "")
        _ = try await browser.library.store.createNotebook(named: "Two", in: "")
        await browser.reload()

        browser.beginSelecting()
        for item in browser.displayed where item.kind == .notebook { browser.toggleSelected(item) }
        await browser.move(try #require(browser.selection), toFolder: "Done")

        #expect(browser.refusal == nil)
        #expect(browser.selection == nil)
        #expect(browser.displayed.map(\.name) == ["Done"])
        #expect(try await browser.library.store.list(folder: "Done").map(\.name) == ["One", "Two"])
    }

    @Test("Moving an item into the folder it is already in is a no-op, not a refusal")
    func movingIntoTheCurrentParent() async throws {
        let (scratch, browser) = try makeBrowser("browser-move-noop")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Done", in: "")
        _ = try await browser.library.store.createNotebook(named: "One", in: "Done")
        await browser.reload()

        await browser.move(["Done/One.tubernotes"], toFolder: "Done")
        #expect(browser.refusal == nil)
        #expect(try await browser.library.store.list(folder: "Done").map(\.name) == ["One"])
    }

    @Test("Moving a folder that holds an open notebook is refused, and nothing moves")
    func movingALockedFolder() async throws {
        let (scratch, browser) = try makeBrowser("browser-move-locked-folder")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Archive", in: "")
        _ = try await browser.library.store.createFolder(named: "Term", in: "")
        let open = try await browser.library.store.createNotebook(named: "Open", in: "Term")
        await browser.reload()
        guard case .opened = await browser.library.checkout(open.relativePath) else {
            Issue.record("open failed")
            return
        }

        // The folder itself, not a neighbour of the open notebook: `Library`
        // gates the source path only, so only a drag of the folder above an
        // open notebook is refused, and the refusal names the notebook the
        // reader has to close, not the folder that was dragged.
        await browser.move(["Term"], toFolder: "Archive")
        #expect(browser.refusal == "close Open.tubernotes first")
        #expect(try await browser.library.store.list(folder: "Archive").isEmpty)
        #expect(try await browser.library.store.list(folder: "Term").map(\.name) == ["Open"])

        _ = await browser.library.release(open.relativePath)
    }

    @Test("A three-item move with one open notebook lands the other two and refuses once")
    func aPartlyRefusedMove() async throws {
        let (scratch, browser) = try makeBrowser("browser-move-gathers")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Done", in: "")
        _ = try await browser.library.store.createNotebook(named: "One", in: "")
        let open = try await browser.library.store.createNotebook(named: "Open", in: "")
        _ = try await browser.library.store.createNotebook(named: "Two", in: "")
        await browser.reload()
        guard case .opened = await browser.library.checkout(open.relativePath) else {
            Issue.record("open failed")
            return
        }

        // "One" sorts before "Open", so the refusal lands in the middle of the
        // loop: gathering, not stopping, is what leaves "Two" moved as well.
        await browser.move(["One.tubernotes", "Open.tubernotes", "Two.tubernotes"], toFolder: "Done")
        #expect(browser.refusal == "close Open.tubernotes first")
        #expect(browser.selection == nil)
        #expect(try await browser.library.store.list(folder: "Done").map(\.name) == ["One", "Two"])
        #expect(try await browser.library.store.list(folder: "").map(\.name) == ["Done", "Open"])

        _ = await browser.library.release(open.relativePath)
    }

    @Test("A refused mutation says so and leaves the listing standing")
    func aRefusalLands() async throws {
        let (scratch, browser) = try makeBrowser("browser-refusal")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await browser.library.store.createNotebook(named: "Open", in: "")
        await browser.reload()
        guard case .opened = await browser.library.checkout(item.relativePath) else {
            Issue.record("open failed")
            return
        }

        await browser.trash([item.relativePath])
        #expect(browser.refusal == "close Open.tubernotes first")
        #expect(browser.displayed.map(\.name) == ["Open"])

        _ = await browser.library.release(item.relativePath)
        await browser.trash([item.relativePath])
        #expect(browser.refusal == nil)
        #expect(browser.displayed.isEmpty)
    }

    @Test("A move's destinations leave out the folders being moved and everything inside them")
    func destinations() async throws {
        let (scratch, browser) = try makeBrowser("browser-destinations")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Outer", in: "")
        _ = try await browser.library.store.createFolder(named: "Inner", in: "Outer")
        _ = try await browser.library.store.createFolder(named: "Other", in: "")
        await browser.reload()

        #expect(await browser.destinations(in: "", excluding: []).map(\.name) == ["Other", "Outer"])
        #expect(await browser.destinations(in: "", excluding: ["Outer"]).map(\.name) == ["Other"])
        #expect(await browser.destinations(in: "Outer", excluding: ["Outer"]).isEmpty)
    }

    @Test("The favorites section lists what is starred, and a tap there unstars it")
    func favoritesSection() async throws {
        let (scratch, browser) = try makeBrowser("browser-favorites")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Term", in: "")
        _ = try await browser.library.store.createNotebook(named: "Essay", in: "Term")
        await browser.reload()

        let folder = try #require(browser.displayed.first)
        await browser.toggleFavorite(folder)
        #expect(browser.isFavorite(folder))

        browser.section = .favorites
        await browser.reload()
        #expect(browser.displayed.map(\.name) == ["Term"])
        await browser.toggleFavorite(try #require(browser.displayed.first))
        #expect(browser.displayed.isEmpty)
        #expect(browser.favorites.isEmpty)
    }

    @Test("Setting a decoration reloads the listing and the item carries it")
    func decorating() async throws {
        let (scratch, browser) = try makeBrowser("browser-decorate")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createFolder(named: "Term", in: "")
        await browser.reload()
        let folder = try #require(browser.displayed.first)
        #expect(folder.decoration == .plain)

        let chosen = FolderDecoration(color: .green, symbol: .book)
        await browser.setDecoration(chosen, on: folder)
        #expect(browser.refusal == nil)
        #expect(browser.displayed.first?.decoration == chosen)
    }

    @Test("The trash section lists, recovers, deletes, and empties")
    func trashSection() async throws {
        let (scratch, browser) = try makeBrowser("browser-trash")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await browser.library.store.createNotebook(named: "One", in: "")
        _ = try await browser.library.store.createNotebook(named: "Two", in: "")
        _ = try await browser.library.store.createNotebook(named: "Three", in: "")
        await browser.reload()
        await browser.trash(Set(browser.displayed.map(\.relativePath)))
        #expect(browser.displayed.isEmpty)

        browser.section = .trash
        await browser.reload()
        #expect(browser.trash.count == 3)

        await browser.recover(try #require(browser.trash.first))
        #expect(browser.trash.count == 2)
        await browser.deletePermanently(try #require(browser.trash.first))
        #expect(browser.trash.count == 1)
        await browser.emptyTrash()
        #expect(browser.trash.isEmpty)
        #expect(browser.refusal == nil)

        browser.section = .documents
        await browser.reload()
        #expect(browser.displayed.count == 1)
    }

    @Test("Creating a folder and a notebook puts both in the folder being shown")
    func creating() async throws {
        let (scratch, browser) = try makeBrowser("browser-create")
        defer { withExtendedLifetime(scratch) {} }
        await browser.createFolder(named: "Term")
        #expect(browser.displayed.map(\.name) == ["Term"])

        browser.enter(try #require(browser.displayed.first))
        await browser.createNotebook(named: "Essay", geometry: .letter, paper: .lined)
        #expect(browser.displayed.map(\.name) == ["Essay"])
        #expect(try await browser.library.store.list(folder: "Term").map(\.name) == ["Essay"])

        await browser.createFolder(named: "..")
        #expect(browser.refusal == "invalid name ..")
    }
}
