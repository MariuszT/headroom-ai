import Foundation

/// One notification the app wants the system to deliver.
public struct RenewalReminder: Equatable, Sendable, Identifiable {
    public let accountID: String
    public let title: String
    public let body: String
    public let fireAt: Date

    public var id: String { accountID }

    public init(accountID: String, title: String, body: String, fireAt: Date) {
        self.accountID = accountID
        self.title = title
        self.body = body
        self.fireAt = fireAt
    }
}

/// Turns the renewals the user set into the notifications to schedule.
///
/// Computed here rather than in the app target so the timing and the wording
/// can be tested without `UNUserNotificationCenter`, which needs a running,
/// registered app bundle. The app target only hands the result over.
public enum RenewalReminders {
    /// Morning rather than midnight: a notification delivered at 00:00 is read
    /// the next day anyway, having spent the night burying itself under
    /// everything else in Notification Centre.
    public static let hourOfDay = 9

    public static func all(
        accounts: [Account],
        renewals: [String: RenewalSchedule],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [RenewalReminder] {
        accounts.compactMap { account in
            guard let schedule = renewals[account.id] else { return nil }
            let status = schedule.status(now: now, calendar: calendar)
            guard let fireAt = fireDate(for: status, calendar: calendar), fireAt > now else {
                // Either the lead day has already passed or the calendar
                // refused the date. A notification cannot be delivered in the
                // past — asking for one fires it at once or drops it, and
                // neither is what "warn me three days before" means. The cell
                // is already amber by then, which is the part that still works.
                return nil
            }
            return RenewalReminder(
                accountID: account.id,
                title: "\(account.email) renews \(countdown(status.leadDays))",
                body: "\(account.provider.displayName) — \(dayAndMonth.string(from: status.date))",
                fireAt: fireAt
            )
        }
    }

    private static func fireDate(for status: RenewalStatus, calendar: Calendar) -> Date? {
        guard let leadDay = calendar.date(
            byAdding: .day,
            value: -status.leadDays,
            to: calendar.startOfDay(for: status.date)
        ) else { return nil }
        return calendar.date(bySettingHour: hourOfDay, minute: 0, second: 0, of: leadDay)
    }

    private static func countdown(_ days: Int) -> String {
        switch days {
        case 0: "today"
        case 1: "tomorrow"
        default: "in \(days) days"
        }
    }

    private static let dayAndMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}
