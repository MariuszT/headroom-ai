import Foundation

/// Refreshes limit usage for every account, honouring the backoff after errors
/// and renewing OAuth tokens just before they expire.
///
/// The mutable state (`cache`, next due dates, failure counts) is protected by
/// actor isolation — no locks and no `@unchecked Sendable`.
public actor Poller {
    public static let baseInterval: TimeInterval = 300
    public static let minimumInterval: TimeInterval = 180
    public static let tokenRefreshThreshold: TimeInterval = 600

    private let store: AccountStore
    private let providers: [Provider: any UsageProvider]
    private let oauth: [Provider: any OAuthProvider]
    private let redeemers: [Provider: any ResetRedeemer]
    /// The clock, injected from outside — plain `Date()` in production, a
    /// controllable clock in tests, so backoff windows measured in minutes can
    /// be moved without a real `Task.sleep`.
    private let clock: @Sendable () async -> Date
    public private(set) var cache: [String: AccountUsage] = [:]
    private var nextDueAt: [String: Date] = [:]
    private var failureCount: [String: Int] = [:]
    /// When each account was last ATTEMPTED — success or failure alike —
    /// independent of `nextDueAt` (which a forced refresh ignores). This is the
    /// one thing a forced "Check now" may never skip: the hard 180-second floor
    /// below which Anthropic's endpoint answers 429. It has to key on the
    /// ATTEMPT rather than on success — an account that has never succeeded (or
    /// has just started returning 429) would otherwise have a floor of zero and
    /// every forced refresh would hammer it.
    private var lastAttempt: [String: Date] = [:]
    /// Accounts with a reset claim on the wire. The actor lets a second call in
    /// at every `await`, so without this two presses could spend two resets.
    private var redeemingResets: Set<String> = []
    /// When a reset was last applied to an account's cache — set in
    /// `redeemReset`, read in `refresh`. A usage read already in flight when
    /// the claim lands started from the pre-reset numbers and can still land
    /// AFTER the claim's own correction, which would silently undo it. A read
    /// whose start predates this timestamp is known stale for that reason
    /// alone, whatever the provider answered.
    private var resetAppliedAt: [String: Date] = [:]
    /// Token renewals on the wire, one per account at most. The actor lets a
    /// second call in at the `await` on the OAuth provider, and a check and a
    /// reset claim (or two checks) can both find the same token about to
    /// expire. Anthropic rotates the refresh token on every renewal, so a
    /// second renewal sent with the same refresh token gets `invalid_grant` —
    /// and would then store its stale tokens with `needsReauth = true` over
    /// the good ones the first renewal had just saved. A later caller waits
    /// for the renewal already in flight and takes its result instead.
    private var renewals: [String: Task<TokenCheck, Never>] = [:]

    public init(
        store: AccountStore,
        providers: [Provider: any UsageProvider],
        oauth: [Provider: any OAuthProvider] = [:],
        redeemers: [Provider: any ResetRedeemer] = [:],
        clock: @escaping @Sendable () async -> Date = { Date() }
    ) {
        self.store = store
        self.providers = providers
        self.oauth = oauth
        self.redeemers = redeemers
        self.clock = clock
    }

    public func loadCache(_ new: [String: AccountUsage]) {
        cache = new
    }

    /// Clears one account's polling history: its last attempt, its backoff
    /// window and its failure count.
    ///
    /// This is called after an account is signed in again. All of that state
    /// keys on the account id, and that does not change when the account is
    /// re-authenticated, so without clearing it fresh credentials inherit the
    /// penalty earned by failed attempts with the old token — including the
    /// hard 180-second floor, which gagged the account at exactly the moment
    /// the user was checking whether the sign-in had worked. The cache stays:
    /// the last known number still beats an empty row.
    public func forgetState(id: String) {
        lastAttempt[id] = nil
        nextDueAt[id] = nil
        failureCount[id] = nil
    }

    /// A token lives for hours, so it is renewed only just before it expires —
    /// every refresh at Anthropic invalidates the previous refresh token, so
    /// the rarer the better.
    public static func needsTokenRefresh(account: Account, now: Date = Date()) -> Bool {
        account.expiresAt.timeIntervalSince(now) < tokenRefreshThreshold
    }

    /// When an account is next due. An account that has never been queried is
    /// always "already due" — hence `.distantPast` rather than the current
    /// time, which lets this method stay synchronous.
    public func nextDue(for account: Account) -> Date {
        nextDueAt[account.id] ?? .distantPast
    }

    /// The account's own last-attempt timestamp — exposed so `AppModel` can
    /// fold it into the delay before its post-reset confirming check (see
    /// `redeemReset` there): a read already on the wire when a reset lands can
    /// record a `lastAttempt` more recent than the claim's own return, and
    /// timing the confirming check from the claim alone could still land it
    /// inside that read's 180-second floor.
    public func lastAttempt(for id: String) -> Date? {
        lastAttempt[id]
    }

    /// `interval` is the gap between refreshes configured by the user (see
    /// `AppModel.intervalSeconds`); it is clamped to `minimumInterval` here
    /// anyway — the 180-second floor holds whether or not the caller (for
    /// instance `AppModel`) remembered to clamp it.
    public func refresh(account: Account, interval: TimeInterval = Poller.baseInterval) async -> AccountUsage {
        let current: Account
        switch await freshToken(for: account) {
        case .ready(let renewed): current = renewed
        case .failed(let fallback): return fallback
        }

        guard let provider = providers[account.provider] else {
            return await lastValueOr(account: account, description: "No client for this provider.")
        }

        // The attempt is recorded BEFORE calling `fetch`, so that no path —
        // neither success nor any of the failure branches below — can query the
        // usage endpoint without noting it for the hard 180-second floor in
        // `refreshAll`.
        let now = await clock()
        lastAttempt[account.id] = now

        do {
            let result = try await provider.fetch(account: current)
            failureCount[account.id] = 0
            nextDueAt[account.id] = now.addingTimeInterval(max(interval, Self.minimumInterval))
            // This fetch started (`now`, captured above) before a reset was
            // applied to this account's cache — its numbers are the pre-reset
            // ones the claim already corrected, so writing them back would
            // silently spend the reset a second time in the row's own display.
            // Treated as an ordinary success otherwise (no backoff): the read
            // itself worked fine, it is simply superseded.
            if let appliedAt = resetAppliedAt[account.id], appliedAt > now {
                return cache[account.id] ?? result
            }
            cache[account.id] = result
            return result
        } catch UsageError.rateLimited {
            await increaseBackoff(account.id)
            return await lastValueOr(account: account, description: "Rate limited. Trying again later.")
        } catch UsageError.organizationNotAllowed {
            // The token works — it is the organisation it bound to that does
            // not report usage. We do not set `needsReauth`, because "sign in
            // again" would send the user back for the same error; what is more,
            // we CLEAR that flag if an earlier rejection left it set. It means
            // "dead token", and this one is alive — left in place it would hide
            // the one message in the row that says what to actually change.
            if current.needsReauth {
                var cleared = current
                cleared.needsReauth = false
                try? store.update(cleared)
            }
            await increaseBackoff(account.id)
            let named = account.organizationName.map { "\"\($0)\"" } ?? "This organisation"
            // Two very different situations answer with the same 403, and the
            // user can only act on one of them.
            let description = account.hasSubscription
                ? "\(named) bills per token and reports no subscription limits. This login does have a subscription — the sign-in page put the token on the wrong organisation, and only that page can choose."
                : "\(named) has no Claude subscription to report — it is an API organisation."
            return await lastValueOr(account: account, description: description)
        } catch UsageError.unauthorized {
            // 401 and 403 from the usage endpoint mean the same thing: this
            // token will never start working. Patient retrying achieves
            // nothing — the account has to be signed in again, and the row has
            // to say so.
            var flagged = current
            flagged.needsReauth = true
            try? store.update(flagged)
            await increaseBackoff(account.id)
            return await lastValueOr(account: account, description: "Rejected by the provider. Add this account again to renew it.")
        } catch {
            await increaseBackoff(account.id)
            return await lastValueOr(account: account, description: "No connection.")
        }
    }

    private enum TokenCheck: Sendable {
        case ready(Account)
        /// Renewal failed; carries the reading the row should show instead.
        /// It is per account, not per caller, so every caller that waited on
        /// the same renewal can be handed the same one.
        case failed(AccountUsage)
    }

    /// Renews the token when it is about to expire — shared by reading and by
    /// claiming a reset, so there is one copy of the rotation rules.
    private func freshToken(for account: Account) async -> TokenCheck {
        // The clock is read first because it is the only suspension point
        // here. Everything after it — joining a renewal in flight, reading the
        // store, starting a renewal — then happens in one uninterrupted
        // stretch, so a renewal that starts OR finishes while this caller is
        // suspended is always seen: joined if still running, and its stored
        // result read if already done.
        let now = await clock()
        if let inFlight = renewals[account.id] {
            return await inFlight.value
        }
        // The caller's copy can predate a renewal that has already finished —
        // `refreshAll` loads its accounts once for the whole pass, and
        // `AppModel` holds what it loaded last. Deciding from that copy would
        // renew again with a refresh token that is already dead, so the
        // newest stored copy decides. An account missing from the store (or
        // an unreadable store) falls back to the copy passed in; `update`
        // below then writes nothing back for it.
        let newest = (try? store.load())?.first(where: { $0.id == account.id }) ?? account
        guard Self.needsTokenRefresh(account: newest, now: now), let provider = oauth[account.provider] else {
            return .ready(newest)
        }
        // Unstructured, so it can be shared: the callers that join it only
        // await its value. It inherits this actor, so its body cannot start
        // before the task is recorded below.
        let renewal = Task { await self.renew(newest, with: provider) }
        renewals[account.id] = renewal
        let result = await renewal.value
        renewals[account.id] = nil
        return result
    }

    /// The renewal itself — reached only through `freshToken`, which makes
    /// sure there is never more than one per account at a time.
    private func renew(_ account: Account, with provider: any OAuthProvider) async -> TokenCheck {
        var current = account
        do {
            let tokens = try await provider.refresh(refreshToken: current.refreshToken)
            current.accessToken = tokens.accessToken
            current.refreshToken = tokens.refreshToken
            current.expiresAt = tokens.expiresAt
            current.needsReauth = false
            do {
                // `update`, not `upsert`: a check can still be in flight
                // when the user deletes the account, and appending it back
                // here would resurrect it. A `false` return is that case —
                // not a failure, because there is nothing left to store the
                // rotated token on.
                try store.update(current)
            } catch {
                // Anthropic rotates the refresh token on EVERY refresh, so
                // the old one is already dead on the server. Failing to
                // store the new one means that in a moment we will hold no
                // working token at all, which is itself a failure deserving
                // backoff and a diagnosis in the row — not a silent `try?`
                // that would hide it.
                await increaseBackoff(account.id)
                return .failed(await lastValueOr(account: account, description: "Could not save the renewed token."))
            }
        } catch OAuthError.invalidGrant {
            current.needsReauth = true
            try? store.update(current)
            return .failed(await lastValueOr(account: account, description: "Rejected by the provider. Add this account again to renew it."))
        } catch {
            await increaseBackoff(account.id)
            return .failed(await lastValueOr(account: account, description: "Could not renew the token."))
        }
        return .ready(current)
    }

    /// Checks one account on demand — the per-account refresh button.
    ///
    /// It behaves like "Check now" narrowed to a single account: the backoff
    /// window is ignored, because the user asked for this one explicitly, and
    /// the failure counter is cleared. The hard 180-second floor since the last
    /// ATTEMPT still holds, for the same reason it holds for the button that
    /// refreshes everything — Anthropic answers 429 below that window no matter
    /// who asked.
    public func refreshOne(
        account: Account,
        interval: TimeInterval = Poller.baseInterval
    ) async -> AccountUsage {
        let now = await clock()
        if let last = lastAttempt[account.id], now.timeIntervalSince(last) < Self.minimumInterval {
            return await lastValueOr(
                account: account,
                description: "Checked moments ago. Waiting before the next one."
            )
        }
        failureCount[account.id] = 0
        return await refresh(account: account, interval: interval)
    }

    /// Spends one banked reset on this account.
    ///
    /// Not an attempt for the 180-second floor — that guards the usage
    /// endpoint, and this is another one. On success the reading is corrected
    /// here rather than asked for again, because the floor would refuse the
    /// question; the caller schedules the confirming check (see `AppModel`).
    public func redeemReset(account: Account) async -> (usage: AccountUsage, result: ResetResult) {
        let now = await clock()
        // Both checks and the claim marker sit between the same two
        // suspension points, so no second call can slip in between them.
        guard !redeemingResets.contains(account.id) else {
            return (await currentReading(account), .alreadyInProgress)
        }
        guard let credits = cache[account.id]?.resets?.current(now: now), credits.available > 0 else {
            return (await currentReading(account), .nothingAvailable)
        }
        redeemingResets.insert(account.id)
        defer { redeemingResets.remove(account.id) }

        // `account` is the caller's own copy — `AppModel` hands over what it
        // last loaded, which can be stale while a `refreshAll` pass is still
        // running: that pass renews and stores tokens as it goes, but
        // `AppModel` only reloads its accounts once the whole pass finishes.
        // With Anthropic rotating the refresh token on every renewal, renewing
        // from the stale copy fails with `invalid_grant`, and `freshToken`
        // would then write the STALE tokens plus `needsReauth = true` over the
        // good ones a concurrent pass just stored. Reading the store again
        // here — after the guards and the claim marker above, so this adds no
        // suspension point between them — gets the newest copy instead.
        guard let stored = (try? store.load())?.first(where: { $0.id == account.id }) else {
            // Gone from the store entirely — removed while the claim was
            // queued. There is nothing left to renew or spend a reset on.
            return (await currentReading(account), .failed)
        }

        let current: Account
        switch await freshToken(for: stored) {
        case .ready(let renewed): current = renewed
        case .failed(let fallback): return (fallback, .failed)
        }
        guard let redeemer = redeemers[account.provider] else {
            return (await currentReading(account), .failed)
        }

        do {
            let outcome = try await redeemer.redeem(account: current, credits: credits, requestID: UUID())
            // Read fresh, right as the server's answer lands — not the `now`
            // from the top of this call, which predates the network round
            // trip to the redeemer: a read that started after this call began
            // but before the server actually confirmed the reset must still be
            // caught as stale by `refresh`. Read BEFORE the cache is touched:
            // the clock is a suspension point, and between writing the
            // corrected reading and stamping it, a read that started earlier
            // could land, miss the stamp and put the pre-reset numbers back.
            let appliedAt = await clock()
            // Read the cache again: a reading may have landed during the
            // claim, and the reset belongs on top of the newest numbers.
            if outcome == .reset, let latest = cache[account.id] {
                // An Anthropic grant keeps its id across its count; every
                // OpenAI credit is its own, so the spent one must go. The
                // Anthropic count spans every grant, so the kept id can
                // belong to a grant this claim just emptied — a press before
                // the confirming check replaces the reading is then answered
                // "already used" at worst, and nothing is spent.
                let nextClaim = account.provider == .anthropic ? credits.claimID : ""
                cache[account.id] = latest.applyingReset(
                    clearing: credits.clears,
                    remaining: credits.consumingOne(nextClaimID: nextClaim)
                )
                // Stamped in the same uninterrupted stretch as the write above.
                resetAppliedAt[account.id] = appliedAt
            }
            return (await currentReading(account), .outcome(outcome))
        } catch UsageError.unauthorized, UsageError.organizationNotAllowed {
            // Unlike the usage endpoint, the claim sits outside `/api/oauth/` —
            // it is undocumented, and its 401/403 says nothing reliable about
            // the token: a permission this one endpoint refuses is not the same
            // as a dead token, and usage reading can still work fine. Flagging
            // `needsReauth` here would hide a working account's bars behind
            // "Add this account again" for no reason; the next usage read is
            // what actually knows whether the token is good, so it is left to
            // decide, and nothing is written to the store here.
            return (await currentReading(account), .failed)
        } catch is URLError {
            // The claim may have reached the server before the connection
            // went — claiming it was not used would be a guess.
            return (await currentReading(account), .unconfirmed)
        } catch ResetError.unrecognizedResponse {
            return (await currentReading(account), .unconfirmed)
        } catch UsageError.http(let code) where code >= 500 {
            // Same reasoning as a dropped connection: a 5xx can be the
            // server failing AFTER it already recorded the claim, so
            // "unspent" would be a guess too.
            return (await currentReading(account), .unconfirmed)
        } catch {
            return (await currentReading(account), .failed)
        }
    }

    /// The reading as the cache holds it, untouched — a reset attempt is not a
    /// check, so it must not mark anything stale.
    private func currentReading(_ account: Account) async -> AccountUsage {
        if let cached = cache[account.id] { return cached }
        return await lastValueOr(account: account, description: "Nothing known about this account yet.")
    }

    /// Requests are spread out in time so that seventeen accounts do not hit
    /// both APIs in the same second — and accounts still inside a backoff
    /// window are skipped entirely, because Anthropic's endpoint rate-limits
    /// hard and repeating requests at the same rhythm after a 429 would only
    /// dig the hole deeper.
    ///
    /// `forced` is "Check now": it clears the failure counter and IGNORES
    /// `nextDueAt` (and therefore the backoff window) for every account —
    /// otherwise the button, pressed between two automatic cycles, would query
    /// no accounts at all and return nothing but cached values marked stale,
    /// without changing a single number. The one thing forcing may not
    /// skip is the hard 180-second floor measured from that particular
    /// account's LAST ATTEMPT (success or failure): Anthropic answers 429 below
    /// that window regardless of who asked for the refresh and regardless of
    /// whether the previous attempt succeeded. The failure counter is cleared
    /// only for the accounts this pass actually queries — an account rejected
    /// by the 180-second floor keeps its counter, otherwise a user pressing the
    /// button now and then would pin every failing account forever to the
    /// shallowest backoff step.
    ///
    /// `onResult`, when given, is called after each account rather than after
    /// the whole series — which lets the caller (see `AppModel`) publish
    /// results incrementally instead of holding the panel empty for the
    /// duration of all seventeen requests. Marked `@MainActor`, because
    /// the only caller is the UI, which has to update its state on the main
    /// actor anyway.
    public func refreshAll(
        interval: TimeInterval = Poller.baseInterval,
        forced: Bool = false,
        onResult: (@MainActor @Sendable (String, AccountUsage) -> Void)? = nil
    ) async -> [String: AccountUsage] {
        let accounts = (try? store.load()) ?? []
        let now = await clock()
        var results: [String: AccountUsage] = [:]
        var previousWasQueried = false

        for account in accounts {
            if forced {
                if let last = lastAttempt[account.id], now.timeIntervalSince(last) < Self.minimumInterval {
                    let result = await lastValueOr(account: account, description: "Checked moments ago. Waiting before the next one.")
                    results[account.id] = result
                    await onResult?(account.id, result)
                    continue
                }
                failureCount[account.id] = 0
            } else if nextDue(for: account) > now {
                let result = await lastValueOr(account: account, description: "Waiting out the backoff after an error.")
                results[account.id] = result
                await onResult?(account.id, result)
                continue
            }
            if previousWasQueried {
                try? await Task.sleep(for: .milliseconds(400))
            }
            previousWasQueried = true
            let result = await refresh(account: account, interval: interval)
            results[account.id] = result
            await onResult?(account.id, result)
        }
        return results
    }

    private func increaseBackoff(_ id: String) async {
        let count = (failureCount[id] ?? 0) + 1
        failureCount[id] = count
        let multiplier = pow(2.0, Double(min(count, 4)))
        nextDueAt[id] = await clock().addingTimeInterval(Self.minimumInterval * multiplier)
    }

    /// An empty window says nothing, while a stale number with a note says
    /// everything — so on an error or a skip (backoff) we fall back to the last
    /// known value, and only show the error when there is none.
    private func lastValueOr(account: Account, description: String) async -> AccountUsage {
        if let previous = cache[account.id] {
            return AccountUsage(
                session: previous.session,
                weekly: previous.weekly,
                scoped: previous.scoped,
                fetchedAt: previous.fetchedAt,
                staleness: .cached(since: previous.fetchedAt),
                resets: previous.resets
            )
        }
        // No windows at all rather than empty ones: nothing is known here, and
        // a pair of zeroes would read as "completely free" to anything that
        // looks at the numbers instead of the staleness.
        return AccountUsage(
            session: nil, weekly: nil, scoped: [],
            fetchedAt: await clock(), staleness: .error(description)
        )
    }
}
