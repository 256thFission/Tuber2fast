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
