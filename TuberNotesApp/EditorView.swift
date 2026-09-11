import PhotosUI
import SwiftUI
import TNEditor
import TNFormat
import TNModel
import TNNotebook
import UIKit
import UniformTypeIdentifiers

/// One open notebook: the intentions across the top, the canvas below, and
/// the save refusal in between. Nothing here reads the notebook; the view
/// model is the only thing that does.
struct EditorView: View {
    @Environment(Workspace.self) private var workspace
    let editor: EditorViewModel

    @State private var isPickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isPickingPDF = false
    @State private var isConfirmingPageDelete = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let failure = editor.lastSaveError {
                RefusalBar(message: Self.message(for: failure))
            } else if let fault = editor.lastContentError {
                // An import or a layer that the page refused: without this it
                // would be a tap that quietly did nothing.
                RefusalBar(message: "That couldn't be added: \(fault.description)")
            }
            CanvasHost(controller: editor.canvasHost)
        }
        .photosPicker(isPresented: $isPickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .fileImporter(isPresented: $isPickingPDF, allowedContentTypes: [.pdf]) { result in
            Task { await importPDF(result) }
        }
        .confirmationDialog(
            "Delete this page?",
            isPresented: $isConfirmingPageDelete,
            titleVisibility: .visible
        ) {
            Button("Delete page", role: .destructive) { editor.deleteCurrentPage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The page and everything on it are removed.")
        }
    }

    // MARK: The toolbar

    private var toolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ToolStrip(editor: editor)
                Divider().frame(height: 22)
                history
                Divider().frame(height: 22)
                pages
                Divider().frame(height: 22)
                paperMenu
                insertMenu
                Button(role: .destructive) {
                    isConfirmingPageDelete = true
                } label: {
                    Label("Delete page", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private var history: some View {
        HStack(spacing: 8) {
            Button { editor.undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly)
            }
            .disabled(!editor.canUndo)

            Button { editor.redo() } label: {
                Label("Redo", systemImage: "arrow.uturn.forward").labelStyle(.iconOnly)
            }
            .disabled(!editor.canRedo)
        }
    }

    private var pages: some View {
        HStack(spacing: 8) {
            Button {
                editor.scroll(toPageIndex: editor.currentPageIndex - 1)
            } label: {
                Label("Previous page", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled(editor.currentPageIndex <= 0)

            Text("Page \(editor.currentPageIndex + 1) of \(editor.pageCount)")
                .font(.callout.monospacedDigit())
                .fixedSize()

            Button {
                editor.scroll(toPageIndex: editor.currentPageIndex + 1)
            } label: {
                Label("Next page", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .disabled(editor.currentPageIndex >= editor.pageCount - 1)

            Button { editor.addPage() } label: {
                Label("Add page", systemImage: "plus.rectangle.portrait").labelStyle(.iconOnly)
            }
        }
    }

    private var paperMenu: some View {
        Menu {
            ForEach(DrawnPaper.allCases, id: \.self) { paper in
                Button {
                    Task { await editor.setPaper(paper) }
                } label: {
                    if editor.currentPaper == .drawn(paper) {
                        Label(Self.paperName(paper), systemImage: "checkmark")
                    } else {
                        Text(Self.paperName(paper))
                    }
                }
            }
        } label: {
            Label("Paper", systemImage: "square.grid.2x2")
        }
        // A page whose paper this build does not know is a placeholder.
        .disabled(editor.currentPaper == nil)
    }

    private var insertMenu: some View {
        Menu {
            Button {
                isPickingPhoto = true
            } label: {
                Label("Photo", systemImage: "photo")
            }
            Button {
                isPickingPDF = true
            } label: {
                Label("PDF", systemImage: "doc")
            }
        } label: {
            Label("Insert", systemImage: "plus.circle")
        }
    }

    private static func paperName(_ paper: DrawnPaper) -> String {
        switch paper {
        case .none: "None"
        case .blank: "Blank"
        case .lined: "Lined"
        case .grid: "Grid"
        case .dotted: "Dotted"
        }
    }

    // MARK: Imports

    private func importPhoto(_ item: PhotosPickerItem) async {
        photoItem = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                workspace.banner = "That photo couldn't be read."
                return
            }
            await editor.importImage(data)
        } catch {
            workspace.banner = "That photo couldn't be read: \(error.localizedDescription)"
        }
    }

    private func importPDF(_ result: Result<URL, any Error>) async {
        switch result {
        case .success(let url):
            do {
                await editor.importPDF(try ImportReader.read(url: url))
            } catch {
                workspace.banner = "That PDF couldn't be read: \(error.localizedDescription)"
            }
        case .failure(let error):
            workspace.banner = "That PDF couldn't be read: \(error.localizedDescription)"
        }
    }
}

/// The canvas runtime's own view controller, handed to SwiftUI and never
/// reconfigured by it: the app cannot name `TNCanvas`, and a SwiftUI update
/// has no business inside a frame path.
struct CanvasHost: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController { controller }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// A save that did not fully land, or content the page refused, in the words
/// Part 7 gives each reason.
private struct RefusalBar: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.red)
    }
}

extension EditorView {
    fileprivate static func message(for failure: SaveFailure) -> String {
        switch failure {
        case .insufficientSpace:
            "Not enough space to save. Your pages are still here; free some space and they'll save."
        case .io(let fault):
            "Couldn't save: \(fault.description). Retrying."
        case .pagesRefused(let pages):
            "\(pages.count) page\(pages.count == 1 ? "" : "s") couldn't be saved. Retrying."
        case .indexWithheld:
            "Saving isn't finished yet. Retrying."
        }
    }
}
