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

    var body: some View {
        Group {
            HStack(spacing: 8) {
                Button {
                    workspace.showLibrary()
                } label: {
                    Label("Library", systemImage: "books.vertical")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(MacaronChipStyle(isOn: workspace.activeTabID == nil))

                ForEach(workspace.tabs) { tab in
                    TabChip(tab: tab, isActive: tab.id == workspace.activeTabID)
                }
                Spacer()
                if workspace.activeTab != nil, let actions = workspace.bandActions {
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
        }
        .scrollIndicators(.hidden)
        .background(Macaron.card)
    }
}

private struct TabChip: View {
    @Environment(Workspace.self) private var workspace
    let tab: Workspace.Tab
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button(tab.name.uppercased()) {
                workspace.activeTabID = tab.id
            }
            .buttonStyle(.plain)
            .font(Macaron.display(14))
            .lineLimit(1)

            Button {
                Task { await workspace.close(tabID: tab.id) }
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tabID = workspace.discardableTabID {
                Button("Discard and close") {
                    Task { await workspace.discardAndClose(tabID: tabID) }
                }
                .font(.callout.weight(.semibold))
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
        .background(.thickMaterial, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        .shadow(radius: 4, y: 2)
    }
}
