import Foundation

/// The two user settings, kept in `UserDefaults`. The keys were renamed along
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
