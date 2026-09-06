import SwiftUI
import AppKit
import HeadroomCore

struct MenuContentView: View {
    @Bindable var model: AppModel
    @State private var showingSettings = false
    /// The measured height of the list. See `list` — without it the panel shows
    /// nothing but its footer.
    @State private var listHeight: CGFloat = 0

    /// Where every cell and every section header currently sits, so a drag can
    /// tell what it is over.
    ///
    /// Reordering runs on a plain `DragGesture` rather than `.draggable` and
    /// `.dropDestination`: those start an `NSDraggingSession`, which needs a
    /// key window, and a `MenuBarExtra` panel never becomes one (see
    /// `HeadroomApp`). Clicks reach the panel, drags never began. A
    /// `DragGesture` stays inside SwiftUI and works here.
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var headerFrames: [String: CGRect] = [:]
    /// What is being dragged right now, and what it is hovering over — the two
    /// together are the only feedback the gesture gives, so it has to be clear.
    @State private var dragging: String?
    @State private var hovering: String?
    /// How far the held thing has travelled from where it was picked up. Only
    /// meaningful while `dragging` is set.
    @State private var dragTranslation: CGSize = .zero
    /// Whether `NSCursor.push` is outstanding, so that exactly one `pop`
    /// answers it. An unbalanced push leaves the whole machine stuck showing a
    /// closed hand.
    @State private var pushedCursor = false

    private static let panelSpace = "headroom.panel"

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
                updateBanner
                storeBanner
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
        .coordinateSpace(.named(Self.panelSpace))
        // The panel can vanish mid-drag — it closes the moment anything else
        // takes focus — and `onEnded` never arrives. Everything the gesture set
        // has to be let go of here, not just the cursor: this `@State` outlives
        // the panel (which is why `onAppear` resets `showingSettings`), so a
        // half-finished drag came back on the next open as a cell stuck in the
        // air, offset by a translation from minutes ago.
        .onDisappear { releaseDrag() }
        .onPreferenceChange(CellFrames.self) { cellFrames = $0 }
        .onPreferenceChange(HeaderFrames.self) { headerFrames = $0 }
        // Settings used to be a sheet, which stayed open behind the panel: the
        // panel closed, "Done" never reached it, and reopening the panel showed
        // Settings again. It is part of the panel now, and opening the panel
        // always starts on the list.
        .onAppear { showingSettings = false }
    }

    // MARK: - Parts

    /// A new release is worth one quiet line, not a dialog. Dismissing it
    /// remembers the version, so this release stays quiet and the next one
    /// speaks up.
    @ViewBuilder
    private var updateBanner: some View {
        if let update = model.availableUpdate {
            bannerRow(text: "Version \(update.version) is available.", tint: .secondary) {
                HStack(spacing: 10) {
                    Button("Download") { model.openUpdate() }
                        .buttonStyle(.borderless)
                    Button("Later") { model.dismissUpdate() }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    /// A store that cannot be read is reported rather than shown as no
    /// accounts, which is what it would otherwise be indistinguishable from.
    @ViewBuilder
    private var storeBanner: some View {
        if let problem = model.storeProblem {
            bannerRow(text: "Could not read the stored accounts: \(problem)", tint: .orange) {
                Button("Try again") { model.loadAccounts() }
                    .buttonStyle(.borderless)
            }
        }
    }

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
                ForEach(model.sections, id: \.self) { provider in
                    let group = model.orderedAccounts(for: provider)
                    if !group.isEmpty {
                        // Only this section's cells are drop targets. Without
                        // the filter a cell dragged over the OTHER section lit
                        // up as though it would land there, and then nothing
                        // happened — the order rejects the cross-provider move,
                        // but the highlight had already promised it.
                        let targets = cellFrames.filter { frame in
                            group.contains { $0.id == frame.key }
                        }
                        sectionHeader(provider)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                            ForEach(group) { account in
                                AccountRowView(
                                    account: account,
                                    usage: model.usage[account.id],
                                    refresh: { model.refreshAccount(id: account.id) },
                                    remove: { model.remove(id: account.id) }
                                )
                                .modifier(Lift(
                                    held: dragging == account.id,
                                    translation: dragTranslation
                                ))
                                // Applied AFTER the lift, so both read the
                                // resting frame rather than the offset one:
                                // the hollow stays where the account came from,
                                // and the drop targets are measured where they
                                // actually sit.
                                .background(reporting(account.id, to: CellFrames.self))
                                .background(vacated(when: dragging == account.id))
                                .background(highlight(when: hovering == account.id))
                                .gesture(reorder(
                                    account.id,
                                    frames: targets,
                                    drop: { model.dropAccount(account.id, onto: $0, in: provider) }
                                ))
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

    /// The section's name, and the control for how it is arranged. The header
    /// is also the handle the whole section is dragged by, which is why the
    /// button sits inside it — a click has to reach the button, not start a
    /// drag of the section.
    private func sectionHeader(_ provider: Provider) -> some View {
        HStack(spacing: 6) {
            Text(provider.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button { model.cycleSortMode(for: provider) } label: {
                Image(systemName: Self.sortIcon(model.sortMode(for: provider)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Self.sortHelp(model.sortMode(for: provider)))
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        // The whole header, not just the label: a 4 pt strip of text is a hard
        // thing to catch.
        .contentShape(Rectangle())
        .modifier(Lift(held: dragging == provider.rawValue, translation: dragTranslation))
        .background(reporting(provider.rawValue, to: HeaderFrames.self))
        .background(vacated(when: dragging == provider.rawValue))
        .background(highlight(when: hovering == provider.rawValue))
        .gesture(reorder(
            provider.rawValue,
            frames: headerFrames,
            drop: { target in
                guard let onto = Provider(rawValue: target) else { return }
                model.dropSection(provider, onto: onto)
            }
        ))
    }

    /// One reordering gesture, shared by the cells and the headers: pick a
    /// thing up, and whatever its own frames say it was let go over is the
    /// target.
    ///
    /// `minimumDistance` is what keeps the buttons inside a cell working — a
    /// click never travels that far, so it reaches the button rather than
    /// starting a drag.
    private func reorder(
        _ id: String,
        frames: [String: CGRect],
        drop: @escaping (String) -> Void
    ) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.panelSpace))
            .onChanged { value in
                if !pushedCursor {
                    NSCursor.closedHand.push()
                    pushedCursor = true
                }
                dragging = id
                dragTranslation = value.translation
                hovering = frames.first { $0.key != id && $0.value.contains(value.location) }?.key
            }
            .onEnded { value in
                defer { releaseDrag() }
                guard let target = frames.first(
                    where: { $0.key != id && $0.value.contains(value.location) }
                )?.key else { return }
                drop(target)
            }
    }

    /// Everything a drag put in the air, put back down. One place, because the
    /// two ways a drag can end — letting go, and the panel closing under it —
    /// were forgetting different halves of it.
    private func releaseDrag() {
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
        dragging = nil
        hovering = nil
        dragTranslation = .zero
    }

    /// The hollow left where the held thing was, drawn in its resting frame
    /// because `offset` moved only the pixels. Without it the row simply has a
    /// hole in it, and nothing says the account is coming back.
    @ViewBuilder
    private func vacated(when held: Bool) -> some View {
        if held {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.06))
                .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func reporting<K: FrameKey>(_ id: String, to: K.Type) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: K.self, value: [id: geometry.frame(in: .named(Self.panelSpace))])
        }
    }

    /// The only sign of where a drop will land, so it is drawn as a filled
    /// shape rather than a hairline border.
    @ViewBuilder
    private func highlight(when active: Bool) -> some View {
        if active {
            RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.22))
        }
    }

    private static func sortIcon(_ mode: SortMode) -> String {
        switch mode {
        case .alphabetical: "character"
        case .fullness: "percent"
        case .manual: "line.3.horizontal"
        }
    }

    /// Each says what the order IS and what the click will do, because the
    /// glyph alone cannot carry either.
    private static func sortHelp(_ mode: SortMode) -> String {
        switch mode {
        case .alphabetical: "Sorted by address. Click to sort by how full each account is."
        case .fullness: "Fullest account first. Click to sort by address."
        case .manual: "Your own order — drag an account to change it. Click to sort by address."
        }
    }
}

/// What being held looks like: the thing leaves the surface and follows the
/// cursor, at full strength and above everything else.
///
/// `offset` comes AFTER the shadow and the scale, and outside the animation,
/// because a held thing has to track the cursor exactly — easing it would feel
/// like lag. It also changes no layout, which is what leaves the slot it came
/// from standing empty behind it (see `vacated`), so the way back stays visible
/// for as long as the drop is undecided.
struct Lift: ViewModifier {
    let held: Bool
    let translation: CGSize

    func body(content: Content) -> some View {
        content
            // A surface of its own, because a cell is otherwise nothing but
            // text on the panel's translucent material — lifted, it stayed
            // see-through and the row underneath read straight through it,
            // which is the opposite of holding something. Negative padding
            // spreads it past the text WITHOUT changing the layout, so the
            // hollow left behind keeps the cell's real size.
            .background {
                if held {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.15))
                        )
                        .padding(-6)
                }
            }
            .scaleEffect(held ? 1.03 : 1)
            .shadow(color: .black.opacity(held ? 0.4 : 0), radius: held ? 9 : 0, y: held ? 4 : 0)
            .animation(.easeOut(duration: 0.12), value: held)
            .offset(held ? translation : .zero)
            .zIndex(held ? 1 : 0)
    }
}

/// Where each draggable thing sits, gathered up from the whole panel. Two
/// keys rather than one, so that a cell and a header can never be found by the
/// same lookup — that is what stops a cell being dropped on a header.
protocol FrameKey: PreferenceKey where Value == [String: CGRect] {}

extension FrameKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

struct CellFrames: FrameKey {}
struct HeaderFrames: FrameKey {}

/// Carries the measured list height out from inside the `ScrollView`.
private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
