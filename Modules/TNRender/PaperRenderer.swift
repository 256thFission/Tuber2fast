import CoreGraphics
import Foundation
import TNModel

/// Draws paper marks into a page-space context. The metrics are rendering
/// constants of this build, never durable: a stored spacing would be a
/// second authority for one picture.
package enum PaperRenderer {
    package enum Metrics {
        package static let ruleSpacing: Double = 24
        package static let gridSpacing: Double = 18
        package static let dotSpacing: Double = 18
        package static let dotRadius: Double = 0.6
        package static let ruleWidth: Double = 0.5
        package static let topMargin: Double = 72
    }

    private static let markColor: CGColor = {
        let mark = DrawnPaper.markColor
        return CGColor(
            srgbRed: CGFloat(mark.red) / 255, green: CGFloat(mark.green) / 255,
            blue: CGFloat(mark.blue) / 255, alpha: CGFloat(mark.alpha) / 255
        )
    }()

    /// The context is in page space: origin top-left, y down, one unit per
    /// page point. Only the marks: the page under them is already white.
    package static func draw(_ paper: DrawnPaper, geometry: PageGeometry, in context: CGContext) {
        let width = geometry.width, height = geometry.height
        context.setStrokeColor(markColor)
        context.setFillColor(markColor)
        context.setLineWidth(Metrics.ruleWidth)
        switch paper {
        case .blank:
            break
        case .lined:
            var y = Metrics.topMargin
            while y < height {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: width, y: y))
                y += Metrics.ruleSpacing
            }
            context.strokePath()
        case .grid:
            var x = Metrics.gridSpacing
            while x < width {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: height))
                x += Metrics.gridSpacing
            }
            var y = Metrics.gridSpacing
            while y < height {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: width, y: y))
                y += Metrics.gridSpacing
            }
            context.strokePath()
        case .dotted:
            var y = Metrics.dotSpacing
            while y < height {
                var x = Metrics.dotSpacing
                while x < width {
                    context.fillEllipse(in: CGRect(x: x - Metrics.dotRadius, y: y - Metrics.dotRadius, width: Metrics.dotRadius * 2, height: Metrics.dotRadius * 2))
                    x += Metrics.dotSpacing
                }
                y += Metrics.dotSpacing
            }
        }
    }
}
