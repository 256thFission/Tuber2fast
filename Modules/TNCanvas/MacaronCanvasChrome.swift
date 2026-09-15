import UIKit

// PROTOTYPE: the Macaron identity's share of the canvas runtime. The palette
// is repeated from TuberNotesApp/Macaron.swift because this module cannot
// see the app target.

enum MacaronCanvasChrome {
    static let ink = UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(white: 0x11 / 255, alpha: 1) }
    static let ground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0x1E / 255, alpha: 1) : UIColor(white: 0xED / 255, alpha: 1) }
    static let grid = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0x33 / 255, alpha: 1) : UIColor(white: 0xD6 / 255, alpha: 1) }
    static let paper = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0x2A / 255, alpha: 1) : .white }
    static let strawberry = UIColor(red: 0xFF / 255, green: 0x6A / 255, blue: 0x8C / 255, alpha: 1)
    static let outline: CGFloat = 3
    static let radius: CGFloat = 14
    static let shadow: CGFloat = 5
}

/// The drawn 34pt grid ground behind the paging scroll view.
final class MacaronGridGround: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        backgroundColor = MacaronCanvasChrome.ground
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MacaronGridGround, _) in
            view.backgroundColor = MacaronCanvasChrome.ground
            view.setNeedsDisplay()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setStrokeColor(MacaronCanvasChrome.grid.cgColor)
        cg.setLineWidth(1.5)
        let step: CGFloat = 34
        var x: CGFloat = 0
        while x < bounds.width { cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: bounds.height)); x += step }
        var y: CGFloat = 0
        while y < bounds.height { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: bounds.width, y: y)); y += step }
        cg.strokePath()
    }
}

/// The page's card: white, 3pt outline, 14pt radius, 5pt hard shadow. Sits
/// under the page canvas at the fitted rect, in screen points, so the zoom
/// never thickens it.
final class MacaronPageFrame: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = MacaronCanvasChrome.paper
        layer.cornerRadius = MacaronCanvasChrome.radius
        layer.borderWidth = MacaronCanvasChrome.outline
        layer.shadowOpacity = 1
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: MacaronCanvasChrome.shadow, height: MacaronCanvasChrome.shadow)
        recolor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MacaronPageFrame, _) in view.recolor() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func recolor() {
        layer.borderColor = MacaronCanvasChrome.ink.cgColor
        layer.shadowColor = MacaronCanvasChrome.ink.cgColor
        backgroundColor = MacaronCanvasChrome.paper
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: MacaronCanvasChrome.radius).cgPath
    }
}
