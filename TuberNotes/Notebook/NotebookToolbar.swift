import SwiftUI
import UIKit

/// Frosted floating menu bar (dark glass): home · page back/forward · tools ·
/// lasso · color · size · zoom · add page · page indicator. Scrolls horizontally
/// if it can't fit.
struct NotebookToolbar: View {
    @ObservedObject var vm: NotebookViewModel
    var onHome: () -> Void
    var onShowPages: () -> Void

    @State private var showColors = false
    @State private var showSize = false

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
        .frame(maxWidth: 780)
        .glassCapsule()
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("notebook-toolbar")
    }

    // MARK: Pieces

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 22)
    }

    private func toolButton(_ tool: WritingTool) -> some View {
        let selected = vm.tool == tool && !vm.isLassoActive
        let fill: Color = tool == .eraser ? .secondary : vm.inkColor
        return Button { vm.selectTool(tool) } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background { if selected { Circle().fill(fill) } }
        }
        .accessibilityIdentifier("tool-\(tool.rawValue)")
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var lassoButton: some View {
        let selected = vm.isLassoActive
        return Button { vm.toggleLasso() } label: {
            Image(systemName: "lasso")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background { if selected { Circle().fill(Color.accentColor) } }
        }
        .accessibilityIdentifier("tool-lasso")
        .accessibilityLabel("Lasso select for assistant")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
