import Testing
@testable import TNEditor
@testable import TNModel
@testable import TuberNotes

/// The colour tray's maths: a colour into hue, saturation and value, and
/// back.
@Suite("The colour tray")
struct ColourTrayTests {
    @Test("A colour through hue, saturation and value comes back within one in every channel")
    func hsvRoundTrips() {
        let levels: [UInt8] = [0, 1, 2, 17, 64, 127, 128, 200, 254, 255]
        var colours = levels.flatMap { red in
            levels.flatMap { green in
                levels.map { blue in ToolColor(rgba: RGBA8(red: red, green: green, blue: blue, alpha: 0xFF)) }
            }
        }
        colours += Theme.presets.flatMap(\.theme.palette).map { ToolColor(rgba: $0) } + ToolColor.highlighterRow
        for colour in colours {
            let back = HSV(colour).colour.rgba
            let channels = [(colour.rgba.red, back.red), (colour.rgba.green, back.green), (colour.rgba.blue, back.blue)]
            #expect(
                channels.allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                "\(colour.rgba.hex) came back \(back.hex)"
            )
        }
    }
}
