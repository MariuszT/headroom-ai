import Foundation
import UserNotifications
import HeadroomCore

/// Hands the reminders `RenewalReminders` computed to the system.
///
/// Thin on purpose: what to say and when to say it is decided in the core,
/// where it is tested. This type only talks to `UNUserNotificationCenter`, and
/// everything it does can fail for reasons outside the app's control.
///
/// Two of those are worth naming. `UNUserNotificationCenter.current()` traps
/// outright in a process with no bundle identifier — which is exactly what
/// `swift run` produces — so every entry point checks for a bundle first and
/// otherwise does nothing. And `make app` falls back to an ad-hoc signature
/// when no Developer ID certificate is present; that signature changes on every
/// rebuild, so macOS can treat each build as a different app and forget the
/// permission already granted. The panel and the menu bar icon never depend on
/// any of this, which is why they, not notifications, carry the feature.
@MainActor
enum RenewalNotifier {
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asks for permission and reports what happened, in the same shape as
    /// `AppModel.setLaunchAtLogin`: the system owns the answer, so the switch
    /// has to show what the system actually decided.
    static func requestAuthorization() async -> String? {
        guard isAvailable else {
            return "Notifications need the bundled app — run \"make app\" and open Headroom AI from there."
        }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            return granted ? nil : "macOS is not allowing notifications from Headroom AI. Turn them on in System Settings → Notifications."
        } catch {
            return "Could not ask for notification permission: \(error.localizedDescription)"
        }
    }

    /// Whether the system would actually deliver anything right now.
    ///
    /// Asked at launch, not only when the switch is flipped. A permission
    /// granted in an earlier session can be gone: revoked in System Settings,
    /// or forgotten because an ad-hoc signature changed and macOS now sees a
    /// different app. Without this the switch keeps saying "on" while every
    /// request is silently dropped — the worst of the three states, because it
    /// is the one that looks fine.
    static func authorizationProblem() async -> String? {
        guard isAvailable else {
            return "Notifications need the bundled app — run \"make app\" and open Headroom AI from there."
        }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return nil
        case .notDetermined:
            // The switch says on, yet the system has no record of ever being
            // asked — which is what a rebuild under a changed signature looks
            // like. Asking again is the repair; reporting it would only tell
            // the user to go and turn on something that is already on.
            return await requestAuthorization()
        default:
            return "macOS is no longer allowing notifications from Headroom AI. Turn them back on in System Settings → Notifications."
        }
    }

    /// Replaces every reminder this app has pending with the current set.
    ///
    /// Wholesale rather than incrementally: a renewal can be edited, cleared or
    /// removed along with its account, and reconciling those cases one by one
    /// is how stale notifications survive. There are as many requests as there
    /// are accounts, which is a dozen at most.
    ///
    /// Entirely synchronous, and that is the point. An earlier version asked
    /// `getPendingNotificationRequests` which ids were ours and applied the
    /// change in the completion handler — a read-modify-write straddling an
    /// async boundary, with no ordering between calls. `loadAccounts` reschedules
    /// on every poll turn while carrying the reminder list captured when that
    /// turn began, so an edit landing mid-callback could be overwritten by the
    /// older list and a just-cleared reminder would come back. Removing our
    /// requests by the ids we are about to write, plus the one for every account
    /// we know of, needs no round trip and cannot interleave.
    static func reschedule(_ reminders: [RenewalReminder], enabled: Bool, knownAccountIDs: [String]) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()

        // Every id this app could have written: one per account it currently
        // knows about, plus any it is about to schedule. An account that has
        // just been removed is in neither, which is why `AppModel.remove`
        // reschedules BEFORE the account leaves the list.
        let ours = Set(knownAccountIDs + reminders.map(\.accountID))
            .map { renewalRequestPrefix + $0 }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        guard enabled else { return }
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.fireAt
            )
            center.add(UNNotificationRequest(
                identifier: renewalRequestPrefix + reminder.accountID,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            ))
        }
    }
}

/// Every request this app schedules starts with it, so clearing our own
/// pending reminders cannot disturb anything else.
///
/// File scope so that the constant reads the same from anywhere; identifiers
/// stay prefixed so a second kind of notification, if one is ever added, can
/// tell its own requests from these.
private let renewalRequestPrefix = "renewal."
