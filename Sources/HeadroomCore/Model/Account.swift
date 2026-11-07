import Foundation

public enum Provider: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai

    /// The products' own names. Anthropic's CLI is Claude Code; OpenAI's is
    /// Codex. "Claude" alone would name the model, not the thing whose limit
    /// this is.
    public var displayName: String {
        switch self {
        case .anthropic: "Claude Code"
        case .openai: "Codex"
        }
    }
}

extension Provider: Identifiable {
    public var id: String { rawValue }
}

public struct Account: Codable, Sendable, Equatable, Identifiable {
    public let provider: Provider
    /// The account's own address, as its provider reports it. This is the
    /// label, and with `workspace` the identity: a second, user-invented name
    /// would identify nothing the two do not already say.
    public var email: String
    public var plan: String?
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    /// Codex only — goes into the `ChatGPT-Account-Id` header.
    public var accountId: String?
    /// Set when a token refresh came back with `invalid_grant`.
    public var needsReauth: Bool
    /// The organisation the token authorised against, as the provider named it.
    /// Explains a refusal — an account can belong to several, and only the one
    /// holding the subscription reports usage — and labels the cell when one
    /// address is connected through more than one of them.
    public var organizationName: String?
    /// Whether the login holds a Claude subscription, as opposed to only API
    /// access. Used to tell "the sign-in picked the wrong organisation" apart
    /// from "there is no subscription here to report".
    public var hasSubscription: Bool
    /// Anthropic only — the id of the organisation named above. `nil` on an
    /// entry stored before this field existed, until it is signed in again.
    public var organizationUUID: String?
    /// The workspace half of `id`, fixed when the entry is first stored.
    ///
    /// Separate from `workspace` because an id must never change under a
    /// stored entry. Renewal dates and the manual order are saved against it,
    /// and `Poller` writes rotated tokens back through it: a renewal in flight
    /// while the id moved would find no entry to land on, and at Anthropic the
    /// previous refresh token is already dead by then. So an entry from before
    /// workspaces were told apart decodes this as `nil` and keeps its old id
    /// for good, even once it learns its workspace.
    var idWorkspace: String?

    /// What a login is bound to beneath its address: the organisation at
    /// Anthropic, the workspace at OpenAI. Both bind a token to exactly one, and
    /// one address can hold several — a personal plan and a team's, say — each
    /// with limits of its own. `nil` only on an Anthropic entry from before
    /// `organizationUUID` was stored.
    public var workspace: String? {
        switch provider {
        case .anthropic: organizationUUID
        case .openai: accountId
        }
    }

    /// An account is identified by provider, email and workspace, so signing
    /// the same login in again overwrites the existing entry rather than adding
    /// a duplicate, while a second workspace at the same address gets an entry
    /// of its own. See `AccountStore.upsert`.
    public var id: String {
        let address = "\(provider.rawValue):\(email.lowercased())"
        return idWorkspace.map { "\(address):\($0)" } ?? address
    }

    public init(
        provider: Provider,
        email: String,
        plan: String? = nil,
        accessToken: String = "",
        refreshToken: String = "",
        expiresAt: Date = .distantPast,
        accountId: String? = nil,
        needsReauth: Bool = false,
        organizationName: String? = nil,
        hasSubscription: Bool = false,
        organizationUUID: String? = nil
    ) {
        self.provider = provider
        self.email = email
        self.plan = plan
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountId = accountId
        self.needsReauth = needsReauth
        self.organizationName = organizationName
        self.hasSubscription = hasSubscription
        self.organizationUUID = organizationUUID
        self.idWorkspace = workspace
    }
}
