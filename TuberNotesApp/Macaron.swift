import SwiftUI
import UIKit

// PROTOTYPE: the Macaron identity skin. Throwaway; nothing here is
// contract-clean. See Artifacts/notebook-ux/MacaronKit.dc.html.

enum Macaron {
    static let inkUI = UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1) }
    static let groundUI = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0x1E / 255, alpha: 1) : UIColor(white: 0xED / 255, alpha: 1) }
    static let gridUI = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0x33 / 255, alpha: 1) : UIColor(white: 0xD6 / 255, alpha: 1) }
    static let cardUI = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0x2A / 255, alpha: 1) : .white }

    static var ink: Color { Color(uiColor: inkUI) }
    static var ground: Color { Color(uiColor: groundUI) }
    static var card: Color { Color(uiColor: cardUI) }
    static let strawberry = Color(red: 0xFF / 255, green: 0x6A / 255, blue: 0x8C / 255)
    static let vanilla = Color(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x47 / 255)

    static let outline: CGFloat = 3
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .rounded) }
}

/// A card: white fill, 3pt outline, optional hard offset shadow.
struct MacaronCard: ViewModifier {
    var fill: Color = Macaron.card
    var radius: CGFloat = 10
    var shadow: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    if shadow > 0 {
                        RoundedRectangle(cornerRadius: radius).fill(Macaron.ink).offset(x: shadow, y: shadow)
                    }
                    RoundedRectangle(cornerRadius: radius).fill(fill)
                    RoundedRectangle(cornerRadius: radius).strokeBorder(Macaron.ink, lineWidth: Macaron.outline)
                }
            )
    }
}

extension View {
    func macaronCard(fill: Color = Macaron.card, radius: CGFloat = 10, shadow: CGFloat = 0) -> some View {
        modifier(MacaronCard(fill: fill, radius: radius, shadow: shadow))
    }
}

/// Every control is a chip. Held: solid accent, white glyph. Nothing tints.
struct MacaronChipStyle: ButtonStyle {
    var isOn = false
    var fill: Color? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let held = isOn || configuration.isPressed
        configuration.label
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .frame(minWidth: 34, minHeight: 34)
            .padding(.horizontal, 4)
            .foregroundStyle(held ? .white : Macaron.ink)
            .macaronCard(fill: held ? Macaron.strawberry : (fill ?? Macaron.card), radius: 10)
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// A 3pt black bar between groups. Not a hairline.
struct MacaronBar: View {
    var body: some View {
        Rectangle().fill(Macaron.ink).frame(width: Macaron.outline, height: 30)
    }
}

/// The drawn 34pt grid ground.
final class MacaronGridView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        backgroundColor = Macaron.groundUI
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MacaronGridView, _) in
            view.backgroundColor = Macaron.groundUI
            view.setNeedsDisplay()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setStrokeColor(Macaron.gridUI.cgColor)
        cg.setLineWidth(1.5)
        let step: CGFloat = 34
        var x: CGFloat = 0
        while x < bounds.width { cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: bounds.height)); x += step }
        var y: CGFloat = 0
        while y < bounds.height { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: bounds.width, y: y)); y += step }
        cg.strokePath()
    }
}

/// Reskins the canvas runtime's view tree from outside, so `TNCanvas` stays
/// untouched: the grey surrounds go clear over a grid ground, and each page
/// mirror gets the 3pt outline and hard shadow. Re-swept on a timer because
/// page views come and go with the window.
@MainActor
final class MacaronCanvasSkin {
    private var timer: Timer?
    private weak var root: UIView?
    private var grid: MacaronGridView?

    func attach(to root: UIView) {
        self.root = root
        sweep()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    private func sweep() {
        guard let root else { return }
        if grid == nil {
            let g = MacaronGridView(frame: root.bounds)
            g.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.insertSubview(g, at: 0)
            grid = g
        }
        walk(root)
    }

    private func walk(_ view: UIView) {
        if view.backgroundColor == .systemGray5 { view.backgroundColor = .clear }
        let name = String(describing: type(of: view))
        if name.contains("PageMirrorView"), view.subviews.first?.backgroundColor == .white {
            frame(view)
        }
        if name.contains("PagePlaceholderView") {
            view.layer.borderColor = Macaron.inkUI.cgColor
            view.layer.borderWidth = Macaron.outline
            view.layer.cornerRadius = 14
        }
        for sub in view.subviews { walk(sub) }
    }

    /// The mirror is scaled by the zoom, so the outline and shadow scale with
    /// it. At the opening fit that is the spec; zoomed in they thicken.
    private func frame(_ mirror: UIView) {
        let layer = mirror.layer
        layer.borderColor = Macaron.inkUI.cgColor
        layer.borderWidth = Macaron.outline
        layer.cornerRadius = 14
        layer.shadowColor = Macaron.inkUI.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 5, height: 5)
        layer.shadowPath = UIBezierPath(roundedRect: mirror.bounds, cornerRadius: 14).cgPath
        mirror.subviews.first?.layer.cornerRadius = 14
        mirror.subviews.first?.clipsToBounds = true
    }
}

/// What the workspace band's Insert and Export chips do for the open editor.
struct MacaronBandActions {
    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let symbol: String
        let action: () -> Void
    }
    var insert: [Row]
    var export: () -> Void
}

/// The grid ground as a SwiftUI background, for sheets and the library.
struct MacaronGround: View {
    var body: some View {
        Canvas { cg, size in
            let step: CGFloat = 34
            var path = Path()
            var x: CGFloat = 0
            while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            cg.stroke(path, with: .color(Color(uiColor: Macaron.gridUI)), lineWidth: 1.5)
        }
        .background(Macaron.ground)
        .ignoresSafeArea()
    }
}

/// A fat rounded header, the way every sheet and section is titled.
struct MacaronHeader: View {
    let text: String
    var size: CGFloat = 22
    init(_ text: String, size: CGFloat = 22) { self.text = text; self.size = size }
    var body: some View {
        Text(text.uppercased())
            .font(Macaron.display(size))
            .foregroundStyle(Macaron.ink)
    }
}

/// A section card with a hard shadow: white, 3pt outline, 14pt radius.
extension View {
    func macaronSection(padding: CGFloat = 16, shadow: CGFloat = 5) -> some View {
        self.padding(padding).macaronCard(fill: Macaron.card, radius: 14, shadow: shadow)
    }
}

/// A text-bearing chip (a button with a word on it), outlined, held = strawberry.
struct MacaronWordChipStyle: ButtonStyle {
    var isOn = false
    var fill: Color? = nil
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let held = isOn || configuration.isPressed
        configuration.label
            .font(Macaron.display(14))
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .foregroundStyle(held ? .white : Macaron.ink)
            .macaronCard(fill: held ? Macaron.strawberry : (fill ?? Macaron.card), radius: 10)
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// A row of outlined chips standing in for a segmented picker: one held.
struct MacaronSegments<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.0) { option in
                Button(option.1) { selection = option.0 }
                    .buttonStyle(MacaronWordChipStyle(isOn: selection == option.0))
            }
        }
    }
}

/// A hard-shadowed selection ring around a swatch or thumbnail.
struct MacaronSelectedFrame: ViewModifier {
    let isSelected: Bool
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(Macaron.ink).offset(x: isSelected ? 4 : 0, y: isSelected ? 4 : 0))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(isSelected ? Macaron.strawberry : Macaron.ink, lineWidth: Macaron.outline))
    }
}

/// Text on any Macaron surface reads in ink, not the system label colour.
struct MacaronSheetChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Macaron.ink)
            .tint(Macaron.strawberry)
            .scrollContentBackground(.hidden)
            .background(MacaronGround())
    }
}

extension View {
    func macaronSheet() -> some View { modifier(MacaronSheetChrome()) }
}
