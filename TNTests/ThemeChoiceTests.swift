import Foundation
import Testing
@testable import TNModel

/// The registry and the one piece of chosen state over it.
@Suite("Theme presets and the choice over them")
struct ThemeChoiceTests {
    @Test("Every preset is named once and identified once")
    func presetsAreDistinct() {
        #expect(Set(Theme.presets.map(\.id)).count == Theme.presets.count)
        // The picker shows the name, so two rows sharing one could not be
        // told apart there.
        #expect(Set(Theme.presets.map(\.name)).count == Theme.presets.count)
    }

    @Test("Lookup finds every row and refuses an id no row has")
    func lookup() {
        for preset in Theme.presets {
            #expect(Theme.preset(preset.id)?.theme == preset.theme)
        }
        #expect(Theme.preset(ThemeID(rawValue: "noSuchTheme")) == nil)
    }

    @Test("Following the system is the two Macarons; a preset is itself in either")
    func resolve() throws {
        #expect(ThemeChoice.system.resolve(dark: false) == .macaron)
        #expect(ThemeChoice.system.resolve(dark: true) == .macaronDark)
        let lime = ThemeID(rawValue: "lime")
        let theme = try #require(Theme.preset(lime)).theme
        #expect(ThemeChoice.preset(lime).resolve(dark: false) == theme)
        #expect(ThemeChoice.preset(lime).resolve(dark: true) == theme)
    }
}
