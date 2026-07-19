import SwiftUI

/// The thin floating menu bar shown over the page: home, writing utensils,
/// ink color, light/dark toggle, add page, and a tappable page indicator.
struct NotebookToolbar: View {
    @ObservedObject var vm: NotebookViewModel
    @AppStorage("tuber.appearance") private var appearanceRaw = AppAppearance.system.rawValue

    var onHome: () -> Void
    var onShowPages: () -> Void

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        HStack(spacing: 12) {
            iconButton("house", action: onHome)
                .accessibilityIdentifier("toolbar-home")

            divider

            ForEach(WritingTool.allCases) { tool in
                toolButton(tool)
            }

            colorMenu

            divider

            iconButton(appearance.symbol) {
                appearanceRaw = appearance.next.rawValue
            }
            .accessibilityIdentifier("toolbar-appearance")

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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityIdentifier("notebook-toolbar")
    }

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.12))
            .frame(width: 1, height: 22)
    }

    private func toolButton(_ tool: WritingTool) -> some View {
        let selected = vm.tool == tool
        let fill: Color = tool == .eraser ? .secondary : vm.inkColor.swatch
        return Button {
            vm.tool = tool
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background {
                    if selected { Circle().fill(fill) }
                }
        }
        .accessibilityIdentifier("tool-\(tool.rawValue)")
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var colorMenu: some View {
        Menu {
            ForEach(InkColor.allCases) { color in
                Button {
                    vm.inkColor = color
                    if vm.tool == .eraser { vm.tool = .pen }
                } label: {
                    Label(
                        color.label,
                        systemImage: vm.inkColor == color ? "checkmark.circle.fill" : "circle.fill"
                    )
                }
            }
        } label: {
            Circle()
                .fill(vm.inkColor.swatch)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
        }
        .accessibilityIdentifier("toolbar-color")
        .accessibilityLabel("Ink color")
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(.primary)
        }
    }
}
