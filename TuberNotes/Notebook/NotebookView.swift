import SwiftUI

/// Editor for a single notebook: a GoodNotes-style vertical page (paper is drawn
/// inside the scrolling canvas), the floating menu bar, and the page navigator.
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
        NotebookCanvas(
            pageID: vm.currentPageID,
            drawingData: vm.currentPage.drawingData,
            tool: vm.tool,
            color: vm.inkUIColor,
            width: vm.activeWidth,
            onChange: { vm.updateCurrentDrawing($0) },
            onLongPress: { withAnimation { showPages = true } }
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 74) // room for the floating toolbar
        // New identity per page → clean canvas + page-turn transition.
        .id(vm.currentPageID)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        ))
        .accessibilityIdentifier("notebook-page-area")
    }
}
