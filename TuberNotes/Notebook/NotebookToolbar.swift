import PhotosUI
import SwiftUI
import UIKit

enum NotebookToolbarDock: String, CaseIterable {
    case top
    case bottom
    case leading
    case trailing

    var isVertical: Bool { self == .leading || self == .trailing }

    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

/// Floating control bar for page navigation, writing tools, agentic layers,
/// and the page navigator. Page-level utilities live in the top navigation bar.
struct NotebookToolbar: View {
    @ObservedObject var vm: NotebookViewModel
    @ObservedObject var undo: NotebookUndoBridge
    @Binding var isLassoActive: Bool
    @Binding var isRefinementActive: Bool
    @Binding var isRefinementLassoActive: Bool
    @Binding var imagePickerItem: PhotosPickerItem?
    let dock: NotebookToolbarDock
    var onDockDragChanged: (CGSize) -> Void
    var onDockDragEnded: (DragGesture.Value) -> Void
    var onAskAgent: () -> Void
    var onRefinementChatModeChanged: (Bool) -> Void = { _ in }

    @State private var showColors = false
    @State private var showLayers = false
    @State private var pressedTool: WritingTool?
    @State private var isLassoHeld = false
    @State private var isColorScrubbing = false
    @State private var pressStartWidth: CGFloat = 0
    @State private var colorScrubStartIndex = 0
    @State private var lastLassoToggle: Date?

    var body: some View {
        Group {
            if hasVisibleControls {
                adaptiveToolbar
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
                    .overlayPreferenceValue(RefinementButtonBoundsPreferenceKey.self) { anchor in
                        GeometryReader { proxy in
                            if isRefinementActive, let anchor {
                                let buttonFrame = proxy[anchor]
                                refinementLassoBubble
                                    .fixedSize()
                                    .position(
                                        x: buttonFrame.midX,
                                        y: buttonFrame.minY - 30
                                    )
                                    .transition(
                                        .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))
                                    )
                                    .zIndex(1)
                            }
                        }
                    }
                    .overlay(alignment: .top) {
                        holdIndicator
                            .offset(y: -64)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .buttonStyle(TactileGlyphButtonStyle())
                    .sensoryFeedback(.selection, trigger: vm.tool.rawValue)
                    .sensoryFeedback(.selection, trigger: isLassoActive)
                    .accessibilityIdentifier("notebook-toolbar")
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isRefinementActive)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: visibleGroupCount)
        .onChange(of: vm.settings.showsWritingTools) { _, isVisible in
            if !isVisible {
                vm.deactivateLasso()
                isRefinementActive = false
                isRefinementLassoActive = false
                pressedTool = nil
                isColorScrubbing = false
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
        .onChange(of: isRefinementActive) { _, isActive in
            if !isActive { isRefinementLassoActive = false }
        }
    }

    private var adaptiveToolbar: some View {
        ViewThatFits(in: dock.isVertical ? .vertical : .horizontal) {
            toolbarContent
                .fixedSize()

            ScrollView(dock.isVertical ? .vertical : .horizontal, showsIndicators: false) {
                toolbarContent
                    .fixedSize()
            }
            .scrollDisabled(pressedTool != nil || isLassoHeld || isColorScrubbing)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.035),
                        .init(color: .black, location: 0.965),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }

    private var toolbarContent: some View {
        toolbarLayout {
            dockGrip

            divider

            if vm.settings.showsWritingTools {
                toolButton(.pen)
                toolButton(.marker)
                toolButton(.eraser)
                divider
                lassoControls
                divider
            }

            imagePickerButton
            divider
            undoControls

            if vm.settings.showsLayers {
                divider
                agenticLayersButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var toolbarLayout: AnyLayout {
        dock.isVertical
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    @ViewBuilder
    private var lassoControls: some View {
        lassoButton
        refinementButton
    }

    @ViewBuilder
    private var undoControls: some View {
        iconButton("arrow.uturn.backward", label: "Undo", enabled: undo.canUndo) {
            undo.undo()
        }
        .accessibilityIdentifier("toolbar-undo")

        iconButton("arrow.uturn.forward", label: "Redo", enabled: undo.canRedo) {
            undo.redo()
        }
        .accessibilityIdentifier("toolbar-redo")
    }

    @ViewBuilder
    private var holdIndicator: some View {
        if let tool = pressedTool {
            ToolWidthHoldIndicator(
                tool: tool,
                width: vm.width(for: tool),
                color: tool == .eraser ? .secondary : vm.inkColor
            )
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
        } else if isColorScrubbing {
            FavoriteColorHoldIndicator(
                colors: vm.settings.favoriteColors,
                selectedHex: vm.inkColorHex
            )
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
        } else if isLassoHeld {
            LassoHoldIndicator()
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
        }
    }

    private var hasVisibleControls: Bool {
        true
    }

    private var visibleGroupCount: Int {
        [
            vm.settings.showsWritingTools,
            vm.settings.showsLayers,
        ].filter { $0 }.count
    }

    // MARK: Pieces

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.12))
            .frame(
                width: dock.isVertical ? 22 : 1,
                height: dock.isVertical ? 1 : 22
            )
    }

    private var dockGrip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .rotationEffect(dock.isVertical ? .degrees(90) : .zero)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { onDockDragChanged($0.translation) }
                    .onEnded(onDockDragEnded)
            )
            .accessibilityLabel("Move toolbar")
            .accessibilityHint("Drag to snap the toolbar to an iPad edge")
            .accessibilityIdentifier("toolbar-dock-grip")
    }

    private var imagePickerButton: some View {
        PhotosPicker(
            selection: $imagePickerItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(Color.primary)
        }
        .accessibilityIdentifier("toolbar-add-image")
        .accessibilityLabel("Add image")
    }

    private func toolButton(_ tool: WritingTool) -> some View {
        let selected = vm.tool == tool
            && !isLassoActive
            && !isRefinementActive
            && !vm.isAgenticLayersActive
        let fill: Color = tool == .eraser ? .secondary : vm.inkColor
        return Button {
            activateToolbarTool(tool)
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(selected ? selectedToolForeground(for: tool) : Color.primary)
                .background { if selected { Circle().fill(fill) } }
                .overlay {
                    if selected {
                        Circle().strokeBorder(
                            selectedToolForeground(for: tool).opacity(0.55),
                            lineWidth: selectedToolBorderWidth(for: tool)
                        )
                    }
                }
                .symbolEffect(.bounce, options: .speed(1.55), value: selected)
                .animation(.spring(response: 0.22, dampingFraction: 0.62), value: selected)
        }
        .highPriorityGesture(widthAdjustmentGesture(for: tool))
        // The high-priority hold protects width adjustment from the horizontal
        // ScrollView, but it can consume the Button's short tap. Observe that
        // tap simultaneously; the shared action is intentionally idempotent.
        .simultaneousGesture(
            TapGesture().onEnded { _ in activateToolbarTool(tool) }
        )
        .accessibilityIdentifier("tool-\(tool.rawValue)")
        .accessibilityLabel(tool.label)
        .accessibilityValue("\(Int(vm.width(for: tool).rounded())) point width")
        .accessibilityHint("Long press, then slide left or right to adjust width")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAdjustableAction { direction in
            adjustWidth(for: tool, direction: direction)
        }
    }

    private func activateToolbarTool(_ tool: WritingTool) {
        pressedTool = nil
        isRefinementActive = false
        vm.selectTool(tool)
    }

    private var lassoButton: some View {
        Button {
            activateLasso()
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
        .highPriorityGesture(lassoHoldGesture)
        // The high-priority hold shows the usage hint, but it consumes the
        // Button's short tap — observe the tap simultaneously so the button
        // actually activates the lasso (same pattern as the tool buttons).
        .simultaneousGesture(
            TapGesture().onEnded { _ in activateLasso() }
        )
        .accessibilityIdentifier("tool-lasso")
        .accessibilityLabel("Selection lasso")
        .accessibilityHint("Draw around strokes to select and move them")
        .accessibilityAddTraits(isLassoActive ? [.isSelected] : [])
    }

    /// Tap toggles: activate the selection lasso, or deactivate it when it is
    /// already the active mode. A single physical tap can invoke this twice
    /// (Button action + the simultaneous TapGesture that survives the
    /// high-priority hold), so duplicate invocations inside one tap window are
    /// coalesced — otherwise the toggle would cancel itself.
    private func activateLasso() {
        let now = Date()
        if let last = lastLassoToggle, now.timeIntervalSince(last) < 0.25 { return }
        lastLassoToggle = now
        isLassoHeld = false
        if isLassoActive {
            vm.deactivateLasso()
        } else {
            // Route the ordinary tap through the same model transition as the
            // hold gesture. In particular, this exits image arrangement before
            // the lasso overlay starts accepting touches.
            vm.activateLasso()
            isRefinementActive = false
        }
    }

    private var lassoHoldGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 24)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, _) = value, !isLassoHeld else { return }
                vm.activateLasso()
                isRefinementActive = false
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
            vm.deactivateLasso(preservingSelection: true)
            vm.isAgenticLayersActive = false
            if isRefinementActive {
                isRefinementActive = false
                isRefinementLassoActive = false
            } else {
                isLassoActive = false
                isRefinementActive = true
            }
        } label: {
            // The badged lasso glyph draws wider and higher than the plain
            // lasso at the same point size; render it slightly smaller and pin
            // it to the same fixed 34×34 cell so the two lassos line up and the
            // toolbar spacing stays even.
            Image(systemName: "lasso.badge.sparkles")
                .font(.system(size: 15, weight: .medium))
                .imageScale(.medium)
                .frame(width: 34, height: 34, alignment: .center)
                .foregroundStyle(isRefinementActive ? Color.white : Color.primary)
                .background {
                    if isRefinementActive {
                        Circle().fill(Color.indigo)
                    }
                }
                .symbolEffect(.pulse, options: .speed(1.4), value: isRefinementActive)
                .animation(.spring(response: 0.22, dampingFraction: 0.62), value: isRefinementActive)
        }
        .accessibilityIdentifier("tool-magic-eraser")
        .accessibilityLabel("Magic Eraser")
        .accessibilityHint("Draw a closed circle with Apple Pencil to reveal AI guidance Pins")
        .accessibilityAddTraits(isRefinementActive ? [.isSelected] : [])
        .anchorPreference(key: RefinementButtonBoundsPreferenceKey.self, value: .bounds) { $0 }
    }

    private var refinementLassoBubble: some View {
        HStack(spacing: 0) {
            Button {
                armRefinementLasso(sendToChat: false)
            } label: {
                Label("Guidance Pins", systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 13)
                    .frame(height: 46)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("refinement-lasso-guidance")
            .accessibilityLabel("Create guidance Pins")
            .accessibilityHint("Draw around notebook content to create AI guidance Pins")

            refinementMenuDivider

            Button {
                armRefinementLasso(sendToChat: true)
            } label: {
                Label("Send to Chat", systemImage: "bubble.left")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 13)
                    .frame(height: 46)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("refinement-lasso-send-to-chat")
            .accessibilityLabel("Send selection to chat")
            .accessibilityHint("Draw around notebook content to send it directly to Pin Chat")

            refinementMenuDivider

            Button {
                onRefinementChatModeChanged(false)
                isRefinementLassoActive = false
                isRefinementActive = false
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 46)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close refinement tool")
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    private var refinementMenuDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 22)
    }

    private func armRefinementLasso(sendToChat: Bool) {
        onRefinementChatModeChanged(sendToChat)
        isLassoActive = false
        isRefinementLassoActive = true
    }

    private func widthAdjustmentGesture(for tool: WritingTool) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 24)
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
                withAnimation(.easeInOut(duration: 0.2)) {
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

    private func adjustWidth(
        for tool: WritingTool,
        direction: AccessibilityAdjustmentDirection
    ) {
        let range = tool.widthRange
        let step = max(1, (range.upperBound - range.lowerBound) / 10)
        let delta: CGFloat
        switch direction {
        case .increment:
            delta = step
        case .decrement:
            delta = -step
        @unknown default:
            return
        }
        vm.selectTool(tool)
        vm.setWidth(vm.width(for: tool) + delta, for: tool)
    }

    private func selectedToolForeground(for tool: WritingTool) -> Color {
        guard tool != .eraser else { return .white }
        return vm.inkUIColor.isLight ? .black : .white
    }

    private func selectedToolBorderWidth(for tool: WritingTool) -> CGFloat {
        let proportionalWidth = vm.width(for: tool).squareRoot()
        return min(max(proportionalWidth, 1.5), 7)
    }

    private var colorButton: some View {
        Button { presentColorPicker() } label: {
            Circle()
                .fill(vm.inkColor)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
                .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1))
                .symbolEffect(.pulse, value: showColors)
        }
        .highPriorityGesture(colorScrubGesture)
        // Match the writing tools: the priority hold protects scrubbing from
        // the adaptive ScrollView, while this observer preserves a short tap.
        .simultaneousGesture(
            TapGesture().onEnded { _ in presentColorPicker() }
        )
        .sensoryFeedback(.selection, trigger: vm.inkColorHex)
        .accessibilityIdentifier("toolbar-color")
        .accessibilityLabel("Ink color")
        .accessibilityValue(vm.inkColorHex)
        .accessibilityHint("Tap for all colors. Long press, then slide left or right through favorites")
        .accessibilityAdjustableAction { direction in
            adjustFavoriteColor(direction)
        }
        .popover(isPresented: $showColors) {
            ColorPalettePopover(vm: vm)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func presentColorPicker() {
        showColors = true
    }

    private var colorScrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 24)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                beginColorScrub()
                guard isColorScrubbing else { return }
                let delta = Int((drag.translation.width / 34).rounded())
                selectFavoriteColor(at: colorScrubStartIndex + delta)
            }
            .onEnded { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isColorScrubbing = false
                }
            }
    }

    private func beginColorScrub() {
        guard !isColorScrubbing, !vm.settings.favoriteColors.isEmpty else { return }
        showColors = false
        pressedTool = nil
        isLassoHeld = false
        isRefinementActive = false
        colorScrubStartIndex = vm.settings.favoriteColors.firstIndex {
            $0.caseInsensitiveCompare(vm.inkColorHex) == .orderedSame
        } ?? 0
        selectFavoriteColor(at: colorScrubStartIndex)
        withAnimation(.easeOut(duration: 0.12)) {
            isColorScrubbing = true
        }
    }

    private func selectFavoriteColor(at proposedIndex: Int) {
        let favorites = vm.settings.favoriteColors
        guard !favorites.isEmpty else { return }
        let index = min(max(proposedIndex, 0), favorites.count - 1)
        let hex = favorites[index]
        guard vm.inkColorHex.caseInsensitiveCompare(hex) != .orderedSame else { return }
        vm.selectColor(hex)
    }

    private func adjustFavoriteColor(_ direction: AccessibilityAdjustmentDirection) {
        let favorites = vm.settings.favoriteColors
        guard !favorites.isEmpty else { return }
        let currentIndex = favorites.firstIndex {
            $0.caseInsensitiveCompare(vm.inkColorHex) == .orderedSame
        }
        let targetIndex: Int
        switch direction {
        case .increment:
            targetIndex = min((currentIndex ?? -1) + 1, favorites.count - 1)
        case .decrement:
            targetIndex = max((currentIndex ?? favorites.count) - 1, 0)
        @unknown default:
            return
        }
        selectFavoriteColor(at: targetIndex)
    }

    private var agenticLayersButton: some View {
        let isActive = vm.isAgenticLayersActive
        return Button {
            showLayers.toggle()
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(isActive ? Color.white : (showLayers ? Color.indigo : Color.primary))
                .background {
                    if isActive {
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
        .accessibilityLabel(showLayers ? "Close layer picker" : "Open layer picker")
        .accessibilityValue(isActive ? "Agentic layer active" : "Agentic layers hidden")
        .accessibilityAddTraits(vm.isAgenticLayersActive ? [.isSelected] : [])
        .popover(isPresented: $showLayers) {
            NotebookLayersPopover(vm: vm) {
                showLayers = false
                onAskAgent()
            }
                .presentationCompactAdaptation(.popover)
        }
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

private struct RefinementButtonBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
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
                    $0.id == vm.selectedLayerID
                })?.id ?? layers.first?.id
                else { return }
                vm.selectAgenticLayer(layerID)
                onAskAgent()
            } label: {
                Label(
                    vm.isAgenticLayersActive ? "Ask on active layer" : "Activate & ask",
                    systemImage: "text.bubble.fill"
                )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(vm.conversationLayers.layers.isEmpty)
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
        let isActive = vm.isAgenticLayersActive
            && vm.selectedLayerID == layer.id
            && layer.isVisible
        return Button {
            vm.toggleAgenticLayerActivation(layer.id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: layer.symbolName)
                Text(layer.name).lineLimit(1)
                Text("\(layer.conversations.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(isActive ? Color.indigo : Color.secondary)
                    .background(.white.opacity(isActive ? 0.86 : 0.65), in: Capsule())
                Image(systemName: isActive ? "eye.fill" : "eye.slash")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .foregroundStyle(isActive ? Color.white : Color.secondary)
            .background(isActive ? Color.indigo : Color.secondary.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(layer.name) Agentic Layer")
        .accessibilityValue(isActive ? "Active" : "Hidden")
        .accessibilityHint(isActive ? "Hides this layer and its Pins" : "Activates this layer and shows its Pins")
        .accessibilityAddTraits(isActive ? .isSelected : [])
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

struct NotebookToolbarSettingsView: View {
    @ObservedObject var vm: NotebookViewModel
    @Binding var pencilDoubleTapEnabled: Bool
    @Binding var pencilSqueezeEnabled: Bool
    @Binding var pencilHoverPreviewEnabled: Bool
    let isAnalysisAccessConfigured: Bool
    let analysisAccessSummary: String
    let onEditAnalysisAccess: () -> Void
    let onDismiss: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 12), count: 6)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Notebook Controls")
                    .font(.headline)

                Text("Working toolbar")
                    .font(.subheadline.weight(.semibold))

                Group {
                    Toggle("Writing tools", isOn: $vm.settings.showsWritingTools)
                        .accessibilityIdentifier("settings-writing-tools")
                    Toggle("Layers", isOn: $vm.settings.showsLayers)
                        .accessibilityIdentifier("settings-agentic-layers")
                }
                .font(.subheadline)

                Picker("Page scroll direction", selection: $vm.settings.pageScrollDirection) {
                    ForEach(NotebookPageScrollDirection.allCases) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings-page-scroll-direction")

                Divider()

                Text("Top toolbar")
                    .font(.subheadline.weight(.semibold))

                Group {
                    Toggle("Export", isOn: $vm.settings.showsExport)
                        .accessibilityIdentifier("settings-export")
                    Toggle("Page lock", isOn: $vm.settings.showsPageLock)
                        .accessibilityIdentifier("settings-page-lock")
                }
                .font(.subheadline)

                Divider()

                Text("Apple Pencil")
                    .font(.headline)

                Group {
                    Toggle("Double-tap follows system action", isOn: $pencilDoubleTapEnabled)
                        .accessibilityIdentifier("settings-pencil-double-tap")
                    Toggle("Squeeze shows shortcuts", isOn: $pencilSqueezeEnabled)
                        .accessibilityIdentifier("settings-pencil-squeeze")
                    Toggle("Hover ink preview", isOn: $pencilHoverPreviewEnabled)
                        .accessibilityIdentifier("settings-pencil-hover")
                }
                .font(.subheadline)

                Text("Double-tap and squeeze honor the actions selected in Settings › Apple Pencil.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Text("Analysis")
                    .font(.headline)

                Button(action: onEditAnalysisAccess) {
                    HStack(spacing: 12) {
                        Image(systemName: isAnalysisAccessConfigured ? "key.fill" : "key")
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notebook analysis access")
                                .foregroundStyle(.primary)
                            Text(analysisAccessSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Notebook analysis access")
                .accessibilityValue(analysisAccessSummary)
                .accessibilityIdentifier("settings-analysis-access")
                .accessibilityHint("View or configure agent provider access for notebook analysis")

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
        .onDisappear(perform: onDismiss)
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

private struct ToolWidthHoldIndicator: View {
    let tool: WritingTool
    let width: CGFloat
    let color: Color

    private let trackWidth: CGFloat = 136
    private let thumbDiameter: CGFloat = 16

    private var progress: CGFloat {
        let range = tool.widthRange
        let raw = (width - range.lowerBound) / (range.upperBound - range.lowerBound)
        return min(max(raw, 0), 1)
    }

    var body: some View {
        VStack(spacing: 7) {
            Text("\(tool.label) · \(Int(width.rounded())) pt")
                .font(.caption2.monospacedDigit().weight(.semibold))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.14))
                    .frame(height: 6)
                Capsule()
                    .fill(color.opacity(tool == .marker ? 0.55 : 1))
                    .frame(width: max(8, trackWidth * progress), height: 6)
                Circle()
                    .fill(.background)
                    .overlay(Circle().strokeBorder(color, lineWidth: 2))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: (trackWidth - thumbDiameter) * progress)
            }
            .frame(width: trackWidth, height: thumbDiameter)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }
}

private struct FavoriteColorHoldIndicator: View {
    let colors: [String]
    let selectedHex: String

    private let maximumVisibleColors = 7

    private var selectedIndex: Int {
        colors.firstIndex {
            $0.caseInsensitiveCompare(selectedHex) == .orderedSame
        } ?? 0
    }

    private var visibleRange: Range<Int> {
        guard colors.count > maximumVisibleColors else { return 0..<colors.count }
        let lowerBound = min(
            max(selectedIndex - maximumVisibleColors / 2, 0),
            colors.count - maximumVisibleColors
        )
        return lowerBound..<(lowerBound + maximumVisibleColors)
    }

    var body: some View {
        VStack(spacing: 7) {
            Text("Favorite \(selectedIndex + 1) of \(colors.count)")
                .font(.caption2.monospacedDigit().weight(.semibold))

            HStack(spacing: 7) {
                if visibleRange.lowerBound > 0 {
                    Image(systemName: "chevron.left")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(visibleRange), id: \.self) { index in
                    let uiColor = UIColor(hex: colors[index]) ?? .black
                    let isSelected = index == selectedIndex
                    Circle()
                        .fill(Color(uiColor))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1))
                        .overlay {
                            if isSelected {
                                Circle()
                                    .strokeBorder(uiColor.isLight ? Color.black : Color.white, lineWidth: 2)
                                    .padding(3)
                            }
                        }
                        .scaleEffect(isSelected ? 1.18 : 1)
                        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isSelected)
                }

                if visibleRange.upperBound < colors.count {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
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
