import Foundation
import Testing
@testable import TNModel
@testable import TuberNotes

/// The one boundary a theme crosses: a choice written to a preference, and
/// read back by a build that may no longer have the row it names.
@Suite("The theme preference")
struct ThemeDefaultsTests {
    /// A domain of its own per test, torn down after it, so a run leaves the
    /// machine holding nothing it did not start with.
    private func withStore(_ body: (ThemeDefaults, UserDefaults) -> Void) {
        let name = "tn.themeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(ThemeDefaults(defaults), defaults)
        defaults.removePersistentDomain(forName: name)
    }

    @Test("An unset preference is no choice at all")
    func absent() {
        withStore { themes, _ in
            #expect(themes.load() == nil)
        }
    }

    @Test("Every choice the app can make comes back as itself")
    func roundTrip() {
        let choices = [ThemeChoice.system] + Theme.presets.map { ThemeChoice.preset($0.id) }
        for choice in choices {
            withStore { themes, _ in
                themes.save(choice)
                #expect(themes.load() == choice)
            }
        }
    }

    @Test("A choice naming a theme this build has no row for opens on the system")
    func unknownIdentity() {
        withStore { themes, _ in
            themes.save(.preset(ThemeID(rawValue: "virtualBoy")))
            #expect(themes.load() == nil)
        }
    }

    @Test("Bytes that are not a choice are not repaired into one")
    func rubbish() {
        withStore { themes, defaults in
            defaults.set(Data([0x00, 0x01]), forKey: "tn.theme")
            #expect(themes.load() == nil)
        }
    }
}

/// What the app opens on, which is the launch argument first and the
/// preference second.
@Suite("The launch theme")
@MainActor
struct LaunchThemeTests {
    private func store() -> ThemeDefaults {
        ThemeDefaults(UserDefaults(suiteName: "tn.launchTests.\(UUID().uuidString)")!)
    }

    @Test("-TNTheme names a theme by the name the picker shows")
    func namedTheme() {
        for preset in Theme.presets {
            let choice = Workspace.launchChoice(["TuberNotes", "-TNTheme", preset.name], store())
            #expect(choice == .preset(preset.id))
        }
    }

    @Test("Without the argument the preference decides, and without one the system does")
    func fallsBackToThePreference() {
        #expect(Workspace.launchChoice(["TuberNotes"], store()) == .system)
        let remembered = store()
        remembered.save(.preset(ThemeID(rawValue: "kirby")))
        #expect(Workspace.launchChoice(["TuberNotes"], remembered) == .preset(ThemeID(rawValue: "kirby")))
    }

    @Test("A theme argument with no name after it is not an argument")
    func danglingArgument() {
        #expect(Workspace.launchChoice(["TuberNotes", "-TNTheme"], store()) == .system)
    }
}
