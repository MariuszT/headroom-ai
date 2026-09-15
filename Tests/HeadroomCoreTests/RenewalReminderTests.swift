import Testing
import Foundation
@testable import HeadroomCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func account(_ email: String) -> Account {
    Account(provider: .anthropic, email: email, expiresAt: .distantPast)
}

/// What the app asks the system to deliver is computed here, in the core, so
/// the timing can be tested without `UNUserNotificationCenter` — the app target
/// only hands the result over.
@Test func aReminderFiresInTheMorningOfTheLeadDay() {
    let schedule = RenewalSchedule(anchor: day(2026, 9, 20), cycle: .monthly, leadDays: 3)

    let reminders = RenewalReminders.all(
        accounts: [account("a@b.pl")],
        renewals: ["anthropic:a@b.pl": schedule],
        now: day(2026, 9, 10),
        calendar: utc
    )

    #expect(reminders.count == 1)
    #expect(reminders.first?.fireAt == day(2026, 9, 17, hour: 9))
}


/// A notification cannot be delivered in the past, and asking for one either
/// fires it immediately or is dropped — neither is what "warn me three days
/// before" means. Setting a renewal already inside its own window therefore
/// schedules nothing; the cell is already showing it in amber, which is the
/// part that still works.
@Test func aLeadDayAlreadyPassedSchedulesNothing() {
    let schedule = RenewalSchedule(anchor: day(2026, 9, 20), cycle: .monthly, leadDays: 3)

    let reminders = RenewalReminders.all(
        accounts: [account("a@b.pl")],
        renewals: ["anthropic:a@b.pl": schedule],
        now: day(2026, 9, 18),
        calendar: utc
    )

    #expect(reminders.isEmpty)
}


/// An account nobody set a date for is not a reminder waiting to happen.
@Test func anAccountWithNoRenewalProducesNoReminder() {
    let reminders = RenewalReminders.all(
        accounts: [account("a@b.pl")],
        renewals: [:],
        now: day(2026, 9, 10),
        calendar: utc
    )

    #expect(reminders.isEmpty)
}


/// The notification has to say WHICH account, because the whole reason this app
/// exists is that there are a dozen of them.
@Test func aReminderNamesTheAccountAndTheDate() {
    let schedule = RenewalSchedule(anchor: day(2026, 9, 20), cycle: .monthly, leadDays: 3)

    let reminder = RenewalReminders.all(
        accounts: [account("a@b.pl")],
        renewals: ["anthropic:a@b.pl": schedule],
        now: day(2026, 9, 10),
        calendar: utc
    ).first

    #expect(reminder?.title == "a@b.pl renews in 3 days")
    #expect(reminder?.body == "Claude Code — 20 Sep")
}
