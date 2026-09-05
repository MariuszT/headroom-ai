import SwiftUI
import AppKit
import HeadroomCore

struct MenuContentView: View {
    @Bindable var model: AppModel
    @State private var showingSettings = false
    /// The measured height of the list. See `list` — without it the panel shows
    /// nothing but its footer.
    @State private var listHeight: CGFloat = 0

    /// Two accounts per row once there are two to place. Seventeen accounts
    /// stacked one per row run well past the height of the screen; side by side
    /// they stay one glance. But a second column with nothing in it is just a
    /// wider panel, so with one account — or none — the panel narrows to a
    /// single column.
    private var isWide: Bool { model.accounts.count > 1 }

    /// `.topLeading` matters: cells in a row differ in height whenever one
    /// carries a note the other does not, and centred cells then sit at
    /// different heights, so neither the addresses nor the limit lines line up
    /// across the row.
    private var columns: [GridItem] {
        isWide
            ? [
                GridItem(.flexible(), spacing: 12, alignment: .topLeading),
                GridItem(.flexible(), spacing: 12, alignment: .topLeading),
              ]
            : [GridItem(.flexible(), alignment: .topLeading)]
    }

    /// Wide enough that a cell fits a label, a bar worth looking at, a
    /// percentage and a full reset date without truncating any of them —
    /// "11 Sep 08:00" alone needs 66 pt.
    private var panelWidth: CGFloat { isWide ? 560 : 380 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingSettings {
                SettingsView(model: model, close: { showingSettings = false })
            } else {
                banner
                if model.accounts.isEmpty {
                    emptyState
                } else {
                    list
                }
                Divider()
                footer
            }
        }
        .frame(width: panelWidth)
        // Settings used to be a sheet, which stayed open behind the panel: the
        // panel closed, "Done" never reached it, and reopening the panel showed
        // Settings again. It is part of the panel now, and opening the panel
        // always starts on the list.
        .onAppear { showingSettings = false }
    }

    // MARK: - Parts

    /// The panel closes the moment the browser takes focus, so a sign-in
    /// reports back here rather than where it was started from.
    @ViewBuilder
    private var banner: some View {
        switch model.loginState {
        case .idle:
            EmptyView()
        case .running(let provider):
            bannerRow(
                text: "Signing in to \(provider.displayName) — finish in your browser.",
                tint: .secondary
            ) {
                Button("Cancel") { model.cancelLogin() }
                    .buttonStyle(.borderless)
            }
        case .failed(_, let message):
            bannerRow(text: message, tint: .orange) {
                Button("Dismiss") { model.dismissLoginState() }
                    .buttonStyle(.borderless)
            }
        case .added(let email):
            bannerRow(text: "Added \(email).", tint: .secondary) {
                Button("Dismiss") { model.dismissLoginState() }
                    .buttonStyle(.borderless)
            }
        case .reconnected(let email):
            bannerRow(
                text: "\(email) was already connected — signed in again and its tokens are fresh.",
                tint: .secondary
            ) {
                Button("Dismiss") { model.dismissLoginState() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func bannerRow(
        text: String,
        tint: Color,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// An empty screen is an invitation to act, not a notice of absence.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("No accounts yet")
                .font(.system(size: 13, weight: .medium))
            Text("Add your Claude Code and Codex accounts to see how much headroom each one has left.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    let group = accounts(for: provider)
                    if !group.isEmpty {
                        Text(provider.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                            ForEach(group) { account in
                                AccountRowView(
                                    account: account,
                                    usage: model.usage[account.id],
                                    refresh: { model.refreshAccount(id: account.id) },
                                    remove: { model.remove(id: account.id) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: ContentHeight.self, value: geometry.size.height)
                }
            )
        }
        // A menu bar panel sizes itself to its content, and a ScrollView has no
        // height of its own — inside such a parent it collapses to zero and
        // leaves nothing but the footer, which looks exactly as though there
        // were no accounts at all (the cells are in the view tree, they just
        // measure zero points). So we measure the content and set the height
        // directly.
        //
        // The upper bound stays: enough accounts still run past the screen, and
        // without scrolling the lower cells and the footer become unreachable.
        .frame(height: min(max(listHeight, 1), 460))
        .onPreferenceChange(ContentHeight.self) { measured in
            Task { @MainActor in listHeight = measured }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Menu("Add account") {
                Button("Claude Code") { model.startLogin(provider: .anthropic) }
                Button("Codex") { model.startLogin(provider: .openai) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isSigningIn)

            Spacer()

            Button { model.refreshNow() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help(model.isRefreshing ? "Checking…" : "Check all accounts now")

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Headroom AI")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Behaviour

    private var isSigningIn: Bool {
        if case .running = model.loginState { return true }
        return false
    }

    /// Accounts with an exhausted window go first — those are the ones that
    /// need a decision. Accounts with no data sink to the end: nothing is known
    /// about them, so they must not pose as a good choice, but they do not
    /// deserve the head of the list either.
    private func accounts(for provider: Provider) -> [Account] {
        model.accounts
            .filter { $0.provider == provider }
            .sorted { first, second in
                let firstPercent = model.usage[first.id]?.session.percent ?? -1
                let secondPercent = model.usage[second.id]?.session.percent ?? -1
                return firstPercent == secondPercent
                    ? first.email.localizedCaseInsensitiveCompare(second.email) == .orderedAscending
                    : firstPercent > secondPercent
            }
    }
}

/// Carries the measured list height out from inside the `ScrollView`.
private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
