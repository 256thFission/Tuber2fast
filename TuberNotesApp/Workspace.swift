import Observation
import SwiftUI
import TNCore
import TNEditor
import TNLibrary
import TNModel
import TNNotebook
import UIKit

/// The app's one owner of durable state: the library, the open tabs, and the
/// background-execution lease. Views render its snapshots and send it
/// intentions; nothing else in the app target holds a `Notebook`.
@MainActor @Observable
final class Workspace {
    /// One open notebook. The tab is identified by the notebook's identity,
    /// which is what the checkout ledger and a link both speak in.
    struct Tab: Identifiable {
        let id: NotebookID
        let path: String
        let name: String
        let editor: EditorViewModel
    }

    let library: Library

    /// The browser's place, options and selection, built here because the
    /// library it reads is built here.
    let browser: LibraryBrowser

    /// The tool presets, the colour recents, and the last kind, shared by
    /// every tab and kept between launches.
    let palette = ToolPalette(store: PreferenceDefaults<ToolPaletteRecord>(key: "tn.toolPalette", .standard))

    private(set) var tabs: [Tab] = []
    /// `nil` means the library is showing.
    var activeTabID: NotebookID?

    /// Which theme was asked for: the system's own light and dark, or one
    /// preset. `choose` is the only way in, so that writing the preference
    /// cannot be separated from making the choice.
    private(set) var choice: ThemeChoice = .system

    func choose(_ choice: ThemeChoice) {
        self.choice = choice
        themeStore.save(choice)
        resolveTheme()
    }

    /// Whether the system is drawing dark. `RootView` reports it; nothing
    /// here asks, and only `.system` is affected by the answer.
    var colourScheme: ColorScheme = .light {
        didSet { resolveTheme() }
    }

    /// The theme every piece of chrome draws from, resolved from the choice
    /// and the hour. The SwiftUI half reads it through the environment; the
    /// canvas is told, through each tab's editor.
    private(set) var theme: Theme = .macaron

    private let themeStore = PreferenceDefaults<ThemeChoice>(key: "tn.theme", .standard)

    private func resolveTheme() {
        theme = choice.resolve(dark: colourScheme == .dark)
        for tab in tabs { tab.editor.apply(theme: theme) }
    }

    /// `-TNTheme <id>` opens on a theme, so a screenshot of one needs no
    /// taps to reach it. It takes a preset's id or `system`, not the name the
    /// picker shows: the id is what the preference saves, and a name is free
    /// to change. It is not saved: a run that exists to be photographed must
    /// not leave the machine holding a theme nobody chose.
    ///
    /// An id no preset has, or a flag read as one, is logged, and the launch
    /// goes on as if the argument were absent. The argument is outside data,
    /// as the preference beside it is, and an app that traps on a typo in
    /// one shows nothing to photograph.
    ///
    /// A saved preset this build has no row for is a preference it cannot
    /// read, so it opens on the system's own light and dark, as unreadable
    /// bytes do: a build that ships fewer themes than the one that wrote the
    /// choice draws rather than traps.
    static func launchChoice(_ arguments: [String], _ store: PreferenceDefaults<ThemeChoice>) -> ThemeChoice {
        if let index = arguments.firstIndex(of: "-TNTheme"), index + 1 < arguments.count {
            let value = arguments[index + 1]
            if value == "system" { return .system }
            if let preset = Theme.preset(ThemeID(rawValue: value)) { return .preset(preset.id) }
            TNLog.event(.lifecycle, "-TNTheme names no theme: \(value)")
        }
        let saved = store.load()
        if case .preset(let id) = saved, Theme.preset(id) == nil { return .system }
        return saved ?? .system
    }

    /// Whether the seat is out. One tenant, one flag.
    var isSeatOpen = LaunchHooks.arguments.contains("-TNSeatOpen")

    /// The refusal surface Part 7 names: one line, dismissible.
    var banner: String?
    /// Set alongside a save-refused banner so the banner can offer the one
    /// action that always works.
    private(set) var discardableTabID: NotebookID?

    /// A link resolved before the index is built refuses with "still loading"
    /// rather than guessing.
    private(set) var identitiesReady = false

    private var leaseFlush: Task<Void, Never>?
    /// A phase change while a flush runs: the flush runs again when it ends.
    /// `.inactive` starts the flush, and a cancelled touch's late commit can
    /// land after that pass captured its pages.
    private var flushAgain = false
    private var memoryWarnings: (any NSObjectProtocol)?

    init() {
        do {
            library = Library(store: try LibraryStore(base: LibraryStore.defaultBase()))
        } catch {
            // Application Support is not optional. A library that cannot make
            // its own directories has no state to preserve and no surface to
            // refuse from, so this fails loud rather than running blind.
            TNPrecondition.fail("the library store could not be created: \(error)")
        }
        browser = LibraryBrowser(library: library, optionsStore: PreferenceDefaults<LibraryViewOptions>(key: "tn.libraryView", .standard))
        // Assigned here rather than in its declaration so the launch
        // argument and the preference are read through the one store this
        // object owns.
        choice = Self.launchChoice(LaunchHooks.arguments, themeStore)
        resolveTheme()
        Task { await self.refreshIdentities() }
        // The renderer caches declare "on memory pressure from the app" as an
        // evictor; this is the one place that keeps the promise.
        memoryWarnings = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.purgeRenderers()
                self?.library.purge()
            }
        }
        #if DEBUG
        // `-TNSmokeNotebook`: create a notebook named Smoke if absent and open
        // it, so a simulator launch reaches the editor with no taps. Debug
        // only; a smoke launch is not a user path.
        if LaunchHooks.arguments.contains("-TNSmokeNotebook") {
            Task { await self.openSmokeNotebook() }
        }
        #endif
    }

    isolated deinit {
        if let memoryWarnings { NotificationCenter.default.removeObserver(memoryWarnings) }
    }

    #if DEBUG
    private func openSmokeNotebook() async {
        let path = "Smoke.tubernotes"
        if (try? await library.store.list(folder: "").contains { $0.relativePath == path }) != true {
            _ = try? await library.store.createNotebook(named: "Smoke", in: "")
        }
        await open(path: path, name: "Smoke")
    }
    #endif

    /// Every open notebook's renderer drops what it can rebuild: decoded
    /// assets and thumbnails. Ink and pages are untouched; the library's
    /// covers go the same way, next door.
    private func purgeRenderers() {
        for tab in tabs {
            let renderer = tab.editor.notebook.renderer
            Task { await renderer.purge() }
        }
    }

    // MARK: Identity

    func refreshIdentities() async {
        do {
            try await library.refreshIdentities()
            identitiesReady = true
        } catch {
            banner = "Couldn't read your library: \(error)"
        }
    }

    /// Every change to the library goes through here. A change can move an
    /// identity within the tree or add one, so the index a link resolves
    /// through is rebuilt after it. The refusal is cleared first: twice
    /// refused with the same words is a value that never changes, and the
    /// banner watches for a change.
    func changeLibrary(_ work: @escaping () async -> Void) {
        browser.refusal = nil
        Task {
            await work()
            await refreshIdentities()
        }
    }

    // MARK: Tabs

    func showLibrary() {
        activeTabID = nil
    }

    var activeTab: Tab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    func open(path: String, name: String) async {
        if let existing = tabs.first(where: { $0.path == path }) {
            activeTabID = existing.id
            return
        }
        switch await library.checkout(path) {
        case .alreadyOpen(let id):
            // The ledger holds it, so some tab does too; a double tap that
            // arrives mid-open lands here and focuses that tab.
            activeTabID = id
        case .opened(let notebook):
            let editor = EditorViewModel(notebook: notebook, palette: palette, theme: theme) { [weak self] target in
                self?.activate(target)
            }
            tabs.append(Tab(id: notebook.notebookID, path: path, name: name, editor: editor))
            activeTabID = notebook.notebookID
        case .failed(let error):
            banner = "Can't open \(name): \(error.description)"
        }
    }

    /// The ordinary close: the editor's final pass decides.
    func close(tabID: NotebookID) async {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        switch await tab.editor.close() {
        case .clean:
            await release(tab)
        case .dirty:
            // The tab stays open, because closing it would be the one way to
            // lose the pages that did not land.
            banner = "Couldn't save \(tab.name); retry, or discard the unsaved pages."
            discardableTabID = tabID
        }
    }

    /// The escape from a save that will not succeed: the checkout ends and
    /// the unsaved pages are abandoned on purpose.
    func discardAndClose(tabID: NotebookID) async {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        await release(tab)
        banner = nil
        discardableTabID = nil
    }

    private func release(_ tab: Tab) async {
        _ = await library.release(tab.path)
        tabs.removeAll { $0.id == tab.id }
        if activeTabID == tab.id { activeTabID = tabs.last?.id }
        if discardableTabID == tab.id { discardableTabID = nil }
    }

    func dismissBanner() {
        banner = nil
        discardableTabID = nil
    }

    // MARK: Links

    private func activate(_ target: LinkTarget) {
        switch target {
        case .internalPage(let page):
            scrollActiveEditor(to: page)
        case .externalPage(let notebookID, let page):
            guard identitiesReady else {
                banner = "Still loading your library."
                return
            }
            switch library.identities.resolve(notebookID) {
            case .live(let path):
                Task {
                    await self.open(path: path, name: LibraryStore.displayName(ofPath: path))
                    self.scrollActiveEditor(to: page)
                }
            case .trashed:
                banner = "That notebook is in the trash. Recover it to open the link."
            case .collided:
                banner = "That link points at two notebooks, so it can't open."
            case .missing:
                banner = "The linked page is no longer in your library."
            }
        }
    }

    private func scrollActiveEditor(to page: PageID) {
        guard let editor = activeTab?.editor else { return }
        guard let index = editor.notebook.pageIDs.firstIndex(of: page) else {
            banner = "The linked page is no longer in your library."
            return
        }
        editor.scroll(toPageIndex: index)
    }

    // MARK: The lease

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase != .active else { return }
        // Leaving the foreground cancels every touch. A tool use PencilKit did
        // not end, ends, so the tab is not wedged when it comes back.
        for tab in tabs { tab.editor.endToolUses() }
        // Before the guard: `.inactive` has usually started the flush, and
        // the pass it runs again must see the typed words. Not on
        // `.inactive`, which Control Center sends and often takes back.
        if phase == .background {
            for tab in tabs { tab.editor.commitTextEditing() }
        }
        guard leaseFlush == nil else {
            flushAgain = true
            return
        }
        leaseFlush = Task {
            repeat {
                self.flushAgain = false
                await self.flushUnderLease()
                if self.flushAgain { TNLog.event(.lifecycle, "lease flush ran again") }
            } while self.flushAgain
            self.leaseFlush = nil
        }
    }

    /// The lease outlives the write. Every open notebook runs one forced pass,
    /// active tab first, and the lease ends when no write is outstanding. An
    /// expired lease is only logged: the format is resumable, so the next open
    /// recovers whatever the pass did not finish.
    private func flushUnderLease() async {
        let editors = orderedEditors
        guard !editors.isEmpty else { return }
        let lease = Lease()
        lease.identifier = UIApplication.shared.beginBackgroundTask(withName: "TuberNotes save") {
            MainActor.assumeIsolated {
                TNLog.event(.lifecycle, "background lease expired with writes outstanding")
                lease.end()
            }
        }
        for editor in editors {
            await editor.flush()
        }
        lease.end()
    }

    /// Active tab first: the notebook the user was just writing in is the one
    /// whose pass has to fit inside the lease.
    private var orderedEditors: [EditorViewModel] {
        guard let active = activeTab else { return tabs.map(\.editor) }
        return [active.editor] + tabs.filter { $0.id != active.id }.map(\.editor)
    }
}

/// A background-execution lease that survives being ended twice: once by the
/// flush finishing, once by the system expiring it.
@MainActor private final class Lease {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
