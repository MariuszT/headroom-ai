import Testing
import Foundation
@testable import HeadroomCore

private func account(_ email: String, _ provider: Provider = .anthropic) -> Account {
    Account(provider: provider, email: email, expiresAt: .distantPast)
}

private func usage(
    _ session: Double,
    weekly: Double = 0,
    staleness: Staleness = .fresh
) -> AccountUsage {
    AccountUsage(
        session: LimitWindow(percent: session, resetsAt: nil, label: "5 hours"),
        weekly: LimitWindow(percent: weekly, resetsAt: nil, label: "Week"),
        scoped: [],
        fetchedAt: Date(),
        staleness: staleness
    )
}

private let three = [account("celina@x.pl"), account("anna@x.pl"), account("bartek@x.pl")]

private func emails(
    _ accounts: [Account] = three,
    usage usageByID: [String: AccountUsage] = [:],
    mode: SortMode,
    manualOrder: [String] = []
) -> [String] {
    AccountOrdering.sorted(accounts, usage: usageByID, mode: mode, manualOrder: manualOrder)
        .map(\.email)
}

// MARK: - Alphabetical

@Test func alphabeticalOrdersByAddress() {
    #expect(emails(mode: .alphabetical) == ["anna@x.pl", "bartek@x.pl", "celina@x.pl"])
}

/// Addresses are not case-sensitive to a reader, so neither is their order —
/// a plain `<` would file every capital ahead of every lowercase letter.
@Test func alphabeticalIgnoresCase() {
    let mixed = [account("Beata@x.pl"), account("anna@x.pl"), account("Cezary@x.pl")]
    #expect(emails(mixed, mode: .alphabetical) == ["anna@x.pl", "Beata@x.pl", "Cezary@x.pl"])
}

@Test func alphabeticalIgnoresUsage() {
    let byUsage = ["anthropic:celina@x.pl": usage(99), "anthropic:anna@x.pl": usage(1)]
    #expect(emails(usage: byUsage, mode: .alphabetical) == ["anna@x.pl", "bartek@x.pl", "celina@x.pl"])
}

// MARK: - Fullness

/// The fullest account first: that is the one about to run out, and therefore
/// the one that needs a decision.
@Test func fullnessPutsTheFullestFirst() {
    let byUsage = [
        "anthropic:anna@x.pl": usage(10),
        "anthropic:bartek@x.pl": usage(90),
        "anthropic:celina@x.pl": usage(50),
    ]
    #expect(emails(usage: byUsage, mode: .fullness) == ["bartek@x.pl", "celina@x.pl", "anna@x.pl"])
}

/// An account nothing is known about must not pose as a good choice, but it
/// has not earned the head of the list either — so it sinks below every
/// account that does have a figure, including one sitting at zero.
@Test func fullnessSinksAccountsWithNoDataToTheEnd() {
    let byUsage = ["anthropic:celina@x.pl": usage(0)]
    #expect(emails(usage: byUsage, mode: .fullness).last != "celina@x.pl")
    #expect(emails(usage: byUsage, mode: .fullness).first == "celina@x.pl")
}

@Test func fullnessBreaksTiesAlphabetically() {
    let byUsage = [
        "anthropic:anna@x.pl": usage(50),
        "anthropic:bartek@x.pl": usage(50),
        "anthropic:celina@x.pl": usage(50),
    ]
    #expect(emails(usage: byUsage, mode: .fullness) == ["anna@x.pl", "bartek@x.pl", "celina@x.pl"])
}

// MARK: - Manual

@Test func manualFollowsTheStoredOrder() {
    let order = ["anthropic:celina@x.pl", "anthropic:anna@x.pl", "anthropic:bartek@x.pl"]
    #expect(emails(mode: .manual, manualOrder: order) == ["celina@x.pl", "anna@x.pl", "bartek@x.pl"])
}

/// A newly added account is in no stored order yet. It goes to the end, where
/// it is predictable — slotting it alphabetically into a hand-made arrangement
/// would look like it landed at random.
@Test func manualAppendsAccountsMissingFromTheStoredOrder() {
    let order = ["anthropic:celina@x.pl"]
    #expect(emails(mode: .manual, manualOrder: order) == ["celina@x.pl", "anna@x.pl", "bartek@x.pl"])
}

/// A removed account leaves its id behind in the stored order; it must not
/// open a gap or displace anyone.
@Test func manualIgnoresStoredIdentifiersThatNoLongerExist() {
    let order = ["anthropic:gone@x.pl", "anthropic:bartek@x.pl", "anthropic:ghost@x.pl"]
    #expect(emails(mode: .manual, manualOrder: order) == ["bartek@x.pl", "anna@x.pl", "celina@x.pl"])
}

@Test func manualWithNoStoredOrderIsAlphabetical() {
    #expect(emails(mode: .manual) == ["anna@x.pl", "bartek@x.pl", "celina@x.pl"])
}

// MARK: - Section order

@Test func sectionsFollowTheStoredOrder() {
    #expect(AccountOrdering.sections(["openai", "anthropic"]) == [.openai, .anthropic])
}

@Test func sectionsFallBackToTheBuiltInOrderWhenNothingIsStored() {
    #expect(AccountOrdering.sections([]) == Provider.allCases)
}

/// A provider added in a later version is in no stored order yet — it has to
/// appear anyway, rather than vanish from the panel.
@Test func sectionsAppendProvidersMissingFromTheStoredOrder() {
    #expect(AccountOrdering.sections(["openai"]) == [.openai, .anthropic])
}

/// Every provider appears exactly once however damaged the stored value is.
@Test func sectionsIgnoreUnknownAndRepeatedIdentifiers() {
    #expect(AccountOrdering.sections(["nonsense", "openai", "openai"]) == [.openai, .anthropic])
}

// MARK: - Reordering after a drop

/// Dropping one cell on another exchanges the two. Nothing else moves.
///
/// The alternative — lifting the dragged account out and re-inserting it at the
/// target's index — is what a LIST does, and it is wrong for a grid dropped
/// onto directly: everything between the two slides over to close the gap, so
/// the account lands NEXT TO the one it was dropped on rather than on it, and
/// cells the user never touched change place. Two cells, two positions,
/// exchanged.
@Test func droppingOneAccountOnAnotherExchangesTheTwo() {
    #expect(AccountOrdering.swapping("c", with: "a", in: ["a", "b", "c"]) == ["c", "b", "a"])
}

/// Direction cannot matter: the same two cells swapped are the same result
/// whichever one was picked up.
@Test func theExchangeIsTheSameInBothDirections() {
    #expect(AccountOrdering.swapping("a", with: "c", in: ["a", "b", "c"])
        == AccountOrdering.swapping("c", with: "a", in: ["a", "b", "c"]))
}

/// The cells in between are not touched — this is the whole difference from
/// re-inserting.
@Test func anExchangeLeavesEveryOtherAccountWhereItWas() {
    #expect(AccountOrdering.swapping("b", with: "e", in: ["a", "b", "c", "d", "e"])
        == ["a", "e", "c", "d", "b"])
}

@Test func neighboursExchangeCleanly() {
    #expect(AccountOrdering.swapping("a", with: "b", in: ["a", "b", "c"]) == ["b", "a", "c"])
}

@Test func droppingSomethingOnItselfChangesNothing() {
    #expect(AccountOrdering.swapping("b", with: "b", in: ["a", "b", "c"]) == ["a", "b", "c"])
}

/// Both of these mean the panel moved under the drag — a refresh removed an
/// account mid-gesture. Doing nothing is right; inventing a position is not.
@Test func droppingAnIdentifierThatIsNotInTheListChangesNothing() {
    #expect(AccountOrdering.swapping("z", with: "a", in: ["a", "b", "c"]) == ["a", "b", "c"])
}

@Test func droppingOntoATargetThatIsNotInTheListChangesNothing() {
    #expect(AccountOrdering.swapping("a", with: "z", in: ["a", "b", "c"]) == ["a", "b", "c"])
}

/// The sections use the same function on provider identifiers — there is one
/// notion of "dropped onto", not two.
@Test func theSameExchangePlacesSections() {
    #expect(AccountOrdering.swapping("openai", with: "anthropic", in: ["anthropic", "openai"])
        == ["openai", "anthropic"])
}

// MARK: - Fullness judges an account the way the menu bar does

/// An account is as full as its tightest window, not as its five-hour one.
/// Judging on the session alone put an account whose weekly limit is exhausted
/// at the BOTTOM of "fullest first" — presented as the emptiest thing to switch
/// to — while the menu bar, which has always used `worstPercent`, reported the
/// same account as full.
@Test func fullnessJudgesAnAccountByItsTightestWindow() {
    let byUsage = [
        "anthropic:anna@x.pl": usage(2, weekly: 100),
        "anthropic:bartek@x.pl": usage(50, weekly: 50),
        "anthropic:celina@x.pl": usage(10, weekly: 10),
    ]
    #expect(emails(usage: byUsage, mode: .fullness) == ["anna@x.pl", "bartek@x.pl", "celina@x.pl"])
}

/// A failed check leaves a cached entry reading 0% (see `Poller.lastValueOr`),
/// so "is there an entry" is not the same question as "is anything known". An
/// account whose row says it was rejected must not head the list of places with
/// room — `MenuBarReading` has always excluded these.
@Test func fullnessSinksAccountsInErrorBelowOnesThatAreSimplyEmpty() {
    let byUsage = [
        "anthropic:anna@x.pl": usage(0, staleness: .error("Rejected by the provider.")),
        "anthropic:bartek@x.pl": usage(0),
        "anthropic:celina@x.pl": usage(30),
    ]
    #expect(emails(usage: byUsage, mode: .fullness) == ["celina@x.pl", "bartek@x.pl", "anna@x.pl"])
}

/// One rule, in one place, for "what figure do we judge this account by".
@Test func aFreshReadingIsJudgedByItsWorstWindow() {
    #expect(usage(20, weekly: 70).knownPercent == 70)
}

@Test func areadingInErrorHasNoFigureToJudge() {
    #expect(usage(0, staleness: .error("nope")).knownPercent == nil)
}

/// A cached figure is stale, not absent — it is the last thing actually known,
/// and the panel shows it, so the order has to use it too.
@Test func aCachedReadingIsStillJudgedByItsWorstWindow() {
    #expect(usage(20, weekly: 70, staleness: .cached(since: Date())).knownPercent == 70)
}
