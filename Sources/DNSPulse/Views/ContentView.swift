import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable {
    case benchmark, servers, websites, history
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    /// Not observed: the root would otherwise redraw the whole window whenever a running test publishes results.
    let engine: BenchmarkEngine
    @State private var selection: SidebarItem? = .benchmark
    @State private var navigator = SectionNavigator()
    /// Sections built so far. Each stays alive behind the one on screen, so switching back doesn't rebuild it.
    @State private var opened: Set<SidebarItem> = [.benchmark]
    /// One per section, for the page's lifetime: a switch flips two flags instead of changing pages' environment.
    @State private var activities = SidebarItem.allCases.map { SectionActivity(isActive: $0 == .benchmark) }

    var body: some View {
        let shown = selection ?? .benchmark
        NavigationSplitView {
            List(selection: $selection) {
                Section("Test") {
                    BenchmarkSidebarLabel()
                        .tag(SidebarItem.benchmark)
                }
                Section("Library") {
                    Label("DNS Servers", systemImage: "server.rack")
                        .badge(store.enabledServers.count)
                        .tag(SidebarItem.servers)
                    Label("Websites", systemImage: "globe")
                        .badge(store.enabledWebsites.count)
                        .tag(SidebarItem.websites)
                }
                Section("Results") {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .badge(store.history.count)
                        .tag(SidebarItem.history)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
            .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 300)
        } detail: {
            SectionStack {
                ForEach(SidebarItem.allCases.filter { $0 == shown || opened.contains($0) }, id: \.self) { item in
                    SectionPage(item: item)
                        .modifier(SectionVisibility(isActive: item == shown, activity: activity(for: item)))
                        .layoutValue(key: PageKey.self, value: item)
                }
            }
        }
        .background(HiddenPageFocusGuard())
        .environment(\.navigator, navigator)
        .onAppear {
            navigator.connect { item in
                // The page being left stays alive, so a field on it would otherwise keep keyboard focus.
                NSApp.keyWindow?.makeFirstResponder(nil)
                selection = item
            }
        }
        .onChange(of: shown) { _, item in
            opened.insert(item)
            for section in SidebarItem.allCases where activity(for: section).isActive != (section == item) {
                activity(for: section).isActive = section == item
            }
        }
        .task { await prewarm() }
    }

    private func activity(for item: SidebarItem) -> SectionActivity {
        activities[SidebarItem.allCases.firstIndex(of: item) ?? 0]
    }

    /// Builds the sections not opened yet, one at a time once the first screen has settled, so the first visit to
    /// each is as quick as coming back to it. Each takes a moment of main-thread work, so none is built during a test.
    private func prewarm() async {
        try? await Task.sleep(for: .milliseconds(1200))
        for item in SidebarItem.allCases where !opened.contains(item) {
            while engine.isRunning, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            if opened.insert(item).inserted {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
}

/// One section's page. Its only input is the section, so it's built once and a switch never re-runs it.
private struct SectionPage: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .benchmark: BenchmarkView()
        case .servers: ServersView()
        case .websites: WebsitesView()
        case .history: HistoryView()
        }
    }
}

/// Hides the pages that aren't on screen: a zero-opacity view can't be seen or clicked, VoiceOver skips it, and it
/// doesn't animate (a re-ranked leaderboard would otherwise play its animation unseen).
/// Pages read `isActiveSection` (backed by `activity`) to drop their toolbar items, window title and delete command,
/// and to keep their text fields out of the Tab order. Nothing in a page's environment changes on a switch: that
/// (including a page-wide `disabled`) would re-render and re-measure both pages involved, and toggling
/// `allowsHitTesting` would re-attach every AppKit view in them.
private struct SectionVisibility: ViewModifier {
    let isActive: Bool
    let activity: SectionActivity

    func body(content: Content) -> some View {
        content
            .transaction { if !isActive { $0.disablesAnimations = true } }
            .opacity(isActive ? 1 : 0)
            .accessibilityHidden(!isActive)
            .environment(\.sectionActivity, activity)
            .layoutValue(key: IsActivePage.self, value: isActive)
    }
}

/// Stacks the section pages like a ZStack, but only the page on screen decides the size. Sizing every hidden page's
/// content as well made each switch re-measure all of them for the window's minimum size, and let a hidden page
/// change how small the window can get.
private struct SectionStack: Layout {
    /// Where each hidden page was last placed. It stays there, so resizing the window (or showing the sidebar)
    /// lays out only the page on screen; a page catches up with the new size when it's shown again.
    struct Cache {
        var placements: [SidebarItem: (point: CGPoint, proposal: ProposedViewSize)] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    // Keeps the placements when a page is opened: by default the cache would be made again.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        subviews.first { $0[IsActivePage.self] }?.sizeThatFits(proposal) ?? .zero
    }

    /// Like a ZStack, the page on screen gets the proposal the stack was sized with, so it reuses its measurement.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for subview in subviews {
            guard let page = subview[PageKey.self] else { continue }
            var placement = (point: CGPoint(x: bounds.midX, y: bounds.midY), proposal: proposal)
            if subview[IsActivePage.self] || cache.placements[page] == nil {
                cache.placements[page] = placement
            } else if let last = cache.placements[page] {
                placement = last
            }
            subview.place(at: placement.point, anchor: .center, proposal: placement.proposal)
        }
    }

    // Pages have no alignment guides to share. Without these, every size query (such as the window's minimum size)
    // would place all the pages to merge their guides, measuring the hidden ones at sizes they're never shown at.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
}

private struct IsActivePage: LayoutValueKey {
    static let defaultValue = false
}

private struct PageKey: LayoutValueKey {
    static let defaultValue: SidebarItem? = nil
}

/// Keeps keyboard focus out of the pages hidden behind the one on screen. They're only transparent, so AppKit still
/// lets Tab land on their lists and text fields (and, with Full Keyboard Access, their buttons), where arrow keys
/// and typing would change a page nobody can see. Gating every control on `isActiveSection` would re-render its page
/// on each switch, so this instead passes focus on to the next control that can be seen.
private struct HiddenPageFocusGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> GuardView { GuardView() }
    func updateNSView(_ view: GuardView, context: Context) {}

    final class GuardView: NSView {
        private var observation: NSKeyValueObservation?
        /// Focus moves made in a row, so a window with nothing visible to focus can't loop forever.
        private var hops = 0
        /// The direction of the move being passed on, so a hop that lands on another hidden view keeps going that way
        /// even once the key-up has replaced the Tab press as the current event.
        private var hopBackwards: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.firstResponder) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.firstResponderChanged(in: window) }
            }
        }

        private func firstResponderChanged(in window: NSWindow) {
            guard let responder = window.firstResponder as? NSView, Self.isTransparent(responder) else {
                hops = 0
                return
            }
            let backwards = hopBackwards
                ?? NSApp.currentEvent.map { $0.type == .keyDown && $0.modifierFlags.contains(.shift) } ?? false
            // Moved on after AppKit has finished making it first responder.
            DispatchQueue.main.async { [weak self, weak window, weak responder] in
                guard let self, let window, let responder, window.firstResponder === responder else { return }
                // A text field edits through the window's field editor, whose delegate (the field) is set only by now;
                // move on from the field itself.
                let view = (responder as? NSText)?.delegate as? NSView ?? responder
                hops += 1
                hopBackwards = backwards
                defer { hopBackwards = nil }
                if hops > 50 {
                    hops = 0
                    window.makeFirstResponder(nil)
                } else if backwards {
                    window.selectKeyView(preceding: view)
                } else {
                    window.selectKeyView(following: view)
                }
            }
        }

        private static func isTransparent(_ view: NSView) -> Bool {
            sequence(first: view, next: { $0.superview }).contains {
                $0.isHidden || $0.alphaValue < 0.01 || ($0.layer?.opacity ?? 1) < 0.01
            }
        }
    }
}

// MARK: - Page helpers

// Like `sectionChrome(title:items:)`, these read `isActiveSection` in a modifier of their own, so a page's body
// never depends on it and a switch doesn't re-run (and re-measure) the whole page.
extension View {
    /// Runs `action` whenever this page becomes the section on screen, including when it first appears there.
    func onSectionActivated(perform action: @escaping () -> Void) -> some View {
        modifier(SectionActivation(action: action))
    }

    /// `onDeleteCommand` that acts only while this page is on screen: a hidden page's list can keep keyboard focus.
    func sectionDeleteCommand(perform action: @escaping () -> Void) -> some View {
        modifier(SectionDeleteCommand(action: action))
    }

    /// Keeps a text field out of the Tab order (and out of reach of typing) while its page is hidden.
    func editableWhileSectionActive() -> some View {
        modifier(SectionEditable())
    }
}

private struct SectionEditable: ViewModifier {
    @Environment(\.isActiveSection) private var isActiveSection

    func body(content: Content) -> some View {
        content.disabled(!isActiveSection)
    }
}

private struct SectionActivation: ViewModifier {
    let action: () -> Void
    @Environment(\.isActiveSection) private var isActiveSection

    func body(content: Content) -> some View {
        content.onChange(of: isActiveSection, initial: true) { _, isActive in
            if isActive { action() }
        }
    }
}

private struct SectionDeleteCommand: ViewModifier {
    let action: () -> Void
    @Environment(\.isActiveSection) private var isActiveSection

    func body(content: Content) -> some View {
        content.onDeleteCommand(perform: isActiveSection ? action : nil)
    }
}

/// The Benchmark row, with a running test's progress as its badge.
private struct BenchmarkSidebarLabel: View {
    @EnvironmentObject private var engine: BenchmarkEngine

    var body: some View {
        BadgedLabel(progress: engine.progress, isRunning: engine.isRunning)
    }

    private struct BadgedLabel: View {
        @ObservedObject var progress: BenchmarkProgress
        let isRunning: Bool

        var body: some View {
            Label("Benchmark", systemImage: "gauge.with.dots.needle.67percent")
                .badge(isRunning ? Text("\(Int(progress.fraction * 100))%") : nil)
        }
    }
}

private struct FooterProgress: View {
    @ObservedObject var progress: BenchmarkProgress
    let isStopping: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(isStopping ? "Stopping…" : "Testing… \(Int(progress.fraction * 100))%")
                .font(.caption.weight(.semibold))
        }
        ProgressView(value: progress.fraction)
            .progressViewStyle(.linear)
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: BenchmarkEngine

    var body: some View {
        let metric = store.settings.rankingMetric
        VStack(alignment: .leading, spacing: 8) {
            if engine.isRunning {
                FooterProgress(progress: engine.progress, isStopping: engine.phase == .stopping)
            } else if let run = engine.run ?? store.history.first, let winner = run.winner(by: metric) {
                Text("LAST WINNER")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ServerAvatar(name: winner.avatarName, color: winner.color, isSystem: winner.isSystem, size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(winner.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text("\(Format.ms(winner.value(for: metric))) · \(winner.shortAddress)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("Press ⌘R to run your first test.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(10)
    }
}
