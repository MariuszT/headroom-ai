import Foundation

/// The one sentence a cell adds under its limit bars, or nothing when the bars
/// already say everything.
///
/// In the core rather than in the view so the branches can be tested without a
/// running app — the same reason `MenuBarReading.all` lives here. It earned
/// that move: making the limit windows optional opened a case in which every
/// branch declined to speak and the cell showed its address and nothing else.
public enum AccountNote {
    public static func text(for account: Account, usage: AccountUsage?) -> String? {
        // Named from the account, not hard-coded: `Poller` sets `needsReauth`
        // on a rejection from EITHER provider, so a Codex account turned away
        // by chatgpt.com used to be told that Anthropic had refused it.
        if account.needsReauth {
            return "Rejected by \(account.provider.displayName). Add this account again to renew it."
        }
        guard let usage else { return "Waiting for the first check." }
        if case .error(let description) = usage.staleness { return description }

        // Before the staleness of a reading comes whether it says anything at
        // all. A reply that parses but carries no windows draws no bars, so
        // without this the cell would be silent — and a field renamed by either
        // provider would empty the whole panel with no explanation anywhere.
        // Said even for a cached reading: how old the silence is matters less
        // than that it is silence.
        if usage.windows.isEmpty {
            return "Checked, but the provider reported no limits."
        }

        if case .cached(let since) = usage.staleness {
            return "Last checked \(ResetFormatter.stringSince(since))."
        }
        return nil
    }
}
