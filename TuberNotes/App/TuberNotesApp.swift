import SwiftUI

@main
struct TuberNotesApp: App {
    @StateObject private var notebookStore = NotebookStore.shared

    var body: some Scene {
        WindowGroup {
            rootContent
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        LibraryView(store: notebookStore)
    }
}
