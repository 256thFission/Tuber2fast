import SwiftUI
import TNModel
import UIKit

extension RGBA8 {
    var color: Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

private struct MacaronThemeKey: EnvironmentKey {
    static let defaultValue = Theme.macaron
}

extension EnvironmentValues {
    /// The six hexes every piece of chrome draws itself from.
    var macaron: Theme {
        get { self[MacaronThemeKey.self] }
        set { self[MacaronThemeKey.self] = newValue }
    }
}

/// The measurements the design fixes and no theme may touch.
enum Macaron {
    static let line: CGFloat = 3
    static let chip: CGFloat = 34
    static let swatch: CGFloat = 18
    static let heldSwatch: CGFloat = 26
    static let shell: CGFloat = 56
    static let shellRadius: CGFloat = 16
    static let shellPadding: CGFloat = 8
    static let chipRadius: CGFloat = 10
    static let swatchRadius: CGFloat = 6
    static let seatRadius: CGFloat = 14
    static let divider = CGSize(width: 3, height: 24)
    static let rowGap: CGFloat = 6
    static let columnGap: CGFloat = 8
    static let chipWall: CGFloat = 4
    static let swatchWall: CGFloat = 3
    static let dash: [CGFloat] = [9, 7]

    /// Lilita One for labels and callsigns, Nunito for body. Neither is in
    /// the repository, so the build stands them in with the system's rounded
    /// face at the weights the mocks read at.
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func body(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

/// The three curves a press is made of.
enum MacaronCurve {
    static let outQuint = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.06)
    static let outBack = Animation.timingCurve(0.34, 1.9, 0.64, 1, duration: 0.13)
    static let settle = Animation.interpolatingSpring(mass: 1, stiffness: 420, damping: 22)
    static let snap = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.34)
    static let reduced = Animation.easeInOut(duration: 0.12)
}

/// The atom. Everything you can press in this design is one of these.
///
/// A cap standing on a wall in its own outline colour, with no lip on the
/// wall and no ring anywhere. Held drops the wall and keeps none of it: that
/// is the whole of the selected state.
struct Keycap<Label: View>: View {
    let fill: RGBA8
    var size = CGSize(width: Macaron.chip, height: Macaron.chip)
    var radius = Macaron.chipRadius
    var wall = Macaron.chipWall
    var isHeld = false
    /// A cap the tool in hand has no use for. Dimmed and inert, never
    /// removed: the run's order is fixed and a gap in it would be read as a
    /// different bar.
    var isEnabled = true
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @Environment(\.macaron) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0
    @State private var trampoline = 0

    private var outline: RGBA8 { theme.outline(of: fill) }

    /// A tool becoming held throws the cap above its rest for a moment,
    /// leaving a taller wall under it, and lands sunk.
    private var wallHeight: CGFloat { trampoline == 2 ? 11 : wall }
    private var wallIsVisible: Bool { trampoline == 2 || !isHeld }
    private var capOffset: CGFloat {
        if trampoline == 2 { return -7 }
        return isHeld ? wall : 0
    }

    /// Volume conserved: 1.14 × 0.82, then 0.86 × 1.24, then rest.
    private var squash: CGSize {
        switch phase {
        case 1: CGSize(width: 1.14, height: 0.82)
        case 2: CGSize(width: 0.86, height: 1.24)
        default: CGSize(width: 1, height: 1)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(outline.color)
                .frame(width: size.width, height: size.height)
                .offset(y: wallHeight)
                .opacity(wallIsVisible ? 1 : 0)

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill.color)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(outline.color, lineWidth: Macaron.line)
                }
                .frame(width: size.width, height: size.height)
                .overlay { label().foregroundStyle(outline.color) }
                .offset(y: capOffset)
        }
        .frame(width: size.width, height: size.height + wall)
        .scaleEffect(
            x: squash.width,
            y: squash.height * (trampoline == 1 ? 0.86 : 1),
            anchor: .bottom
        )
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(.rect)
        .onTapGesture { if isEnabled { press() } }
        .animation(reduceMotion ? MacaronCurve.reduced : MacaronCurve.settle, value: isHeld)
        .onChange(of: isHeld) { _, held in if held { trampolineIn() } }
    }

    /// Squash, throw, settle sunk. Only on the way in: letting go of a tool
    /// is the other tool's arrival, and two dialects at once is noise.
    private func trampolineIn() {
        guard !reduceMotion else { return }
        withAnimation(MacaronCurve.outQuint) { trampoline = 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(MacaronCurve.outBack) { trampoline = 2 }
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(MacaronCurve.settle) { trampoline = 0 }
        }
    }

    /// The fill commits on the stretch, not on contact.
    private func press() {
        guard !reduceMotion else {
            action()
            return
        }
        withAnimation(MacaronCurve.outQuint) { phase = 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(MacaronCurve.outBack) { phase = 2 }
            action()
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(MacaronCurve.settle) { phase = 0 }
        }
    }
}

extension Keycap where Label == EmptyView {
    init(
        fill: RGBA8,
        size: CGSize = CGSize(width: Macaron.chip, height: Macaron.chip),
        radius: CGFloat = Macaron.chipRadius,
        wall: CGFloat = Macaron.chipWall,
        isHeld: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.init(
            fill: fill, size: size, radius: radius, wall: wall, isHeld: isHeld,
            isEnabled: isEnabled, action: action, label: { EmptyView() }
        )
    }
}

/// The shell every floating piece of chrome sits in: flat, never a keycap,
/// and hugging its contents at 8 points of padding.
struct MacaronShell<Content: View>: View {
    var radius = Macaron.shellRadius
    /// Off by default: the writing bar's shell is flat. Only a thing that
    /// floats free of an edge — the seat — takes the hard offset.
    var floats = false
    @ViewBuilder var content: () -> Content

    @Environment(\.macaron) private var theme

    var body: some View {
        content()
            .padding(Macaron.shellPadding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme.chrome.color)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
                    }
            }
            // The hard zero-blur offset the earlier kit gave floating things.
            // The document names no colour for it, so it takes the ground's
            // own outline: nothing is black but ink, and the chrome's outline
            // here would read as a second border rather than as a shadow.
            .shadow(
                color: floats ? theme.outline(of: theme.ground).color : .clear,
                radius: 0, x: 0, y: 6
            )
    }
}

/// The 3 × 24 bar between runs on the writing bar. A readout, so it is flat.
struct MacaronDivider: View {
    var vertical = false
    @Environment(\.macaron) private var theme

    var body: some View {
        Capsule(style: .continuous)
            .fill(theme.outline(of: theme.chrome).color)
            .frame(
                width: vertical ? Macaron.divider.height : Macaron.divider.width,
                height: vertical ? Macaron.divider.width : Macaron.divider.height
            )
    }
}
