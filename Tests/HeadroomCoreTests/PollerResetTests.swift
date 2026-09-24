import Testing
import Foundation
@testable import HeadroomCore

private struct StubOAuth: OAuthProvider {
    let requiredPort: UInt16 = 0
    let result: Result<Tokens, Error>
    func authorizationURL(pkce: PKCE, redirectURI: String) -> URL { URL(string: "https://example.invalid")! }
    func exchange(code: String, pkce: PKCE, redirectURI: String) async throws -> Tokens { fatalError("unused") }
    func refresh(refreshToken: String) async throws -> Tokens { try result.get() }
}

private actor StubRedeemer: ResetRedeemer {
    private(set) var calls = 0
    private(set) var lastAccessToken: String?
    private let result: Result<ResetOutcome, Error>
    init(_ result: Result<ResetOutcome, Error>) { self.result = result }
    func redeem(account: Account, credits: ResetCredits, requestID: UUID) async throws -> ResetOutcome {
        calls += 1
        lastAccessToken = account.accessToken
        return try result.get()
    }
}

/// Holds the claim open until released — to put a second call, or a reading,
/// inside the first one's `await`.
private actor GatedRedeemer: ResetRedeemer {
    private(set) var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func redeem(account: Account, credits: ResetCredits, requestID: UUID) async throws -> ResetOutcome {
        calls += 1
        await withCheckedContinuation { waiters.append($0) }
        return .reset
    }
    func release() {
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private func claudeAccount(expiresAt: Date = .distantFuture) -> Account {
    Account(provider: .anthropic, email: "a@b.pl", accessToken: "tok", refreshToken: "ref", expiresAt: expiresAt)
}

private func resets(available: Int = 1, expiresAt: Date? = nil) -> ResetCredits {
    ResetCredits(available: available, expiresAt: expiresAt, clears: ["5 hours", "Week"], usableNow: true, blockedReason: nil, claimID: "g-1")
}

private func reading(session: Double = 37, resets: ResetCredits? = resets()) -> AccountUsage {
    AccountUsage(
        session: LimitWindow(percent: session, resetsAt: Date(), label: "5 hours"),
        weekly: LimitWindow(percent: 73, resetsAt: Date(), label: "Week"),
        scoped: [LimitWindow(percent: 12, resetsAt: nil, label: "Fable")],
        fetchedAt: Date(), staleness: .fresh, resets: resets
    )
}

private func makePoller(
    _ account: Account,
    redeemer: any ResetRedeemer,
    providers: [Provider: any UsageProvider] = [:],
    oauth: [Provider: any OAuthProvider] = [:],
    cached: AccountUsage? = reading(),
    clock: @escaping @Sendable () async -> Date = { Date() }
) async throws -> (Poller, AccountStore) {
    let store = AccountStore(secrets: InMemorySecretStore())
    try store.upsert(account)
    let poller = Poller(store: store, providers: providers, oauth: oauth, redeemers: [account.provider: redeemer], clock: clock)
    if let cached { await poller.loadCache([account.id: cached]) }
    return (poller, store)
}

/// A hand-driven clock — lets `refresh`'s "before the reset" and
/// `redeemReset`'s "reset applied at" timestamps be placed deterministically,
/// without depending on real wall-clock ordering across suspended tasks.
private actor TestClock {
    private var now: Date
    init(_ start: Date = Date()) { now = start }
    func reading() -> Date { now }
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

/// Holds a usage fetch open until released — to put a reset claim (and its
/// cache correction) inside a usage read for the same account that started
/// earlier but has not returned yet.
private actor GatedProvider: UsageProvider {
    private(set) var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let result: AccountUsage
    init(returning result: AccountUsage) { self.result = result }
    func fetch(account: Account) async throws -> AccountUsage {
        calls += 1
        await withCheckedContinuation { waiters.append($0) }
        return result
    }
    func release() {
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private struct ImmediateProvider: UsageProvider {
    let result: AccountUsage
    func fetch(account: Account) async throws -> AccountUsage { result }
}

private func waitUntil(_ condition: @escaping () async -> Bool) async {
    for _ in 0..<200 where !(await condition()) {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Test func aSuccessfulResetZeroesTheNamedWindowsAndCountsDown() async throws {
    let account = claudeAccount()
    let redeemer = StubRedeemer(.success(.reset))
    let (poller, _) = try await makePoller(account, redeemer: redeemer, cached: reading(resets: resets(available: 2)))

    let (usage, result) = await poller.redeemReset(account: account)

    #expect(result == .outcome(.reset))
    #expect(usage.session?.percent == 0)
    #expect(usage.weekly?.percent == 0)
    #expect(usage.scoped.first?.percent == 12)
    #expect(usage.resets?.available == 1)
    #expect(usage.resets?.claimID == "g-1")
    #expect(await poller.cache[account.id] == usage)
}

@Test func theLastResetLeavesNoResetsBehind() async throws {
    let account = claudeAccount()
    let (poller, _) = try await makePoller(account, redeemer: StubRedeemer(.success(.reset)))
    let (usage, _) = await poller.redeemReset(account: account)
    #expect(usage.resets == nil)
}

/// Every OpenAI credit is its own id, so the one just spent must not be
/// offered again — the server picks the next one.
@Test func aCodexResetDropsTheSpentCreditId() async throws {
    let account = Account(provider: .openai, email: "a@b.pl", accessToken: "tok", refreshToken: "ref", expiresAt: .distantFuture)
    let (poller, _) = try await makePoller(account, redeemer: StubRedeemer(.success(.reset)), cached: reading(resets: resets(available: 2)))
    let (usage, _) = await poller.redeemReset(account: account)
    #expect(usage.resets?.claimID == "")
}

@Test func aRefusalLeavesTheReadingAlone() async throws {
    let account = claudeAccount()
    let before = reading()
    let (poller, _) = try await makePoller(account, redeemer: StubRedeemer(.success(.nothingToReset)), cached: before)

    let (usage, result) = await poller.redeemReset(account: account)

    #expect(result == .outcome(.nothingToReset))
    #expect(usage == before)
}

@Test func withoutResetsNothingIsSent() async throws {
    let account = claudeAccount()
    let redeemer = StubRedeemer(.success(.reset))
    let (poller, _) = try await makePoller(account, redeemer: redeemer, cached: reading(resets: nil))

    let (_, result) = await poller.redeemReset(account: account)

    #expect(result == .nothingAvailable)
    #expect(await redeemer.calls == 0)
}

@Test func anExpiredResetIsNotSent() async throws {
    let account = claudeAccount()
    let redeemer = StubRedeemer(.success(.reset))
    let (poller, _) = try await makePoller(account, redeemer: redeemer, cached: reading(resets: resets(expiresAt: Date(timeIntervalSinceNow: -60))))

    let (_, result) = await poller.redeemReset(account: account)

    #expect(result == .nothingAvailable)
    #expect(await redeemer.calls == 0)
}

/// A renewal that fails must not reach the redeemer at all — there is no
/// working token to claim with, and the failure is reported the same way a
/// plain refusal is.
@Test func aFailedTokenRenewalNeverReachesTheRedeemer() async throws {
    let account = claudeAccount(expiresAt: Date(timeIntervalSinceNow: 60))
    let redeemer = StubRedeemer(.success(.reset))
    let oauth = StubOAuth(result: .failure(OAuthError.invalidGrant))
    let (poller, _) = try await makePoller(account, redeemer: redeemer, oauth: [.anthropic: oauth])

    let (_, result) = await poller.redeemReset(account: account)

    #expect(result == .failed)
    #expect(await redeemer.calls == 0)
}

@Test func anExpiringTokenIsRenewedBeforeTheClaim() async throws {
    let account = claudeAccount(expiresAt: Date(timeIntervalSinceNow: 60))
    let redeemer = StubRedeemer(.success(.reset))
    let oauth = StubOAuth(result: .success(Tokens(accessToken: "fresh", refreshToken: "ref2", expiresAt: .distantFuture)))
    let (poller, store) = try await makePoller(account, redeemer: redeemer, oauth: [.anthropic: oauth])

    _ = await poller.redeemReset(account: account)

    #expect(await redeemer.lastAccessToken == "fresh")
    #expect(try store.load().first?.refreshToken == "ref2")
}

/// The claim endpoint sits outside `/api/oauth/` and is undocumented — its
/// 401/403 says nothing reliable about the token, unlike the usage endpoint's.
/// Flagging `needsReauth` here would hide a perfectly working account behind
/// "Add this account again"; the next usage read is what actually decides.
@Test func aRejectionOfTheClaimDoesNotAskForASignIn() async throws {
    let account = claudeAccount()
    let (poller, store) = try await makePoller(account, redeemer: StubRedeemer(.failure(UsageError.unauthorized)))

    let (_, result) = await poller.redeemReset(account: account)

    #expect(result == .failed)
    #expect(try store.load().first?.needsReauth == false)
}

/// Same reasoning, for the other domain error the usage reader treats as a
/// dead token: the claim's own 403 for it is not that.
@Test func anOrganizationRefusalOfTheClaimDoesNotAskForASignIn() async throws {
    let account = claudeAccount()
    let (poller, store) = try await makePoller(account, redeemer: StubRedeemer(.failure(UsageError.organizationNotAllowed)))

    let (_, result) = await poller.redeemReset(account: account)

    #expect(result == .failed)
    #expect(try store.load().first?.needsReauth == false)
}

@Test func aNetworkErrorOnThePostIsUnconfirmed() async throws {
    let account = claudeAccount()
    let before = reading()
    let (poller, _) = try await makePoller(account, redeemer: StubRedeemer(.failure(URLError(.timedOut))), cached: before)

    let (usage, result) = await poller.redeemReset(account: account)

    #expect(result == .unconfirmed)
    #expect(usage == before)
}

@Test func anUnrecognisedAnswerIsUnconfirmed() async throws {
    let account = claudeAccount()
    let (poller, _) = try await makePoller(account, redeemer: StubRedeemer(.failure(ResetError.unrecognizedResponse)))
    #expect(await poller.redeemReset(account: account).result == .unconfirmed)
}

@Test func aServerErrorOnThePostIsUnconfirmed() async throws {
    let account = claudeAccount()
    let before = reading()
    let (poller, _) = try await makePoller(account, redeemer: StubRedeemer(.failure(UsageError.http(502))), cached: before)

    let (usage, result) = await poller.redeemReset(account: account)

    #expect(result == .unconfirmed)
    #expect(usage == before)
}

@Test func aClientErrorOnThePostIsAPlainFailure() async throws {
    let account = claudeAccount()
    let (poller, _) = try await makePoller(account, redeemer: StubRedeemer(.failure(UsageError.http(400))))
    #expect(await poller.redeemReset(account: account).result == .failed)
}

@Test func aFailureBeforeTheClaimIsAPlainFailure() async throws {
    let account = claudeAccount()
    let (poller, _) = try await makePoller(account, redeemer: StubRedeemer(.failure(ResetError.organizationUnknown)))
    #expect(await poller.redeemReset(account: account).result == .failed)
}

@Test func aSecondRedeemWhileTheFirstIsInFlightIsRefused() async throws {
    let account = claudeAccount()
    let redeemer = GatedRedeemer()
    let (poller, _) = try await makePoller(account, redeemer: redeemer)

    let first = Task { await poller.redeemReset(account: account) }
    await waitUntil { await redeemer.calls == 1 }
    let second = await poller.redeemReset(account: account)
    await redeemer.release()

    #expect(second.result == .alreadyInProgress)
    #expect(await first.value.result == .outcome(.reset))
    #expect(await redeemer.calls == 1)
}

/// `AppModel` hands `redeemReset` its own, possibly stale, copy of the
/// account — a `refreshAll` pass can have rotated and stored a new token
/// while that copy sat unread. Anthropic's rotation means the stale
/// `refreshToken` is already dead, so renewing from it would fail and, worse,
/// overwrite the good stored tokens with `needsReauth = true`. The claim must
/// load the newest copy from the store instead.
@Test func aClaimUsesTheStoredAccountNotTheStaleCopyThePanelPassedIn() async throws {
    let stored = claudeAccount(expiresAt: .distantFuture)
    var staleCopy = stored
    staleCopy.accessToken = "old"
    staleCopy.expiresAt = Date(timeIntervalSinceNow: 60)
    let redeemer = StubRedeemer(.success(.reset))
    // Would hand back `invalid_grant` if it were ever called — the stored
    // copy does not need a refresh at all, so it should never be reached.
    let oauth = StubOAuth(result: .failure(OAuthError.invalidGrant))
    var storedWithToken = stored
    storedWithToken.accessToken = "stored"
    let (poller, store) = try await makePoller(storedWithToken, redeemer: redeemer, oauth: [.anthropic: oauth])

    let (_, result) = await poller.redeemReset(account: staleCopy)

    #expect(result == .outcome(.reset))
    #expect(await redeemer.lastAccessToken == "stored")
    #expect(try store.load().first?.needsReauth == false)
}

/// The account can have been removed from the store while a reset button
/// press was still landing — `AppModel` guards against writing its result
/// back, but the claim itself must not go out for an account that is gone.
@Test func aClaimForAnAccountMissingFromTheStoreFails() async throws {
    let account = claudeAccount()
    let redeemer = StubRedeemer(.success(.reset))
    let store = AccountStore(secrets: InMemorySecretStore())
    // Deliberately not stored, to simulate a removal that raced the claim.
    let poller = Poller(store: store, providers: [:], redeemers: [account.provider: redeemer])
    await poller.loadCache([account.id: reading()])

    let (_, result) = await poller.redeemReset(account: account)

    #expect(result == .failed)
    #expect(await redeemer.calls == 0)
}

@Test func theResetIsAppliedToTheLatestCacheNotTheOneCapturedBeforeTheCall() async throws {
    let account = claudeAccount()
    let redeemer = GatedRedeemer()
    let (poller, _) = try await makePoller(account, redeemer: redeemer, cached: reading(session: 37))

    let first = Task { await poller.redeemReset(account: account) }
    await waitUntil { await redeemer.calls == 1 }
    // A reading that landed while the claim was on the wire.
    let newer = reading(session: 90).replacingResets(resets())
    let withNewScoped = AccountUsage(
        session: newer.session, weekly: newer.weekly,
        scoped: [LimitWindow(percent: 55, resetsAt: nil, label: "Fable")],
        fetchedAt: newer.fetchedAt, staleness: .fresh, resets: resets()
    )
    await poller.loadCache([account.id: withNewScoped])
    await redeemer.release()

    let (usage, _) = await first.value
    #expect(usage.session?.percent == 0)
    #expect(usage.scoped.first?.percent == 55)
}

/// A usage read already on the wire when a reset claim lands started from the
/// pre-reset numbers and must not be allowed to land afterwards and undo the
/// correction `redeemReset` already wrote — see `Poller.resetAppliedAt`.
@Test func aReadStartedBeforeAResetDoesNotOverwriteTheZeroedReading() async throws {
    let account = claudeAccount()
    let clock = TestClock()
    let staleReading = reading(session: 91, resets: resets(available: 1))
    let provider = GatedProvider(returning: staleReading)
    let (poller, _) = try await makePoller(
        account, redeemer: StubRedeemer(.success(.reset)),
        providers: [account.provider: provider],
        cached: staleReading,
        clock: { await clock.reading() }
    )

    // The read starts first and captures `now` before the claim lands.
    let readStartedAt = await clock.reading()
    let refreshTask = Task { await poller.refresh(account: account) }
    await waitUntil { await provider.calls == 1 }

    // The claim lands and applies its correction while the read is still
    // gated open.
    await clock.advance(by: 5)
    let (_, result) = await poller.redeemReset(account: account)
    #expect(result == .outcome(.reset))
    let corrected = await poller.cache[account.id]
    #expect(corrected?.session?.percent == 0)

    // Only now does the earlier read return, with the pre-reset numbers.
    await provider.release()
    let returned = await refreshTask.value

    // The stale numbers must not have overwritten the correction, and the
    // call itself must hand back the corrected reading rather than the one it
    // actually fetched.
    #expect(await poller.cache[account.id] == corrected)
    #expect(returned == corrected)
    #expect(returned.session?.percent == 0)

    // Discarding a superseded read is not a failure: the usual success
    // bookkeeping (backoff cleared, next poll scheduled a full interval out
    // from THIS read's own start) still applies.
    #expect(await poller.nextDue(for: account) == readStartedAt.addingTimeInterval(Poller.baseInterval))
}

/// The mirror case: once a read starts AFTER the reset has landed, it is
/// trusted normally — this is what lets the confirming check (see
/// `AppModel.redeemReset`) actually pick up the provider's own numbers.
@Test func aReadStartedAfterAResetOverwritesNormally() async throws {
    let account = claudeAccount()
    let clock = TestClock()
    let freshFromProvider = reading(session: 12, resets: nil)
    let provider = ImmediateProvider(result: freshFromProvider)
    let (poller, _) = try await makePoller(
        account, redeemer: StubRedeemer(.success(.reset)),
        providers: [account.provider: provider],
        cached: reading(session: 91, resets: resets(available: 1)),
        clock: { await clock.reading() }
    )

    let (_, result) = await poller.redeemReset(account: account)
    #expect(result == .outcome(.reset))

    // A read starting well after the claim landed — as the confirming check
    // does, ~185 seconds later.
    await clock.advance(by: 200)
    let returned = await poller.refresh(account: account)

    #expect(returned == freshFromProvider)
    #expect(await poller.cache[account.id] == freshFromProvider)
}

// MARK: - One token renewal per account at a time

/// Behaves like Anthropic's token endpoint: every refresh token works once,
/// and a second use of it is `invalid_grant`. The first renewal is held open
/// until released, so a second caller can be put inside its `await`.
private actor GatedOAuth: OAuthProvider {
    nonisolated let requiredPort: UInt16 = 0
    private(set) var calls = 0
    private var spent: Set<String> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let tokens: Tokens
    init(returning tokens: Tokens) { self.tokens = tokens }
    nonisolated func authorizationURL(pkce: PKCE, redirectURI: String) -> URL { URL(string: "https://example.invalid")! }
    func exchange(code: String, pkce: PKCE, redirectURI: String) async throws -> Tokens { fatalError("unused") }
    func refresh(refreshToken: String) async throws -> Tokens {
        calls += 1
        guard spent.insert(refreshToken).inserted else { throw OAuthError.invalidGrant }
        await withCheckedContinuation { waiters.append($0) }
        return tokens
    }
    func release() {
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Remembers which access token each usage read went out with.
private actor RecordingProvider: UsageProvider {
    private(set) var accessTokens: [String] = []
    private let result: AccountUsage
    init(returning result: AccountUsage) { self.result = result }
    func fetch(account: Account) async throws -> AccountUsage {
        accessTokens.append(account.accessToken)
        return result
    }
}

private let renewedTokens = Tokens(accessToken: "fresh", refreshToken: "ref2", expiresAt: .distantFuture)

/// A per-account check and a reset claim can both find the same account's
/// token about to expire. Both renewing would send the same refresh token
/// twice: Anthropic rotates it on the first use, so the second gets
/// `invalid_grant` — and would then write its stale tokens with
/// `needsReauth = true` over the good ones the first just stored. The second
/// caller has to wait for the first renewal and use its result.
@Test func aCheckAndAClaimNeedingARenewalAtOnceRenewOnlyOnce() async throws {
    let account = claudeAccount(expiresAt: Date(timeIntervalSinceNow: 60))
    let oauth = GatedOAuth(returning: renewedTokens)
    let provider = RecordingProvider(returning: reading())
    let redeemer = StubRedeemer(.success(.reset))
    let (poller, store) = try await makePoller(
        account, redeemer: redeemer,
        providers: [account.provider: provider],
        oauth: [.anthropic: oauth]
    )

    let check = Task { await poller.refreshOne(account: account) }
    await waitUntil { await oauth.calls == 1 }
    let claim = Task { await poller.redeemReset(account: account) }
    // Long enough for the claim to reach its own renewal decision while the
    // first renewal is still held open.
    try? await Task.sleep(for: .milliseconds(100))
    await oauth.release()

    _ = await check.value
    let (_, result) = await claim.value

    #expect(await oauth.calls == 1)
    #expect(result == .outcome(.reset))
    #expect(await provider.accessTokens == ["fresh"])
    #expect(await redeemer.lastAccessToken == "fresh")
    let saved = try #require(try store.load().first)
    #expect(saved.accessToken == "fresh")
    #expect(saved.refreshToken == "ref2")
    #expect(saved.needsReauth == false)
}

/// The same for two reads of one account — a `refreshAll` pass and the
/// per-account button, say.
@Test func twoChecksNeedingARenewalAtOnceRenewOnlyOnce() async throws {
    let account = claudeAccount(expiresAt: Date(timeIntervalSinceNow: 60))
    let oauth = GatedOAuth(returning: renewedTokens)
    let provider = RecordingProvider(returning: reading())
    let (poller, store) = try await makePoller(
        account, redeemer: StubRedeemer(.success(.reset)),
        providers: [account.provider: provider],
        oauth: [.anthropic: oauth]
    )

    let first = Task { await poller.refresh(account: account) }
    await waitUntil { await oauth.calls == 1 }
    let second = Task { await poller.refresh(account: account) }
    try? await Task.sleep(for: .milliseconds(100))
    await oauth.release()

    let results = [await first.value, await second.value]

    #expect(await oauth.calls == 1)
    #expect(results.allSatisfy { $0.staleness == .fresh })
    #expect(await provider.accessTokens == ["fresh", "fresh"])
    let saved = try #require(try store.load().first)
    #expect(saved.refreshToken == "ref2")
    #expect(saved.needsReauth == false)
}

/// A caller still holding the copy from before a renewal — a `refreshAll`
/// pass loads its accounts once — must not renew again from that copy's
/// already rotated refresh token when the stored twin is fresh.
@Test func aCheckFromAStaleCopyUsesTheAlreadyRenewedStoredAccount() async throws {
    var stored = claudeAccount(expiresAt: .distantFuture)
    stored.accessToken = "stored"
    var staleCopy = stored
    staleCopy.accessToken = "old"
    staleCopy.expiresAt = Date(timeIntervalSinceNow: 60)
    let oauth = StubOAuth(result: .failure(OAuthError.invalidGrant))
    let provider = RecordingProvider(returning: reading())
    let (poller, store) = try await makePoller(
        stored, redeemer: StubRedeemer(.success(.reset)),
        providers: [stored.provider: provider],
        oauth: [.anthropic: oauth]
    )

    let result = await poller.refresh(account: staleCopy)

    #expect(result.staleness == .fresh)
    #expect(await provider.accessTokens == ["stored"])
    #expect(try store.load().first?.needsReauth == false)
}
