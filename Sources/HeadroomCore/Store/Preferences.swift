import Foundation

/// The user's settings, kept in `UserDefaults`. The oldest keys were renamed along
/// with the app; every read reaches for the new key first and falls back to the
/// old one only when it is missing. That way correctness does NOT depend on the
/// order in which something reads these settings relative to `migrate()` —
/// unlike before, when `AppModel`'s property initialisers read the new keys
/// before `init()` had run the migration, so for a whole first session after
/// the rebrand the hard-coded defaults sat in memory (and `didSet` could
/// permanently overwrite correctly migrated data if the user touched the
/// toggle or the slider).
public struct Preferences {
    private let defaults: UserDefaults

    private static let showsPercentNewKey = "showPercentInMenuBar"
    private static let showsPercentOldKey = "pokazujProcent"
    private static let refreshIntervalNewKey = "refreshInterval"
    private static let refreshIntervalOldKey = "interwal"
    private static let menuBarMetricKey = "menuBarMetric"
    private static let dismissedUpdateKey = "dismissedUpdateVersion"
    private static let sectionOrderKey = "sectionOrder"

    // Per-provider, so that one section's arrangement says nothing about the
    // other's — which is the whole reason the control sits in each header.
    private static func sortModeKey(_ provider: Provider) -> String { "sortMode.\(provider.rawValue)" }
    private static func manualOrderKey(_ provider: Provider) -> String { "manualOrder.\(provider.rawValue)" }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var showsPercentInMenuBar: Bool {
        get {
            if let value = defaults.object(forKey: Self.showsPercentNewKey) as? Bool {
                return value
            }
            return defaults.object(forKey: Self.showsPercentOldKey) as? Bool ?? true
        }
        nonmutating set { defaults.set(newValue, forKey: Self.showsPercentNewKey) }
    }

    /// What the menu bar's number answers. An unrecognised stored value falls
    /// back to the default rather than failing — the set of metrics may grow or
    /// shrink between versions.
    public var menuBarMetric: MenuBarMetric {
        get {
            (defaults.string(forKey: Self.menuBarMetricKey)).flatMap(MenuBarMetric.init(rawValue:))
                ?? .bestAccount
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.menuBarMetricKey) }
    }

    /// The version whose update notice was dismissed. Storing the version
    /// rather than a flag means the next release speaks up again, while the one
    /// already waved away stays quiet.
    public var dismissedUpdateVersion: String? {
        get { defaults.string(forKey: Self.dismissedUpdateKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.dismissedUpdateKey) }
    }

    /// How one section arranges its accounts. An unrecognised stored value
    /// falls back to the default rather than failing — the set of modes may
    /// grow or shrink between versions.
    public func sortMode(for provider: Provider) -> SortMode {
        defaults.string(forKey: Self.sortModeKey(provider))
            .flatMap(SortMode.init(rawValue:)) ?? .alphabetical
    }

    public func setSortMode(_ mode: SortMode, for provider: Provider) {
        defaults.set(mode.rawValue, forKey: Self.sortModeKey(provider))
    }

    /// The account ids of one section, in the order they were dragged into.
    /// Anything stored under that key that is not a list of strings is not an
    /// order, and reads as none.
    public func manualOrder(for provider: Provider) -> [String] {
        defaults.stringArray(forKey: Self.manualOrderKey(provider)) ?? []
    }

    public func setManualOrder(_ order: [String], for provider: Provider) {
        defaults.set(order, forKey: Self.manualOrderKey(provider))
    }

    /// The providers, in the order their sections are shown. Empty until the
    /// user drags one — see `AccountOrdering.sections`, which fills the gaps.
    public var sectionOrder: [String] {
        get { defaults.stringArray(forKey: Self.sectionOrderKey) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Self.sectionOrderKey) }
    }

    /// The slider in Settings is limited to 180...1800, and the same clamp
    /// applies here again on both read AND write — otherwise an older value
    /// written by an earlier version of the app could fall below the threshold
    /// at which Anthropic hard-rejects requests (429 per account).
    public var refreshIntervalSeconds: Double {
        get {
            let stored = (defaults.object(forKey: Self.refreshIntervalNewKey) as? Double)
                ?? (defaults.object(forKey: Self.refreshIntervalOldKey) as? Double)
                ?? Poller.baseInterval
            return Self.clampRefreshInterval(stored)
        }
        nonmutating set { defaults.set(Self.clampRefreshInterval(newValue), forKey: Self.refreshIntervalNewKey) }
    }

    /// The lower bound is Anthropic's hard threshold (`Poller.minimumInterval`);
    /// the upper one is the range of the slider in Settings. Public so that a
    /// caller such as `AppModel` can check whether a value will be clamped
    /// before storing it, without duplicating the same bounds.
    public static func clampRefreshInterval(_ value: Double) -> Double {
        min(max(value, Poller.minimumInterval), 1800)
    }

    /// Copies the old keys to the new ones and removes the old. With the
    /// fallback in place on read this is only housekeeping, not a condition for
    /// correctness — safe to call repeatedly, since later runs have nothing
    /// left to move.
    public func migrate() {
        for (old, new) in [(Self.showsPercentOldKey, Self.showsPercentNewKey),
                            (Self.refreshIntervalOldKey, Self.refreshIntervalNewKey)] {
            guard defaults.object(forKey: new) == nil, let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: new)
            defaults.removeObject(forKey: old)
        }
    }
}
