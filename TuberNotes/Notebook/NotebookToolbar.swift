import PhotosUI
import SwiftUI
import UIKit

/// Frosted floating menu bar (dark glass): home · page nav · tools · lasso ·
/// add/arrange image · color · size · zoom · add page · page indicator.
/// Selected tool is shown by a filled highlight (not by color), so the eraser
/// reads as selected too. Ink color shows as a small chip on the ink tools.
struct NotebookToolbar: View {
    @ObservedObject var vm: NotebookViewModel
    var onHome: () -> Void
    var onShowPages: () -> Void

    @State private var showColors = false
    @State private var showSize = false
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                iconButton("house", action: onHome)
                    .accessibilityIdentifier("toolbar-home")

                divider

                iconButton("chevron.left", enabled: vm.canGoBack) {
                    withAnimation(.easeInOut) { vm.goBack() }
                }
                .accessibilityIdentifier("toolbar-prev-page")
                iconButton("chevron.right", enabled: vm.canGoForward) {
                    withAnimation(.easeInOut) { vm.goForward() }
                }
                .accessibilityIdentifier("toolbar-next-page")

                divider

                ForEach(WritingTool.allCases) { toolButton($0) }
                lassoButton

                divider

                addImageButton
                if !vm.currentPage.images.isEmpty { arrangeButton }

                colorButton
                sizeButton

                divider

                iconButton("minus.magnifyingglass", enabled: vm.zoomScale > 0.5) { vm.zoomOut() }
                    .accessibilityIdentifier("toolbar-zoom-out")
                Button { vm.resetZoom() } label: {
                    Text(vm.zoomLabel)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 42)
                }
                .accessibilityIdentifier("toolbar-zoom-reset")
                iconButton("plus.magnifyingglass", enabled: vm.zoomScale < 5) { vm.zoomIn() }
                    .accessibilityIdentifier("toolbar-zoom-in")

                divider

                iconButton("plus.rectangle.on.rectangle") { vm.addPage() }
                    .accessibilityIdentifier("toolbar-add-page")

                Button(action: onShowPages) {
                    Text(vm.pageLabel)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .accessibilityIdentifier("toolbar-page-indicator")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: 820)
        .glassCapsule()
        .environment(\.colorScheme, .dark)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    let aspect = ui.size.width / max(ui.size.height, 1)
                    vm.addImage(data: data, aspect: aspect)
                }
                pickerItem = nil
            }
        }
        .accessibilityIdentifier("notebook-toolbar")
    }

    // MARK: Pieces

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 22)
    }

    /// Selection = filled highlight behind the glyph. Ink color = tiny corner chip.
    private func toolButton(_ tool: WritingTool) -> some View {
        let selected = vm.tool == tool && !vm.isLassoActive && !vm.isArrangingImages
        return Button { vm.selectTool(tool) } label: {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 34, height: 34)
                }
                Image(systemName: tool.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                if tool.usesColor {
                    Circle()
                        .fill(vm.inkColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 0.75))
                        .offset(x: 11, y: 11)
                }
            }
            .frame(width: 34, height: 34)
        }
        .accessibilityIdentifier("tool-\(tool.rawValue)")
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func modeButton(_ symbol: String, selected: Bool, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 34, height: 34)
                }
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
            }
            .frame(width: 34, height: 34)
        }
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var lassoButton: some View {
        modeButton("lasso", selected: vm.isLassoActive, id: "tool-lasso", label: "Lasso select for assistant") {
            vm.toggleLasso()
        }
    }

    private var addImageButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
        }
        .accessibilityIdentifier("toolbar-add-image")
        .accessibilityLabel("Add image")
    }

    private var arrangeButton: some View {
        modeButton("arrow.up.and.down.and.arrow.left.and.right",
                   selected: vm.isArrangingImages, id: "toolbar-arrange-images", label: "Arrange images") {
            withAnimation { vm.toggleArrangeImages() }
        }
    }

    private var colorButton: some View {
        Button { showColors = true } label: {
            Circle()
                .fill(vm.inkColor)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
                .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 1))
        }
        .accessibilityIdentifier("toolbar-color")
        .accessibilityLabel("Ink color")
        .popover(isPresented: $showColors) {
            ColorPalettePopover(vm: vm)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    private var sizeButton: some View {
        Button { showSize = true } label: {
            Image(systemName: "lineweight")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(.primary)
        }
        .accessibilityIdentifier("toolbar-size")
        .accessibilityLabel("Stroke size")
        .popover(isPresented: $showSize) {
            ToolSizePopover(vm: vm)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    private func iconButton(_ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.28))
        }
        .disabled(!enabled)
    }
}

// MARK: - Color popover

private struct ColorPalettePopover: View {
    @ObservedObject var vm: NotebookViewModel
    @State private var custom: Color = .black
    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Colors").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(InkPalette.standard, id: \.self) { swatch($0) }
            }
            Divider()
            ColorPicker("Custom color", selection: $custom, supportsOpacity: false)
                .font(.subheadline)
                .onChange(of: custom) { _, newValue in
                    vm.selectColor(UIColor(newValue).hexString)
                }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func swatch(_ hex: String) -> some View {
        let ui = UIColor(hex: hex) ?? .label
        let isSelected = vm.inkColorHex.caseInsensitiveCompare(hex) == .orderedSame
        return Button { vm.selectColor(hex) } label: {
            Circle()
                .fill(Color(ui))
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                    }
                }
        }
        .accessibilityIdentifier("swatch-\(hex)")
    }
}

// MARK: - Size popover (all tools, including eraser)

private struct ToolSizePopover: View {
    @ObservedObject var vm: NotebookViewModel

    var body: some View {
        VStack(spacing: 14) {
            Text("\(vm.tool.label) size").font(.subheadline.weight(.semibold))

            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.9))
                Capsule()
                    .fill(previewColor)
                    .frame(width: 170, height: max(2, min(vm.activeWidth, 44)))
            }
            .frame(width: 200, height: 52)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)))

            Slider(value: Binding(get: { vm.activeWidth }, set: { vm.activeWidth = $0 }), in: vm.widthRange)

            Text(String(format: "%.0f pt", vm.activeWidth))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 232)
    }

    private var previewColor: Color {
        switch vm.tool {
        case .eraser: return Color(uiColor: .systemGray3)
        case .marker: return vm.inkColor.opacity(0.4)
        default:      return vm.inkColor
        }
    }
}
