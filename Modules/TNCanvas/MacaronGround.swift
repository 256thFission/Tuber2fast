import TNModel
import UIKit

extension RGBA8 {
    var uiColor: UIColor {
        UIColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }
}

/// The wallpaper behind the page: two colours and the theme's tile, and
/// nothing else.
///
/// A pattern colour rather than a drawn layer, so the ground is one value
/// wherever the writing bar parks and costs nothing per frame. It is set on
/// the paging scroll view alone — the page controllers are clear — because a
/// second pattern origin at a slot boundary is a visible seam in the grid.
enum MacaronGround {
    static func grid(_ theme: Theme, scale: CGFloat) -> UIColor {
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(scale, 1)
        format.opaque = true
        let tile = theme.groundTile
        let size = CGSize(width: tile.size, height: tile.size)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            theme.ground.uiColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            theme.ground2.uiColor.setFill()
            // Top and left only: the neighbouring tiles supply the other two
            // sides, so every rule is one line wide and not two.
            context.fill(CGRect(x: 0, y: 0, width: tile.size, height: tile.lineWidth))
            context.fill(CGRect(x: 0, y: 0, width: tile.lineWidth, height: tile.size))
        }
        return UIColor(patternImage: image)
    }
}

/// What the paper looks like from the outside. Fixed by the design: radius
/// 10 and a 3pt line, never black, in the paper's own derived outline.
enum MacaronPage {
    static let radius: CGFloat = 10
    static let lineWidth: CGFloat = 3

    static func outline(_ theme: Theme) -> UIColor { theme.outline(of: theme.paper).uiColor }

    static func paper(_ theme: Theme) -> UIColor { theme.paper.uiColor }
}
