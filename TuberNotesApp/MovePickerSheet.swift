import SwiftUI
import TuberStore

/// The Move destination picker, tonight's honest version (`03-review.md`
/// M-J): a drill-down sheet over folders — push into a folder to go deeper,
/// "Move Here" commits to the level on screen — where the observed picker
/// is an expandable tree (spec §6.3), a follow-up. Same semantics: folders
/// only, a New Folder affordance top-right, and the item being moved (with
/// everything under it) never offered as a destination.
struct MovePickerSheet: View {
    /// The items being moved — one from the chevron menu, several from
    /// select mode. Same picker, same exclusions, one commit.
    let items: [LibraryItem]
    /// The listing the move leaves: the move re-lists it, and when the
    /// store's collision suffix changed a name, its banner says so.
    let model: FolderListingModel

    @Environment(\.dismiss) private var dismiss

    init(item: LibraryItem, model: FolderListingModel) {
        self.items = [item]
        self.model = model
    }

    init(items: [LibraryItem], model: FolderListingModel) {
        self.items = items
        self.model = model
    }

    var body: some View {
        NavigationStack {
            MovePickerLevel(folderPath: "", items: items, model: model) { dismiss() }
                .navigationDestination(for: String.self) { folderPath in
                    MovePickerLevel(folderPath: folderPath, items: items, model: model) {
                        dismiss()
                    }
                }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("library.move.sheet")
    }

    /// Folders only, minus the moved item and everything under it: the
    /// destination the store refuses (`destinationInsideSource`) is never
    /// offered, and a document is never a destination.
    nonisolated static func destinationFolders(
        in items: [LibraryItem],
        excluding movedPath: String
    ) -> [LibraryItem] {
        destinationFolders(in: items, excludingAll: [movedPath])
    }

    /// The batch form: a level drops every folder that is any moved item or
    /// lives under one — offering the inside of any part of the move is the
    /// same refusal-in-waiting as offering the inside of the whole.
    nonisolated static func destinationFolders(
        in items: [LibraryItem],
        excludingAll movedPaths: [String]
    ) -> [LibraryItem] {
        items.filter { candidate in
            guard case .folder = candidate.kind else { return false }
            return movedPaths.allSatisfy { moved in
                candidate.id != moved && !candidate.id.hasPrefix(moved + "/")
            }
        }
    }
}

/// One level of the drill-down: the folders under `folderPath`, the Move
/// Here bar beneath, New Folder top-right.
private struct MovePickerLevel: View {
    let folderPath: String
    let items: [LibraryItem]
    let model: FolderListingModel
    /// Dismisses the whole sheet — `@Environment(\.dismiss)` here would pop
    /// the navigation stack instead, so the root owns the dismissal.
    let onFinished: () -> Void

    @State private var folders: [LibraryItem] = []
    @State private var refused: String?
    @State private var notice: String?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    private var title: String {
        folderPath.isEmpty
            ? "Documents"
            : folderPath.split(separator: "/").last.map(String.init) ?? folderPath
    }

    var body: some View {
        VStack(spacing: 0) {
            levelBody
            moveHereBar
        }
        .background(Color(white: 0.09))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folderPath.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onFinished() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newFolderName = ""
                    showingNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("New Folder")
            }
        }
        .task { await load() }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Untitled", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - The folder listing

    @ViewBuilder
    private var levelBody: some View {
        if let refused {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(refused)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if folders.isEmpty {
            VStack {
                Spacer()
                Text("No folders here")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(white: 0.55))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(folders) { folder in
                        row(folder)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(16)
            }
        }
    }

    private func row(_ folder: LibraryItem) -> some View {
        NavigationLink(value: folder.id) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(LibraryStyle.folderColor(decoration(of: folder)))
                Text(folder.name)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color(white: 0.15))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.move.folder.\(folder.name)")
    }

    private func decoration(of folder: LibraryItem) -> FolderDecoration {
        if case .folder(let decoration) = folder.kind { return decoration }
        return FolderDecoration()
    }

    // MARK: - Move Here

    private var moveHereBar: some View {
        VStack(spacing: 8) {
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
            Button {
                let listing = model
                let batch = items
                let destination = folderPath
                Task {
                    // One item keeps the single move's own banner wording;
                    // a batch collects its collisions batch-style.
                    if batch.count == 1, let only = batch.first {
                        await listing.move(only, toFolder: destination)
                        listing.exitSelection()
                    } else {
                        await listing.moveBatch(batch, toFolder: destination)
                    }
                    onFinished()
                }
            } label: {
                Text("Move Here")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.move.here")
        }
        .padding(16)
    }

    // MARK: - Loading and creation

    private func load() async {
        do {
            let listing = try await model.library.listFolder(folderPath)
            folders = MovePickerSheet.destinationFolders(
                in: listing.items, excludingAll: items.map(\.id)
            )
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            refused = nil
        } catch {
            refused = FolderListingModel.describe(error)
        }
    }

    private func createFolder() {
        // An empty field takes the placeholder, exactly as it reads — the
        // same promise the New Folder sheet makes.
        let chosen = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = chosen.isEmpty ? "Untitled" : chosen
        let destination = folderPath
        let library = model.library
        Task {
            do {
                _ = try await library.createFolder(
                    named: finalName,
                    in: destination,
                    decoration: FolderDecoration()
                )
            } catch {
                notice = FolderListingModel.describe(error)
            }
            await load()
        }
    }
}
