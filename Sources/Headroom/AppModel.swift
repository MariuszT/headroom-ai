import SwiftUI
import AppKit
import Observation
import ServiceManagement
import HeadroomCore

@Observable
@MainActor
final class AppModel {
    private(set) var accounts: [Account] = []
    /// Set when the accounts could not be read — a locked keychain, or a prompt
    /// the user dismissed. It exists so the panel can say what happened: an
    /// empty list looks exactly like having lost every account, and the user
    /// would go and sign them all in again.
    private(set) var storeProblem: String?
    private(set) var usage: [String: AccountUsage] = [:]
    private(set) var isRefreshing = false

    /// The initial value reads `Preferences()` directly (not through
    /// `self.preferences`, because `self` does not exist yet in a property
    /// initialiser) — but that does not matter: the read falls back to the old
    /// key on its own when the new one is missing, so correctness does not
    /// depend on whether `preferences.migrate()` in `init()` has run yet.
    var showsPercentInMenuBar = Preferences().showsPercentInMenuBar {
        didSet { preferences.showsPercentInMenuBar = showsPercentInMenuBar }
    }

    /// How each section arranges its accounts, and the arrangement itself.
    /// Mirrored here rather than read from `Preferences` on every access,
    /// because `@Observable` tracks stored properties — a computed read of
    /// `UserDefaults` would change the order without redrawing the panel.
    ///
    /// Keyed by `Provider.rawValue` because that is the currency `Preferences`
    /// and `AccountOrdering.sections` already deal in, so nothing has to be
    /// converted on the way in or out. (`Provider` is perfectly `Hashable` —
    /// synthesised from its `String` raw value, which is also what
    /// `ForEach(model.sections, id: \.self)` relies on.)
    private(set) var sortModes: [String: SortMode] = [:]
    private(set) var manualOrders: [String: [String]] = [:]
    /// The sections in the order they are shown; always every provider exactly
    /// once — see `AccountOrdering.sections`.
    private(set) var sections: [Provider] = AccountOrdering.sections(Preferences().sectionOrder)

    func sortMode(for provider: Provider) -> SortMode {
        sortModes[provider.rawValue] ?? .alphabetical
    }

    /// One section's accounts, arranged the way that section is set to arrange
    /// them. See `AccountOrdering.sorted` — the logic lives in the core so it
    /// can be tested without a running app.
    func orderedAccounts(for provider: Provider) -> [Account] {
        AccountOrdering.sorted(
            accounts.filter { $0.provider == provider },
            usage: usage,
            mode: sortMode(for: provider),
            manualOrder: manualOrders[provider.rawValue] ?? []
        )
    }

    /// The button in the section header. Manual is not in the cycle: it is
    /// entered by dragging, and clicking out of it returns to alphabetical.
    func cycleSortMode(for provider: Provider) {
        setSortMode(sortMode(for: provider).next, for: provider)
    }

    private func setSortMode(_ mode: SortMode, for provider: Provider) {
        sortModes[provider.rawValue] = mode
        preferences.setSortMode(mode, for: provider)
    }

    /// Two accounts exchanging places, within a single section.
    ///
    /// The order is taken from what is on screen, not from what was stored:
    /// the first drag out of an alphabetical section has no stored order to
    /// rearrange, and the arrangement the user is looking at is the one they
    /// mean to change. Dropping is also what enters manual mode — asking for a
    /// separate click to keep the result would be a trap.
    func dropAccount(_ draggedID: String, onto targetID: String, in provider: Provider) {
        let shown = orderedAccounts(for: provider).map(\.id)
        let reordered = AccountOrdering.swapping(draggedID, with: targetID, in: shown)
        guard reordered != shown else { return }
        manualOrders[provider.rawValue] = reordered
        preferences.setManualOrder(reordered, for: provider)
        setSortMode(.manual, for: provider)
    }

    func dropSection(_ dragged: Provider, onto target: Provider) {
        let reordered = AccountOrdering.swapping(
            dragged.rawValue, with: target.rawValue, in: sections.map(\.rawValue)
        )
        sections = AccountOrdering.sections(reordered)
        preferences.sectionOrder = reordered
    }

    /// Which question the menu bar answers. See `MenuBarMetric`.
    var menuBarMetric = Preferences().menuBarMetric {
        didSet { preferences.menuBarMetric = menuBarMetric }
    }

    /// The slider in Settings is limited to 180...1800; `Preferences` clamps to
    /// the same bounds on read and write, so here we merely mirror the result
    /// of that clamp into `intervalSeconds` rather than computing it twice.
    var intervalSeconds: Double = Preferences().refreshIntervalSeconds {
        didSet {
            let target = Preferences.clampRefreshInterval(intervalSeconds)
            guard target == intervalSeconds else {
                intervalSeconds = target
                return
            }
            preferences.refreshIntervalSeconds = intervalSeconds
        }
    }

    /// Whether macOS starts the app at login. The real state lives in the
    /// system, not here, so this mirrors it and is re-read after every change
    /// rather than assumed: registration can fail, and it can also land in
    /// `.requiresApproval` when the user has switched the item off in System
    /// Settings, which is not a failure but is not "on" either.
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    /// Set when the system refused the last change, so the panel can say so
    /// instead of quietly flipping the switch back.
    private(set) var launchAtLoginProblem: String?

    func setLaunchAtLogin(_ wanted: Bool) {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginProblem = nil
        } catch {
            launchAtLoginProblem = wanted
                ? "macOS refused to add this as a login item. Check Login Items in System Settings."
                : "macOS refused to remove this login item. Check Login Items in System Settings."
        }
        // Trust the system over what we asked for.
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        if launchesAtLogin != wanted, launchAtLoginProblem == nil {
            launchAtLoginProblem = SMAppService.mainApp.status == .requiresApproval
                ? "Waiting for approval in System Settings, under Login Items."
                : nil
        }
    }

    /// A newer release, once one is found and while it has not been waved away.
    private(set) var availableUpdate: AvailableUpdate?

    /// What this build calls itself, which is what any newer version is
    /// compared against.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func dismissUpdate() {
        preferences.dismissedUpdateVersion = availableUpdate?.version
        availableUpdate = nil
    }

    func openUpdate() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.url)
    }

    /// Checked at launch and every six hours after. GitHub allows sixty
    /// unauthenticated calls an hour, so this is nowhere near anything, and a
    /// failed check is silent by design.
    private static let updateCheckInterval: TimeInterval = 6 * 3600
    private var lastUpdateCheck: Date?

    private func checkForUpdateIfDue() async {
        let now = Date()
        if let last = lastUpdateCheck, now.timeIntervalSince(last) < Self.updateCheckInterval {
            return
        }
        lastUpdateCheck = now
        guard let found = await UpdateChecker().check(currentVersion: currentVersion) else { return }
        guard preferences.dismissedUpdateVersion != found.version else { return }
        availableUpdate = found
    }

    private let preferences = Preferences()
    private let store = AccountStore.default
    private let poller: Poller
    private var loopTask: Task<Void, Never>?
    /// A handle on the sign-in currently in progress. Kept here rather than in
    /// the view so that "Cancel" and closing the window can genuinely interrupt
    /// it: `LoginFlow.logIn` responds to cancellation of this task by releasing
    /// the `CallbackListener` (see `LoginFlow.awaitCodeWithTimeout`), instead
    /// of merely hiding the window and leaving the listener — and, for Codex,
    /// port 1455 — occupied for the life of the process.
    private var loginTask: Task<Void, Never>?

    init() {
        // Versions before the move to the keychain left the tokens in a file;
        // this picks them up once and deletes it.
        _ = try? KeychainMigration.run(to: store)
        preferences.migrate()
        poller = Poller(
            store: store,
            providers: [
                .anthropic: AnthropicUsageClient(),
                .openai: CodexUsageClient(),
            ],
            oauth: [
                .anthropic: AnthropicOAuth(),
                .openai: OpenAIOAuth(),
            ],
            redeemers: [
                .anthropic: AnthropicResetClient(),
                .openai: CodexResetClient(),
            ]
        )
        for provider in Provider.allCases {
            sortModes[provider.rawValue] = preferences.sortMode(for: provider)
            manualOrders[provider.rawValue] = preferences.manualOrder(for: provider)
        }
        loadAccounts()
        // At launch, not only when Settings is opened. A permission granted in
        // an earlier session can be gone — revoked in System Settings, or
        // forgotten because the signature changed between builds — and until
        // this runs the switch keeps claiming "on" while every request is
        // dropped. That is the worst of the three states, because it is the one
        // that looks fine.
        checkNotificationAuthorization()
        startLoop()
    }

    /// See `MenuBarReading.all` — the logic lives in the core so it can be
    /// tested without a running app.
    var menuBarReadings: [MenuBarReading] {
        MenuBarReading.all(accounts: accounts, usage: usage, metric: menuBarMetric)
    }

    /// See `AccountStore.reload(keeping:)` — the logic lives in the core so it
    /// can be tested without a running app.
    func loadAccounts() {
        let reading = store.reload(keeping: accounts)
        accounts = reading.accounts
        storeProblem = reading.message
        // Rebuilt here rather than once in `init`, because this also runs after
        // a sign-in: an account added mid-session must pick up a date it
        // already had, and re-reading is safe because `setRenewal` writes
        // through to `Preferences` before it ever gets here.
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: the latter TRAPS on a
        // duplicate key. `AccountStore.load` decodes the stored array verbatim
        // and never deduplicates — uniqueness is an invariant `upsert` happens
        // to keep, not one the document guarantees — so a single duplicated
        // entry would turn a cosmetic oddity into a crash at launch, inside the
        // one method written to survive a damaged store.
        renewals = Dictionary(
            accounts.compactMap { account in
                preferences.renewal(for: account.id).map { (account.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Also on every reload, not just on edit: a reminder is scheduled for a
        // single date, so the one for a renewal that has just passed has to be
        // replaced by one for the next cycle, and an app left running for weeks
        // would otherwise go quiet after the first round.
        rescheduleReminders()
    }


    /// Forced: ignores `nextDueAt` (and therefore the backoff, and "too early
    /// for an automatic cycle") for every account, respecting only the hard
    /// 180-second floor since the last ATTEMPT (see
    /// `Poller.refreshAll(forced:)`) — without this, "Check now" pressed
    /// between two automatic cycles queried no accounts at all and merely
    /// flagged all seventeen as stale without changing a single number.
    func refreshNow() {
        Task { await refreshOnce(forced: true) }
    }

    /// Checks one account, from the button on its own cell. Useful when a
    /// single account is stale or was just rejected and the others are fine.
    func refreshAccount(id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        Task {
            usage[id] = await poller.refreshOne(account: account, interval: intervalSeconds)
            loadAccounts()
        }
    }

    func remove(id: String) {
        // Only once the account is really gone. `store.remove` throws on a
        // locked keychain or a refused prompt, and `loadAccounts` then puts the
        // account straight back on screen — while the renewal the user typed by
        // hand would already have been deleted for good. Clearing state for a
        // removal that did not happen is the same defect as `63c91fa`.
        guard (try? store.remove(id: id)) != nil else {
            loadAccounts()
            return
        }
        usage[id] = nil
        resetMessages[id] = nil
        resetAttempts[id] = nil
        // The renewal lives outside the account (see `Preferences.renewal`), so
        // it does not leave with it — and an id is `provider:email`, which a
        // later sign-in of the same address would reuse, inheriting a date set
        // for an account the user deliberately removed.
        setRenewal(nil, for: id)
        loadAccounts()
    }

    // MARK: - Limit resets

    /// One sentence about each account's last reset attempt, shown under its
    /// bars until it has nothing left to say.
    private(set) var resetMessages: [String: String] = [:]
    /// Accounts whose reset claim is on the wire — the row greys its buttons.
    private(set) var redeemingResets: Set<String> = []
    /// Which attempt currently owns `resetMessages[id]`. Comparing the message
    /// TEXT to decide whether to clear it (as this used to) lets an earlier
    /// attempt's timer clear a newer attempt's identical sentence — two
    /// presses in a row both failing say the exact same words. Tagging each
    /// attempt with its own id makes "is this still mine to clear" exact
    /// instead of a coincidence of wording.
    private var resetAttempts: [String: UUID] = [:]

    func redeemReset(id: String) {
        guard let account = accounts.first(where: { $0.id == id }), !redeemingResets.contains(id) else { return }
        redeemingResets.insert(id)
        resetMessages[id] = nil
        let attempt = UUID()
        resetAttempts[id] = attempt
        Task {
            let (newUsage, result) = await poller.redeemReset(account: account)
            redeemingResets.remove(id)
            // The account can have been removed while the claim was in the
            // air — `remove(id:)` already cleared its entries, and an id is
            // `provider:email`, reusable by a later sign-in of the same
            // address. Writing here would resurrect state for an account
            // that is gone, or hand it to whoever signs in next.
            guard accounts.contains(where: { $0.id == id }) else { return }
            usage[id] = newUsage.keepingStaleness(of: usage[id])
            let message = ResetLine.message(for: result)
            resetMessages[id] = message
            loadAccounts()

            if ResetLine.needsConfirmationCheck(result) {
                // The refresh loop waits a whole interval between passes, so
                // the provider's own numbers are asked for here, as soon as
                // the 180-second floor allows. The message stays until then:
                // it is what explains the zeroed bars.
                //
                // Timing from the claim's own return alone is not enough: a
                // regular poll can have a read for this very account already
                // on the wire when the claim lands (see `Poller.refresh` and
                // `resetAppliedAt`), which records a `lastAttempt` of its own
                // — possibly closer to "now" than the claim's return time.
                // Sleeping from the LATER of the two keeps this confirming
                // call outside the 180-second floor either way, so it is never
                // waved off with "Checked moments ago" and left to the next
                // full cycle to notice the confirmed reset.
                let claimReturnedAt = Date()
                let earliestConfirmAt = max(claimReturnedAt, await poller.lastAttempt(for: id) ?? claimReturnedAt)
                    .addingTimeInterval(Poller.minimumInterval + 5)
                let delay = earliestConfirmAt.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                if let current = accounts.first(where: { $0.id == id }) {
                    let confirmed = await poller.refreshOne(account: current, interval: intervalSeconds)
                    // Re-checked for the same reason as the guard above: the
                    // account may have been removed while THIS await was in
                    // flight too.
                    guard accounts.contains(where: { $0.id == id }) else { return }
                    // A regular poll can land in between and put this very
                    // call inside the 180-second floor — `refreshOne` then
                    // hands back the cache relabelled `.cached(since:)`
                    // instead of confirming anything. Writing that would mark
                    // an already-fresh reading stale for no reason: the
                    // regular poll that tripped the floor already delivered
                    // newer numbers, and if the claim genuinely failed to take
                    // effect, the next poll will surface that on its own.
                    if confirmed.staleness == .fresh {
                        usage[id] = confirmed
                    }
                    loadAccounts()
                }
            } else {
                try? await Task.sleep(for: .seconds(10))
            }
            // Only our own sentence — a newer attempt may have replaced it.
            // Tagged by id rather than by comparing text (see `resetAttempts`),
            // so two attempts landing the same wording can't clear each other.
            if resetAttempts[id] == attempt {
                resetMessages[id] = nil
                resetAttempts[id] = nil
            }
        }
    }

    /// When each account's plan renews, mirrored here for the same reason as
    /// `sortModes`: SwiftUI observes this model, not `UserDefaults`.
    private(set) var renewals: [String: RenewalSchedule] = [:]

    func setRenewal(_ schedule: RenewalSchedule?, for id: String) {
        renewals[id] = schedule
        preferences.setRenewal(schedule, for: id)
        rescheduleReminders()
    }

    /// Whether macOS should deliver the reminders too. The panel and the icon
    /// show renewals regardless — this only adds a banner, and it is the one
    /// part that a refused permission can take away.
    var notifiesRenewals = Preferences().notifiesRenewals {
        didSet {
            preferences.notifiesRenewals = notifiesRenewals
            guard notifiesRenewals else {
                renewalNotificationProblem = nil
                rescheduleReminders()
                return
            }
            authorizationTask?.cancel()
            authorizationTask = Task {
                let problem = await RenewalNotifier.requestAuthorization()
                // The switch can have been turned off while the system dialog
                // was up. Reporting "not allowed" under a switch that is
                // already off leaves an orange line no one can clear.
                guard !Task.isCancelled, notifiesRenewals else { return }
                renewalNotificationProblem = problem
                rescheduleReminders()
            }
        }
    }

    private(set) var renewalNotificationProblem: String?

    /// Held so a second flip of the switch cancels the first one's pending
    /// answer rather than racing it for the same field.
    private var authorizationTask: Task<Void, Never>?

    /// Re-checks what the system currently allows — at launch, and again
    /// whenever Settings is opened.
    func checkNotificationAuthorization() {
        guard notifiesRenewals else {
            renewalNotificationProblem = nil
            return
        }
        authorizationTask?.cancel()
        authorizationTask = Task {
            let problem = await RenewalNotifier.authorizationProblem()
            guard !Task.isCancelled, notifiesRenewals else { return }
            renewalNotificationProblem = problem
        }
    }

    private func rescheduleReminders() {
        RenewalNotifier.reschedule(
            RenewalReminders.all(accounts: accounts, renewals: renewals),
            enabled: notifiesRenewals,
            knownAccountIDs: accounts.map(\.id)
        )
    }

    /// Whether any account is inside its own lead window — what puts the mark
    /// on the menu bar icon. Deliberately separate from the glyphs' fill, which
    /// means usage and must go on meaning only that.
    func hasRenewalDue(now: Date = Date()) -> Bool {
        accounts.contains { account in
            renewals[account.id]?.status(now: now).isAlerting ?? false
        }
    }

    /// What a sign-in is doing, and how the last one ended.
    ///
    /// This lives on the model rather than in a view because the panel closes
    /// the instant the browser takes focus — by the time there is anything to
    /// report, whatever started the sign-in is gone. The user comes back by
    /// clicking the menu bar icon, and the panel has to be able to tell them
    /// what happened.
    enum LoginState: Equatable {
        case idle
        case running(Provider)
        case failed(Provider, String)
        /// Signed in to an account that was not on the list before.
        case added(String)
        /// Signed in again to an account already on the list. Nothing is
        /// duplicated — the identity is provider:email, so the entry is
        /// overwritten with fresh tokens — but the user asked for it and
        /// deserves to be told that is what happened.
        case reconnected(String)
    }

    private(set) var loginState: LoginState = .idle

    /// Starts a sign-in in the background and reports through `loginState`.
    /// There is no name to ask for — the provider tells us the email — so this
    /// takes only the provider and opens the browser immediately.
    ///
    /// The task handle is kept on `self` so that `cancelLogin()` can genuinely
    /// interrupt it: that is the only way an abandoned sign-in releases the
    /// `CallbackListener` instead of holding it — and, for Codex, port 1455 —
    /// for the life of the process.
    func startLogin(provider: Provider) {
        loginTask?.cancel()
        loginState = .running(provider)
        let knownIDs = Set(accounts.map(\.id))
        loginTask = Task { [store] in
            let flow = LoginFlow(store: store) { url in
                NSWorkspace.shared.open(url)
            }
            do {
                let added = try await flow.logIn(provider: provider)
                guard !Task.isCancelled else { return }
                loadAccounts()
                await checkImmediately(added)
                loginState = knownIDs.contains(added.id)
                    ? .reconnected(added.email)
                    : .added(added.email)
            } catch {
                guard !Task.isCancelled else { return }
                loginState = .failed(provider, errorDescription(error, provider: provider))
            }
        }
    }

    /// A freshly added account is checked at once and on its own, rather than
    /// through `refreshNow()`. That path skips two things which made a sign-in
    /// end in an empty row and look as though nothing had happened: the hard
    /// 180-second floor inherited from attempts with the old token (the
    /// poller's state keys on the account, not on the token) and the
    /// `guard !isRefreshing` that silently drops the request whenever an
    /// automatic cycle happens to be running — and a browser sign-in takes long
    /// enough to land in one.
    private func checkImmediately(_ account: Account) async {
        await poller.forgetState(id: account.id)
        usage[account.id] = await poller.refresh(account: account, interval: intervalSeconds)
        loadAccounts()
    }

    /// Clears whatever the last sign-in left on screen.
    func dismissLoginState() {
        loginState = .idle
    }

    /// Called from "Cancel" — whether or not a sign-in is in progress (with no
    /// running task it is a safe no-op).
    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        loginState = .idle
    }

    /// An occupied port 1455 is the only error the user can fix themselves, so
    /// we say plainly what is blocking them.
    func errorDescription(_ error: Error, provider: Provider) -> String {
        if case OAuthError.portInUse = error, provider == .openai {
            return "Port 1455 is in use. Quit any running `codex login` and try again."
        }
        if case OAuthError.stateMismatch = error {
            return "The browser's reply does not match this sign-in. Try again."
        }
        if case OAuthError.timedOut = error {
            return "No sign-in came back from the browser within five minutes. Try again."
        }
        if case OAuthError.incompleteCodexIdentity = error {
            return "Codex did not return a complete account identity (email or account id). Try signing in again."
        }
        if error is AnthropicProfileError {
            return "Could not read the Claude account identity. Try again."
        }
        return "Sign-in failed: \(error)"
    }

    private func startLoop() {
        loopTask = Task {
            while !Task.isCancelled {
                await refreshOnce()
                await checkForUpdateIfDue()
                await waitForNextRefresh()
            }
        }
    }

    /// Sleeps up to `intervalSeconds`, but in one-second slices, re-reading the
    /// current value each time — so a change on the Settings slider takes
    /// effect immediately (shortening it wakes the loop within a second)
    /// instead of waiting out the previously configured gap, which may be half
    /// an hour. The refresh still happens only once per turn of the loop, at
    /// its start, so this introduces no extra duplicate request.
    private func waitForNextRefresh() async {
        var elapsed: TimeInterval = 0
        while elapsed < intervalSeconds, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            elapsed += 1
        }
    }

    /// The only place that actually queries the `Poller`. Checking and setting
    /// `isRefreshing` has no `await` between the two, so on `@MainActor` it is
    /// indivisible — the startup loop and a manual "Check now" never query the
    /// providers at the same time: whichever arrives second simply does
    /// nothing, instead of duplicating requests. `forced` passes straight
    /// through to `Poller.refreshAll(forced:)` — the automatic loop never
    /// sets it, "Check now" always does.
    ///
    /// `onResult` publishes into `usage` AFTER EACH ACCOUNT rather than after
    /// the whole series of seventeen requests — without it the panel would sit
    /// empty for 15-20 s at app start even though the first results are ready
    /// within a fraction of a second. It is also the ONLY thing that publishes:
    /// see the note at the call below for why the returned dictionary is
    /// thrown away.
    ///
    /// Accounts are reloaded here (not only in `init`, `remove` and after a
    /// sign-in) for two reasons: `needsReauth`, written by the `Poller` after
    /// an `invalid_grant`, has to reach the view in the same cycle in which it
    /// appeared rather than after an app restart — and those same
    /// `accounts` drive `sorted(_:)` in `MenuContentView`.
    private func refreshOnce(forced: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        // The results land through `onResult`, one at a time, and the returned
        // dictionary is deliberately DISCARDED. `refreshAll` keys it by the
        // accounts it loaded when the pass began, so assigning it wholesale
        // threw away anything written while the pass was running — above all
        // the reading `checkImmediately` stores for an account signed in
        // mid-pass, which a browser sign-in takes long enough to be. That row
        // then sat empty until the next cycle, up to half an hour later, which
        // is the very thing `checkImmediately` exists to prevent.
        //
        // Nothing is lost by discarding it: every branch of `refreshAll`
        // publishes through `onResult` — see `refreshAllPublishesSkippedAccountsToo`.
        _ = await poller.refreshAll(
            interval: intervalSeconds,
            forced: forced,
            onResult: { [weak self] id, accountUsage in
                self?.usage[id] = accountUsage
            }
        )
        loadAccounts()
        isRefreshing = false
    }
}
