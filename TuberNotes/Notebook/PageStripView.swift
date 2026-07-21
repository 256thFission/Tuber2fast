import SwiftUI

/// Toggleable horizontal strip of page thumbnails at the top for quick
/// navigation. Tap a page to jump to it; press-and-hold then drag to reorder,
/// or drag a lifted page up onto the trash chip to delete it.
struct PageStripView: View {
    @ObservedObject var vm: NotebookViewModel

    // Cell geometry — kept in sync with StripCell (40pt wide) + HStack spacing.
    private let cellWidth: CGFloat = 40
    private let cellSpacing: CGFloat = 10
    private var stride: CGFloat { cellWidth + cellSpacing }
    private let deleteLift: CGFloat = 46   // drag up past this to arm delete

    @State private var draggingID: UUID?
    @State private var pickupIndex: Int?
    @State private var dragOffset: CGSize = .zero
    @State private var willDelete = false

    private var isDragging: Bool { draggingID != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: cellSpacing) {
                    ForEach(Array(vm.notebook.pages.enumerated()), id: \.element.id) { index, page in
                        cell(index: index, page: page)
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
            .scrollDisabled(isDragging)
            .onChange(of: vm.currentIndex) { _, index in
                guard !isDragging else { return }
                withAnimation { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(vm.currentIndex, anchor: .center) }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .top) { trashChip }
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("page-strip")
    }

    // MARK: Cell

    @ViewBuilder
    private func cell(index: Int, page: NotebookPage) -> some View {
        let lifted = draggingID == page.id
        StripCell(page: page, number: index + 1, isCurrent: index == vm.currentIndex)
            .scaleEffect(lifted ? 1.16 : 1)
            .offset(lifted ? dragOffset : .zero)
            .opacity(lifted && willDelete ? 0.7 : 1)
            .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: 8, y: 4)
            .zIndex(lifted ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isDragging else { return }
                withAnimation(.easeInOut) { vm.go(to: index) }
            }
            .gesture(reorderGesture(id: page.id))
            .accessibilityIdentifier("strip-page-\(index + 1)")
            .accessibilityLabel("Page \(index + 1)")
            .accessibilityHint("Double tap to open. Press and hold, then drag to reorder, or drag up to delete.")
    }

    // MARK: Trash affordance

    @ViewBuilder
    private var trashChip: some View {
        if isDragging {
            HStack(spacing: 6) {
                Image(systemName: willDelete ? "trash.fill" : "trash")
                Text(willDelete ? "Release to delete" : "Drag up to delete")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(willDelete ? Color.white : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                (willDelete ? Color.red : Color.black.opacity(0.35)),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .scaleEffect(willDelete ? 1.06 : 1)
            .offset(y: -42)
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Reorder gesture

    private func reorderGesture(id: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }

                if draggingID == nil {
                    draggingID = id
                    pickupIndex = vm.notebook.pages.firstIndex { $0.id == id }
                }

                let tx = drag.translation.width
                let ty = drag.translation.height
                let armDelete = ty < -deleteLift && vm.pageCount > 1

                if armDelete {
                    if !willDelete { withAnimation(.easeOut(duration: 0.15)) { willDelete = true } }
                    dragOffset = CGSize(width: tx, height: ty)
                } else {
                    if willDelete { withAnimation(.easeOut(duration: 0.15)) { willDelete = false } }
                    let start = pickupIndex ?? 0
                    let delta = Int((tx / stride).rounded())
                    let target = max(0, min(start + delta, vm.pageCount - 1))
                    if let current = vm.notebook.pages.firstIndex(where: { $0.id == id }), current != target {
                        withAnimation(.easeInOut(duration: 0.18)) { vm.movePage(from: current, to: target) }
                    }
                    dragOffset = CGSize(width: tx - CGFloat(delta) * stride, height: ty)
                }
            }
            .onEnded { _ in
                if willDelete, vm.pageCount > 1,
                   let idx = vm.notebook.pages.firstIndex(where: { $0.id == id }) {
                    withAnimation(.easeInOut) { vm.deletePage(at: idx) }
                } else {
                    vm.persistNow()
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                    draggingID = nil
                    pickupIndex = nil
                    dragOffset = .zero
                    willDelete = false
                }
            }
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
                    .strokeBorder(isCurrent ? Color.accentColor : Color.white.opacity(0.18),
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
