import SwiftUI
import TNEditor
import TNModel

/// The band across the top: what is open, where you are in it, and the
/// actions that are not instruments.
///
/// Flat everywhere except the tabs. Tabs are keycaps and the active one is
/// sunk; the shell, the library chip, the action chips, the readout and the
/// seat toggle have no wall at all.
struct MacaronBand: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.macaron) private var theme
    let editor: EditorViewModel
    let action: (BandAction) -> Void

    /// How much of the top the band takes, so nothing else parks under it.
    static let slack: CGFloat = 56 + 32

    private static let height: CGFloat = 56
    private static let gap: CGFloat = 9
    private static let padding: CGFloat = 13

    var body: some View {
        HStack(spacing: Self.gap) {
            libraryChip
            tabs
            if overflow > 0 { overflowChip }
            Spacer(minLength: Self.gap)
            readout
            MacaronDivider()
            undoRedo
            MacaronDivider()
            ForEach(BandAction.allCases, id: \.self) { action in
                chip(action)
            }
        }
        .padding(.horizontal, Self.padding)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        // The status bar sits over the band's own top, which reaches the
        // display's edge: the band has no top to outline, the way a docked
        // seat has no right one.
        .safeAreaPadding(.top)
        .background {
            shell.fill(theme.chrome.color)
                .overlay {
                    shell.strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
                }
                .padding(.top, -Macaron.shellRadius)
        }
    }

    private var shell: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: Macaron.shellRadius,
            bottomTrailingRadius: Macaron.shellRadius,
            style: .continuous
        )
    }

    // MARK: What is open

    /// Round, and flat: it leaves the notebook rather than acting on it.
    private var libraryChip: some View {
        Button { workspace.showLibrary() } label: {
            Circle()
                .fill(theme.chrome.color)
                .overlay { Circle().strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line) }
                .overlay {
                    Image(systemName: "books.vertical.fill")
                        .font(Macaron.body(14))
                        .foregroundStyle(theme.outline(of: theme.chrome).color)
                }
                .frame(width: Macaron.chip, height: Macaron.chip)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Library")
        // The themes hang off the one chip that is about the whole app
        // rather than about the notebook. The band's own list is fixed.
        .contextMenu {
            Button("Themes…") { workspace.isShowingThemes = true }
        }
    }

    /// Four at most on the band itself; the rest go behind the overflow chip.
    private var shown: [Workspace.Tab] { Array(workspace.tabs.prefix(4)) }
    private var overflow: Int { max(0, workspace.tabs.count - shown.count) }

    private var tabs: some View {
        HStack(spacing: Self.gap) {
            ForEach(shown) { tab in
                tabCap(tab)
            }
        }
    }

    private func tabCap(_ tab: Workspace.Tab) -> some View {
        let isActive = tab.id == workspace.activeTabID
        return Keycap(
            fill: isActive ? theme.accent : theme.chrome,
            size: CGSize(width: width(of: tab), height: Macaron.chip),
            isHeld: isActive
        ) {
            workspace.activeTabID = tab.id
        } label: {
            HStack(spacing: 6) {
                Text(tab.name)
                    .font(Macaron.title(13))
                    .lineLimit(1)
                Text(callsign(of: tab))
                    .font(Macaron.body(10))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(
                                theme.outline(of: isActive ? theme.accent : theme.chrome).color,
                                lineWidth: 1.5
                            )
                    }
            }
            .padding(.horizontal, 9)
        }
        .overlay(alignment: .topTrailing) { if tab.editor.isSaving { dirtyDot } }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func width(of tab: Workspace.Tab) -> CGFloat {
        // Room for the name and its badge. Measured off the name's length
        // rather than laid out, so a tab does not resize under the finger.
        min(196, 92 + CGFloat(tab.name.count) * 7)
    }

    /// Hung off the corner, no wall, and it says one thing: this notebook
    /// has pages that have not landed yet.
    private var dirtyDot: some View {
        Circle()
            .fill(theme.secondary.color)
            .overlay {
                Circle().strokeBorder(
                    Theme.mix(theme.secondary, toward: theme.ink, theme.outlineMixPale).color,
                    lineWidth: 1.5
                )
            }
            .frame(width: 11, height: 11)
            .offset(x: 4, y: -4)
            .transition(.scale(scale: 1.5).combined(with: .opacity))
            .accessibilityLabel("Unsaved")
    }

    /// In the ground colour, so four tabs and a count do not read as five
    /// tabs.
    private var overflowChip: some View {
        Menu {
            ForEach(workspace.tabs.dropFirst(shown.count)) { tab in
                Button(tab.name) { workspace.activeTabID = tab.id }
            }
        } label: {
            RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                .fill(theme.ground.color)
                .overlay {
                    RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                        .strokeBorder(theme.outline(of: theme.ground).color, lineWidth: Macaron.line)
                }
                .overlay {
                    Text(verbatim: "+\(overflow)")
                        .font(Macaron.title(13))
                        .foregroundStyle(theme.outline(of: theme.ground).color)
                }
                .frame(width: Macaron.chip, height: Macaron.chip)
        }
        .accessibilityLabel(Text(verbatim: "\(overflow) more notebooks"))
    }

    /// A letter off the name and two digits off the identity, in the shape
    /// the mocks print it in. Nothing in the format holds a callsign yet, so
    /// it is read off what does identify a notebook.
    private func callsign(of tab: Workspace.Tab) -> String {
        let letter = tab.name.first.map { String($0).uppercased() } ?? "N"
        // Off the identity's own bytes, not its hash: a hash is seeded per
        // launch, and a callsign that changes when the app restarts names
        // nothing.
        let digits = tab.id.raw.uuid
        return "\(letter)\(Int(digits.0) % 10)·\(Int(digits.1) % 10)"
    }

    // MARK: Where you are

    /// A readout, so it is flat and has no wall.
    private var readout: some View {
        Text(verbatim: "\(editor.currentPageIndex + 1) / \(editor.pageCount)")
            .font(Macaron.body(14).monospacedDigit())
            .foregroundStyle(theme.outline(of: theme.chrome).color)
            .fixedSize()
    }

    private var undoRedo: some View {
        HStack(spacing: Self.gap) {
            flatChip("arrow.uturn.backward", "Undo", enabled: editor.canUndo) { editor.undo() }
            flatChip("arrow.uturn.forward", "Redo", enabled: editor.canRedo) { editor.redo() }
        }
    }

    private func chip(_ action: BandAction) -> some View {
        flatChip(action.symbol, action.label, tint: action.tint(theme)) { self.action(action) }
    }

    private func flatChip(
        _ symbol: String,
        _ label: String,
        tint: RGBA8? = nil,
        enabled: Bool = true,
        tap: @escaping () -> Void
    ) -> some View {
        let fill = tint ?? theme.chrome
        return Button(action: tap) {
            RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                .fill(fill.color)
                .overlay {
                    RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                        .strokeBorder(theme.outline(of: fill).color, lineWidth: Macaron.line)
                }
                .overlay {
                    Image(systemName: symbol)
                        .font(Macaron.body(14))
                        .foregroundStyle(theme.outline(of: fill).color)
                }
                .frame(width: Macaron.chip, height: Macaron.chip)
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// The band's actions, in the order the design lists them. Undo and redo
/// are not here: they are a pair with their own enablement, next to the
/// readout they undo their way back through.
enum BandAction: CaseIterable {
    case lasso, text, insert, export, seat

    var symbol: String {
        switch self {
        case .lasso: "lasso"
        case .text: "textformat"
        case .insert: "plus.circle"
        case .export: "square.and.arrow.up"
        case .seat: "sidebar.right"
        }
    }

    var label: String {
        switch self {
        case .lasso: "Lasso"
        case .text: "Text"
        case .insert: "Insert"
        case .export: "Export"
        case .seat: "Seat"
        }
    }

    /// The seat toggle is the seat's own colour, which is the secondary.
    func tint(_ theme: Theme) -> RGBA8? { self == .seat ? theme.secondary : nil }
}
