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
            // library has no band, so it keeps the plain chip bar.
            if workspace.activeTab == nil {
                TabBar()
                Divider()
            }
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
        .environment(\.macaron, workspace.theme)
        .background(workspace.theme.ground.color)
        // Macaron follows the system after dark. A theme picked by hand is
        // a choice, and the system does not get to overrule it.
        .onAppear { followScheme() }
        .onChange(of: scheme) { _, _ in followScheme() }
    }

    private func followScheme() {
        guard !workspace.themeIsChosen else { return }
        switch (scheme, workspace.theme) {
        case (.dark, .macaron): workspace.theme = .macaronDark
        case (.light, .macaronDark): workspace.theme = .macaron
        default: break
        }
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
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button {
                    workspace.showLibrary()
                } label: {
                    Label("Library", systemImage: "books.vertical")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .tint(workspace.activeTabID == nil ? .accentColor : .secondary)

                ForEach(workspace.tabs) { tab in
                    TabChip(tab: tab, isActive: tab.id == workspace.activeTabID)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }
}

private struct TabChip: View {
    @Environment(Workspace.self) private var workspace
    let tab: Workspace.Tab
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button(tab.name) {
                workspace.activeTabID = tab.id
            }
            .buttonStyle(.plain)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .clipShape(.rect(cornerRadius: 8))
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
