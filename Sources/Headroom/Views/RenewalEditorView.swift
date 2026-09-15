import SwiftUI
import HeadroomCore

/// Setting when one account's plan renews: the date, how often it repeats, and
/// how far ahead the cell should start saying so.
///
/// Drawn as a layer OVER the panel rather than inside the cell. Expanding a
/// cell pushed every account below it down and resized the whole panel around
/// what is a brief, modal errand — the list is what the panel is for, and it
/// should still be there, unmoved, when the errand ends.
///
/// This is a layer, not a `sheet` or a `popover`. Those outlive the panel: the
/// panel closes the instant anything else takes focus, and the sheet stays
/// standing with no way left to dismiss it. That is the trap described on
/// `SettingsView`, and it applies here for the same reason.
///
/// Every field is the user's own knowledge. Neither provider reports any of it
/// — the OAuth tokens this app holds reach usage and profile endpoints only,
/// and Anthropic's organisation endpoints refuse them outright.
struct RenewalEditorView: View {
    let email: String
    let renewal: RenewalSchedule?
    let save: (RenewalSchedule?) -> Void
    let cancel: () -> Void

    /// `RenewalSchedule.Cycle` without its associated value — a `Picker` tag has
    /// to be plainly `Hashable`, and the interval is edited beside it.
    ///
    /// Named for the unit it counts in, so the three read as one set: Daily,
    /// Monthly, Yearly. An earlier draft called this one "Every", which named a
    /// different kind of thing from its neighbours and left the row reading
    /// "Repeats: Every".
    private enum CycleKind: String, CaseIterable, Identifiable {
        case daily, monthly, yearly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .daily: "Daily"
            case .monthly: "Monthly"
            case .yearly: "Yearly"
            }
        }
    }

    @State private var anchor: Date
    @State private var kind: CycleKind
    @State private var interval: Int
    @State private var leadDays: Int

    init(
        email: String,
        renewal: RenewalSchedule?,
        save: @escaping (RenewalSchedule?) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.email = email
        self.renewal = renewal
        self.save = save
        self.cancel = cancel
        // An account with no renewal set opens on today, monthly, warning three
        // days ahead — the shape almost every one of these plans has.
        _anchor = State(initialValue: renewal?.anchor ?? Date())
        _leadDays = State(initialValue: renewal?.leadDays ?? 3)
        switch renewal?.cycle {
        case .days(let stored):
            _kind = State(initialValue: .daily)
            // Clamped to the same range as the stepper below. `Stepper(in:)`
            // bounds what its arrows produce, not what it is handed, so a
            // stored zero — which `RenewalSchedule.date(atStep:)` explicitly
            // expects to see — would render as "every 0 days" and be written
            // straight back on Save. Opening the editor repairs it instead.
            _interval = State(initialValue: min(max(stored, 1), 365))
        case .yearly:
            _kind = State(initialValue: .yearly)
            _interval = State(initialValue: 1)
        case .monthly, .none:
            _kind = State(initialValue: .monthly)
            _interval = State(initialValue: 1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Renewal")
                    .font(.system(size: 13, weight: .medium))
                Text(email)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // A grid rather than stacked rows so the controls line up in one
            // column however wide their labels are.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Renews on")
                    DatePicker("", selection: $anchor, displayedComponents: .date)
                        .labelsHidden()
                }

                GridRow {
                    Text("Repeats")
                    HStack(spacing: 6) {
                        Picker("", selection: $kind) {
                            ForEach(CycleKind.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()

                        if kind == .daily {
                            Stepper(value: $interval, in: 1...365) {
                                Text(interval == 1 ? "every day" : "every \(interval) days")
                            }
                            .fixedSize()
                        }
                    }
                }

                GridRow {
                    Text("Warn")
                    Stepper(value: $leadDays, in: 0...30) {
                        Text(leadDays == 0
                            ? "on the day"
                            : leadDays == 1 ? "1 day before" : "\(leadDays) days before")
                    }
                    .fixedSize()
                }
            }
            // One size for every control in the card. Without it the compact
            // date picker draws its own small steppers next to full-size ones
            // on the rows below, and the card reads as three different dialogs.
            .controlSize(.small)
            .font(.system(size: 11))

            HStack(spacing: 10) {
                if renewal != nil {
                    Button("Clear") { save(nil) }
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 4)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(edited) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .shadow(radius: 12, y: 4)
    }

    private var edited: RenewalSchedule {
        let cycle: RenewalSchedule.Cycle = switch kind {
        case .daily: .days(interval)
        case .monthly: .monthly
        case .yearly: .yearly
        }
        return RenewalSchedule(anchor: anchor, cycle: cycle, leadDays: leadDays)
    }
}
