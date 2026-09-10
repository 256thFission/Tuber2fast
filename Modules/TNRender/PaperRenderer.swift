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

    private static let markColor = CGColor(srgbRed: 0.58, green: 0.65, blue: 0.75, alpha: 1)
    private static let pageColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// The context is in page space: origin top-left, y down, one unit per
    /// page point. `none` draws nothing at all; the source shows through.
    package static func draw(_ paper: Paper, geometry: PageGeometry, in context: CGContext) {
        let width = geometry.width, height = geometry.height
        if paper != .none {
            context.setFillColor(pageColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.setStrokeColor(markColor)
        context.setFillColor(markColor)
        context.setLineWidth(Metrics.ruleWidth)
        switch paper {
        case .none, .blank:
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
