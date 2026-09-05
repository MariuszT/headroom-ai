import Testing
import Foundation
@testable import HeadroomCore

/// `UserDefaults(suiteName:)` with a random name per test — never `.standard`,
/// which holds the user's real settings. Cleaned up after each test by the name
/// remembered at creation (not `.description`, which does not return it in a
/// form `removePersistentDomain` accepts).
private func tempDefaults() -> (defaults: UserDefaults, name: String) {
    let name = UUID().uuidString
    return (UserDefaults(suiteName: name)!, name)
}

@Test func readsTheNewKeyWhenPresent() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "showPercentInMenuBar")

    #expect(Preferences(defaults: defaults).showsPercentInMenuBar == false)
}

@Test func fallsBackToTheOldKeyWhenTheNewOneIsMissing() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "pokazujProcent")

    #expect(Preferences(defaults: defaults).showsPercentInMenuBar == false)
}

@Test func aValueBelow180sIsClampedOnRead() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(60.0, forKey: "refreshInterval")

    #expect(Preferences(defaults: defaults).refreshIntervalSeconds == 180)
}

@Test func aValueBelow180sIsClampedOnWrite() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)

    preferences.refreshIntervalSeconds = 60

    #expect(preferences.refreshIntervalSeconds == 180)
    #expect(defaults.object(forKey: "refreshInterval") as? Double == 180)
}

@Test func migrateRemovesTheOldKey() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "pokazujProcent")
    defaults.set(600.0, forKey: "interwal")

    Preferences(defaults: defaults).migrate()

    #expect(defaults.object(forKey: "pokazujProcent") == nil)
    #expect(defaults.object(forKey: "interwal") == nil)
    #expect(defaults.object(forKey: "showPercentInMenuBar") as? Bool == true)
    #expect(defaults.object(forKey: "refreshInterval") as? Double == 600)
}

@Test func migrateDoesNotOverwriteAnExistingNewValue() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "pokazujProcent")
    defaults.set(true, forKey: "showPercentInMenuBar")

    Preferences(defaults: defaults).migrate()

    #expect(defaults.object(forKey: "showPercentInMenuBar") as? Bool == true)
}

@Test func theMenuBarMetricDefaultsToTheBestAccount() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(Preferences(defaults: defaults).menuBarMetric == .bestAccount)
}

@Test func theMenuBarMetricSurvivesAWriteAndAnUnknownValue() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)

    preferences.menuBarMetric = .accountsWithRoom
    #expect(preferences.menuBarMetric == .accountsWithRoom)

    // A metric written by a version that had one we no longer do must not
    // leave the menu bar with nothing to show.
    defaults.set("somethingRemoved", forKey: "menuBarMetric")
    #expect(preferences.menuBarMetric == .bestAccount)
}
