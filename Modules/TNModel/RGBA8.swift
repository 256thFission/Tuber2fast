/// A colour as the four bytes it is durably written as.
///
/// One parser. `TextRun.color` is a `"#RRGGBBAA"` string and the app's tool
/// palette holds ink colours; a second hand-rolled hex check beside this one
/// is how the two spellings start to disagree.
///
/// No UIKit: this is a durable value, and `TNModel` may not name a UI
/// framework. The `UIColor` bridge lives with the tool, in `TNEditor`.
package struct RGBA8: Equatable, Sendable, Codable {
    package let red: UInt8
    package let green: UInt8
    package let blue: UInt8
    package let alpha: UInt8

    package init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `"#RRGGBBAA"`: exactly nine characters, ASCII hex in either case.
    ///
    /// ASCII, deliberately. `Character.isHexDigit` is true of the fullwidth
    /// forms too, so the check this replaced accepted a colour no renderer
    /// would ever read back the same way.
    package init?(hex: String) {
        guard hex.count == 9, hex.hasPrefix("#") else { return nil }
        var nibbles: [UInt8] = []
        nibbles.reserveCapacity(8)
        for character in hex.dropFirst() {
            guard character.isASCII, let value = character.hexDigitValue else { return nil }
            nibbles.append(UInt8(value))
        }
        self.init(
            red: nibbles[0] << 4 | nibbles[1],
            green: nibbles[2] << 4 | nibbles[3],
            blue: nibbles[4] << 4 | nibbles[5],
            alpha: nibbles[6] << 4 | nibbles[7]
        )
    }

    /// Always uppercase `"#RRGGBBAA"`, whatever case it was parsed from.
    package var hex: String {
        "#" + [red, green, blue, alpha].map(Self.hexPair).joined()
    }

    private static let digits = Array("0123456789ABCDEF")

    private static func hexPair(_ byte: UInt8) -> String {
        String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}
