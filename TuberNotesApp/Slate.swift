import SwiftUI
import UIKit

/// PROTOTYPE: the Slate identity's palette. Throwaway.
enum Slate {
    static let ground = Color(red: 0x2F / 255, green: 0x4A / 255, blue: 0x3E / 255)
    static let groundUI = UIColor(red: 0x2F / 255, green: 0x4A / 255, blue: 0x3E / 255, alpha: 1)
    static let band = Color(red: 0x26 / 255, green: 0x39 / 255, blue: 0x2F / 255)
    static let paperUI = UIColor(red: 0xFB / 255, green: 0xF8 / 255, blue: 0xF0 / 255, alpha: 1)
    static let chalk = Color(red: 0xF1 / 255, green: 0xEB / 255, blue: 0xD8 / 255)
    static let chalkDim = chalk.opacity(0.65)
    static let yellow = Color(red: 0xF5 / 255, green: 0xD7 / 255, blue: 0x7E / 255)
    static let railTop = Color(red: 0xB0 / 255, green: 0x8A / 255, blue: 0x57 / 255)
    static let railBottom = Color(red: 0x8E / 255, green: 0x6B / 255, blue: 0x3E / 255)

    static let label = Font.system(.callout, design: .rounded)

    /// The wooden rail under the band.
    static var rail: some View {
        LinearGradient(colors: [railTop, railBottom], startPoint: .top, endPoint: .bottom)
            .frame(height: 14)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 3)
            .zIndex(1)
    }

    /// A dashed chalk line between groups on the strip.
    static var separator: some View {
        Path { p in
            p.move(to: CGPoint(x: 1, y: 0))
            p.addLine(to: CGPoint(x: 1, y: 28))
        }
        .stroke(chalk.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
        .frame(width: 2, height: 28)
    }

    /// The ground behind the pages, the paper's colour, and the shadow the
    /// page casts. Done from outside the canvas by walking its views: the app
    /// cannot name TNCanvas, and this is a skin, not a runtime change. Pages
    /// are made lazily, so the walk repeats on a timer.
    @MainActor static func paint(_ root: UIView) {
        if root.backgroundColor == .systemGray5 || root.backgroundColor == .systemGray6 {
            root.backgroundColor = groundUI
        }
        if root is UIImageView, root.backgroundColor == .white {
            root.backgroundColor = paperUI
            if let paper = root.superview, paper.layer.shadowOpacity == 0 {
                paper.layer.shadowColor = UIColor.black.cgColor
                paper.layer.shadowOpacity = 0.45
                paper.layer.shadowOffset = CGSize(width: 0, height: 6)
                paper.layer.shadowRadius = 9
                paper.clipsToBounds = false
            }
        }
        for child in root.subviews { paint(child) }
    }
}
