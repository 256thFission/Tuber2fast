import Foundation
import Testing
@testable import TNCanvas
@testable import TNModel
import UIKit

/// The canvas's own chrome over the page, drawn in every preset: the lasso's
/// frame and a text box being edited are TNCanvas state no launch argument
/// reaches, so the theme screenshots cannot show them. Each preset leaves one
/// image in the result bundle, for a person to judge whether the outlines
/// hold up over white paper. Nothing here passes judgement on the colours.
@Suite("Canvas chrome per theme")
@MainActor
struct ThemeRenderTests {
    @Test("The lasso's frame, unlocked and locked, and an open text box, over white paper", arguments: Theme.presets)
    func chromeOverPaper(_ preset: ThemePreset) throws {
        let paper = UIView(frame: CGRect(x: 0, y: 0, width: 760, height: 240))
        paper.backgroundColor = .white
        for (index, locked) in [false, true].enumerated() {
            paper.addSubview(LayerSelectionView(
                layer: LayerID(),
                transform: .placing(sourceWidth: 180, sourceHeight: 120, at: (60 + Double(index) * 240, 80), scale: 1),
                locked: locked, movesOnly: false, theme: preset.theme
            ))
        }
        paper.addSubview(TextEditingView(
            text: TextLayer(
                rect: PageRect(x: 540, y: 80, width: 180, height: 120),
                runs: [TextRun(string: "1. Show that the sum converges.", style: .body)], alignment: .leading
            ),
            typing: .body, theme: preset.theme
        ))
        paper.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: paper.bounds, format: format).image { context in
            paper.layer.render(in: context.cgContext)
        }
        Attachment.record(try #require(image.pngData()), named: "\(preset.id.rawValue).png")
    }
}
