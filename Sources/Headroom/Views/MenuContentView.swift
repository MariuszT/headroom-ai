import SwiftUI
import AppKit
import HeadroomCore

struct MenuContentView: View {
    @Bindable var model: AppModel
    @State private var showingSettings = false
    /// The measured height of the list. See `list` — without it the panel shows
    /// nothing but its footer.
    @State private var listHeight: CGFloat = 0
    /// Everything in the panel that is not the list — banners, divider,
    /// footer — measured so the list knows how much of the screen is its own.
    @State private var chromeHeight: CGFloat = 0
    /// The usable height of the screen the panel is actually on — see
    /// `PanelWindowBridge`.
    @State private var screenHeight: CGFloat?
    /// The height the whole panel wants, measured so its window can be shrunk
    /// to it — see `PanelWindowFit`.
    @State private var panelHeight: CGFloat = 0
    /// The renewal editor's own height. It is a layer over the panel, outside
    /// the stack `panelHeight` measures, and can be taller than a short list.
    @State private var editorHeight: CGFloat = 0

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

    /// The account whose renewal is being edited, or none. Held here rather
    /// than in the cell because the editor is drawn over the whole panel.
    @State private var editingRenewalFor: String?

    var body: some View {
        // Top-aligned: when the renewal editor makes the window taller than
        // the panel, the panel stays under the menu bar instead of dropping by
        // half the difference. The editor's layer fills the window on its own,
        // so its card stays centred.
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if showingSettings {
                    SettingsView(model: model, close: { showingSettings = false })
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        updateBanner
                        storeBanner
                        banner
                    }
                    .background(measuring(ChromeHeight.self))
                    if model.accounts.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Divider()
                        footer
                    }
                    .background(measuring(ChromeHeight.self))
                }
            }
            .frame(width: panelWidth)
            .background(measuring(PanelContentHeight.self))
            .coordinateSpace(.named(Self.panelSpace))
            // The panel can vanish mid-drag — it closes the moment anything else
            // takes focus — and `onEnded` never arrives. Everything the gesture set
            // has to be let go of here, not just the cursor: this `@State` outlives
            // the panel (which is why `onAppear` resets `showingSettings`), so a
            // half-finished drag came back on the next open as a cell stuck in the
            // air, offset by a translation from minutes ago.
            .onDisappear { releaseDrag() }
            // Here, on the panel, because the banners and the footer are the
            // list's siblings: a preference only travels up to ancestors.
            .onPreferenceChange(ChromeHeight.self) { measured in
                Task { @MainActor in chromeHeight = measured }
            }
            .onPreferenceChange(PanelContentHeight.self) { measured in
                Task { @MainActor in panelHeight = measured }
            }
            .background(PanelWindowBridge(
                contentSize: CGSize(width: panelWidth, height: windowHeight)
            ) { screenHeight = $0 })
            .onPreferenceChange(CellFrames.self) { cellFrames = $0 }
            .onPreferenceChange(HeaderFrames.self) { headerFrames = $0 }
            // Settings used to be a sheet, which stayed open behind the panel: the
            // panel closed, "Done" never reached it, and reopening the panel showed
            // Settings again. It is part of the panel now, and opening the panel
            // always starts on the list.
            .onAppear { showingSettings = false }

            if let id = editingRenewalFor,
               let account = model.accounts.first(where: { $0.id == id }) {
                renewalEditor(for: account)
            }
        }
        // Like `showingSettings`, this `@State` outlives the panel, so an
        // editor left open would come back over the list the next time the
        // panel is opened.
        .onDisappear { editingRenewalFor = nil }
    }

    /// The editor, and the scrim that both dims the list and swallows clicks
    /// meant for it — without the scrim the cells underneath stay draggable
    /// while a modal errand is open on top of them.
    private func renewalEditor(for account: Account) -> some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .onTapGesture { editingRenewalFor = nil }

            RenewalEditorView(
                email: account.email,
                renewal: model.renewals[account.id],
                save: {
                    model.setRenewal($0, for: account.id)
                    editingRenewalFor = nil
                },
                cancel: { editingRenewalFor = nil }
            )
            .background(measuring(EditorHeight.self))
        }
        .transition(.opacity)
        .onPreferenceChange(EditorHeight.self) { measured in
            Task { @MainActor in editorHeight = measured }
        }
    }

    /// What the window should be: the panel, or the renewal editor over it when
    /// that is taller — with room around the editor's card so it does not
    /// touch the window's edges.
    private var windowHeight: CGFloat {
        // Only while the editor is actually drawn: it disappears when its
        // account does, even though `editingRenewalFor` still names it.
        guard let id = editingRenewalFor, model.accounts.contains(where: { $0.id == id }),
              editorHeight > 0
        else { return panelHeight }
        return max(panelHeight, editorHeight + 2 * Self.editorMargin)
    }

    private static let editorMargin: CGFloat = 12

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
                                    renewal: model.renewals[account.id],
                                    refresh: { model.refreshAccount(id: account.id) },
                                    remove: { model.remove(id: account.id) },
                                    editRenewal: { editingRenewalFor = account.id },
                                    resetMessage: model.resetMessages[account.id],
                                    isRedeemingReset: model.redeemingResets.contains(account.id),
                                    redeemReset: { model.redeemReset(id: account.id) }
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
        // The list grows with its content until the panel would run past the
        // bottom of the screen, and only then scrolls — see `PanelHeight`.
        // Without the bound, enough accounts would push the lower cells and
        // the footer off the screen, out of reach.
        .frame(height: PanelHeight.list(
            content: listHeight,
            chrome: chromeHeight,
            screen: screenHeight ?? NSScreen.main?.visibleFrame.height ?? 800
        ))
        .onPreferenceChange(ContentHeight.self) { measured in
            Task { @MainActor in listHeight = measured }
        }
    }

    private func measuring<Key: PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGFloat {
        GeometryReader { geometry in
            Color.clear.preference(key: key, value: geometry.size.height)
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

/// The whole panel's natural height — what its window should be.
private struct PanelContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The renewal editor's card, measured on its own.
private struct EditorHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The banners above the list and the footer below it, added together.
private struct ChromeHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

/// The panel's hold on its own window, for the two things SwiftUI cannot do
/// from inside `MenuBarExtra`.
///
/// It reports the usable height of the screen the window is on. `NSScreen.main`
/// is the screen of the key window, which with two displays can be the other
/// one — a list sized for a tall external monitor would then run off the
/// bottom of the laptop screen whose menu bar was clicked. Read again whenever
/// the window moves to another screen or the screen's usable area changes.
///
/// And it fits the window to the content's size, which `MenuBarExtra` does
/// only when the content grows, never when it shrinks — see `PanelWindowFit`.
private struct PanelWindowBridge: NSViewRepresentable {
    /// The size to fit the window to.
    let contentSize: CGSize
    let report: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        Probe(report: report)
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.report = report
        nsView.request(contentSize)
    }

    final class Probe: NSView {
        var report: (CGFloat) -> Void
        private var observers: [NSObjectProtocol] = []
        private var requested: CGSize?

        init(report: @escaping (CGFloat) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        // The observers are dropped here, not in `deinit`: leaving the window
        // calls this with `window == nil` first, and the closures only hold
        // this view weakly.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            // Moving to another screen, and the same screen changing its usable
            // area — a different resolution, the Dock resized or moved.
            let triggers: [(Notification.Name, Any?)] = [
                (NSWindow.didChangeScreenNotification, window),
                (NSApplication.didChangeScreenParametersNotification, nil),
            ]
            observers = triggers.map { name, object in
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.send() }
                }
            }
            send()
            apply()
        }

        /// Sizes the window to a NEW measurement only. SwiftUI calls this on
        /// every redraw, often still carrying the previous size while the
        /// content has already changed — acting on that would size the window
        /// to what the panel used to be. So a size is applied once, when it
        /// first arrives.
        func request(_ size: CGSize) {
            guard size != requested else { return }
            requested = size
            apply()
        }

        /// Deferred out of the SwiftUI update it is called from: resizing the
        /// window inside it would lay the panel out again mid-pass. Also run
        /// when the view reaches a window, so a size requested before that is
        /// not lost.
        private func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let size = self.requested, let window = self.window else { return }
                let content = window.contentRect(forFrameRect: window.frame)
                guard let fitted = PanelWindowFit.frame(
                    window: content, content: size, screen: window.screen?.visibleFrame
                ) else { return }
                window.setFrame(window.frameRect(forContentRect: fitted), display: true)
            }
        }

        private func send() {
            guard let height = window?.screen?.visibleFrame.height else { return }
            // Out of the view update this may be called from.
            DispatchQueue.main.async { [report] in report(height) }
        }
    }
}
