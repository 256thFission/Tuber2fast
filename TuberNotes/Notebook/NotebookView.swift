import SwiftUI

/// The editor for a single notebook: paper + PencilKit canvas for the current
/// page, the floating menu bar, and the long-press page navigator.
struct NotebookView: View {
    @StateObject private var vm: NotebookViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPages = false

    init(notebook: Notebook, store: NotebookStore) {
        _vm = StateObject(wrappedValue: NotebookViewModel(notebook: notebook, store: store))
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            pageArea

            VStack {
                Spacer()
                NotebookToolbar(
                    vm: vm,
                    onHome: { vm.persistNow(); dismiss() },
                    onShowPages: { withAnimation { showPages = true } }
                )
                .padding(.bottom, 14)
            }

            if showPages {
                PageFlipOverlay(vm: vm) { withAnimation { showPages = false } }
                    .transition(.opacity)
            }
        }
        .navigationTitle(vm.notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { vm.persistNow(); dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityIdentifier("notebook-back")
            }
        }
        .onDisappear { vm.persistNow() }
    }

    private var pageArea: some View {
        ZStack {
            PaperBackground()
            NotebookCanvas(
                pageID: vm.currentPageID,
                drawingData: vm.currentPage.drawingData,
                tool: vm.tool,
                inkColor: vm.inkColor,
                strokeWidth: vm.strokeWidth,
                onChange: { vm.updateCurrentDrawing($0) },
                onLongPress: { withAnimation { showPages = true } }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.black.opacity(0.08), lineWidth: 1))
        .padding(20)
        .padding(.bottom, 74) // room for the floating toolbar
        // Changing identity per page gives a clean canvas + a page-turn transition.
        .id(vm.currentPageID)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        ))
        .accessibilityIdentifier("notebook-page-area")
    }
}

/// White ruled paper. Kept white in both appearances so ink stays legible.
struct PaperBackground: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var lines = Path()
            stride(from: 36.0, through: size.height, by: 36.0).forEach { y in
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(.blue.opacity(0.12)), lineWidth: 1)
        }
    }
}
