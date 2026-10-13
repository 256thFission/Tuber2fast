import SwiftUI
import TNEditor
import TNModel

/// The seat: a panel with one tenant in it, docked to the right edge or
/// floating over the ground.
///
/// Flat everywhere. The body is the derived seat colour, the title strip is
/// the accent, and the badges are readouts, so nothing in here stands on a
/// wall. Docked it drops its right border and right radius and casts no
/// shadow, because it is not floating over anything on that side.
struct MacaronSeat: View {
    let editor: EditorViewModel
    @Binding var isOpen: Bool

    @Environment(\.macaron) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFloating: Bool
    @State private var committed = CGSize(width: 250, height: 300)
    @State private var requested: CGSize?
    @State private var drift: CGSize = .zero
    @State private var place: CGSize = .zero

    private static let strip: CGFloat = 34

    init(editor: EditorViewModel, isOpen: Binding<Bool>) {
        self.editor = editor
        _isOpen = isOpen
        _isFloating = State(initialValue: LaunchHooks.arguments.contains("-TNSeatFloating"))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dashed and accent-pale: the size being asked for has no body
            // yet, and will not have one until the finger lifts.
            if let requested {
                RoundedRectangle(cornerRadius: Macaron.seatRadius, style: .continuous)
                    .strokeBorder(
                        theme.accent.color.opacity(0.55),
                        style: StrokeStyle(lineWidth: Macaron.line, dash: Macaron.dash)
                    )
                    .frame(width: requested.width, height: requested.height)
            }
            body(of: committed)
        }
        // Docked, the right line is pushed off the edge rather than drawn:
        // there is nothing on that side for it to separate the seat from.
        .offset(
            x: place.width + drift.width + (isFloating ? 0 : Macaron.line),
            y: place.height + drift.height
        )
        .shadow(
            color: isFloating ? theme.outline(of: theme.ground).color : .clear,
            radius: 0, x: 0, y: 6
        )
    }

    private func body(of size: CGSize) -> some View {
        VStack(spacing: 0) {
            title
            tenant
        }
        .frame(width: size.width, height: size.height)
        .background(theme.seatBody.color)
        .clipShape(shell)
        .overlay { shell.strokeBorder(theme.outline(of: theme.seatBody).color, lineWidth: Macaron.line) }
        .overlay(alignment: .bottomTrailing) { grip }
    }

    /// Docked, the right edge is the iPad's edge: no border and no radius
    /// on a side there is nothing on.
    private var shell: some InsettableShape {
        UnevenRoundedRectangle(
            topLeadingRadius: Macaron.seatRadius,
            bottomLeadingRadius: Macaron.seatRadius,
            bottomTrailingRadius: isFloating ? Macaron.seatRadius : 0,
            topTrailingRadius: isFloating ? Macaron.seatRadius : 0,
            style: .continuous
        )
    }

    private var title: some View {
        ZStack {
            theme.accent.color
            HStack(spacing: 8) {
                // The grab bar appears only once the seat is off the edge:
                // a docked seat has nowhere to be dragged to.
                if isFloating {
                    Image(systemName: "line.3.horizontal")
                        .font(Macaron.body(12))
                        .foregroundStyle(theme.outline(of: theme.accent).color)
                }
                Text("Pages")
                    .font(Macaron.title(14))
                    .foregroundStyle(theme.outline(of: theme.accent).color)
                Spacer()
                badge
                Button { isOpen = false } label: {
                    Image(systemName: "xmark")
                        .font(Macaron.body(13))
                        .foregroundStyle(theme.outline(of: theme.accent).color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close the seat")
            }
            .padding(.horizontal, 10)
        }
        .frame(height: Self.strip)
        .contentShape(.rect)
        .gesture(carry)
    }

    /// A readout, so it is flat.
    @ViewBuilder private var badge: some View {
        if editor.isSaving {
            Text(verbatim: "SAVING")
                .font(Macaron.body(9))
                .foregroundStyle(theme.outline(of: theme.accent).color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(theme.outline(of: theme.accent).color, lineWidth: 1.5)
                }
        }
    }

    /// One tenant. The pages, which is the thing the band's readout counts.
    private var tenant: some View {
        ScrollView {
            VStack(spacing: Macaron.rowGap) {
                ForEach(Array(editor.navigatorPages.enumerated()), id: \.offset) { index, page in
                    Button { editor.scroll(toPageIndex: index) } label: {
                        HStack {
                            Text(verbatim: "\(index + 1)")
                                .font(Macaron.title(13))
                            if let mark = page.bookmark {
                                Text(mark).font(Macaron.body(12)).lineLimit(1)
                            }
                            Spacer()
                        }
                        .foregroundStyle(theme.outline(of: theme.seatBody).color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background {
                            RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                                .fill(page.isCurrent ? theme.paper.color : .clear)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    /// Orange, and it squashes like any held cap while it travels with the
    /// dashed target.
    private var grip: some View {
        RoundedRectangle(cornerRadius: Macaron.swatchRadius, style: .continuous)
            .fill(theme.secondary.color)
            .overlay {
                RoundedRectangle(cornerRadius: Macaron.swatchRadius, style: .continuous)
                    .strokeBorder(theme.outline(of: theme.secondary).color, lineWidth: Macaron.line)
            }
            .frame(width: Macaron.swatch, height: Macaron.swatch)
            .scaleEffect(x: requested == nil ? 1 : 1.14, y: requested == nil ? 1 : 0.82)
            .padding(6)
            .offset(
                x: (requested?.width ?? committed.width) - committed.width,
                y: (requested?.height ?? committed.height) - committed.height
            )
            .gesture(resize)
            .accessibilityLabel("Resize the seat")
    }

    // MARK: Gestures

    /// Dragging the strip lifts the seat off the edge. It lands where it is
    /// let go of; the eight snap points belong to the writing bar.
    private var carry: some Gesture {
        DragGesture()
            .onChanged { drift = $0.translation }
            .onEnded { value in
                drift = .zero
                place.width += value.translation.width
                place.height += value.translation.height
                withAnimation(reduceMotion ? MacaronCurve.reduced : MacaronCurve.settle) {
                    isFloating = place != .zero
                }
            }
    }

    /// The body holds its committed frame while the dash runs ahead, and
    /// takes the new frame in one step on release.
    private var resize: some Gesture {
        DragGesture()
            .onChanged { value in
                requested = CGSize(
                    width: max(180, committed.width + value.translation.width),
                    height: max(160, committed.height + value.translation.height)
                )
            }
            .onEnded { _ in
                if let requested { committed = requested }
                self.requested = nil
            }
    }
}
