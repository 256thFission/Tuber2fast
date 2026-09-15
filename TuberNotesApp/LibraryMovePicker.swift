import SwiftUI
import TNLibrary

/// Where a move lands: the folder tree, one level at a time, with "Move
/// here" confirming whichever level is showing. The root is a destination
/// like any other.
struct LibraryMovePicker: View {
    let browser: LibraryBrowser
    let paths: Set<String>
    let confirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stack: [String] = []

    var body: some View {
        NavigationStack(path: $stack) {
            level("")
                .navigationDestination(for: String.self) { level($0) }
        }
    }

    private func level(_ folder: String) -> some View {
        LibraryMoveLevel(browser: browser, paths: paths, folder: folder) { destination in
            confirm(destination)
            dismiss()
        } cancel: {
            dismiss()
        }
    }
}

private struct LibraryMoveLevel: View {
    let browser: LibraryBrowser
    let paths: Set<String>
    let folder: String
    let confirm: (String) -> Void
    let cancel: () -> Void

    @State private var folders: [LibraryItem] = []

    var body: some View {
        List(folders) { item in
            NavigationLink(value: item.relativePath) {
                Label(item.name, systemImage: "folder.fill")
                    .font(Macaron.display(15))
            }
            .listRowBackground(Color.clear)
        }
        .macaronSheet()
        .overlay {
            if folders.isEmpty {
                ContentUnavailableView("No folders here", systemImage: "folder")
            }
        }
        .navigationTitle(folder.isEmpty ? "Documents" : Workspace.displayName(ofPath: folder))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { cancel() }
                    .buttonStyle(MacaronWordChipStyle())
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(folder.isEmpty ? "Move to Documents" : "Move here") { confirm(folder) }
                    .buttonStyle(MacaronWordChipStyle(isOn: true))
            }
        }
        .task(id: folder) {
            folders = await browser.destinations(in: folder, excluding: paths)
        }
    }
}
