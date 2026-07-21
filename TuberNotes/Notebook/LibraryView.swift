import SwiftUI
import UniformTypeIdentifiers

/// Gallery page: a grid of locally-saved notebooks. Tap to open, `+` to create,
/// import SPUD from Files, or use the context menu to rename and delete.
struct LibraryView: View {
    @ObservedObject var store: NotebookStore

    @AppStorage(GestureWelcomeLightbox.dismissedStorageKey)
    private var didDismissGestureWelcome = false
    @State private var path: [LibraryRoute] = []
    @State private var showingNew = false
    @State private var newTitle = ""
    @State private var newCover: NotebookCover = .indigo
    @State private var newTemplate: PageTemplate = .linedMedium
    @State private var renaming: Notebook?
    @State private var renameText = ""
    @State private var pendingDeletion: Notebook?
    @State private var openingNotebookID: UUID?
    @State private var isImportingSPUD = false
    @State private var isImportingPDF = false
    @State private var importError: String?
    @State private var pdfImportError: String?
    @State private var showGestureWelcome = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .navigationDestination(for: LibraryRoute.self) { route in
                destination(for: route)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showGestureWelcome = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Gesture guide")
                    .accessibilityIdentifier("library-gesture-guide")

                    Button { isImportingSPUD = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import SPUD")
                    .accessibilityIdentifier("library-import-spud")

                    Button { isImportingPDF = true } label: {
                        Image(systemName: "doc.badge.plus")
                    }
                    .accessibilityLabel("Import PDF")
                    .accessibilityIdentifier("library-import-pdf")

                    Button { showingNew = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New notebook")
                    .accessibilityIdentifier("library-new-notebook")
                }
            }
            .sheet(isPresented: $showingNew) { newNotebookSheet }
            .fileImporter(
                isPresented: $isImportingSPUD,
                allowedContentTypes: [.tuberNoteArchive],
                allowsMultipleSelection: false,
                onCompletion: importSPUD
            )
            .fileImporter(
                isPresented: $isImportingPDF,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false,
                onCompletion: importPDF
            )
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
            .alert("Couldn’t Import SPUD", isPresented: importErrorBinding) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "The selected file is not a valid SPUD notebook.")
            }
            .alert("Couldn’t Import PDF", isPresented: pdfImportErrorBinding) {
                Button("OK", role: .cancel) { pdfImportError = nil }
            } message: {
                Text(pdfImportError ?? "The selected PDF could not be read.")
            }
            .confirmationDialog(
                "Delete \(pendingDeletion?.title ?? "notebook")?",
                isPresented: deletionBinding,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let notebook = pendingDeletion {
                        store.delete(notebook)
                    }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This notebook and all of its pages will be permanently deleted.")
            }
        }
        .allowsHitTesting(!showGestureWelcome)
        .accessibilityHidden(showGestureWelcome)
        .overlay {
            if showGestureWelcome {
                GestureWelcomeLightbox(onDismiss: dismissGestureWelcome)
                    .transition(.opacity)
            }
        }
        .onAppear {
            if !didDismissGestureWelcome {
                showGestureWelcome = true
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(store.notebooks) { notebook in
                    Button {
                        open(notebook)
                    } label: {
                        NotebookCoverCard(
                            notebook: notebook,
                            isOpening: openingNotebookID == notebook.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(openingNotebookID != nil)
                    .accessibilityIdentifier("notebook-card-\(notebook.id.uuidString)")
                    .contextMenu {
                        Button { beginRename(notebook) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) { pendingDeletion = notebook } label: {
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
                            Button {
                                newCover = cover
                            } label: {
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
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(cover.displayName) cover")
                            .accessibilityAddTraits(cover == newCover ? .isSelected : [])
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
        path.append(.notebook(notebook.id))
    }

    private func resetNewForm() {
        newTitle = ""
        newCover = .indigo
        newTemplate = .linedMedium
    }

    private func dismissGestureWelcome() {
        didDismissGestureWelcome = true
        showGestureWelcome = false
    }

    // MARK: Rename

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    private var pdfImportErrorBinding: Binding<Bool> {
        Binding(get: { pdfImportError != nil }, set: { if !$0 { pdfImportError = nil } })
    }

    private func importSPUD(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let notebook = try store.importSPUD(from: sourceURL)
            path.append(.notebook(notebook.id))
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importPDF(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let notebook = try store.importPDF(from: sourceURL)
            path.append(.notebook(notebook.id))
        } catch {
            pdfImportError = error.localizedDescription
        }
    }

    private func beginRename(_ notebook: Notebook) {
        renaming = notebook
        renameText = notebook.title
    }

    private func open(_ notebook: Notebook) {
        guard openingNotebookID == nil else { return }
        if reduceMotion {
            path.append(.notebook(notebook.id))
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
            openingNotebookID = notebook.id
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard openingNotebookID == notebook.id else { return }
            path.append(.notebook(notebook.id))
            openingNotebookID = nil
        }
    }

    @ViewBuilder
    private func destination(for route: LibraryRoute) -> some View {
        switch route {
        case .notebook(let id):
            if let notebook = store.notebook(id: id) {
                NotebookView(
                    notebook: notebook,
                    store: store,
                    onAgentNavigationRequest: { request in
                        open(request, from: notebook.id)
                    }
                )
            } else {
                ContentUnavailableViewCompat(title: "Notebook missing", systemImage: "book.closed")
            }
        case .agentNavigation(let request):
            if case let .openNotebook(notebookID, pageIndex) = request,
               let notebook = store.notebook(id: notebookID),
               notebook.pages.indices.contains(pageIndex) {
                NotebookView(
                    notebook: notebook,
                    store: store,
                    initialPageIndex: pageIndex,
                    onReturnFromAgentNavigation: returnFromAgentNavigation
                )
            } else {
                ContentUnavailableViewCompat(title: "Notebook missing", systemImage: "book.closed")
            }
        }
    }

    private func open(_ request: AgentNavigationRequest, from originatingNotebookID: UUID) {
        guard case let .openNotebook(notebookID, pageIndex) = request,
              notebookID != originatingNotebookID,
              let notebook = store.notebook(id: notebookID),
              notebook.pages.indices.contains(pageIndex)
        else { return }

        path.append(.agentNavigation(request))
    }

    private func returnFromAgentNavigation() {
        guard case .agentNavigation = path.last else { return }
        path.removeLast()
    }
}

private enum LibraryRoute: Hashable {
    case notebook(UUID)
    case agentNavigation(AgentNavigationRequest)
}

// MARK: - Cover card

struct NotebookCoverCard: View {
    let notebook: Notebook
    var isOpening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                notebook.cover.gradient
                Rectangle()
                    .fill(.black.opacity(0.16))
                    .frame(width: 8)
                Image(systemName: isOpening ? "book.fill" : "book.closed.fill")
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(14)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, options: .speed(1.35), value: isOpening)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 5)
            .rotation3DEffect(
                .degrees(isOpening ? -7 : 0),
                axis: (x: 0, y: 1, z: 0),
                anchor: .leading,
                perspective: 0.7
            )
            .scaleEffect(isOpening ? 1.035 : 1)
            .shadow(color: .black.opacity(isOpening ? 0.25 : 0), radius: 14, x: 8, y: 7)

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
