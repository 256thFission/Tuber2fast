import SwiftUI

/// Gallery page: a grid of locally-saved notebooks. Tap to open, `+` to create,
/// context-menu to rename or delete.
struct LibraryView: View {
    @ObservedObject var store: NotebookStore

    @State private var path: [UUID] = []
    @State private var showingNew = false
    @State private var newTitle = ""
    @State private var newCover: NotebookCover = .indigo
    @State private var newTemplate: PageTemplate = .linedMedium
    @State private var renaming: Notebook?
    @State private var renameText = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.notebooks.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("Notebooks")
            .navigationDestination(for: UUID.self) { id in
                if let notebook = store.notebook(id: id) {
                    NotebookView(notebook: notebook, store: store)
                } else {
                    ContentUnavailableViewCompat(title: "Notebook missing", systemImage: "book.closed")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNew = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("library-new-notebook")
                }
            }
            .sheet(isPresented: $showingNew) { newNotebookSheet }
            .alert("Rename notebook", isPresented: renameBinding) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let n = renaming {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.rename(n, to: trimmed.isEmpty ? n.title : trimmed)
                    }
                    renaming = nil
                }
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(store.notebooks) { notebook in
                    NavigationLink(value: notebook.id) {
                        NotebookCoverCard(notebook: notebook)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("notebook-card-\(notebook.id.uuidString)")
                    .contextMenu {
                        Button { beginRename(notebook) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) { store.delete(notebook) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No notebooks yet")
                .font(.title3.weight(.semibold))
            Text("Create your first notebook to start writing with Apple Pencil.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showingNew = true } label: {
                Label("New notebook", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: New notebook

    private var newNotebookSheet: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Untitled notebook", text: $newTitle)
                }
                Section("Cover") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 54))], spacing: 14) {
                        ForEach(NotebookCover.allCases) { cover in
                            Circle()
                                .fill(cover.gradient)
                                .frame(width: 44, height: 44)
                                .overlay {
                                    if cover == newCover {
                                        Image(systemName: "checkmark")
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                    }
                                }
                                .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 1))
                                .onTapGesture { newCover = cover }
                                .accessibilityIdentifier("cover-\(cover.rawValue)")
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Paper") {
                    Picker("Template", selection: $newTemplate) {
                        ForEach(PageTemplate.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            .navigationTitle("New notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { resetNewForm(); showingNew = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createNotebook() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func createNotebook() {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = store.createNotebook(
            title: trimmed.isEmpty ? "Untitled" : trimmed,
            cover: newCover,
            template: newTemplate
        )
        resetNewForm()
        showingNew = false
        path.append(notebook.id)
    }

    private func resetNewForm() {
        newTitle = ""
        newCover = .indigo
        newTemplate = .linedMedium
    }

    // MARK: Rename

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func beginRename(_ notebook: Notebook) {
        renaming = notebook
        renameText = notebook.title
    }
}

// MARK: - Cover card

struct NotebookCoverCard: View {
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                notebook.cover.gradient
                Rectangle()
                    .fill(.black.opacity(0.16))
                    .frame(width: 8)
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(14)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 5)

            Text(notebook.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("\(notebook.pages.count) page\(notebook.pages.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - iOS 16 fallback for ContentUnavailableView

struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
