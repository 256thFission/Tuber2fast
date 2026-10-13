import CoreText
import Foundation
import Testing
@testable import TNModel

@Suite("TNModel identities")
struct IdentityTests {
    @Test("An identity encodes as its uppercase UUID string and refuses any other spelling")
    func canonicalSpelling() throws {
        let id = PageID()
        let data = try JSONEncoder().encode(id)
        #expect(String(data: data, encoding: .utf8) == "\"\(id.raw.uuidString)\"")
        let lower = "\"\(id.raw.uuidString.lowercased())\"".data(using: .utf8)!
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PageID.self, from: lower) }
    }
}

@Suite("TNModel colour")
struct RGBA8Tests {
    @Test("A hex colour is nine characters, a hash, and eight ASCII hex digits")
    func parsingRejectsEverythingElse() {
        #expect(RGBA8(hex: "#0A1B2C3D") == RGBA8(red: 0x0A, green: 0x1B, blue: 0x2C, alpha: 0x3D))
        #expect(RGBA8(hex: "#0a1b2c3d") == RGBA8(red: 0x0A, green: 0x1B, blue: 0x2C, alpha: 0x3D))
        #expect(RGBA8(hex: "#000000FF") == RGBA8(red: 0, green: 0, blue: 0, alpha: 255))
        #expect(RGBA8(hex: "#000000") == nil)
        #expect(RGBA8(hex: "#000000FFF") == nil)
        #expect(RGBA8(hex: "000000FFF") == nil)
        #expect(RGBA8(hex: "#00000GFF") == nil)
        #expect(RGBA8(hex: "") == nil)
        // Fullwidth digits are hex digits to `Character.isHexDigit`, which is
        // why the parser asks for ASCII as well.
        #expect(RGBA8(hex: "#\u{FF10}0000FFF") == nil)
    }

    @Test("A parsed colour spells itself back in uppercase")
    func roundTripsUppercase() {
        #expect(RGBA8(hex: "#0a1b2cff")?.hex == "#0A1B2CFF")
        #expect(RGBA8(red: 255, green: 0, blue: 16, alpha: 255).hex == "#FF0010FF")
        let parsed = RGBA8(hex: "#12345678")
        #expect(parsed.flatMap { RGBA8(hex: $0.hex) } == parsed)
    }

    @Test("A text run is valid exactly when its colour parses")
    func textRunValidityFollowsTheParser() {
        #expect(TextRun(string: "a").isValid)
        #expect(TextRun(string: "a", color: "#ABCDEF01").isValid)
        #expect(!TextRun(string: "a", color: "#ABCDEF").isValid)
        #expect(!TextRun(string: "a", color: "ABCDEF01").isValid)
        #expect(!TextRun(string: "a", color: "#ABCDEFGH").isValid)
        #expect(!TextRun(string: "a", size: 0).isValid)
        #expect(!TextRun(string: "a", font: "").isValid)
        #expect(!TextRun(string: "a", font: "Georgia").isValid)
    }
}

@Suite("TNModel text")
struct TextStyleTests {
    private let red = TextStyle(font: .system, size: 16, bold: false, italic: false, underline: false, color: RGBA8(red: 255, green: 0, blue: 0, alpha: 255))

    @Test("Adjacent runs of one style merge; unequal neighbours stay apart; an empty run merges away")
    func merging() {
        let runs = [TextRun(string: "a", style: .body), TextRun(string: "b", style: .body), TextRun(string: "", style: red), TextRun(string: "c", style: red)]
        #expect(TextRun.merging(runs) == [TextRun(string: "ab", style: .body), TextRun(string: "c", style: red)])
        #expect(TextRun.merging([TextRun(string: "", style: .body)]) == [TextRun(string: "", style: .body)])
        #expect(TextRun.merging([]) == [])
    }

    @Test("A run round-trips its style and spells the colour uppercase")
    func styleRoundTrip() {
        let run = TextRun(string: "x", style: red)
        #expect(run.color == "#FF0000FF")
        #expect(run.style == red)
        #expect(TextRun(string: "x", color: "#ff0000ff").style == red)
    }

    @Test("A style changed in some fields keeps every other")
    func textStyleWithChangesOnlyNamedFields() {
        let styled = TextStyle(font: .system, size: 18, bold: true, italic: true, underline: true, color: red.color)
        #expect(styled.with() == styled)
        #expect(styled.with(size: 32) == TextStyle(font: .system, size: 32, bold: true, italic: true, underline: true, color: red.color))
        #expect(styled.with(bold: false) == TextStyle(font: .system, size: 18, bold: false, italic: true, underline: true, color: red.color))
        #expect(styled.with(italic: false) == TextStyle(font: .system, size: 18, bold: true, italic: false, underline: true, color: red.color))
        #expect(styled.with(underline: false) == TextStyle(font: .system, size: 18, bold: true, italic: true, underline: false, color: red.color))
        #expect(styled.with(color: TextStyle.body.color) == TextStyle(font: .system, size: 18, bold: true, italic: true, underline: true, color: TextStyle.body.color))
        #expect(TextStyle.body.with(size: 24, bold: true) == TextStyle(font: .system, size: 24, bold: true, italic: false, underline: false, color: TextStyle.body.color))
    }

    @Test("Equal styles resolve equal fonts")
    func equalStylesEqualFonts() {
        let bold = TextStyle(font: .system, size: 20, bold: true, italic: false, underline: false, color: TextStyle.body.color)
        let a = TextTypesetting.resolve(bold), b = TextTypesetting.resolve(bold)
        #expect(CTFontCopyPostScriptName(a) == CTFontCopyPostScriptName(b))
        #expect(CTFontGetSize(a) == 20)
        #expect(CTFontGetSymbolicTraits(a).contains(.boldTrait))
        #expect(!CTFontGetSymbolicTraits(TextTypesetting.resolve(.body)).contains(.boldTrait))
    }

    @Test("The builder tags every run, and an untagged range commits as the typing style")
    func runsAndTags() {
        let attributed = TextTypesetting.attributed([TextRun(string: "ab", style: .body), TextRun(string: "c", style: red)], alignment: .center)
        #expect(TextTypesetting.runs(of: attributed, typing: red) == [TextRun(string: "ab", style: .body), TextRun(string: "c", style: red)])
        let mutable = NSMutableAttributedString(attributedString: attributed)
        mutable.append(NSAttributedString(string: "d"))
        #expect(TextTypesetting.runs(of: mutable, typing: red).last == TextRun(string: "d", style: red))
        #expect(TextTypesetting.lineHeight(of: .body) > 16)
    }
}

@Suite("TNModel placement")
struct PageSpaceTransformTests {
    /// A quarter turn about the origin, applied after a placement.
    private func rotated(_ transform: PageSpaceTransform) -> PageSpaceTransform {
        transform.concatenating(PageSpaceTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0))
    }

    @Test("A rotated square contains its interior and misses just outside its edge")
    func containsARotatedSquare() {
        let square = rotated(.placing(sourceWidth: 100, sourceHeight: 100, at: (200, 200), scale: 1))
        let centre = square.apply(x: 0.5, y: 0.5)
        #expect(square.contains(PagePoint(x: centre.x, y: centre.y)))
        // A point a whisker inside the middle of one edge, and one a whisker
        // outside it, along the edge's own normal.
        let inside = square.apply(x: 0.5, y: 0.99)
        let outside = square.apply(x: 0.5, y: 1.01)
        #expect(square.contains(PagePoint(x: inside.x, y: inside.y)))
        #expect(!square.contains(PagePoint(x: outside.x, y: outside.y)))
        // The axis-aligned rect of a rotated square admits corners the square
        // does not; this is the case a `CGRect.contains` would get wrong.
        let corner = square.apply(x: 0, y: 0)
        #expect(!square.contains(PagePoint(x: corner.x - 1, y: corner.y - 1)))
    }

    @Test("A rect spelled as a transform contains its interior and not its outside")
    func containsARect() {
        let rect = PageSpaceTransform.unitSquare(to: PageRect(x: 10, y: 20, width: 100, height: 40))
        #expect(rect.contains(PagePoint(x: 60, y: 40)))
        #expect(rect.contains(PagePoint(x: 10, y: 20)))
        #expect(!rect.contains(PagePoint(x: 9.5, y: 40)))
        #expect(!rect.contains(PagePoint(x: 60, y: 61)))
    }

    @Test("Extents are the object's own width and height, and a rotation does not change them")
    func extentsSurviveRotation() {
        let placed = PageSpaceTransform.placing(sourceWidth: 300, sourceHeight: 200, at: (10, 20), scale: 1)
        #expect(placed.unitExtents.width == 300)
        #expect(placed.unitExtents.height == 200)
        let turned = rotated(placed)
        #expect(abs(turned.unitExtents.width - 300) < 1e-9)
        #expect(abs(turned.unitExtents.height - 200) < 1e-9)
    }

    @Test("A degenerate transform contains nothing rather than trapping")
    func degenerateContainsNothing() {
        let flat = PageSpaceTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)
        #expect(!flat.contains(PagePoint(x: 0, y: 0)))
    }
}
