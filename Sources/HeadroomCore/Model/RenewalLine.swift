import Foundation

/// The one line a cell adds when the user has told the app when that account's
/// plan renews.
///
/// In the core rather than in the view for the same reason as `AccountNote`:
/// the branches are testable without a running app, and "tomorrow" versus "in 1
/// day" is exactly the kind of wording that goes wrong unnoticed.
public enum RenewalLine {
    private static let dayAndMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    /// Always names the date alongside the countdown. A countdown on its own
    /// cannot be checked against a bank statement without doing the arithmetic
    /// first.
    public static func text(
        for schedule: RenewalSchedule,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let status = schedule.status(now: now, calendar: calendar)
        return "Renews \(countdown(status.daysAway)) (\(dayAndMonth.string(from: status.date)))"
    }

    private static func countdown(_ days: Int) -> String {
        switch days {
        case 0: "today"
        case 1: "tomorrow"
        default: "in \(days) days"
        }
    }
}
