import SwiftUI
import TNModel

/// The window: a chip bar of what is open, one surface below it, and the
/// refusal banner over the top.
struct RootView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            Rectangle().fill(Macaron.ink).frame(height: Macaron.outline)
            surface
        }
        .overlay(alignment: .top) {
            if let message = workspace.banner {
                BannerView(message: message)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: workspace.banner)
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

    /// How many tabs the band shows before folding the rest into "+N".
    private static let visibleTabs = 4

    var body: some View {
        let shown = Array(workspace.tabs.prefix(Self.visibleTabs))
        let hidden = workspace.tabs.dropFirst(Self.visibleTabs)
        HStack(spacing: 8) {
            Button {
                workspace.showLibrary()
            } label: {
                Label("Library", systemImage: "books.vertical").labelStyle(.iconOnly)
            }
            .buttonStyle(MacaronChipStyle(isOn: workspace.activeTabID == nil))

            ForEach(shown) { tab in
                TabChip(tab: tab, isActive: tab.id == workspace.activeTabID)
            }
            if !hidden.isEmpty {
                Menu {
                    ForEach(Array(hidden)) { tab in
                        Button(tab.name) { workspace.activeTabID = tab.id }
                    }
                } label: {
                    Text("+\(hidden.count)")
                        .font(Macaron.display(14))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 34)
                        .foregroundStyle(Macaron.ink)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(style: StrokeStyle(lineWidth: Macaron.outline, dash: [6, 4]))
                                .foregroundStyle(Macaron.ink)
                        )
                }
            }
            Spacer()
            if workspace.activeTab != nil, let actions = workspace.bandActions {
                actions.readout()
                    .buttonStyle(MacaronChipStyle())
                    .menuStyle(.button)
                Menu {
                    ForEach(actions.insert) { row in
                        Button(action: row.action) { Label(row.label, systemImage: row.symbol) }
                    }
                } label: {
                    Label("Insert", systemImage: "plus.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(MacaronChipStyle())
                Button(action: actions.export) {
                    Label("Export", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                }
                .buttonStyle(MacaronChipStyle(fill: Macaron.vanilla))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Macaron.card)
    }
}

/// The tab: name, page callsign, a vanilla dot while unsaved. Held tab is
/// strawberry with a hard shadow.
private struct TabChip: View {
    @Environment(Workspace.self) private var workspace
    let tab: Workspace.Tab
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                workspace.activeTabID = tab.id
            } label: {
                HStack(spacing: 6) {
                    Text(tab.name.uppercased())
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\u{00B7} \(tab.editor.currentPageIndex + 1)")
                        .opacity(isActive ? 1 : 0.6)
                    if tab.editor.isSaving {
                        Circle()
                            .fill(Macaron.vanilla)
                            .overlay(Circle().strokeBorder(Macaron.ink, lineWidth: 2))
                            .frame(width: 11, height: 11)
                    }
                }
                .font(Macaron.display(14))
            }
            .buttonStyle(.plain)

            Button {
                Task { await workspace.close(tabID: tab.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .black))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.name)")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .frame(maxWidth: 220)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(isActive ? .white : Macaron.ink)
        .macaronCard(fill: isActive ? Macaron.strawberry : Macaron.card, radius: 10, shadow: isActive ? 3 : 0)
        .padding(.trailing, isActive ? 3 : 0)
    }
}

/// One line, dismissible, and the one action that always works when a save
/// will not succeed.
private struct BannerView: View {
    @Environment(Workspace.self) private var workspace
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(message)
                .font(Macaron.display(14))
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tabID = workspace.discardableTabID {
                Button("Discard and close") {
                    Task { await workspace.discardAndClose(tabID: tabID) }
                }
                .buttonStyle(MacaronWordChipStyle(fill: Macaron.vanilla))
            }

            Button {
                workspace.dismissBanner()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .foregroundStyle(.white)
        .macaronCard(fill: Macaron.strawberry, radius: 12, shadow: 5)
    }
}
