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
                MacaronBanner(message: message, onDismiss: { workspace.dismissBanner() }) {
                    if let tabID = workspace.discardableTabID {
                        // The one thing that still works when a save will not.
                        MacaronButton(title: "Discard and close", fill: workspace.theme.accent) {
                            Task { await workspace.discardAndClose(tabID: tabID) }
                        }
                    }
                }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: workspace.banner)
        .environment(\.macaron, workspace.theme)
        .background(workspace.theme.ground.color)
        // What UIKit draws itself (alerts, menus, the keyboard) follows a
        // preset rather than the hour. System leaves the hour alone, so
        // the scheme read below is still the system's own.
        .preferredColorScheme(workspace.choice == .system ? nil : (workspace.theme.invertsMix ? .dark : .light))
        // The view reports the hour and the workspace decides what to do
        // with it: a theme picked by hand is a choice, and the system does
        // not get to overrule it.
        .onAppear { workspace.colourScheme = scheme }
        .onChange(of: scheme) { _, scheme in workspace.colourScheme = scheme }
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
            FlatChip(width: nil) {
                HStack(spacing: Macaron.rowGap) {
                    Image(systemName: "books.vertical").font(Macaron.body(.label))
                    Text("Library").font(Macaron.title(.label))
                }
                .padding(.horizontal, Macaron.shellPadding)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The band's tabs, in the bar the library keeps: keycaps, and the active
/// one is sunk. Unlike the band's, each one closes.
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
                    .font(Macaron.title(.label))
                    .lineLimit(1)

                Image(systemName: "xmark")
                    .font(Macaron.body(.text))
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
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityLabel(tab.name)
        // The cap folds its label into one element, glyph included, and a
        // gesture brings no action with it. Without this, VoiceOver has no
        // way to close a tab.
        .accessibilityAction(named: Text("Close \(tab.name)")) {
            Task { await workspace.close(tabID: tab.id) }
        }
    }
}
