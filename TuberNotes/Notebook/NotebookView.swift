import SwiftUI

/// Editor for one notebook: the zoomable page on a dark backdrop, a frosted
/// floating tool bar, a toggleable top page strip, a template menu, and the
/// frosted assistant sidebar (with lasso selection) that floats over the page.
struct NotebookView: View {
    @StateObject private var vm: NotebookViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tuber.fingerDrawing") private var fingerDrawing = false
    @AppStorage("tuber.snapStraight") private var snapStraight = true

    @State private var showPages = false
    @State private var showStrip = false
    @State private var showSidebar = false
    @State private var showKeyPopup = false

    init(notebook: Notebook, store: NotebookStore) {
        _vm = StateObject(wrappedValue: NotebookViewModel(notebook: notebook, store: store))
    }

    var body: some View {
        ZStack {
            EditorBackdrop()

            VStack(spacing: 0) {
                if showStrip {
                    PageStripView(vm: vm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                pageArea
            }

            // Assistant floats OVER the page (doesn't shrink it).
            if showSidebar {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    AgentSidebarView(
                        vm: vm,
                        onClose: { withAnimation { showSidebar = false } },
                        onEditKey: { withAnimation { showKeyPopup = true } }
                    )
                }
                .transition(.move(edge: .trailing))
                .zIndex(5)
            }

            if vm.isArrangingImages {
                arrangeControls.zIndex(6)
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
            .zIndex(7)

            if showPages {
                PageFlipOverlay(vm: vm) { withAnimation { showPages = false } }
                    .transition(.opacity)
                    .zIndex(8)
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

    private var arrangeControls: some View {
        VStack {
            HStack(spacing: 10) {
                Label("Move & pinch to resize", systemImage: "hand.draw")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                Divider().frame(height: 18).overlay(.white.opacity(0.3))
                Button(role: .destructive) { vm.deleteSelectedImage() } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(vm.selectedImageID == nil)
                Button("Done") { withAnimation { vm.finishArrangingImages() } }
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassCapsule()
            .environment(\.colorScheme, .dark)
            .padding(.top, 12)
            Spacer()
        }
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
            images: vm.currentPage.images,
            isArrangingImages: vm.isArrangingImages,
            selectedImageID: vm.selectedImageID,
            onChange: { vm.updateCurrentDrawing($0) },
            onLongPress: { withAnimation { showPages = true } },
            onZoomChanged: { vm.zoomScale = $0 },
            onLassoChanged: { vm.lassoRect = $0 },
            onImagesChanged: { vm.updateImages($0) },
            onSelectImage: { vm.selectImage($0) }
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 74)
        .id(vm.currentPageID)
        .accessibilityIdentifier("notebook-page-area")
    }
}
