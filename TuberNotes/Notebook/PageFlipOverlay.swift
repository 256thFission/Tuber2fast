import PencilKit
import SwiftUI

/// Shown when the user long-presses the page. Lets them flip pages with
/// arrows, a swipe, or thumbnails, and add/delete pages.
struct PageFlipOverlay: View {
    @ObservedObject var vm: NotebookViewModel
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 18) {
                Text("Pages")
                    .font(.headline)

                HStack(spacing: 28) {
                    flipButton("chevron.left", enabled: vm.canGoBack) {
                        withAnimation(.easeInOut) { vm.goBack() }
                    }
                    Text(vm.pageLabel)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 90)
                    flipButton("chevron.right", enabled: vm.canGoForward) {
                        withAnimation(.easeInOut) { vm.goForward() }
                    }
                }

                thumbnails

                HStack(spacing: 12) {
                    Button {
                        withAnimation(.easeInOut) { vm.addPage() }
                    } label: {
                        Label("Add page", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

                    if vm.pageCount > 1 {
                        Button(role: .destructive) {
                            withAnimation(.easeInOut) { vm.deleteCurrentPage() }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Done") { onDismiss() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: 540)
            .glassPanel(cornerRadius: 24)
            .environment(\.colorScheme, .dark)
            .padding(24)
            .gesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        if value.translation.width < -40 {
                            withAnimation(.easeInOut) { vm.goForward() }
                        } else if value.translation.width > 40 {
                            withAnimation(.easeInOut) { vm.goBack() }
                        }
                    }
            )
        }
        .accessibilityIdentifier("page-flip-overlay")
    }

    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(vm.notebook.pages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        withAnimation(.easeInOut) { vm.go(to: index) }
                    } label: {
                        PageThumbnail(page: page, isCurrent: index == vm.currentIndex, number: index + 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("page-thumbnail-\(index + 1)")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private func flipButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.25))
                .frame(width: 52, height: 52)
                .background(Circle().fill(.primary.opacity(0.08)))
        }
        .disabled(!enabled)
    }
}

private struct PageThumbnail: View {
    let page: NotebookPage
    let isCurrent: Bool
    let number: Int

    private var thumbWidth: CGFloat { 64 }
    private var thumbHeight: CGFloat { 64 * NotebookPageLayout.aspect }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(.white)
                if let image = render() {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: thumbWidth, height: thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isCurrent ? Color.accentColor : Color.black.opacity(0.12),
                        lineWidth: isCurrent ? 3 : 1
                    )
            )
            Text("\(number)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
    }

    private func render() -> UIImage? {
        page.renderThumbnail(maxWidth: 160)
    }
}
