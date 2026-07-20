import SwiftUI
import UIKit

/// Contextual controls shown near the Apple Pencil tip after a configured
/// double-tap or Pencil Pro squeeze.
struct PencilShortcutPalette: View {
    enum Mode: Equatable {
        case full
        case colorsOnly
    }

    @ObservedObject var vm: NotebookViewModel
    @ObservedObject var undo: NotebookUndoBridge
    let mode: Mode
    var onAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if !vm.settings.favoriteColors.isEmpty {
                colorRow
            }

            if mode == .full {
                if !vm.settings.favoriteColors.isEmpty { separator }
                toolRow
                separator
                undoRow
            }
        }
        .padding(14)
        .frostedGlass(cornerRadius: 20)
        .environment(\.colorScheme, .dark)
        .frame(width: 212)
        .accessibilityIdentifier("pencil-shortcut-palette")
        .accessibilityElement(children: .contain)
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
    }

    private var colorRow: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(30), spacing: 10), count: 5),
            spacing: 10
        ) {
            ForEach(vm.settings.favoriteColors, id: \.self) { hex in
                swatch(hex)
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        let uiColor = UIColor(hex: hex) ?? .black
        let isSelected = vm.inkColorHex.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            vm.selectColor(hex)
            onAction()
        } label: {
            Circle()
                .fill(Color(uiColor))
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(uiColor.isLight ? Color.black : Color.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pencil-palette-swatch-\(hex)")
        .accessibilityLabel("Ink color \(hex)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            ForEach(WritingTool.allCases) { tool in
                let isSelected = vm.tool == tool && !vm.isLassoActive
                Button {
                    vm.selectTool(tool)
                    onAction()
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 38, height: 34)
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(.white.opacity(0.92))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pencil-palette-tool-\(tool.rawValue)")
                .accessibilityLabel(tool.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var undoRow: some View {
        HStack(spacing: 6) {
            paletteButton(
                "arrow.uturn.backward",
                label: "Undo",
                identifier: "pencil-palette-undo",
                enabled: undo.canUndo
            ) {
                undo.undo()
                onAction()
            }
            paletteButton(
                "arrow.uturn.forward",
                label: "Redo",
                identifier: "pencil-palette-redo",
                enabled: undo.canRedo
            ) {
                undo.redo()
                onAction()
            }
        }
    }

    private func paletteButton(
        _ symbol: String,
        label: String,
        identifier: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.28))
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }
}
