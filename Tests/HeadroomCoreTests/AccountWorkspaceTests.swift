import Testing
import Foundation
@testable import HeadroomCore

private let expiry = Date(timeIntervalSince1970: 1_788_500_000)

private func emptyStore() -> AccountStore {
    AccountStore(secrets: InMemorySecretStore())
}

private func claudeLogin(
    _ organization: String?,
    name: String? = nil,
    email: String = "a@b.pl",
    token: String = "tok"
) -> Account {
    Account(
        provider: .anthropic, email: email,
        accessToken: token, refreshToken: "ref", expiresAt: expiry,
        organizationName: name, organizationUUID: organization
    )
}

private func codexLogin(_ workspace: String, token: String = "tok") -> Account {
    Account(
        provider: .openai, email: "a@b.pl",
        accessToken: token, refreshToken: "ref", expiresAt: expiry,
        accountId: workspace
    )
}

/// A store holding one entry exactly as a version from before workspaces were
/// told apart wrote it: no `organizationUUID`, no `idWorkspace`.
private func storeWithOlderEntry(
    provider: Provider = .anthropic,
    organizationName: String? = "Acme",
    accountId: String? = nil
) throws -> AccountStore {
    var entry: [String: Any] = [
        "provider": provider.rawValue,
        "email": "a@b.pl",
        "accessToken": "old",
        "refreshToken": "ref",
        "expiresAt": 1_788_500_000,
        "needsReauth": false,
        "hasSubscription": true,
    ]
    if let organizationName { entry["organizationName"] = organizationName }
    if let accountId { entry["accountId"] = accountId }
    let data = try JSONSerialization.data(withJSONObject: [entry])
    return AccountStore(secrets: InMemorySecretStore(data: data))
}

// MARK: - One address, several workspaces

/// The defect this exists for: the id used to be provider and email alone, so
/// the second organisation's sign-in replaced the first one's entry, tokens and
/// all, and reported it as a reconnection.
@Test func oneAddressInTwoOrganisationsIsTwoAccounts() throws {
    let store = emptyStore()
    try store.upsert(claudeLogin("o-1", token: "first"))
    try store.upsert(claudeLogin("o-2", token: "second"))

    let saved = try store.load()
    #expect(saved.map(\.accessToken) == ["first", "second"])
    #expect(Set(saved.map(\.id)).count == 2)
}

@Test func oneAddressInTwoCodexWorkspacesIsTwoAccounts() throws {
    let store = emptyStore()
    try store.upsert(codexLogin("ws-1", token: "first"))
    try store.upsert(codexLogin("ws-2", token: "second"))

    let saved = try store.load()
    #expect(saved.map(\.accessToken) == ["first", "second"])
    #expect(Set(saved.map(\.id)).count == 2)
}

/// Colleagues share an organisation; that does not make them one login.
@Test func twoAddressesInOneOrganisationAreTwoAccounts() throws {
    let store = emptyStore()
    try store.upsert(claudeLogin("o-1", email: "a@b.pl"))
    try store.upsert(claudeLogin("o-1", email: "c@d.pl"))

    #expect(try store.load().map(\.email) == ["a@b.pl", "c@d.pl"])
}

@Test func signingInToAnOrganisationAgainRenewsThatEntryOnly() throws {
    let store = emptyStore()
    try store.upsert(claudeLogin("o-1", token: "first"))
    try store.upsert(claudeLogin("o-2", token: "other"))

    let renewed = try store.upsert(claudeLogin("o-1", token: "fresh"))

    let saved = try store.load()
    #expect(saved.map(\.accessToken) == ["fresh", "other"])
    #expect(renewed.id == saved[0].id)
}

/// Addresses are compared the way `id` always spelled them.
@Test func aSecondSignInMatchesWhateverTheCaseOfTheAddress() throws {
    let store = emptyStore()
    try store.upsert(claudeLogin("o-1", email: "A@b.pl", token: "first"))
    try store.upsert(claudeLogin("o-1", email: "a@B.pl", token: "fresh"))

    #expect(try store.load().map(\.accessToken) == ["fresh"])
}

/// `update` is how `Poller` stores a rotated token, and at Anthropic the
/// previous refresh token is dead by then. Landing on the neighbouring
/// organisation's entry would cost both of them a sign-in.
@Test func aRotatedTokenLandsOnItsOwnOrganisation() throws {
    let store = emptyStore()
    try store.upsert(claudeLogin("o-1", token: "first"))
    var second = try store.upsert(claudeLogin("o-2", token: "second"))

    second.accessToken = "rotated"
    #expect(try store.update(second))

    #expect(try store.load().map(\.accessToken) == ["first", "rotated"])
}

@Test func removingOneOrganisationLeavesTheOther() throws {
    let store = emptyStore()
    let first = try store.upsert(claudeLogin("o-1", token: "first"))
    try store.upsert(claudeLogin("o-2", token: "second"))

    try store.remove(id: first.id)

    #expect(try store.load().map(\.accessToken) == ["second"])
}

@Test func aWorkspaceSurvivesTheRoundTripThroughTheStore() throws {
    let store = emptyStore()
    let stored = try store.upsert(claudeLogin("o-1"))

    let loaded = try store.load()[0]
    #expect(loaded.organizationUUID == "o-1")
    #expect(loaded.id == stored.id)
}

// MARK: - Entries stored by earlier versions

/// Renewal dates and the manual order are saved against the id, so an upgrade
/// that moved it would quietly drop them.
@Test func anOlderEntryKeepsTheIdentifierItWasStoredUnder() throws {
    #expect(try storeWithOlderEntry().load()[0].id == "anthropic:a@b.pl")

    let codex = try storeWithOlderEntry(provider: .openai, organizationName: nil, accountId: "ws-1")
    #expect(try codex.load()[0].id == "openai:a@b.pl")
}

/// The id stays even once the workspace is known — and the caller is handed
/// that id, not the one its own copy of the account would have spelled.
@Test func signingInToAnOlderEntrysOrganisationRenewsItUnderItsOldIdentifier() throws {
    let store = try storeWithOlderEntry(organizationName: "Acme")

    let renewed = try store.upsert(claudeLogin("o-1", name: "Acme", token: "fresh"))

    let saved = try store.load()
    #expect(saved.count == 1)
    #expect(saved[0].accessToken == "fresh")
    #expect(saved[0].organizationUUID == "o-1")
    #expect(saved[0].id == "anthropic:a@b.pl")
    #expect(renewed.id == "anthropic:a@b.pl")
}

/// What someone upgrading with one organisation connected does next. The older
/// entry has no uuid to compare, so its name is what keeps it from being lost.
@Test func anotherOrganisationArrivesBesideAnOlderEntry() throws {
    let store = try storeWithOlderEntry(organizationName: "Acme")

    try store.upsert(claudeLogin("o-2", name: "Other", token: "fresh"))

    let saved = try store.load()
    #expect(saved.map(\.accessToken) == ["old", "fresh"])
    #expect(Set(saved.map(\.id)).count == 2)
}

/// Nothing says these are two logins, so this does what every sign-in did
/// before workspaces were told apart.
@Test func anOlderEntryWithNoOrganisationNameIsOverwritten() throws {
    let store = try storeWithOlderEntry(organizationName: nil)

    try store.upsert(claudeLogin("o-1", name: "Acme", token: "fresh"))

    #expect(try store.load().map(\.accessToken) == ["fresh"])
}

/// An older entry that merely could be this login must not win over one that
/// is, even when it comes first in the list.
@Test func anExactMatchBeatsAnOlderEntryThatCouldBeTheSameLogin() throws {
    let store = try storeWithOlderEntry(organizationName: nil)
    try store.save(try store.load() + [claudeLogin("o-2", token: "second")])

    try store.upsert(claudeLogin("o-2", token: "fresh"))

    #expect(try store.load().map(\.accessToken) == ["old", "fresh"])
}

/// An older entry that has learned its uuid still holds the bare id, which is
/// also what a sign-in with no uuid would take. `update` finds entries by id, so
/// a second one under it would have its rotated tokens written over the first.
@Test func noTwoEntriesEverShareAnIdentifier() throws {
    let store = try storeWithOlderEntry(organizationName: "Acme")
    try store.upsert(claudeLogin("o-1", name: "Acme"))

    try store.upsert(claudeLogin(nil, name: "Other", token: "fresh"))

    let saved = try store.load()
    #expect(saved.map(\.accessToken) == ["fresh"])
    #expect(saved[0].id == "anthropic:a@b.pl")
}

/// Codex entries always stored their workspace, so nothing here has to fall
/// back on a name.
@Test func signingInToAnOlderCodexEntrysWorkspaceRenewsIt() throws {
    let store = try storeWithOlderEntry(provider: .openai, organizationName: nil, accountId: "ws-1")

    let renewed = try store.upsert(codexLogin("ws-1", token: "fresh"))

    #expect(try store.load().map(\.accessToken) == ["fresh"])
    #expect(renewed.id == "openai:a@b.pl")
}

@Test func anotherCodexWorkspaceArrivesBesideAnOlderEntry() throws {
    let store = try storeWithOlderEntry(provider: .openai, organizationName: nil, accountId: "ws-1")

    try store.upsert(codexLogin("ws-2", token: "fresh"))

    let saved = try store.load()
    #expect(saved.map(\.accessToken) == ["old", "fresh"])
    #expect(Set(saved.map(\.id)).count == 2)
}

// MARK: - Labels

private func claude(_ organization: String?, name: String?, email: String = "a@x.pl") -> Account {
    Account(provider: .anthropic, email: email, organizationName: name, organizationUUID: organization)
}

private func codex(_ workspace: String, plan: String?, email: String = "a@x.pl") -> Account {
    Account(provider: .openai, email: email, plan: plan, accountId: workspace)
}

@Test func anAddressConnectedOnceNeedsNoLabel() {
    let accounts = [claude("o-1", name: "Acme"), claude("o-2", name: "Other", email: "b@x.pl")]
    #expect(AccountLabels.workspaces(in: accounts).isEmpty)
}

@Test func organisationsAtOneAddressAreLabelledByName() {
    let acme = claude("o-1", name: "Acme")
    let other = claude("o-2", name: "Other")

    let labels = AccountLabels.workspaces(in: [acme, other])

    #expect(labels[acme.id] == "Acme")
    #expect(labels[other.id] == "Other")
}

@Test func addressesAreComparedWithoutRegardToCase() {
    let acme = claude("o-1", name: "Acme", email: "A@x.pl")
    let other = claude("o-2", name: "Other", email: "a@X.pl")

    #expect(AccountLabels.workspaces(in: [acme, other]).count == 2)
}

@Test func codexWorkspacesAreLabelledByTheirPlan() {
    let personal = codex("11111111-aaaa", plan: "plus")
    let team = codex("22222222-bbbb", plan: "team")

    let labels = AccountLabels.workspaces(in: [personal, team])

    #expect(labels[personal.id] == "plus")
    #expect(labels[team.id] == "team")
}

/// Two Team workspaces are the case a name cannot settle, and a cell labelled
/// the same as its neighbour would be no label at all.
@Test func workspacesSharingANameAreToldApartByTheirIds() {
    let first = codex("11111111-aaaa", plan: "team")
    let second = codex("22222222-bbbb", plan: "team")

    let labels = AccountLabels.workspaces(in: [first, second])

    #expect(labels[first.id] == "team · 111111")
    #expect(labels[second.id] == "team · 222222")
}

/// The older entry has no uuid to show, but its neighbour still needs a label.
@Test func anEntryWithNothingToShowIsLeftUnlabelled() {
    let older = claude(nil, name: nil)
    let acme = claude("o-1", name: "Acme")

    let labels = AccountLabels.workspaces(in: [older, acme])

    #expect(labels[older.id] == nil)
    #expect(labels[acme.id] == "Acme")
}

/// The two sit in different sections, so nothing on screen is ambiguous.
@Test func oneAddressAtBothProvidersNeedsNoLabel() {
    let accounts = [claude("o-1", name: "Acme"), codex("ws-1", plan: "plus")]
    #expect(AccountLabels.workspaces(in: accounts).isEmpty)
}

@Test func aDisplayNameCarriesTheLabelOnlyWhenThereIsOne() {
    let acme = claude("o-1", name: "Acme")
    let other = claude("o-2", name: "Other")

    #expect(AccountLabels.displayName(of: acme, among: [acme]) == "a@x.pl")
    #expect(AccountLabels.displayName(of: acme, among: [acme, other]) == "a@x.pl (Acme)")
}
