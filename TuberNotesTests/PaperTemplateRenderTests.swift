import CoreGraphics
import Foundation
import Testing
@testable import TuberModel
@testable import TuberRender

/// `PaperTemplateRenderer` on its own: page points in, marks out.
///
/// It is wired to nothing, which is what makes this suite worth writing at all
/// — every assertion below is about the geometry itself, with no composite, no
/// cache, no canvas, and no store between the constant and the pixel.
///
/// The one rule these tests exist to hold is **A17**: a template is measured in
/// absolute page points from the top-left, never as a fraction of the page.
/// `spacingIsAbsoluteAndNotAFractionOfThePage` is that rule in the only form a
/// test can hold — the same template into two differently shaped pages, and the
/// same spacing in points out of both.
@Suite("Paper templates, as geometry")
struct PaperTemplateRenderTests {

    // MARK: - blank

    @Test("A blank template leaves the context exactly as it found it")
    func blankMarksNothing() throws {
        let untouched = Canvas(pageWidth: 200, pageHeight: 200, scale: 2)
        let drawnOn = Canvas(pageWidth: 200, pageHeight: 200, scale: 2)
        drawnOn.draw(.blank)

        #expect(
            drawnOn.bytes == untouched.bytes,
            "a blank page must be byte-identical to a page nothing drew on"
        )

        // And the comparison can fail, which is what makes the assertion above
        // worth having: the same call with a template that marks does differ.
        let ruled = Canvas(pageWidth: 200, pageHeight: 200, scale: 2)
        ruled.draw(.lined)
        #expect(ruled.bytes != untouched.bytes)
    }

    // MARK: - lined

    @Test("A lined page marks exactly its rows, and nothing between them")
    func linedMarksItsRows() throws {
        // Two pixels per page point, so a half-point rule is exactly one
        // device row and a fully covered pixel is exactly the mark colour.
        let canvas = Canvas(pageWidth: 200, pageHeight: 200, scale: 2)
        canvas.draw(.lined)

        let first = PaperTemplateRenderer.Metrics.topMargin
        let spacing = PaperTemplateRenderer.Metrics.ruleSpacing

        #expect(canvas.isBlankRow(atPagePoint: first - spacing), "nothing above the top margin")
        for row in 0..<4 {
            let y = first + Double(row) * spacing
            #expect(canvas.isMarkedRow(atPagePoint: y), "the rule at \(y) pt is missing")
            #expect(
                canvas.isBlankRow(atPagePoint: y + spacing / 2),
                "something is drawn halfway between two rules"
            )
        }

        // A rule spans the page's whole width and is one device row tall at
        // this scale — the property the lens turns into sharpness.
        let deviceRow = Int(first * 2)
        #expect(canvas.isMark(x: 0, y: deviceRow) && canvas.isMark(x: 399, y: deviceRow))
        #expect(canvas.isBlank(x: 200, y: deviceRow + 1), "a 0.5 pt rule is one row at 2 px/pt, not two")
        #expect(canvas.isBlank(x: 200, y: deviceRow - 1))
    }

    // MARK: - grid

    @Test("A grid page marks rows and columns, and nothing in a cell")
    func gridMarksRowsAndColumns() throws {
        let canvas = Canvas(pageWidth: 200, pageHeight: 200, scale: 2)
        canvas.draw(.grid)
        let spacing = PaperTemplateRenderer.Metrics.gridSpacing

        // A point on a column but not on a row, and the transpose.
        #expect(canvas.isMark(atPagePoint: CGPoint(x: spacing, y: spacing * 2.5)))
        #expect(canvas.isMark(atPagePoint: CGPoint(x: spacing * 2.5, y: spacing)))
        // The middle of a cell is bare page.
        #expect(canvas.isBlank(atPagePoint: CGPoint(x: spacing * 2.5, y: spacing * 2.5)))
        // The grid is measured from the origin, so the lattice starts one
        // spacing in — a line along the page edge would be a border, not
        // ruling.
        #expect(canvas.isBlankRow(atPagePoint: 0))
    }

    // MARK: - dotted

    @Test("A dotted page marks the intersections only")
    func dottedMarksIntersectionsOnly() throws {
        // Four pixels per page point, so a 1.2 pt dot is nearly five pixels
        // across and "is there a dot here" is not an antialiasing question.
        let canvas = Canvas(pageWidth: 100, pageHeight: 100, scale: 4)
        canvas.draw(.dotted)
        let spacing = PaperTemplateRenderer.Metrics.dotSpacing

        // Just inside the first intersection: wholly covered, so exactly the
        // mark colour.
        #expect(canvas.isMark(x: Int(spacing * 4) - 1, y: Int(spacing * 4) - 1))
        #expect(canvas.isMark(x: Int(spacing * 2 * 4) - 1, y: Int(spacing * 4) - 1))

        // On a lattice line but not at an intersection: a dot grid draws no
        // lines at all, which is the whole difference from `grid`.
        #expect(canvas.isBlank(atPagePoint: CGPoint(x: spacing, y: spacing * 1.5)))
        #expect(canvas.isBlank(atPagePoint: CGPoint(x: spacing * 1.5, y: spacing)))
        #expect(canvas.isBlank(atPagePoint: CGPoint(x: spacing * 1.5, y: spacing * 1.5)))
    }

    // MARK: - A17

    @Test("Spacing is absolute page points, not a fraction of the page")
    func spacingIsAbsoluteAndNotAFractionOfThePage() throws {
        // US Letter portrait, and A4-ish landscape: the mixed geometry a
        // single document genuinely holds once a worksheet is imported beside
        // a canonical appended page.
        let portrait = Canvas(pageWidth: 612, pageHeight: 792, scale: 2)
        let landscape = Canvas(pageWidth: 842, pageHeight: 595, scale: 2)
        portrait.draw(.lined)
        landscape.draw(.lined)

        let portraitRules = portrait.markedRowsInPagePoints()
        let landscapeRules = landscape.markedRowsInPagePoints()
        #expect(portraitRules.count > landscapeRules.count, "the taller page holds more rules")

        for rules in [portraitRules, landscapeRules] {
            #expect(
                rules.first == PaperTemplateRenderer.Metrics.topMargin,
                "the first rule sits a fixed margin from the top of any page (got \(rules))"
            )
            let gaps = Set(zip(rules, rules.dropFirst()).map { $1 - $0 })
            #expect(
                gaps == [PaperTemplateRenderer.Metrics.ruleSpacing],
                "the spacing must be one absolute number on every page (got \(gaps))"
            )
        }

        // The same statement for the other axis, where a fraction-of-the-page
        // bug would be loudest: the wider page gets *more* columns at the same
        // pitch, never wider cells.
        let portraitGrid = Canvas(pageWidth: 612, pageHeight: 792, scale: 2)
        let landscapeGrid = Canvas(pageWidth: 842, pageHeight: 595, scale: 2)
        portraitGrid.draw(.grid)
        landscapeGrid.draw(.grid)
        let portraitColumns = portraitGrid.markedColumnsInPagePoints()
        let landscapeColumns = landscapeGrid.markedColumnsInPagePoints()
        #expect(landscapeColumns.count > portraitColumns.count)
        #expect(portraitColumns.first == landscapeColumns.first)
        #expect(
            Set(zip(portraitColumns, portraitColumns.dropFirst()).map { $1 - $0 })
                == Set(zip(landscapeColumns, landscapeColumns.dropFirst()).map { $1 - $0 })
        )
    }

    @Test("A page shorter than one rule spacing draws no rules, and does not trap")
    func aTinyPageIsNotASpecialCase() throws {
        // Absolute spacing means a small page simply has few marks on it.
        // Nothing is clamped and nothing is stretched to fit — stretching is
        // exactly what A17 forbids.
        let canvas = Canvas(pageWidth: 40, pageHeight: 40, scale: 4)
        canvas.draw(.lined)
        #expect(canvas.markedRowsInPagePoints().isEmpty, "the top margin alone is past this page")

        let dots = Canvas(pageWidth: 40, pageHeight: 40, scale: 4)
        dots.draw(.dotted)
        #expect(dots.isMark(x: Int(18 * 4) - 1, y: Int(18 * 4) - 1), "the lattice still starts where it starts")
    }

    // MARK: - the clip

    @Test("Only marks intersecting the clip are emitted at all")
    func theClipDecidesWhichMarksExist() throws {
        // The context carries no CoreGraphics clip, so anything `draw` emits
        // outside `clippedTo` lands on these pixels and is visible here. That
        // is the point: this asserts the renderer skipped them rather than
        // that CoreGraphics threw them away.
        let canvas = Canvas(pageWidth: 200, pageHeight: 200, scale: 2)
        canvas.draw(.lined, clippedTo: CGRect(x: 0, y: 90, width: 200, height: 40))

        #expect(canvas.isMarkedRow(atPagePoint: 96), "the rule inside the clip must be drawn")
        #expect(canvas.isMarkedRow(atPagePoint: 120))
        #expect(canvas.isBlankRow(atPagePoint: 72), "a rule above the clip must never be emitted")
        #expect(canvas.isBlankRow(atPagePoint: 144), "nor one below it")

        // A clip entirely off the page marks nothing anywhere.
        let elsewhere = Canvas(pageWidth: 200, pageHeight: 200, scale: 2)
        let untouched = Canvas(pageWidth: 200, pageHeight: 200, scale: 2)
        elsewhere.draw(.grid, clippedTo: CGRect(x: 400, y: 400, width: 50, height: 50))
        #expect(elsewhere.bytes == untouched.bytes)
    }

    // MARK: - Helpers

    /// A bitmap in page space, with the CTM `StaticLayerRenderer` establishes:
    /// origin top-left, y down, units page points.
    ///
    /// A class because the bytes are read back after drawing and the backing
    /// buffer has to outlive the context.
    private final class Canvas {
        let pageWidth: Double
        let pageHeight: Double
        let scale: Double
        let widthPixels: Int
        let heightPixels: Int
        private let storage: UnsafeMutableRawPointer
        private let context: CGContext
        private let bytesPerRow: Int

        init(pageWidth: Double, pageHeight: Double, scale: Double) {
            self.pageWidth = pageWidth
            self.pageHeight = pageHeight
            self.scale = scale
            widthPixels = Int((pageWidth * scale).rounded())
            heightPixels = Int((pageHeight * scale).rounded())
            bytesPerRow = widthPixels * 4
            // Zeroed before the context exists, not merely filled afterwards:
            // the bitmap's fourth byte per pixel is *skipped* by this format,
            // so a byte-identity assertion over uninitialized memory would
            // compare two piles of allocator leftovers.
            storage = UnsafeMutableRawPointer.allocate(
                byteCount: bytesPerRow * heightPixels, alignment: 8
            )
            storage.initializeMemory(
                as: UInt8.self, repeating: 0, count: bytesPerRow * heightPixels
            )
            guard let made = CGContext(
                data: storage,
                width: widthPixels,
                height: heightPixels,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                preconditionFailure("could not build a \(widthPixels)x\(heightPixels) context")
            }
            context = made
            // The same white page the composite fills, so "unmarked" is one
            // known value rather than whatever the allocator left behind.
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: widthPixels, height: heightPixels))
            context.translateBy(x: 0, y: CGFloat(heightPixels))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        }

        deinit { storage.deallocate() }

        func draw(_ template: PageTemplate, clippedTo clip: CGRect? = nil) {
            PaperTemplateRenderer.draw(
                template,
                in: context,
                pageSize: CGSize(width: pageWidth, height: pageHeight),
                clippedTo: clip ?? CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            )
        }

        /// Every byte of the bitmap, for the byte-identity assertions.
        var bytes: Data {
            Data(bytes: storage, count: bytesPerRow * heightPixels)
        }

        /// One pixel, as 8-bit RGB. The bitmap is little-endian 32-bit with
        /// the alpha byte skipped, so the channel order in memory is B, G, R.
        func pixel(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
            precondition(x >= 0 && x < widthPixels && y >= 0 && y < heightPixels)
            let base = storage.advanced(by: y * bytesPerRow + x * 4)
                .assumingMemoryBound(to: UInt8.self)
            return (Int(base[2]), Int(base[1]), Int(base[0]))
        }

        func isBlank(x: Int, y: Int) -> Bool {
            let p = pixel(x: x, y: y)
            return p.r == 255 && p.g == 255 && p.b == 255
        }

        /// Anything that is not bare page.
        ///
        /// The partition is deliberately "pure white or not", with no
        /// tolerance: every mark in these tests lands on whole device pixels,
        /// so a *partly* covered pixel means the renderer put a mark somewhere
        /// other than where it said. That is what makes "one device row, not
        /// two" a real assertion rather than a restatement of the tolerance.
        func isMark(x: Int, y: Int) -> Bool { !isBlank(x: x, y: y) }

        func isMark(atPagePoint point: CGPoint) -> Bool {
            isMark(x: Int(Double(point.x) * scale), y: Int(Double(point.y) * scale))
        }

        func isBlank(atPagePoint point: CGPoint) -> Bool {
            isBlank(x: Int(Double(point.x) * scale), y: Int(Double(point.y) * scale))
        }

        /// Whether the device row containing this page-space y carries a mark
        /// across the page's middle.
        func isMarkedRow(atPagePoint y: Double) -> Bool {
            let row = Int(y * scale)
            guard row >= 0 && row < heightPixels else { return false }
            return isMark(x: widthPixels / 2, y: row)
        }

        func isBlankRow(atPagePoint y: Double) -> Bool {
            let row = Int(y * scale)
            guard row >= 0 && row < heightPixels else { return true }
            return isBlank(x: widthPixels / 2, y: row)
        }

        /// The page-space y of every marked device row, down the page's middle.
        func markedRowsInPagePoints() -> [Double] {
            (0..<heightPixels)
                .filter { isMark(x: widthPixels / 2, y: $0) }
                .map { Double($0) / scale }
        }

        /// The page-space x of every marked device column, across the page's
        /// middle — sampled on a row a `grid`'s horizontal rules do not occupy.
        func markedColumnsInPagePoints() -> [Double] {
            let row = Int(PaperTemplateRenderer.Metrics.gridSpacing * 1.5 * scale)
            return (0..<widthPixels)
                .filter { isMark(x: $0, y: row) }
                .map { Double($0) / scale }
        }
    }
}
