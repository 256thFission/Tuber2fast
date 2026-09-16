import SwiftUI
import TNModel

/// Every theme the build has, as a wall of cards, with the system's own
/// light and dark above them.
///
/// The panel stays up after a tap: the whole app repaints under it, which is
/// the only way to compare two themes.
struct ThemesPanel: View {
    @Environment(Workspace.self) private var workspace
    let onClose: () -> Void

    private static let columns = 4

    var body: some View {
        MacaronPanel(title: "Themes", onClose: onClose) {
            MacaronButton(
                title: "Follow the system",
                icon: "circle.lefthalf.filled",
                isHeld: workspace.choice == .system
            ) {
                workspace.choose(.system)
            }

            // Laid out in rows rather than in a `LazyVGrid`: a lazy
            // container has no ideal height, so the panel cannot hug it and
            // the sheet opens with a field of empty chrome under the cards.
            Grid(horizontalSpacing: Macaron.columnGap, verticalSpacing: Macaron.columnGap) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row], id: \.id) { preset in
                            card(preset)
                        }
                    }
                }
            }
        }
    }

    private func card(_ preset: ThemePreset) -> some View {
        ThemeCard(preset: preset, isChosen: workspace.choice == .preset(preset.id)) {
            workspace.choose(.preset(preset.id))
        }
    }

    private var rows: [[ThemePreset]] {
        stride(from: 0, to: Theme.presets.count, by: Self.columns).map { start in
            Array(Theme.presets[start ..< min(start + Self.columns, Theme.presets.count)])
        }
    }
}

/// A theme, small: its ground with a bar of its chrome lying on it, carrying
/// the accent and the secondary. Every line on the card is the card's own
/// theme's, so a card shows what that theme derives rather than what the app
/// is currently drawing in.
private struct ThemeCard: View {
    let preset: ThemePreset
    let isChosen: Bool
    let action: () -> Void

    @Environment(\.macaron) private var panel

    private static let width: CGFloat = 132
    private static let height: CGFloat = 76
    private static let dot: CGFloat = 14

    var body: some View {
        VStack(spacing: Macaron.rowGap) {
            Keycap(
                fill: preset.theme.ground,
                size: CGSize(width: Self.width, height: Self.height),
                isHeld: isChosen,
                action: action
            ) {
                bar
            }
            // The card draws in its own theme; its name is the panel's, and
            // reads in the theme the app is actually wearing.
            .environment(\.macaron, preset.theme)
            .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(preset.name)

            Text(preset.name)
                .font(Macaron.title(13))
                .foregroundStyle(panel.outline(of: panel.chrome).color)
                .lineLimit(1)
        }
    }

    private var bar: some View {
        let theme = preset.theme
        return HStack(spacing: Macaron.rowGap) {
            dot(theme.accent)
            dot(theme.secondary)
        }
        .padding(Macaron.rowGap)
        .background {
            RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                .fill(theme.chrome.color)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                .strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
        }
    }

    private func dot(_ fill: RGBA8) -> some View {
        Circle()
            .fill(fill.color)
            .overlay {
                Circle().strokeBorder(preset.theme.outline(of: fill).color, lineWidth: Macaron.line)
            }
            .frame(width: Self.dot, height: Self.dot)
    }
}
