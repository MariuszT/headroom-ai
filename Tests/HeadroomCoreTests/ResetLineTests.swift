import Testing
import Foundation
@testable import HeadroomCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func credits(_ available: Int = 1, expiresAt: Date? = nil, clears: [String] = ["5 hours", "Week"]) -> ResetCredits {
    ResetCredits(available: available, expiresAt: expiresAt, clears: clears, usableNow: true, blockedReason: nil, claimID: "g")
}

private let october22 = utc.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 16))!

@Test func oneResetWithADate() {
    #expect(ResetLine.text(for: credits(1, expiresAt: october22), calendar: utc) == "1 reset available · until 22 Oct")
}

@Test func severalResetsArePlural() {
    #expect(ResetLine.text(for: credits(2, expiresAt: october22), calendar: utc) == "2 resets available · until 22 Oct")
}

@Test func withoutADateTheLineStopsAtTheCount() {
    #expect(ResetLine.text(for: credits(1), calendar: utc) == "1 reset available")
}

@Test func threeDaysOrLessBeforeExpiryIsUrgent() {
    let now = october22.addingTimeInterval(-3 * 86_400)
    #expect(ResetLine.isUrgent(credits(expiresAt: october22), now: now) == true)
    #expect(ResetLine.isUrgent(credits(expiresAt: october22), now: now.addingTimeInterval(-1)) == false)
    #expect(ResetLine.isUrgent(credits(), now: now) == false)
}

@Test func theConfirmationNamesWhatItClearsAndHowFullItIs() {
    let usage = AccountUsage(
        session: LimitWindow(percent: 37.6, resetsAt: nil, label: "5 hours"),
        weekly: LimitWindow(percent: 73, resetsAt: nil, label: "Week"),
        scoped: [], fetchedAt: Date(), staleness: .fresh
    )
    #expect(ResetLine.confirmation(for: credits(), usage: usage) == "Reset 5 hours (37%) + Week (73%)? 1 left")
}

@Test func aWindowWithoutAReadingIsNamedWithoutANumber() {
    #expect(ResetLine.confirmation(for: credits(2), usage: nil) == "Reset 5 hours + Week? 2 left")
}

@Test func nothingNamedFallsBackToLimits() {
    #expect(ResetLine.confirmation(for: credits(clears: []), usage: nil) == "Reset limits? 1 left")
}

@Test func everyResultHasItsSentence() {
    #expect(ResetLine.message(for: .outcome(.reset)) == "Reset used. Numbers confirm in about 3 min.")
    #expect(ResetLine.message(for: .outcome(.nothingToReset)) == "Nothing to reset yet. The reset is still yours.")
    #expect(ResetLine.message(for: .outcome(.alreadyUsed)) == "This reset was already used.")
    #expect(ResetLine.message(for: .outcome(.coolingDown)) == "Cooling down. Try again later.")
    #expect(ResetLine.message(for: .outcome(.ineligible)) == "The provider says this account can't use it.")
    #expect(ResetLine.message(for: .failed) == "Reset failed. Nothing was used.")
    #expect(ResetLine.message(for: .unconfirmed) == "Couldn't confirm the reset. Checking again in about 3 min.")
    #expect(ResetLine.message(for: .nothingAvailable) == "No reset available right now.")
    #expect(ResetLine.message(for: .alreadyInProgress) == "A reset is already in progress.")
}

@Test func onlyResultsThatMayHaveChangedTheNumbersAreCheckedAgain() {
    #expect(ResetLine.needsConfirmationCheck(.outcome(.reset)))
    #expect(ResetLine.needsConfirmationCheck(.outcome(.alreadyUsed)))
    #expect(ResetLine.needsConfirmationCheck(.unconfirmed))
    #expect(!ResetLine.needsConfirmationCheck(.outcome(.nothingToReset)))
    #expect(!ResetLine.needsConfirmationCheck(.failed))
    #expect(!ResetLine.needsConfirmationCheck(.alreadyInProgress))
}
