import Foundation
import Testing
@testable import TNModel

/// The registry and the one piece of chosen state over it.
@Suite("Theme presets and the choice over them")
struct ThemeChoiceTests {
    @Test("Every preset is named once and identified once")
    func presetsAreDistinct() {
        #expect(Set(Theme.presets.map(\.id)).count == Theme.presets.count)
        // `-TNTheme <name>` names a theme by its display name, so two rows
        // sharing one would make the argument ambiguous.
        #expect(Set(Theme.presets.map(\.name)).count == Theme.presets.count)
    }

    @Test("Lookup finds every row and refuses an id no row has")
    func lookup() {
        for preset in Theme.presets {
            #expect(Theme.preset(preset.id)?.theme == preset.theme)
        }
        #expect(Theme.preset(ThemeID(rawValue: "nintendo64")) == nil)
    }

    @Test("Following the system is the two Macarons; a preset is itself in either")
    func resolve() {
        #expect(ThemeChoice.system.resolve(dark: false) == .macaron)
        #expect(ThemeChoice.system.resolve(dark: true) == .macaronDark)
        let boy = ThemeID(rawValue: "gameBoy")
        #expect(ThemeChoice.preset(boy).resolve(dark: false) == .gameBoy)
        #expect(ThemeChoice.preset(boy).resolve(dark: true) == .gameBoy)
    }

    @Test("A choice survives the shape the preference is written in")
    func roundTrip() throws {
        let choices = [ThemeChoice.system] + Theme.presets.map { ThemeChoice.preset($0.id) }
        for choice in choices {
            let data = try PropertyListEncoder().encode(choice)
            #expect(try PropertyListDecoder().decode(ThemeChoice.self, from: data) == choice)
        }
    }
}
