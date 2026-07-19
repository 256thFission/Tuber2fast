import SwiftUI

/// Editor for one notebook: the zoomable page floating on a dark backdrop, a
/// frosted floating tool bar, a toggleable top page strip, a template menu, and
/// the frosted assistant sidebar (with lasso selection).
struct NotebookView: View {
    @StateObject private var vm: NotebookViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tuber.fingerDrawing") private var fingerDrawing = false
    @AppStorage("tuber.snapStraight") private var snapStraight = true

    @State private var showPages = false      // bottom long-press navigator
    @State private var showStrip = false       // top page strip
    @State private var showSidebar = false     // assistant
    @State private var showKeyPopup = false     // centered API-key entry

    init(notebook: Notebook, store: NotebookStore) {
        _vm = StateObject(wrappedValue: NotebookViewModel(notebook: notebook, store: store))
    }

    var body: some View {
        ZStack {
            EditorBackdrop()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if showStrip {
                        PageStripView(vm: vm)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    pageArea
                }

                if showSidebar {
                    AgentSidebarView(
                        vm: vm,
                        onClose: { withAnimation { showSidebar = false } },
                        onEditKey: { withAnimation { showKeyPopup = true } }
                    )
                    .transition(.move(edge: .trailing))
                }
            }

            VStack {
                Spacer()
                NotebookToolbar(
                    vm: vm,
                    onHome: { vm.persistNow(); dismiss() },
                    onShowPages: { withAnimation { showPages = true } }
                )
                .padding(.bottom, 16)
                .padding(.trailing, showSidebar ? 348 : 0)
            }

            if showPages {
                PageFlipOverlay(vm: vm) { withAnimation { showPages = false } }
                    .transition(.opacity)
            }

            if showKeyPopup {
                APIKeyPopup { withAnimation { showKeyPopup = false } }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10)
            }
        }
        .navigationTitle(vm.notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { vm.persistNow(); dismiss() } label: { Image(systemName: "chevron.left") }
                    .accessibilityIdentifier("notebook-back")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { withAnimation { showStrip.toggle() } } label: {
                    Image(systemName: showStrip ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2")
                }
                .accessibilityIdentifier("nav-page-strip")

                templateMenu

                Button { withAnimation { showSidebar.toggle() } } label: {
                    Image(systemName: showSidebar ? "sparkles.rectangle.stack.fill" : "sparkles")
                }
                .accessibilityIdentifier("nav-assistant")
            }
        }
        .onDisappear { vm.persistNow() }
    }

    private var templateMenu: some View {
        Menu {
            Picker("Template", selection: Binding(get: { vm.currentTemplate }, set: { vm.setTemplate($0) })) {
                ForEach(PageTemplate.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Toggle("Snap to straight line", isOn: $snapStraight)
            Toggle("Finger drawing", isOn: $fingerDrawing)
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .accessibilityIdentifier("nav-template")
    }

    private var pageArea: some View {
        NotebookCanvas(
            pageID: vm.currentPageID,
            drawingData: vm.currentPage.drawingData,
            tool: vm.tool,
            color: vm.inkUIColor,
            width: vm.activeWidth,
            template: vm.currentTemplate,
            zoomScale: vm.zoomScale,
            fingerDrawing: fingerDrawing,
            isLassoActive: vm.isLassoActive,
            lassoRect: vm.lassoRect,
            snapStraight: snapStraight,
            onChange: { vm.updateCurrentDrawing($0) },
            onLongPress: { withAnimation { showPages = true } },
            onZoomChanged: { vm.zoomScale = $0 },
            onLassoChanged: { vm.lassoRect = $0 }
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 74)
        .id(vm.currentPageID)
        .accessibilityIdentifier("notebook-page-area")
    }
}
