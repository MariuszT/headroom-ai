import Foundation

/// What tells accounts at one address apart on screen.
///
/// Most addresses are connected once, and for those the address says it all, so
/// only accounts sharing theirs get a label. In the core rather than in the
/// view so the branches can be tested without a running app.
public enum AccountLabels {
    /// Labels by account id. Accounts are compared within their provider: one
    /// address at both Claude Code and Codex sits in two sections, and a reader
    /// cannot mistake one for the other.
    public static func workspaces(in accounts: [Account]) -> [String: String] {
        let logins = Dictionary(grouping: accounts) {
            "\($0.provider.rawValue):\($0.email.lowercased())"
        }
        var labels: [String: String] = [:]
        for group in logins.values where group.count > 1 {
            for account in group {
                labels[account.id] = label(for: account, in: group)
            }
        }
        return labels
    }

    /// The address, and the label when it needs one — for the places that give
    /// an account a single line: a banner, a notification, a heading.
    public static func displayName(of account: Account, among accounts: [Account]) -> String {
        workspaces(in: accounts)[account.id].map { "\(account.email) (\($0))" } ?? account.email
    }

    /// A Codex sign-in stores no workspace name, only the plan (see
    /// `LoginFlow.accountIdentity`), so the plan is what labels it.
    private static func name(of account: Account) -> String? {
        account.organizationName ?? account.plan
    }

    /// The name alone when it sets this account apart. Two Team workspaces share
    /// theirs, and then the opening of the id is the one thing left that differs.
    private static func label(for account: Account, in group: [Account]) -> String? {
        let name = Self.name(of: account)
        if name != nil, group.filter({ Self.name(of: $0) == name }).count == 1 {
            return name
        }
        let parts = [name, account.workspace.map { String($0.prefix(6)) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
