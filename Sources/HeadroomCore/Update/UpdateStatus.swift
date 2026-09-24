import Foundation

/// What one look at GitHub came back with.
public enum UpdateCheckResult: Equatable, Sendable {
    case available(AvailableUpdate)
    case upToDate
    /// No answer, or one that could not be read — not the same as "nothing
    /// newer", and not to be reported as such.
    case failed
}

/// Where the update check stands, as Settings shows it.
public enum UpdateStatus: Equatable, Sendable {
    case notChecked
    case checking
    case checked(UpdateCheckResult, at: Date)
}

/// The sentences Settings says about updates. In the core for the same reason
/// as `RenewalLine`: the branches are testable without a running app.
public enum UpdateStatusLine {
    public static let schedule =
        "Checked automatically at launch and every \(Int(UpdateChecker.automaticInterval / 3600)) hours."

    public static func text(
        for status: UpdateStatus,
        currentVersion: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        switch status {
        case .notChecked:
            return nil
        case .checking:
            return "Checking…"
        case .checked(.available(let update), _):
            return "Headroom AI \(update.version) is available"
        case .checked(.failed, _):
            return "Couldn't reach GitHub."
        case .checked(.upToDate, let checkedAt):
            return "You're up to date (\(currentVersion)) · checked \(time(checkedAt, now: now, calendar: calendar))"
        }
    }

    /// The time alone for today; with the day once it is not today, or a check
    /// from last night would read as if it had just happened.
    private static func time(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        return formatter.string(from: date)
    }
}
