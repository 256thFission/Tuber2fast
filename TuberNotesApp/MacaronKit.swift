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
    /// The theme every piece of chrome draws itself from.
    var macaron: Theme {
        get { self[MacaronThemeKey.self] }
        set { self[MacaronThemeKey.self] = newValue }
    }
}

/// The measurements the design fixes and no theme may touch.
enum Macaron {
    static let line: CGFloat = 3
    /// The band is 16 in from each edge (`Docs/Design/Macaron.md` §4.2), so
    /// 16 is what a page's margin is, and what separates one block of a page
    /// from the next.
    static let inset: CGFloat = 16
    static let chip: CGFloat = 34
    static let swatch: CGFloat = 18
    static let heldSwatch: CGFloat = 26
    static let shell: CGFloat = 56
    static let shellRadius: CGFloat = 16
    static let shellPadding: CGFloat = 8
    static let chipRadius: CGFloat = 10
    static let swatchRadius: CGFloat = 6
    static let seatRadius: CGFloat = 14
    static let bubbleRadius: CGFloat = 19
    static let divider = CGSize(width: 3, height: 24)
    static let rowGap: CGFloat = 6
    static let columnGap: CGFloat = 8
    static let chipWall: CGFloat = 4
    static let swatchWall: CGFloat = 3
    static let dash: [CGFloat] = [9, 7]
    /// How long a cap with a hold is held before the hold fires. The charge
    /// squash runs exactly this long, so it lands as the hold does.
    static let hold: TimeInterval = 0.45

    /// Lilita One for labels and callsigns, Nunito for body. Neither is in
    /// the repository, so the build stands them in with the system's rounded
    /// face at the weights the mocks read at.
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func body(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func title(_ size: TypeScale) -> Font { title(size.rawValue) }
    static func body(_ size: TypeScale) -> Font { body(size.rawValue) }
}

/// Every size the chrome sets a word at, smallest first. A size is one of
/// these in either face; a size between two of them is a size nobody chose.
enum TypeScale: CGFloat {
    case badge = 9
    case detail = 10
    case caption = 11
    case small = 12
    case text = 13
    case label = 14
    case button = 15
    case instrument = 16
    case headline = 17
    case large = 22
    case display = 28
}

/// The curves the chrome moves on, each one of Macaron.md §7's seven, and
/// the cross-fade Reduce Motion collapses them to.
enum MacaronCurve {
    static let outQuint = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.06)
    static let outBack = Animation.timingCurve(0.34, 1.9, 0.64, 1, duration: 0.13)
    static let settle = Animation.interpolatingSpring(mass: 1, stiffness: 420, damping: 22)
    static let snap = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.34)
    /// In-out-sine over the hold.
    static let charge = Animation.timingCurve(0.37, 0, 0.63, 1, duration: Macaron.hold)
    static let reduced = Animation.easeInOut(duration: 0.12)
}

/// A keycap's face without its tap: the fill, its derived outline, and the
/// wall the cap stands on, in the outline colour and with no lip. `Keycap`
/// draws with it, and so does a cap whose tap belongs to something else: a
/// menu, a share link, or a listing that decides what a tap on a cell means.
///
/// It draws behind content already at the cap's size, and leaves the room
/// under the cap for the wall to its caller.
struct KeycapFace: ViewModifier {
    let fill: RGBA8
    var radius = Macaron.chipRadius
    /// How far the cap sits below its rest: zero standing, the wall's
    /// height sunk, negative thrown.
    let capOffset: CGFloat
    /// How far the wall's top sits below the cap's.
    let wallOffset: CGFloat
    var wallIsVisible = true

    @Environment(\.macaron) private var theme

    func body(content: Content) -> some View {
        let outline = theme.outline(of: fill)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .foregroundStyle(outline.color)
            .background { shape.fill(fill.color) }
            .overlay { shape.strokeBorder(outline.color, lineWidth: Macaron.line) }
            .background {
                shape.fill(outline.color)
                    .offset(y: wallOffset)
                    .opacity(wallIsVisible ? 1 : 0)
            }
            .offset(y: capOffset)
    }
}

extension KeycapFace {
    /// A cap at rest, standing or sunk. Only `Keycap`'s own trampoline
    /// needs the moments in between.
    init(fill: RGBA8, sunk: Bool) {
        self.init(
            fill: fill,
            capOffset: sunk ? Macaron.chipWall : 0,
            wallOffset: sunk ? 0 : Macaron.chipWall
        )
    }
}

/// The atom. Everything you can press in this design is one of these.
///
/// A cap standing on a wall in its own outline colour, with no lip on the
/// wall and no ring anywhere. Held drops the wall and keeps none of it: that
/// is the whole of the selected state.
struct Keycap<Label: View>: View {
    let fill: RGBA8
    /// A width of zero means the label decides, which is how a cap with a
    /// word on it gets to be as wide as the word.
    var size = CGSize(width: Macaron.chip, height: Macaron.chip)
    var radius = Macaron.chipRadius
    var wall = Macaron.chipWall
    var isHeld = false
    /// A cap the tool in hand has no use for. Dimmed and inert, never
    /// removed: the run's order is fixed and a gap in it would be read as a
    /// different bar.
    var isEnabled = true
    /// What VoiceOver calls a cap whose label is only a symbol. A cap with a
    /// word on it is called by the word.
    var name: String?
    /// A second thing the cap does when held for `Macaron.hold` rather than
    /// tapped. While the hold charges, the cap squashes toward 88%.
    var hold: (() -> Void)?
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0
    @State private var trampoline = 0
    @State private var isCharging = false

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
        label()
            .frame(width: size.width > 0 ? size.width : nil, height: size.height)
            .modifier(KeycapFace(
                fill: fill,
                radius: radius,
                capOffset: capOffset,
                wallOffset: wallHeight - capOffset,
                wallIsVisible: wallIsVisible
            ))
            .frame(height: size.height + wall, alignment: .top)
        .scaleEffect(
            x: squash.width,
            y: squash.height * (trampoline == 1 ? 0.86 : 1),
            anchor: .bottom
        )
        .scaleEffect(isCharging ? 0.88 : 1, anchor: .bottom)
        .animation(isCharging ? MacaronCurve.charge : MacaronCurve.settle, value: isCharging)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(.rect)
        .onTapGesture { if isEnabled { press() } }
        .modifier(HoldGesture(hold: hold, isEnabled: isEnabled, isCharging: $isCharging, squashes: !reduceMotion))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(name ?? ""), isEnabled: name != nil)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if isEnabled { press() } }
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

    /// The press acts on lift, and the squash plays after it. An action
    /// held back for the animation lands on whatever the tool has become
    /// meanwhile, and the editor traps on a request the tool cannot take.
    private func press() {
        action()
        guard !reduceMotion else { return }
        withAnimation(MacaronCurve.outQuint) { phase = 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(MacaronCurve.outBack) { phase = 2 }
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(MacaronCurve.settle) { phase = 0 }
        }
    }
}

/// A cap's hold, on the caps that have one. Every other cap takes no long
/// press, so a cap held a long time still taps on lift.
///
/// Whether the gesture is there is fixed by the call site, and `isEnabled`
/// only gates it. A branch that followed `isEnabled` would rebuild every
/// swatch each time the hand moved to or from a tool with no colour, and
/// cross-fade the held one's trampoline.
private struct HoldGesture: ViewModifier {
    let hold: (() -> Void)?
    let isEnabled: Bool
    @Binding var isCharging: Bool
    let squashes: Bool

    func body(content: Content) -> some View {
        if let hold {
            content.onLongPressGesture(minimumDuration: Macaron.hold) {
                isCharging = false
                if isEnabled { hold() }
            } onPressingChanged: { pressing in
                isCharging = pressing && squashes && isEnabled
            }
        } else {
            content
        }
    }
}

extension Keycap where Label == Color {
    init(
        fill: RGBA8,
        size: CGSize = CGSize(width: Macaron.chip, height: Macaron.chip),
        radius: CGFloat = Macaron.chipRadius,
        wall: CGFloat = Macaron.chipWall,
        isHeld: Bool = false,
        isEnabled: Bool = true,
        hold: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            fill: fill, size: size, radius: radius, wall: wall, isHeld: isHeld,
            isEnabled: isEnabled, hold: hold, action: action, label: { Color.clear }
        )
    }
}

extension Keycap where Label == KeycapSymbol {
    /// A cap with only a symbol on it. The name is not optional: a symbol is
    /// not something VoiceOver can read out.
    init(
        _ name: String,
        systemImage: String,
        symbolSize: TypeScale = .label,
        fill: RGBA8,
        isHeld: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.init(
            fill: fill, isHeld: isHeld, isEnabled: isEnabled, name: name, action: action,
            label: { KeycapSymbol(systemImage: systemImage, size: symbolSize) }
        )
    }
}

/// The one thing on a cap that has only a symbol on it.
struct KeycapSymbol: View {
    let systemImage: String
    let size: TypeScale

    var body: some View {
        Image(systemName: systemImage).font(Macaron.body(size))
    }
}

/// The shell every floating piece of chrome sits in: flat, never a keycap,
/// and hugging its contents at 8 points of padding.
struct MacaronShell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @Environment(\.macaron) private var theme

    var body: some View {
        content()
            .padding(Macaron.shellPadding)
            .background {
                RoundedRectangle(cornerRadius: Macaron.shellRadius, style: .continuous)
                    .fill(theme.chrome.color)
                    .overlay {
                        RoundedRectangle(cornerRadius: Macaron.shellRadius, style: .continuous)
                            .strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
                    }
            }
    }
}

/// A chip with no wall, for what is not a key: a handle, a count, a way out
/// of the notebook. A wall would say "press me" about something that is
/// dragged, or that leaves rather than acts.
///
/// The tap is the caller's, because it may be a button, a menu or a drag,
/// and a caller that disables itself dims the chip.
struct FlatChip<Label: View>: View {
    /// The chrome when nil.
    var fill: RGBA8?
    var isRound = false
    /// Nil means the label decides, which is how a chip with a word on it
    /// gets to be as wide as the word.
    var width: CGFloat? = Macaron.chip
    @ViewBuilder var label: () -> Label

    @Environment(\.macaron) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let fill = fill ?? theme.chrome
        let outline = theme.outline(of: fill)
        label()
            .foregroundStyle(outline.color)
            .frame(width: width, height: Macaron.chip)
            .background {
                if isRound {
                    face(Circle(), fill, outline)
                } else {
                    face(RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous), fill, outline)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
    }

    private func face(_ shape: some InsettableShape, _ fill: RGBA8, _ outline: RGBA8) -> some View {
        shape.fill(fill.color)
            .overlay { shape.strokeBorder(outline.color, lineWidth: Macaron.line) }
    }
}

/// A speech bubble on a tail, pointing at the control that opened it. Flat:
/// it is a transient, not a keyboard, so nothing in it stands on a wall.
///
/// The tail is the popover's own arrow. The popover's background is painted
/// in the chrome, so the system's material shows nowhere: not in the tail,
/// and not in the margin the system keeps around the bubble.
struct MacaronBubble<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @Environment(\.macaron) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Macaron.bubbleRadius, style: .continuous)
        content()
            .padding(Macaron.shellPadding)
            .background { shape.fill(theme.chrome.color) }
            .overlay { shape.strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line) }
            .presentationBackground(theme.chrome.color)
            .presentationCompactAdaptation(.popover)
    }
}

extension View {
    /// Shows a `MacaronBubble` off this view. The one way a bubble is shown,
    /// so no view draws a popover of its own.
    func macaronBubble<Content: View>(
        isPresented: Binding<Bool>,
        attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: Edge? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        popover(isPresented: isPresented, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) {
            MacaronBubble(content: content)
        }
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

/// A sheet's chrome. `Docs/Design/Macaron.md` names no sheet, so this is
/// derived from the seat in its §4.3, which is the one panel it does name:
/// an accent title strip with a close control, a flat body, and a 3pt
/// derived outline.
///
/// It fills its presentation rather than floating inside it, so the sheet's
/// own corners are the only corners and no second border appears.
struct MacaronPanel<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.macaron) private var theme

    static var strip: CGFloat { 44 }
    /// A fitted panel hugs its content, and a browsing panel holding one
    /// item would hug down to a strip. This is the narrowest a panel is
    /// allowed to get.
    static var minWidth: CGFloat { 480 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                theme.accent.color
                HStack(spacing: 8) {
                    Text(title)
                        .font(Macaron.title(17))
                        .foregroundStyle(theme.outline(of: theme.accent).color)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(Macaron.body(15))
                            .foregroundStyle(theme.outline(of: theme.accent).color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 14)
            }
            .frame(height: Self.strip)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content()
                }
                .frame(minWidth: Self.minWidth, maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .background(theme.chrome.color)
        .presentationBackground(theme.chrome.color)
        // A panel is as tall as what is in it. A fixed card with a field of
        // empty chrome under the last control reads as a panel that failed
        // to load.
        .presentationSizing(.fitted)
        .environment(\.macaron, theme)
    }
}

/// A keycap with a word on it. The same atom the bar's chips are; only the
/// width and the label differ, so a panel's buttons press like the bar's.
///
/// The fill says what the button is. Chrome for an ordinary action, the
/// accent for the one action the panel exists to perform, the secondary for
/// a second-rank one, and the ground for a control that is not a peer of the
/// others — the band's overflow chip sets that last precedent. Nothing here
/// gets a colour the six tokens do not already hold, so a destructive action
/// is an ordinary cap whose word says what it does.
struct MacaronButton: View {
    let title: String
    var icon: String?
    var fill: RGBA8?
    var isHeld = false
    var isEnabled = true
    var action: () -> Void

    @Environment(\.macaron) private var theme

    var body: some View {
        Keycap(
            fill: fill ?? theme.chrome,
            size: CGSize(width: 0, height: Macaron.chip + 6),
            isHeld: isHeld,
            isEnabled: isEnabled,
            action: action
        ) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(Macaron.body(14))
                }
                Text(title).font(Macaron.title(15))
            }
            .padding(.horizontal, 14)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// A section's name over the controls it covers. A readout, so it is flat.
struct MacaronHeading: View {
    let text: String
    @Environment(\.macaron) private var theme

    var body: some View {
        Text(text.uppercased())
            .font(Macaron.body(11))
            .tracking(1.2)
            .foregroundStyle(theme.outline(of: theme.chrome).color)
    }
}

/// A line of writing the person does rather than presses. Flat, and in the
/// ground, which is the one token that reads as a hole in the chrome rather
/// than a surface standing on it.
struct MacaronField: View {
    let prompt: String
    @Binding var text: String

    @Environment(\.macaron) private var theme

    var body: some View {
        TextField(prompt, text: $text)
            .font(Macaron.body(15))
            .foregroundStyle(theme.ink.color)
            .tint(theme.accent.color)
            .padding(.horizontal, 10)
            .frame(height: Macaron.chip)
            .background {
                RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                    .fill(theme.ground.color)
                    .overlay {
                        RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                            .strokeBorder(theme.outline(of: theme.ground).color, lineWidth: Macaron.line)
                    }
            }
    }
}

/// A sentence the sheet says about a choice. A readout, so it is flat.
struct MacaronNote: View {
    let text: String

    @Environment(\.macaron) private var theme

    var body: some View {
        Text(text)
            .font(Macaron.body(11))
            .foregroundStyle(theme.outline(of: theme.chrome).color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A run of caps. Each cap is as wide as its word, neighbours sit one column
/// gap apart, and a line that will not fit the width wraps to the next one a
/// row gap down. A fixed column grid would centre every word in a column of
/// the widest word's width, which reads as caps floating at unrelated
/// distances rather than as one run.
struct MacaronRun: Layout {
    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(of sizes: [CGSize], within limit: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for (index, size) in sizes.enumerated() {
            if !line.indices.isEmpty, line.width + Macaron.columnGap + size.width > limit {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + Macaron.columnGap + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let laid = lines(of: sizes, within: proposal.width ?? .infinity)
        let gaps = Macaron.rowGap * CGFloat(max(laid.count - 1, 0))
        return CGSize(
            width: laid.map(\.width).max() ?? 0,
            height: laid.map(\.height).reduce(0, +) + gaps
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in lines(of: sizes, within: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + Macaron.columnGap
            }
            y += line.height + Macaron.rowGap
        }
    }
}
