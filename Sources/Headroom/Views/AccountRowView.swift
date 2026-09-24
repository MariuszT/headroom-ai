import SwiftUI
import HeadroomCore

/// One account's cell: its address, and every limit window the provider
/// reports, each on its own labelled line — the five-hour window, the weekly
/// one, and any per-model weekly limits. Hiding a window until it crossed a
/// threshold, as this used to, answers "how much is left?" with silence for
/// every window that happens to be healthy, and the reader cannot tell that
/// apart from the window not existing.
///
/// Everything that has nothing to say is absent rather than empty. A cell with
/// no data yet shows its address and one line explaining why — no placeholder
/// dashes standing in for numbers that do not exist. Placeholders read as
/// broken data; absence reads as absence.
struct AccountRowView: View {
    let account: Account
    let usage: AccountUsage?
    /// When this account's plan renews, as the user told us — neither provider
    /// reports it. See `RenewalSchedule`.
    let renewal: RenewalSchedule?
    let refresh: () -> Void
    let remove: () -> Void
    /// Opens the renewal editor, which is drawn over the panel rather than
    /// inside this cell — see `MenuContentView.renewalEditor`.
    let editRenewal: () -> Void
    /// What the last reset attempt came to, until `AppModel` clears it.
    let resetMessage: String?
    let isRedeemingReset: Bool
    let redeemReset: () -> Void

    /// Removing an account means signing in through a browser again to undo it,
    /// so a single stray click must not be enough. The confirmation is inline
    /// rather than a dialog: a menu bar panel cannot host one reliably — that
    /// is the same trap that made Settings unclosable.
    @State private var confirmingRemoval = false
    /// Spending a reset cannot be undone, so it asks first — inline, for the
    /// same reason as removal.
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(account.email)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if account.needsReauth {
                    Text("sign in")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                if let resets {
                    Button { confirmingReset = true } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help(resets.usableNow
                        ? "Reset \(account.email)'s limits"
                        : (resets.blockedReason ?? "Not usable right now"))
                    .disabled(!resets.usableNow || confirmingRemoval || confirmingReset || isRedeemingReset)
                }

                Button(action: editRenewal) {
                    Image(systemName: renewal == nil ? "calendar" : "calendar.badge.clock")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(renewalStatus?.isAlerting == true
                    ? AnyShapeStyle(Color.orange)
                    : AnyShapeStyle(.tertiary))
                .help(renewal == nil
                    ? "Set when \(account.email) renews"
                    : "Change when \(account.email) renews")
                .disabled(confirmingRemoval || confirmingReset)

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Check \(account.email) now")
                .disabled(confirmingRemoval || confirmingReset)

                Button { confirmingRemoval = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Remove \(account.email)")
                .disabled(confirmingRemoval || confirmingReset)
            }

            if confirmingRemoval {
                confirmation
            } else if confirmingReset, let resets {
                resetConfirmation(resets)
            } else {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    WindowLine(window: window)
                }

                if let renewal {
                    // Colour only inside the account's own lead window. A date
                    // two months out is information, not a warning, and a panel
                    // that colours everything teaches the eye to skip it.
                    Text(RenewalLine.text(for: renewal))
                        .font(.system(size: 10))
                        .foregroundStyle(renewalStatus?.isAlerting == true ? Color.orange : .secondary)
                        .lineLimit(1)
                }

                if let resets {
                    Text(ResetLine.text(for: resets))
                        .font(.system(size: 10))
                        .foregroundStyle(ResetLine.isUrgent(resets) ? Color.orange : .secondary)
                        .lineLimit(1)
                }

                if let resetMessage {
                    Text(resetMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove account") { confirmingRemoval = true }
                .disabled(confirmingReset || isRedeemingReset)
        }
        // Closes once the claim has come back; the outcome then shows as
        // `resetMessage` under the bars.
        .onChange(of: isRedeemingReset) { _, redeeming in
            if !redeeming { confirmingReset = false }
        }
        // A poll landing while the confirmation is open can take `resets` away
        // entirely — none left, expired, or `needsReauth` flipping true. Left
        // open, the row would be stuck: every other button disabled by
        // `confirmingReset`, no `resets` left to draw the confirmation itself,
        // and no Cancel visible to get out of it.
        .onChange(of: resets == nil) { _, gone in
            if gone { confirmingReset = false }
        }
    }

    private var confirmation: some View {
        HStack(spacing: 10) {
            Text("Remove it?")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Cancel") { confirmingRemoval = false }
                .buttonStyle(.borderless)
            Button("Remove") { remove() }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
        }
        .font(.system(size: 10))
    }

    private func resetConfirmation(_ resets: ResetCredits) -> some View {
        HStack(spacing: 10) {
            Text(isRedeemingReset ? "Resetting…" : ResetLine.confirmation(for: resets, usage: usage))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Cancel") { confirmingReset = false }
                .buttonStyle(.borderless)
                .disabled(isRedeemingReset)
            Button("Reset") { redeemReset() }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                // `resets` can turn unusable (cooldown, paused, …) while the
                // confirmation sits open — a poll landing in between — and the
                // button must stop offering to spend something the provider
                // would refuse.
                .disabled(isRedeemingReset || !resets.usableNow)
        }
        .font(.system(size: 10))
    }

    // MARK: - Data

    /// Every window the provider reported, in the order they matter: the
    /// session window first, then the week, then whatever per-model limits came
    /// back. Empty when there is nothing to show — the note then explains why.
    private var windows: [LimitWindow] {
        guard !account.needsReauth, let usage else { return [] }
        if case .error = usage.staleness { return [] }
        return usage.windows
    }

    /// One sentence, and only when it adds something the lines above do not
    /// already say. See `AccountNote` — the branches live in the core so they
    /// can be tested without a running app.
    private var note: String? {
        AccountNote.text(for: account, usage: usage)
    }

    private var renewalStatus: RenewalStatus? {
        renewal?.status(now: Date())
    }

    /// The resets worth offering: none for an account that has to sign in
    /// again, and none past their expiry — a cached reading can outlive them
    /// (see `ResetCredits.current(now:)`).
    private var resets: ResetCredits? {
        guard !account.needsReauth else { return nil }
        return usage?.resets?.current()
    }
}

/// One limit window: what it is, how much of it is gone, and when it comes
/// back.
private struct WindowLine: View {
    let window: LimitWindow

    var body: some View {
        HStack(spacing: 6) {
            Text(window.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 60, alignment: .leading)

            Bar(value: window.percent, color: color)

            Text("\(Int(window.percent))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(window.percent >= 80 ? color : .primary)
                .lineLimit(1)
                // "100%" measures 30.1 pt at this size, so a 30 pt column wrapped
                // it onto two lines — at exactly the moment the number matters most.
                .frame(width: 36, alignment: .trailing)

            if let resetsAt = window.resetsAt {
                Text(ResetFormatter.string(for: resetsAt))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // "11 Sep 08:00" measures 66 pt at this size; 56 cut it off.
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    /// Colour appears only once something needs attention. There is no green
    /// anywhere: a panel where everything glows green teaches the eye to scroll
    /// past it, and then red stops working too.
    private var color: Color {
        if window.percent >= 100 { return .red }
        if window.percent >= 80 { return .orange }
        return .primary.opacity(0.55)
    }
}

/// The usage bar, drawn only when there is a value to draw.
private struct Bar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if value > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, geometry.size.width * min(max(value / 100, 0), 1)))
                }
            }
        }
        .frame(height: 4)
    }
}
