import Testing
import Foundation
@testable import HeadroomCore

/// A fixed UTC calendar, never `.current` — these tests assert on exact days,
/// and a machine in another time zone must not change what day a renewal falls
/// on.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

/// The rule that decides whether a monthly plan keeps its day of the month.
///
/// Every step is counted FROM THE ANCHOR, never from the previous step. Adding
/// a month to 31 January lands on 28 February, because the calendar clamps to
/// the length of the month — and stepping again from there would give 28 March,
/// then 28 April, so a plan anchored on the 31st would quietly become a plan
/// renewing on the 28th. Counting the n-th month from the anchor brings the
/// 31st back in every month that has one.
@Test func aMonthlyScheduleAnchoredOnThe31stDoesNotSlideToTheShorterMonth() {
    let schedule = RenewalSchedule(anchor: day(2026, 1, 31), cycle: .monthly, leadDays: 3)

    #expect(schedule.next(onOrAfter: day(2026, 2, 1), calendar: utc) == day(2026, 2, 28))
    #expect(schedule.next(onOrAfter: day(2026, 3, 1), calendar: utc) == day(2026, 3, 31))
}


/// The same counting-from-the-anchor rule, where it matters most: 29 February
/// exists once every four years, so a yearly plan anchored on it must come back
/// to the 29th in the next leap year rather than settling on the 28th.
@Test func aYearlyScheduleAnchoredOn29FebruaryReturnsToItInTheNextLeapYear() {
    let schedule = RenewalSchedule(anchor: day(2024, 2, 29), cycle: .yearly, leadDays: 7)

    #expect(schedule.next(onOrAfter: day(2027, 1, 1), calendar: utc) == day(2027, 2, 28))
    #expect(schedule.next(onOrAfter: day(2028, 1, 1), calendar: utc) == day(2028, 2, 29))
}


/// A plan billed every N days drifts across months by design — it has no day of
/// the month to keep.
@Test func aScheduleOfEveryNDaysCountsDaysAndNotMonths() {
    let schedule = RenewalSchedule(anchor: day(2026, 1, 20), cycle: .days(30), leadDays: 2)

    #expect(schedule.next(onOrAfter: day(2026, 1, 21), calendar: utc) == day(2026, 2, 19))
    #expect(schedule.next(onOrAfter: day(2026, 2, 20), calendar: utc) == day(2026, 3, 21))
}


/// A renewal you have not reached yet is its own next renewal. Counting always
/// starts at step zero, so an anchor set in the future is returned unchanged
/// rather than skipped to the cycle after it.
@Test func anAnchorInTheFutureIsItselfTheNextRenewal() {
    let schedule = RenewalSchedule(anchor: day(2026, 12, 1), cycle: .monthly, leadDays: 3)

    #expect(schedule.next(onOrAfter: day(2026, 9, 15), calendar: utc) == day(2026, 12, 1))
}


/// "In 1 day" has to mean one crossing of midnight, not 24 hours. Half an hour
/// before midnight, a renewal half an hour after it is tomorrow — subtracting
/// the two instants and dividing by 86_400 would call that zero days and the
/// row would read "today".
@Test func daysAwayCountsMidnightsRatherThanTwentyFourHourBlocks() {
    let schedule = RenewalSchedule(anchor: day(2026, 9, 16, hour: 0), cycle: .monthly, leadDays: 3)

    let status = schedule.status(now: day(2026, 9, 15, hour: 23), calendar: utc)

    #expect(status.daysAway == 1)
}


/// The whole point of `leadDays`: the account speaks up inside its own window
/// and stays quiet outside it.
@Test func anAccountAlertsOnlyOnceItIsInsideItsOwnLeadWindow() {
    let schedule = RenewalSchedule(anchor: day(2026, 9, 20), cycle: .monthly, leadDays: 3)

    #expect(schedule.status(now: day(2026, 9, 16), calendar: utc).isAlerting == false)
    #expect(schedule.status(now: day(2026, 9, 17), calendar: utc).isAlerting == true)
}


/// Renewals are wall-clock dates, not instants. A schedule stepping across the
/// spring clock change keeps its hour, because adding days through the calendar
/// adds 23 hours that day — adding 86_400 seconds would walk the renewal an
/// hour earlier each time.
@Test func aDailyScheduleKeepsItsHourAcrossADaylightSavingChange() {
    var warsaw = Calendar(identifier: .gregorian)
    warsaw.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    let anchor = warsaw.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 12))!
    let schedule = RenewalSchedule(anchor: anchor, cycle: .days(3), leadDays: 1)

    let dayAfter = warsaw.date(byAdding: .day, value: 1, to: anchor)!
    let next = schedule.next(onOrAfter: dayAfter, calendar: warsaw)

    #expect(warsaw.component(.hour, from: next) == 12)
    #expect(warsaw.component(.day, from: next) == 30)
}


/// A stored interval of zero must not be able to hang the app.
///
/// `Preferences.renewal(for:)` decodes whatever sits under its key, and
/// `{"days":{"_0":0}}` decodes into a perfectly valid-looking schedule. Stepping
/// by zero never advances the candidate, so the search for the next renewal
/// never ends — on the main thread, from `MenuBarIcon.label`, which runs on
/// every redraw. The editor's stepper cannot produce it; a hand-edited
/// `UserDefaults` or an older stored shape can.
@Test func anIntervalOfZeroDaysCannotStallTheSearch() {
    let schedule = RenewalSchedule(anchor: day(2026, 1, 1), cycle: .days(0), leadDays: 1)

    #expect(schedule.next(onOrAfter: day(2026, 1, 5), calendar: utc) == day(2026, 1, 5))
}


/// The search starts from a computed guess rather than from the anchor, so that
/// an old anchor does not cost one calendar round trip per elapsed cycle. The
/// guess is floored and must never land PAST the answer — this is the case that
/// catches it, because three years of monthly steps leave plenty of room for an
/// off-by-one to hide in.
@Test func anAnchorYearsBackStillLandsOnTheVeryNextRenewal() {
    // Anchored at midnight on purpose. With an anchor at midday the floored
    // month count comes out one short anyway, and the correcting loop hides an
    // estimate that overshoots — the assertion would pass either way and prove
    // nothing. At midnight the count is exact, so the estimate has to be too.
    let anchor = day(2023, 4, 10, hour: 0)
    let schedule = RenewalSchedule(anchor: anchor, cycle: .monthly, leadDays: 3)

    #expect(schedule.next(onOrAfter: day(2026, 9, 10, hour: 0), calendar: utc) == day(2026, 9, 10, hour: 0))
    #expect(schedule.next(onOrAfter: day(2026, 9, 11, hour: 0), calendar: utc) == day(2026, 10, 10, hour: 0))
}
