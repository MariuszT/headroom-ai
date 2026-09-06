import Foundation

/// How one section arranges its accounts.
public enum SortMode: String, Codable, Sendable, CaseIterable {
    /// The default: the order a reader can predict without knowing anything
    /// about the numbers.
    case alphabetical
    /// The fullest first — what the panel did before there was a choice.
    case fullness
    /// Whatever the user dragged them into.
    case manual

    /// What the button in the section header cycles through. Manual is not in
    /// the cycle: it is entered by dragging, and clicking out of it returns
    /// here — offering it as a click would put the user in an order they never
    /// arranged.
    public var next: SortMode {
        switch self {
        case .alphabetical: .fullness
        case .fullness, .manual: .alphabetical
        }
    }
}

/// Arranging accounts and sections. Pure functions, kept out of the views so
/// the order can be tested without a running app.
public enum AccountOrdering {
    /// `accounts` is one section's worth — already filtered to a single
    /// provider, because no order ever mixes them.
    public static func sorted(
        _ accounts: [Account],
        usage: [String: AccountUsage],
        mode: SortMode,
        manualOrder: [String]
    ) -> [Account] {
        switch mode {
        case .alphabetical:
            byAddress(accounts)
        case .fullness:
            fullestFirst(accounts, usage: usage)
        case .manual:
            manually(accounts, order: manualOrder)
        }
    }

    private static func byAddress(_ accounts: [Account]) -> [Account] {
        // Case-insensitive: to a reader "Beata" sits between "anna" and
        // "cezary", and a plain `<` would file every capital ahead of them all.
        accounts.sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
    }

    /// Accounts with an exhausted window go first — those are the ones that
    /// need a decision. Accounts nothing is known about sink to the end: they
    /// must not pose as a good choice, but they do not deserve the head of the
    /// list either. Hence the -1 for a missing figure, which loses even to an
    /// account sitting at zero.
    ///
    /// "Known" and "full" both come from `AccountUsage.knownPercent`, which is
    /// the same rule the menu bar judges by — an account is as full as its
    /// TIGHTEST window, and one whose last check failed has no figure at all
    /// however much its empty cached windows read like zero.
    private static func fullestFirst(_ accounts: [Account], usage: [String: AccountUsage]) -> [Account] {
        accounts.sorted { first, second in
            let firstPercent = usage[first.id]?.knownPercent ?? -1
            let secondPercent = usage[second.id]?.knownPercent ?? -1
            return firstPercent == secondPercent
                ? first.email.localizedCaseInsensitiveCompare(second.email) == .orderedAscending
                : firstPercent > secondPercent
        }
    }

    /// Stored ids first, in the stored order; everything the order does not
    /// mention goes to the end, alphabetically.
    ///
    /// Both halves of that matter. Ids of accounts since removed are skipped,
    /// so a deletion leaves no gap; accounts the order has never heard of — one
    /// added since the arrangement was made — land at the end, where they are
    /// predictable, rather than somewhere in the middle that would look random.
    private static func manually(_ accounts: [Account], order: [String]) -> [Account] {
        var remaining = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Account] = []
        for id in order {
            guard let account = remaining.removeValue(forKey: id) else { continue }
            result.append(account)
        }
        return result + byAddress(Array(remaining.values))
    }

    /// The order after one drop: the two exchange places, and nothing else
    /// moves.
    ///
    /// An exchange, not a re-insertion. Lifting the dragged item out and
    /// putting it back at the target's index is what a LIST does, and it is
    /// wrong for a grid dropped onto directly: closing the gap slides every
    /// item in between over by one, so the dragged account ends up NEXT TO the
    /// one it was dropped on instead of on it, and cells the user never touched
    /// change place. Two cells, two positions, exchanged — which is also the
    /// only reading the highlight on the target can honestly promise.
    ///
    /// Serves both the cells and the section headers — "dropped onto" is one
    /// idea, not two, and the ids happen to be account ids in one case and
    /// provider identifiers in the other.
    ///
    /// Either identifier being absent means the panel moved under the drag: a
    /// refresh removed an account between picking it up and letting it go. The
    /// order is then returned untouched, because there is no position to infer.
    public static func swapping(_ dragged: String, with target: String, in ids: [String]) -> [String] {
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target)
        else { return ids }

        var result = ids
        result.swapAt(from, to)
        return result
    }

    /// The sections, in the order they are shown.
    ///
    /// Stored providers first, then any the stored order does not name. That
    /// second half is what keeps a provider added in a later version — or one
    /// missing from a damaged stored value — from disappearing off the panel.
    /// Unknown and repeated entries are dropped, so every provider appears
    /// exactly once whatever is in `UserDefaults`.
    public static func sections(_ storedOrder: [String]) -> [Provider] {
        var result: [Provider] = []
        for identifier in storedOrder {
            guard let provider = Provider(rawValue: identifier), !result.contains(provider) else { continue }
            result.append(provider)
        }
        return result + Provider.allCases.filter { !result.contains($0) }
    }
}
