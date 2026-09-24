import Foundation

/// Every sentence the panel says about banked limit resets. In the core for
/// the same reason as `RenewalLine`: singular versus plural and the wording of
/// each outcome are the kind of thing that goes wrong unnoticed in a view.
public enum ResetLine {
    /// The same lead the renewal reminder defaults to: close enough to act on,
    /// far enough that the colour still means something.
    static let urgentWindow: TimeInterval = 3 * 86_400

    public static func text(for credits: ResetCredits, calendar: Calendar = .current) -> String {
        let noun = credits.available == 1 ? "reset" : "resets"
        let count = "\(credits.available) \(noun) available"
        guard let expiresAt = credits.expiresAt else { return count }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM"
        return "\(count) · until \(formatter.string(from: expiresAt))"
    }

    public static func isUrgent(_ credits: ResetCredits, now: Date = Date()) -> Bool {
        guard let expiresAt = credits.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= urgentWindow
    }

    /// Names each window the reset clears with how full it is now, so a reset
    /// spent on a nearly empty window is spent knowingly.
    public static func confirmation(for credits: ResetCredits, usage: AccountUsage?) -> String {
        let windows = usage?.windows ?? []
        let parts = credits.clears.map { label in
            guard let window = windows.first(where: { $0.label == label }) else { return label }
            return "\(label) (\(Int(window.percent))%)"
        }
        let head = parts.isEmpty ? "Reset limits" : "Reset " + parts.joined(separator: " + ")
        return "\(head)? \(credits.available) left"
    }

    public static func message(for result: ResetResult) -> String {
        switch result {
        case .outcome(.reset): "Reset used. Numbers confirm in about 3 min."
        case .outcome(.nothingToReset): "Nothing to reset yet. The reset is still yours."
        case .outcome(.alreadyUsed): "This reset was already used."
        case .outcome(.coolingDown): "Cooling down. Try again later."
        case .outcome(.ineligible): "The provider says this account can't use it."
        case .failed: "Reset failed. Nothing was used."
        case .unconfirmed: "Couldn't confirm the reset. Checking again in about 3 min."
        case .nothingAvailable: "No reset available right now."
        case .alreadyInProgress: "A reset is already in progress."
        }
    }

    /// The results after which the provider's numbers may differ from what the
    /// panel shows — worth asking again once the 180-second floor allows.
    public static func needsConfirmationCheck(_ result: ResetResult) -> Bool {
        switch result {
        case .outcome(.reset), .outcome(.alreadyUsed), .unconfirmed: true
        default: false
        }
    }
}
