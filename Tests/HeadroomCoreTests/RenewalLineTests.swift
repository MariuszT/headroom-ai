import Testing
import Foundation
@testable import HeadroomCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private func schedule(_ anchor: Date, leadDays: Int = 3) -> RenewalSchedule {
    RenewalSchedule(anchor: anchor, cycle: .monthly, leadDays: leadDays)
}

/// The line always names the date, not just the countdown. "In 3 days" alone
/// forces the reader to do the arithmetic before they can check it against a
/// bank statement, and a countdown with no date cannot be verified at all.
@Test func theLineNamesTheDayAsWellAsTheCountdown() {
    let text = RenewalLine.text(for: schedule(day(2026, 9, 18)), now: day(2026, 9, 15), calendar: utc)

    #expect(text == "Renews in 3 days (18 Sep)")
}


/// Counting is in days, so one day away is a word rather than a number — "in 1
/// day" is how nothing else in this app speaks (see `ResetFormatter`).
@Test func aRenewalOneDayAwayReadsAsTomorrow() {
    let text = RenewalLine.text(for: schedule(day(2026, 9, 16)), now: day(2026, 9, 15), calendar: utc)

    #expect(text == "Renews tomorrow (16 Sep)")
}


@Test func aRenewalOnTheCurrentDayReadsAsToday() {
    let text = RenewalLine.text(for: schedule(day(2026, 9, 15)), now: day(2026, 9, 15), calendar: utc)

    #expect(text == "Renews today (15 Sep)")
}


/// Far from its window the line is still shown — the panel answers "when does
/// this renew?" whether or not the answer is urgent. Colour, not presence, is
/// what the lead window controls.
@Test func aRenewalOutsideItsLeadWindowIsStillNamed() {
    let text = RenewalLine.text(for: schedule(day(2026, 10, 20)), now: day(2026, 9, 15), calendar: utc)

    #expect(text == "Renews in 35 days (20 Oct)")
}
