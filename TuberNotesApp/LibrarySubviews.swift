import SwiftUI
import TNLibrary

/// Where you are and one step back. The path is the truth; the crumbs are a
/// rendering of it.
struct LibraryPathBar: View {
    let folder: String
    let navigate: (String) -> Void

    private var components: [(name: String, path: String)] {
        var path = ""
        return folder.split(separator: "/").map { component in
            path = path.isEmpty ? String(component) : "\(path)/\(component)"
            return (String(component), path)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                navigate(parentPath)
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .disabled(folder.isEmpty)

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    crumb("Library", path: "")
                    ForEach(components, id: \.path) { component in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        crumb(component.name, path: component.path)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var parentPath: String {
        guard let slash = folder.lastIndex(of: "/") else { return "" }
        return String(folder[..<slash])
    }

    @ViewBuilder private func crumb(_ name: String, path: String) -> some View {
        Button(name) { navigate(path) }
            .font(.subheadline)
            .foregroundStyle(path == folder ? Color.primary : Color.accentColor)
            .disabled(path == folder)
            .lineLimit(1)
    }
}

/// A folder or a notebook: a symbol, a name, when it changed, and whether it
/// is checked out. Thumbnails are not drawn yet.
struct LibraryItemCell: View {
    let item: LibraryItem
    let isLocked: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.12))
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: item.kind == .folder ? "folder.fill" : "book.closed.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: .circle)
                        .padding(6)
                        .accessibilityLabel("Open")
                }
            }
            Text(item.name)
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}

/// What the trash holds, and the two things you can do with an entry.
struct TrashSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [TrashEntry] = []

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("Trash is empty", systemImage: "trash")
                } else {
                    List(entries) { entry in
                        HStack {
                            Image(systemName: entry.kind == .folder ? "folder" : "book.closed")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(entry.name)
                                Text("Deleted \(entry.origin.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Recover") { Task { await recover(entry) } }
                                .buttonStyle(.bordered)
                            Button("Delete", role: .destructive) { Task { await delete(entry) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        do {
            entries = try await workspace.library.store.listTrash()
        } catch {
            workspace.banner = "\(error)"
        }
    }

    private func recover(_ entry: TrashEntry) async {
        do {
            _ = try await workspace.library.store.recover(entry)
            await reload()
            await workspace.refreshIdentities()
        } catch {
            workspace.banner = "\(error)"
        }
    }

    private func delete(_ entry: TrashEntry) async {
        do {
            try await workspace.library.store.deletePermanently(entry)
            await reload()
            await workspace.refreshIdentities()
        } catch {
            workspace.banner = "\(error)"
        }
    }
}
