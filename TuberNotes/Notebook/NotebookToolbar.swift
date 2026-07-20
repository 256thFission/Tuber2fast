import SwiftUI
import UIKit

/// Floating control bar for page navigation, writing tools, agentic layers,
/// exports, page locking, and the page navigator.
struct NotebookToolbar: View {
    @ObservedObject var vm: NotebookViewModel
    @Binding var isPageLocked: Bool
    @Binding var isLassoActive: Bool
    @Binding var isRefinementActive: Bool
    @Environment(\.colorScheme) private var colorScheme
    var onHome: () -> Void
    var onShowPages: () -> Void
    var onExportPDF: () -> Void
    var onExportArchive: () -> Void
    var onAskAgent: () -> Void

    @State private var showColors = false
    @State private var showSize = false
    @State private var showLayers = false
    @State private var showSettings = false
    @State private var pressedTool: WritingTool?
    @State private var isLassoHeld = false
    @State private var pressStartWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                iconButton("house", label: "Back to notebooks", action: onHome)
                    .accessibilityIdentifier("toolbar-home")

                if vm.settings.showsPageNavigation {
                    divider

                    iconButton("chevron.left", label: "Previous page", enabled: vm.canGoBack) {
                        withAnimation(.easeInOut) { vm.goBack() }
                    }
                    .accessibilityIdentifier("toolbar-prev-page")

                    if vm.canGoForward {
                        iconButton("chevron.right", label: "Next page") {
                            withAnimation(.easeInOut) { vm.goForward() }
                        }
                        .accessibilityIdentifier("toolbar-next-page")
                    } else {
                        iconButton("plus", label: "Add page") {
                            withAnimation(.easeInOut) { vm.addPage() }
                        }
                        .accessibilityIdentifier("toolbar-add-page")
                    }
                }

                if vm.settings.showsWritingTools {
                    divider

                    ForEach(WritingTool.allCases) { tool in
                        toolButton(tool)
                    }
                    lassoButton
                    refinementButton

                    colorButton
                    if vm.tool.usesWidth { sizeButton }
                }

                if showsUtilityControls {
                    divider
                }

                if vm.settings.showsLayers {
                    agenticLayersButton
                }

                if vm.settings.showsExport {
                    exportMenu
                }

                if vm.settings.showsPageLock {
                    lockButton
                }

                settingsButton

                Button(action: onShowPages) {
                    Text(vm.pageLabel)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .accessibilityLabel("Show pages")
                .accessibilityValue(vm.pageLabel)
                .accessibilityIdentifier("toolbar-page-indicator")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .scrollDisabled(pressedTool != nil || isLassoHeld)
        .frame(maxWidth: 820)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .buttonStyle(TactileGlyphButtonStyle())
        .sensoryFeedback(.selection, trigger: vm.tool.rawValue)
        .sensoryFeedback(.selection, trigger: isLassoActive)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: isPageLocked)
        .accessibilityIdentifier("notebook-toolbar")
        .onChange(of: vm.settings.showsWritingTools) { _, isVisible in
            if !isVisible {
                isLassoActive = false
                isRefinementActive = false
            }
        }
        .onChange(of: vm.settings.showsLayers) { _, isVisible in
            if !isVisible {
                vm.isAgenticLayersActive = false
                showLayers = false
            }
        }
        .onChange(of: vm.isAgenticLayersActive) { _, isActive in
            if isActive { isRefinementActive = false }
        }
    }

    // MARK: Pieces

    private var divider: some View {
        Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 22)
    }

    private var showsUtilityControls: Bool {
        vm.settings.showsLayers || vm.settings.showsExport || vm.settings.showsPageLock
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(.primary)
        }
        .accessibilityIdentifier("toolbar-settings")
        .accessibilityLabel("Notebook toolbar settings")
        .popover(isPresented: $showSettings) {
            NotebookToolbarSettingsView(vm: vm)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var lockButton: some View {
        Button {
            isPageLocked.toggle()
        } label: {
            Image(systemName: isPageLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(isPageLocked ? Color.accentColor : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .speed(1.4), value: isPageLocked)
        }
        .accessibilityIdentifier("toolbar-page-lock")
        .accessibilityLabel(isPageLocked ? "Unlock page" : "Lock page")
        .accessibilityValue(isPageLocked ? "Locked" : "Unlocked")
    }

    private func toolButton(_ tool: WritingTool) -> some View {
        let selected = vm.tool == tool
            && !isLassoActive
            && !isRefinementActive
            && !vm.isAgenticLayersActive
        let fill: Color = tool == .eraser ? .secondary : vm.inkColor
        return Button {
            pressedTool = nil
            isLassoActive = false
            isRefinementActive = false
            vm.selectTool(tool)
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(selected ? selectedToolForeground(for: tool) : Color.primary)
                .background { if selected { Circle().fill(fill) } }
                .overlay {
                    if selected && tool != .eraser && selectedToolNeedsOutline {
                        Circle().strokeBorder(.primary.opacity(0.35), lineWidth: 1)
                    }
                }
                .symbolEffect(.bounce, options: .speed(1.55), value: selected)
                .animation(.spring(response: 0.22, dampingFraction: 0.62), value: selected)
        }
        .overlay(alignment: .bottom) {
            if pressedTool == tool {
                ToolWidthHoldIndicator(
                    tool: tool,
                    width: vm.width(for: tool),
                    color: fill
                )
                .offset(y: -48)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
            }
        }
        .simultaneousGesture(widthAdjustmentGesture(for: tool))
        .zIndex(pressedTool == tool ? 2 : 0)
        .accessibilityIdentifier("tool-\(tool.rawValue)")
        .accessibilityLabel(tool.label)
        .accessibilityValue("\(Int(vm.width(for: tool).rounded())) point width")
        .accessibilityHint("Long press, then slide left or right to adjust width")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var lassoButton: some View {
        Button {
            isLassoHeld = false
            isLassoActive = true
            isRefinementActive = false
            vm.isAgenticLayersActive = false
        } label: {
            Image(systemName: "lasso")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(isLassoActive ? Color.white : Color.primary)
                .background {
                    if isLassoActive {
                        Circle().fill(Color.accentColor)
                    }
                }
                .symbolEffect(.pulse, options: .speed(1.5), value: isLassoActive)
                .animation(.spring(response: 0.22, dampingFraction: 0.62), value: isLassoActive)
        }
        .overlay(alignment: .bottom) {
            if isLassoHeld {
                LassoHoldIndicator()
                    .offset(y: -48)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
            }
        }
        .simultaneousGesture(lassoHoldGesture)
        .zIndex(isLassoHeld ? 2 : 0)
        .accessibilityIdentifier("tool-lasso")
        .accessibilityLabel("Selection lasso")
        .accessibilityHint("Draw around strokes to select and move them")
        .accessibilityAddTraits(isLassoActive ? [.isSelected] : [])
    }

    private var lassoHoldGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 24)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, _) = value, !isLassoHeld else { return }
                isLassoActive = true
                isRefinementActive = false
                vm.isAgenticLayersActive = false
                withAnimation(.easeOut(duration: 0.12)) {
                    isLassoHeld = true
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    isLassoHeld = false
                }
            }
    }

    private var refinementButton: some View {
        Button {
            isLassoActive = false
            vm.isAgenticLayersActive = false
            isRefinementActive.toggle()
        } label: {
            Image(systemName: "lasso.badge.sparkles")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(isRefinementActive ? Color.white : Color.primary)
                .background {
                    if isRefinementActive {
                        Circle().fill(Color.indigo)
                    }
                }
                .symbolEffect(.pulse, options: .speed(1.4), value: isRefinementActive)
                .animation(.spring(response: 0.22, dampingFraction: 0.62), value: isRefinementActive)
        }
        .accessibilityIdentifier("tool-refinement-lasso")
        .accessibilityLabel("Drawing refinement")
        .accessibilityHint("Select a region to refine and apply directly to the page")
        .accessibilityAddTraits(isRefinementActive ? [.isSelected] : [])
    }

    private func widthAdjustmentGesture(for tool: WritingTool) -> some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 24)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .second(true, let drag?):
                    beginWidthAdjustment(for: tool)
                    let range = tool.widthRange
                    let delta = drag.translation.width / 140 * (range.upperBound - range.lowerBound)
                    vm.setWidth(pressStartWidth + delta, for: tool)
                default:
                    break
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    pressedTool = nil
                }
            }
    }

    private func beginWidthAdjustment(for tool: WritingTool) {
        guard pressedTool != tool else { return }
        isRefinementActive = false
        vm.selectTool(tool)
        pressStartWidth = vm.width(for: tool)
        withAnimation(.easeOut(duration: 0.12)) {
            pressedTool = tool
        }
    }

    private func selectedToolForeground(for tool: WritingTool) -> Color {
        guard tool != .eraser else { return .white }
        return vm.inkUIColor.isLight ? .black : .white
    }

    private var selectedToolNeedsOutline: Bool {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let toolbarBackground = UIColor.systemGroupedBackground.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
        return contrastRatio(vm.inkUIColor, toolbarBackground) < 1.4
    }

    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }

        func linearize(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(red)
            + 0.7152 * linearize(green)
            + 0.0722 * linearize(blue)
    }

    private var colorButton: some View {
        Button { showColors = true } label: {
            Circle()
                .fill(vm.inkColor)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
                .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1))
                .symbolEffect(.pulse, value: showColors)
        }
        .accessibilityIdentifier("toolbar-color")
        .accessibilityLabel("Ink color")
        .popover(isPresented: $showColors) {
            ColorPalettePopover(vm: vm)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var sizeButton: some View {
        Button { showSize = true } label: {
            Image(systemName: "lineweight")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(.primary)
                .symbolEffect(.bounce, options: .speed(1.4), value: showSize)
        }
        .accessibilityIdentifier("toolbar-size")
        .accessibilityLabel("Stroke size")
        .popover(isPresented: $showSize) {
            ToolSizePopover(vm: vm)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var agenticLayersButton: some View {
        let isHighlighted = showLayers || vm.isAgenticLayersActive
        return Button {
            showLayers.toggle()
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                .background {
                    if isHighlighted {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .indigo, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
                .symbolEffect(.bounce, options: .speed(1.35), value: showLayers)
                .animation(.spring(response: 0.24, dampingFraction: 0.65), value: showLayers)
        }
        .accessibilityIdentifier("toolbar-agentic-layers")
        .accessibilityLabel(showLayers ? "Close layers" : "Open layers")
        .accessibilityValue(vm.isAgenticLayersActive ? "Agentic layer active" : "Drawing layer active")
        .accessibilityAddTraits(vm.isAgenticLayersActive ? [.isSelected] : [])
        .popover(isPresented: $showLayers) {
            NotebookLayersPopover(vm: vm) {
                showLayers = false
                onAskAgent()
            }
                .presentationCompactAdaptation(.popover)
        }
    }

    private var exportMenu: some View {
        Menu {
            Button(action: onExportPDF) {
                Label("Export PDF", systemImage: "doc.richtext")
            }
            Button(action: onExportArchive) {
                Label("Export SPUD", systemImage: "archivebox")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(.primary)
        }
        .accessibilityIdentifier("toolbar-export")
        .accessibilityLabel("Export note")
    }

    private func iconButton(
        _ symbol: String,
        label: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.25))
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct NotebookLayersPopover: View {
    @ObservedObject var vm: NotebookViewModel
    let onAskAgent: () -> Void
    @State private var newLayerName = ""
    @State private var pendingLayerKind: NewLayerKind?

    private enum NewLayerKind {
        case agentic
        case drawing

        var title: String {
            switch self {
            case .agentic: "New Agentic Layer"
            case .drawing: "New Drawing Layer"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            layerSection(
                title: "Agentic layers",
                symbol: "sparkles",
                addLabel: "Add agentic layer",
                kind: .agentic
            ) {
                ForEach(vm.conversationLayers.layers) { layer in
                    agenticLayerChip(layer)
                }
            }

            Button {
                let layers = vm.conversationLayers.layers
                guard let layerID = layers.first(where: {
                    $0.id == vm.selectedLayerID && $0.isVisible
                })?.id ?? layers.first(where: \.isVisible)?.id
                else { return }
                vm.selectAgenticLayer(layerID)
                onAskAgent()
            } label: {
                Label("Ask on this layer", systemImage: "text.bubble.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(!vm.conversationLayers.layers.contains(where: \.isVisible))
            .accessibilityHint("Adds the answer as a Pin on the selected Agentic Layer")

            Divider()

            layerSection(
                title: "Drawing layers",
                symbol: "pencil.and.outline",
                addLabel: "Add drawing layer",
                kind: .drawing
            ) {
                ForEach(vm.currentPage.drawingLayers) { layer in
                    drawingLayerChip(layer)
                }
            }
        }
        .padding(18)
        .frame(width: 460)
        .alert(
            pendingLayerKind?.title ?? "New Layer",
            isPresented: Binding(
                get: { pendingLayerKind != nil },
                set: { if !$0 { pendingLayerKind = nil } }
            )
        ) {
            TextField("Layer name", text: $newLayerName)
            Button("Cancel", role: .cancel) { pendingLayerKind = nil }
            Button("Create") { createLayer() }
        }
        .accessibilityIdentifier("notebook-layers-popover")
    }

    private func layerSection<Content: View>(
        title: String,
        symbol: String,
        addLabel: String,
        kind: NewLayerKind,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                Button {
                    newLayerName = ""
                    pendingLayerKind = kind
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(addLabel)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    content()
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func agenticLayerChip(_ layer: ConversationLayer) -> some View {
        let selected = vm.isAgenticLayersActive && vm.selectedLayerID == layer.id
        return layerChip(
            name: layer.name,
            detail: "\(layer.conversations.count)",
            symbol: layer.symbolName,
            isSelected: selected,
            isVisible: layer.isVisible,
            select: { vm.selectAgenticLayer(layer.id) },
            toggleVisibility: { vm.toggleAgenticLayerVisibility(layer.id) }
        )
        .accessibilityIdentifier("agentic-layer-\(layer.id.uuidString)")
    }

    private func drawingLayerChip(_ layer: DrawingLayer) -> some View {
        let selected = !vm.isAgenticLayersActive && vm.currentDrawingLayerID == layer.id
        return layerChip(
            name: layer.name,
            detail: nil,
            symbol: "pencil.tip",
            isSelected: selected,
            isVisible: layer.isVisible,
            select: { vm.selectDrawingLayer(layer.id) },
            toggleVisibility: { vm.toggleDrawingLayerVisibility(layer.id) }
        )
        .accessibilityIdentifier("drawing-layer-\(layer.id.uuidString)")
    }

    private func layerChip(
        name: String,
        detail: String?,
        symbol: String,
        isSelected: Bool,
        isVisible: Bool,
        select: @escaping () -> Void,
        toggleVisibility: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 2) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                    Text(name).lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.white.opacity(isSelected ? 0.22 : 0.7), in: Capsule())
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.leading, 11)
                .padding(.vertical, 9)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .opacity(isVisible ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!isVisible)

            Button(action: toggleVisibility) {
                Image(systemName: isVisible ? "eye" : "eye.slash")
                    .font(.caption.weight(.semibold))
                    .frame(width: 32, height: 36)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible ? "Hide \(name)" : "Show \(name)")
        }
        .padding(.trailing, 4)
        .background(isSelected ? Color.indigo : Color.secondary.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func createLayer() {
        switch pendingLayerKind {
        case .agentic:
            vm.addAgenticLayer(named: newLayerName)
        case .drawing:
            vm.addDrawingLayer(named: newLayerName)
        case nil:
            return
        }
        pendingLayerKind = nil
    }
}

/// A short downstroke and spring-back makes the glass toolbar feel like a row
/// of physical controls while leaving every glyph's resting appearance intact.
private struct TactileGlyphButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.84 : 1)
            .offset(y: configuration.isPressed && !reduceMotion ? 1.5 : 0)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.58),
                value: configuration.isPressed
            )
    }
}

// MARK: - Color popover

private struct NotebookToolbarSettingsView: View {
    @ObservedObject var vm: NotebookViewModel

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 12), count: 6)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Notebook Toolbar")
                    .font(.headline)

                Group {
                    Toggle("Page navigation", isOn: $vm.settings.showsPageNavigation)
                        .accessibilityIdentifier("settings-page-navigation")
                    Toggle("Writing tools", isOn: $vm.settings.showsWritingTools)
                        .accessibilityIdentifier("settings-writing-tools")
                    Toggle("Layers", isOn: $vm.settings.showsLayers)
                        .accessibilityIdentifier("settings-agentic-layers")
                    Toggle("Export", isOn: $vm.settings.showsExport)
                        .accessibilityIdentifier("settings-export")
                    Toggle("Page lock", isOn: $vm.settings.showsPageLock)
                        .accessibilityIdentifier("settings-page-lock")
                }
                .font(.subheadline)

                Divider()

                Text("Favorite Colors")
                    .font(.headline)

                Text("Favorites appear first in the ink color picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(InkPalette.standard, id: \.self) { hex in
                        favoriteSwatch(hex)
                    }
                }

                Button {
                    vm.toggleFavoriteColor(vm.inkColorHex)
                } label: {
                    Label(
                        vm.isFavoriteColor(vm.inkColorHex) ? "Remove current color" : "Add current color",
                        systemImage: vm.isFavoriteColor(vm.inkColorHex) ? "heart.slash" : "heart"
                    )
                }
                .font(.subheadline)
            }
            .padding(20)
        }
        .frame(width: 340, height: 520)
        .accessibilityIdentifier("notebook-toolbar-settings")
    }

    private func favoriteSwatch(_ hex: String) -> some View {
        let color = UIColor(hex: hex) ?? .black
        let isFavorite = vm.isFavoriteColor(hex)

        return Button {
            vm.toggleFavoriteColor(hex)
        } label: {
            Circle()
                .fill(Color(color))
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1))
                .overlay {
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(color.isLight ? Color.black : Color.white)
                    }
                }
        }
        .accessibilityLabel("\(hex) favorite color")
        .accessibilityValue(isFavorite ? "Favorite" : "Not favorite")
    }
}

private struct ColorPalettePopover: View {
    @ObservedObject var vm: NotebookViewModel
    @State private var custom: Color = .black

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !vm.settings.favoriteColors.isEmpty {
                Text("Favorites").font(.subheadline.weight(.semibold))

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.settings.favoriteColors, id: \.self) { hex in
                        swatch(hex)
                    }
                }

                Divider()
            }

            Text("All Colors").font(.subheadline.weight(.semibold))

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(InkPalette.standard, id: \.self) { hex in
                    swatch(hex)
                }
            }

            Divider()

            ColorPicker("Custom color", selection: $custom, supportsOpacity: false)
                .font(.subheadline)
                .onChange(of: custom) { newValue in
                    vm.selectColor(UIColor(newValue).hexString)
                }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func swatch(_ hex: String) -> some View {
        let ui = UIColor(hex: hex) ?? .black
        let isSelected = vm.inkColorHex.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            vm.selectColor(hex)
        } label: {
            Circle()
                .fill(Color(ui))
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ui.isLight ? Color.black : Color.white)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                    }
                }
        }
        .accessibilityIdentifier("swatch-\(hex)")
        .accessibilityLabel("Ink color \(hex)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Size popover

private struct ToolSizePopover: View {
    @ObservedObject var vm: NotebookViewModel

    var body: some View {
        VStack(spacing: 14) {
            Text("\(vm.tool.label) size")
                .font(.subheadline.weight(.semibold))

            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.white)
                Capsule()
                    .fill((vm.tool == .eraser ? Color.secondary : vm.inkColor)
                        .opacity(vm.tool == .marker ? 0.4 : 1))
                    .frame(width: 170, height: max(2, min(vm.activeWidth, 44)))
            }
            .frame(width: 200, height: 52)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1)))

            Slider(
                value: Binding(get: { vm.activeWidth }, set: { vm.activeWidth = $0 }),
                in: vm.widthRange
            )

            Text(String(format: "%.0f pt", vm.activeWidth))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 232)
    }
}

private struct ToolWidthHoldIndicator: View {
    let tool: WritingTool
    let width: CGFloat
    let color: Color

    private var progress: CGFloat {
        let range = tool.widthRange
        return (width - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 7) {
            Text("\(tool.label) · \(Int(width.rounded())) pt")
                .font(.caption2.monospacedDigit().weight(.semibold))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.14))
                Capsule()
                    .fill(color.opacity(tool == .marker ? 0.55 : 1))
                    .frame(width: max(8, 140 * progress))
                Circle()
                    .fill(.background)
                    .overlay(Circle().strokeBorder(color, lineWidth: 2))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .frame(width: 18, height: 18)
                    .offset(x: 131 * progress)
            }
            .frame(width: 140, height: 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }
}

private struct LassoHoldIndicator: View {
    var body: some View {
        VStack(spacing: 4) {
            Label("Lasso", systemImage: "lasso")
                .font(.caption2.weight(.semibold))
            Text("Draw around strokes to select and move them")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }
}
