import CoreGraphics
import PencilKit
import UIKit

/// The four inks a stroke can be laid in. A closed set, because the tool
/// picker is the app's, and a colour the runtime cannot draw is not a
/// state worth representing.
package enum ToolColor: String, Sendable, Equatable, CaseIterable {
    case black, blue, red, green

    package var uiColor: UIColor {
        switch self {
        case .black: UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        case .blue: UIColor(red: 0.10, green: 0.44, blue: 0.78, alpha: 1)
        case .red: UIColor(red: 0.77, green: 0.16, blue: 0.16, alpha: 1)
        case .green: UIColor(red: 0.17, green: 0.51, blue: 0.24, alpha: 1)
        }
    }
}

/// Three nib widths in page points.
///
/// The numbers are taste, not measurement: nothing has held a Pencil to
/// them yet. `Docs/Unproven.md` is where that stays recorded.
package enum ToolWidth: String, Sendable, Equatable, CaseIterable {
    case thin, medium, thick

    package var points: CGFloat {
        switch self {
        case .thin: 2
        case .medium: 5
        case .thick: 12
        }
    }
}

/// What the editor is doing with the Pencil. The enum is the durable-free
/// half of the environment: the app picks one, the binding turns it into
/// the `PKTool` the runtime applies.
package enum EditorTool: Sendable, Equatable {
    case pen(color: ToolColor, width: ToolWidth)
    case marker(color: ToolColor)
    /// `bitmap` is the pixel eraser; false is the stroke eraser.
    case eraser(bitmap: Bool)
    case lasso

    package var pkTool: any PKTool {
        switch self {
        case .pen(let color, let width):
            PKInkingTool(.pen, color: color.uiColor, width: width.points)
        case .marker(let color):
            // A marker is wide by definition; a width control for it would
            // be a second way to say the same thing.
            PKInkingTool(.marker, color: color.uiColor, width: ToolWidth.thick.points)
        case .eraser(let bitmap):
            PKEraserTool(bitmap ? .bitmap : .vector)
        case .lasso:
            PKLassoTool()
        }
    }
}
