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
    let refresh: () -> Void
    let remove: () -> Void

    /// Removing an account means signing in through a browser again to undo it,
    /// so a single stray click must not be enough. The confirmation is inline
    /// rather than a dialog: a menu bar panel cannot host one reliably — that
    /// is the same trap that made Settings unclosable.
    @State private var confirmingRemoval = false

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

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Check \(account.email) now")
                .disabled(confirmingRemoval)

                Button { confirmingRemoval = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Remove \(account.email)")
                .disabled(confirmingRemoval)
            }

            if confirmingRemoval {
                confirmation
            } else {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    WindowLine(window: window)
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
        .contextMenu { Button("Remove account") { confirmingRemoval = true } }
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

    // MARK: - Data

    /// Every window the provider reported, in the order they matter: the
    /// session window first, then the week, then whatever per-model limits came
    /// back. Empty when there is nothing to show — the note then explains why.
    private var windows: [LimitWindow] {
        guard !account.needsReauth, let usage else { return [] }
        if case .error = usage.staleness { return [] }
        return [usage.session, usage.weekly] + usage.scoped
    }

    /// One sentence, and only when it adds something the lines above do not
    /// already say.
    private var note: String? {
        if account.needsReauth { return "Rejected by Anthropic. Add this account again to renew it." }
        guard let usage else { return "Waiting for the first check." }
        if case .error(let description) = usage.staleness { return description }
        if case .cached(let since) = usage.staleness {
            return "Last checked \(ResetFormatter.stringSince(since))."
        }
        return nil
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
                .frame(width: 30, alignment: .trailing)

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
