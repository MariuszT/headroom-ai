import Testing
import Foundation
@testable import HeadroomCore

private func tempDefaults() -> (defaults: UserDefaults, name: String) {
    let name = UUID().uuidString
    return (UserDefaults(suiteName: name)!, name)
}

@Test func sortModeStartsAlphabetical() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(Preferences(defaults: defaults).sortMode(for: .anthropic) == .alphabetical)
}

@Test func sortModeSurvivesTheRoundTrip() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)

    preferences.setSortMode(.manual, for: .anthropic)

    #expect(preferences.sortMode(for: .anthropic) == .manual)
}

/// The whole point of putting the control in each section header: one section's
/// arrangement is none of the other's business.
@Test func eachProviderKeepsItsOwnSortMode() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)

    preferences.setSortMode(.manual, for: .anthropic)

    #expect(preferences.sortMode(for: .openai) == .alphabetical)
}

/// The set of modes may shrink between versions; a value no longer recognised
/// falls back to the default rather than failing.
@Test func anUnrecognisedSortModeFallsBackToTheDefault() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("byMoonPhase", forKey: "sortMode.anthropic")

    #expect(Preferences(defaults: defaults).sortMode(for: .anthropic) == .alphabetical)
}

@Test func theManualOrderStartsEmpty() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(Preferences(defaults: defaults).manualOrder(for: .anthropic).isEmpty)
}

@Test func theManualOrderSurvivesTheRoundTrip() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)

    preferences.setManualOrder(["anthropic:b@x.pl", "anthropic:a@x.pl"], for: .anthropic)

    #expect(preferences.manualOrder(for: .anthropic) == ["anthropic:b@x.pl", "anthropic:a@x.pl"])
}

@Test func eachProviderKeepsItsOwnManualOrder() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)

    preferences.setManualOrder(["anthropic:a@x.pl"], for: .anthropic)

    #expect(preferences.manualOrder(for: .openai).isEmpty)
}

/// Anything but a list of strings under that key is not an order — reading it
/// as one would crash on a cast.
@Test func aManualOrderOfTheWrongTypeReadsAsEmpty() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(42, forKey: "manualOrder.anthropic")

    #expect(Preferences(defaults: defaults).manualOrder(for: .anthropic).isEmpty)
}

@Test func theSectionOrderStartsEmpty() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(Preferences(defaults: defaults).sectionOrder.isEmpty)
}

@Test func theSectionOrderSurvivesTheRoundTrip() {
    let (defaults, name) = tempDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)

    preferences.sectionOrder = ["openai", "anthropic"]

    #expect(preferences.sectionOrder == ["openai", "anthropic"])
}
