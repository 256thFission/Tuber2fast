import SwiftUI

/// Toggleable horizontal strip of page thumbnails at the top for quick navigation.
struct PageStripView: View {
    @ObservedObject var vm: NotebookViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(vm.notebook.pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            withAnimation(.easeInOut) { vm.go(to: index) }
                        } label: {
                            StripCell(page: page, number: index + 1, isCurrent: index == vm.currentIndex)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityIdentifier("strip-page-\(index + 1)")
                    }

                    Button {
                        withAnimation(.easeInOut) { vm.addPage() }
                    } label: {
                        AddCell()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("strip-add-page")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: vm.currentIndex) { _, index in
                withAnimation { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(vm.currentIndex, anchor: .center) }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
        }
        .accessibilityIdentifier("page-strip")
    }
}

private struct StripCell: View {
    let page: NotebookPage
    let number: Int
    let isCurrent: Bool

    private let w: CGFloat = 40
    private var h: CGFloat { 40 * NotebookPageLayout.aspect }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.white)
                if let image = page.renderThumbnail(maxWidth: 80) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isCurrent ? Color.accentColor : Color.black.opacity(0.12),
                                  lineWidth: isCurrent ? 2.5 : 1)
            )
            Text("\(number)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
    }
}

private struct AddCell: View {
    private let w: CGFloat = 40
    private var h: CGFloat { 40 * NotebookPageLayout.aspect }

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                .foregroundStyle(.secondary)
                .frame(width: w, height: h)
                .overlay(Image(systemName: "plus").font(.caption).foregroundStyle(.secondary))
            Text("Add").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
