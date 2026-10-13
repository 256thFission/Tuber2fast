import SwiftUI
import TNModel

/// The window: a chip bar of what is open, one surface below it, and the
/// refusal banner over the top.
struct RootView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            // The band carries the tabs while a notebook is open. The
            // library has no band, so it keeps the chip bar, which is the
            // same object: flush with the top of the display.
            if workspace.activeTab == nil {
                TabBar()
            }
            surface
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .top) {
            if let message = workspace.banner {
                BannerView(message: message)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: workspace.banner)
        .environment(\.macaron, workspace.theme)
        .background(workspace.theme.ground.color)
        // Presented here rather than beside either library chip: the picker
        // is about the whole app, and the two chips live in different views.
        .sheet(isPresented: themesBinding) {
            ThemesPanel { workspace.isShowingThemes = false }
        }
        // The view reports the hour and the workspace decides what to do
        // with it: a theme picked by hand is a choice, and the system does
        // not get to overrule it.
        .onAppear { workspace.colourScheme = scheme }
        .onChange(of: scheme) { _, scheme in workspace.colourScheme = scheme }
    }

    private var themesBinding: Binding<Bool> {
        Binding(get: { workspace.isShowingThemes }, set: { workspace.isShowingThemes = $0 })
    }

    @ViewBuilder private var surface: some View {
        if let tab = workspace.activeTab {
            // Identity by tab: switching tabs must not hand one tab's canvas
            // host to another tab's editor.
            EditorView(editor: tab.editor)
                .id(tab.id)
        } else {
            LibraryView()
        }
    }
}

private struct TabBar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.macaron) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Macaron.columnGap) {
                libraryChip
                ForEach(workspace.tabs) { tab in
                    TabChip(tab: tab, isActive: tab.id == workspace.activeTabID)
                }
            }
            .padding(.horizontal, Macaron.inset)
            .frame(height: Macaron.shell)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .safeAreaPadding(.top)
        .background {
            shell.fill(theme.chrome.color)
                .overlay {
                    shell.strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
                }
                .padding(.top, -Macaron.shellRadius)
        }
    }

    /// Only the bottom corners are rounded: the top two are the display's.
    private var shell: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: Macaron.shellRadius,
            bottomTrailingRadius: Macaron.shellRadius,
            style: .continuous
        )
    }

    /// Flat, like the band's library chip: it leaves what is open rather
    /// than acting on it, and this bar is only shown when nothing is open.
    private var libraryChip: some View {
        Button {
            workspace.showLibrary()
        } label: {
            HStack(spacing: Macaron.rowGap) {
                Image(systemName: "books.vertical").font(Macaron.body(14))
                Text("Library").font(Macaron.title(14))
            }
            .foregroundStyle(theme.outline(of: theme.chrome).color)
            .padding(.horizontal, Macaron.shellPadding)
            .frame(height: Macaron.chip)
            .background {
                RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                    .fill(theme.chrome.color)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                    .strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
            }
        }
        .buttonStyle(.plain)
        // The themes hang off the library chip, and this is the one the app
        // opens on.
        .contextMenu {
            Button("Themes…") { workspace.isShowingThemes = true }
        }
    }
}

/// The band's tabs, in the bar the library keeps: keycaps, and the active
/// one is sunk. The close cap stands beside the name rather than inside it,
/// because a cap holds one press and this chip answers two.
private struct TabChip: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.macaron) private var theme
    let tab: Workspace.Tab
    let isActive: Bool

    var body: some View {
        // One cap, not two: the close glyph rides inside the name's cap so a
        // tab reads as a single object. The glyph keeps its own tap region —
        // the innermost gesture wins, so the cap's own tap still activates
        // everywhere else on it.
        Keycap(
            fill: isActive ? theme.accent : theme.chrome,
            size: CGSize(width: 0, height: Macaron.chip),
            isHeld: isActive
        ) {
            workspace.activeTabID = tab.id
        } label: {
            HStack(spacing: Macaron.rowGap) {
                Text(tab.name)
                    .font(Macaron.title(14))
                    .lineLimit(1)

                Image(systemName: "xmark")
                    .font(Macaron.body(13))
                    .frame(width: Macaron.chip - Macaron.shellPadding, height: Macaron.chip)
                    .contentShape(.rect)
                    .onTapGesture {
                        Task { await workspace.close(tabID: tab.id) }
                    }
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Close \(tab.name)")
            }
            .padding(.leading, Macaron.shellPadding)
            .padding(.trailing, Macaron.chipWall)
        }
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(tab.name)
        // The cap folds its label into one element, glyph included, and a
        // gesture brings no action with it. Without this, VoiceOver has no
        // way to close a tab.
        .accessibilityAction(named: Text("Close \(tab.name)")) {
            Task { await workspace.close(tabID: tab.id) }
        }
    }
}

/// One line, dismissible, and the one action that always works when a save
/// will not succeed.
private struct BannerView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.macaron) private var theme
    let message: String

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
    }

    /// The words are a readout and stay flat; the two things you can do
    /// about them are caps.
    var body: some View {
        HStack(alignment: .center, spacing: Macaron.columnGap) {
            Text(message)
                .font(Macaron.body(14))
                .foregroundStyle(theme.outline(of: theme.chrome).color)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tabID = workspace.discardableTabID {
                // The one thing that still works when a save will not.
                MacaronButton(title: "Discard and close", fill: theme.accent) {
                    Task { await workspace.discardAndClose(tabID: tabID) }
                }
            }

            Keycap(fill: theme.chrome, size: CGSize(width: Macaron.chip, height: Macaron.chip)) {
                workspace.dismissBanner()
            } label: {
                Image(systemName: "xmark").font(Macaron.body(13))
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Dismiss")
        }
        .padding(Macaron.shellPadding)
        .background { shape.fill(theme.chrome.color) }
        .overlay { shape.strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line) }
        // It floats over whatever it interrupted, so it takes a hard
        // zero-blur offset. The offset is the ground's own outline: nothing is
        // black but ink, and the chrome's outline would read as a second border.
        .shadow(color: theme.outline(of: theme.ground).color, radius: 0, x: 0, y: 6)
    }
}
