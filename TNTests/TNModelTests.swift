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
    }
}

@Suite("TNModel text")
struct TextStyleTests {
    private let red = TextStyle(font: "system", size: 16, bold: false, italic: false, underline: false, color: RGBA8(red: 255, green: 0, blue: 0, alpha: 255))

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

    @Test("Equal styles resolve equal fonts")
    func equalStylesEqualFonts() {
        let bold = TextStyle(font: "system", size: 20, bold: true, italic: false, underline: false, color: TextStyle.body.color)
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
