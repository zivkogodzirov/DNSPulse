import SwiftUI

struct BenchmarkView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: BenchmarkEngine

    var body: some View {
        let shownRun = engine.run ?? store.history.first
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ControlPanel()
                if let notice = engine.notice {
                    NoticeBanner(text: notice) { engine.notice = nil }
                }
                NewNetworkBanner()
                if engine.phase != .idle, !engine.isRetest {
                    ProgressPanel(progress: engine.progress)
                }
                if let shownRun {
                    ResultsView(run: shownRun, isLive: engine.isRunning && !engine.isRetest, isPrevious: engine.run == nil, allowsRetest: true)
                } else {
                    WelcomePanel()
                }
            }
            .padding(24)
            // The website grid uses extra width on large windows; everything else stays at a readable width.
            .resultsPageWidth(1240, allowsWide: shownRun != nil)
            .frame(maxWidth: .infinity)
            .background(ScrollActivity { engine.holdsResults = $0 })
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .providesContentWidthLimit(padding: 24)
        .task {
            if engine.interception == .unknown { engine.checkInterception() }
        }
        .sectionChrome(title: "Benchmark") {
            ToolbarItem(placement: .primaryAction) {
                if engine.isRunning {
                    Button { engine.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop the test (⌘.)")
                        .disabled(engine.phase == .stopping)
                } else {
                    Button { engine.start(store: store) } label: { Label("Start Test", systemImage: "play.fill") }
                        .help("Start a test (⌘R)")
                }
            }
        }
    }
}

/// Reports when the enclosing scroll view starts scrolling (true) and when it has been still for a moment (false).
/// Reports the window's backing scale factor when the view joins a window and whenever the scale changes,
/// e.g. when the window moves between a Retina and a non-Retina display.
private struct BackingScaleReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> Reporter { Reporter() }

    func updateNSView(_ view: Reporter, context: Context) {
        view.onChange = onChange
    }

    final class Reporter: NSView {
        var onChange: (CGFloat) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            report()
        }

        /// After the current layout pass, so the change doesn't land in the middle of one.
        private func report() {
            guard let scale = window?.backingScaleFactor else { return }
            DispatchQueue.main.async { [weak self] in self?.onChange(scale) }
        }
    }
}

private struct ScrollActivity: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Reporter { Reporter() }

    func updateNSView(_ view: Reporter, context: Context) {
        view.onChange = onChange
    }

    final class Reporter: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?
        private var settle: DispatchWorkItem?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                              queue: .main) { [weak self] _ in self?.scrolled() }
        }

        private func scrolled() {
            if settle == nil { onChange(true) }
            settle?.cancel()
            // Reports the end even if this view has gone by then, so nothing is left on hold.
            let report = onChange
            let work = DispatchWorkItem { [weak self] in
                self?.settle = nil
                report(false)
            }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}

// MARK: - Controls

private struct ControlPanel: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: BenchmarkEngine
    @Environment(\.accent) private var accent
    @Environment(\.navigator) private var navigator

    private let timeoutOptions = [500, 1000, 1500, 2000, 3000, 5000]
    private let websiteOptions = [0, 10, 25, 50, 75]
    /// The window's display scale, once it has one (see `BackingScaleReader`).
    @State private var displayScale: CGFloat?

    var body: some View {
        let servers = store.enabledServers.count
        let sites = store.testDomains.count
        let rounds = store.settings.rounds

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                AppIconView(size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Find your fastest DNS")
                        .font(.title2.weight(.bold))
                    HStack(spacing: 6) {
                        Button { navigator?.show(.servers) } label: {
                            Label("\(servers) servers", systemImage: "server.rack")
                        }
                        .buttonStyle(.link)
                        Text("×")
                        Button { navigator?.show(.websites) } label: {
                            Label("\(sites) websites", systemImage: "globe")
                        }
                        .buttonStyle(.link)
                        Text("× \(rounds) round\(rounds == 1 ? "" : "s") =")
                        Text("\((servers * sites * rounds).formatted()) lookups")
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        NetworkChip()
                        NetworkCheckLabel()
                    }
                    ActiveResolverLabel()
                }
                Spacer()
                if engine.isRunning {
                    Button { engine.stop() } label: {
                        Label(engine.phase == .stopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(ProminentButtonStyle(color: .red))
                    .disabled(engine.phase == .stopping)
                } else {
                    Button { engine.start(store: store) } label: {
                        Label("Start Test", systemImage: "play.fill")
                    }
                    .buttonStyle(ProminentButtonStyle(color: accent))
                    .disabled(servers == 0 || sites == 0)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 30) {
                    Field(title: "Rounds", help: "Each round looks up every website on every server once. More rounds give a steadier average.") {
                        RoundsControl(rounds: $store.settings.rounds)
                    }
                    Field(title: "Test mode", help: store.settings.mode.detail) {
                        Picker("Test mode", selection: $store.settings.mode) {
                            ForEach(TestMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 290)
                    }
                    Spacer(minLength: 0)
                }

                HStack(alignment: .top, spacing: 30) {
                    Field(title: "Websites per test", help: "Use fewer websites for a quicker test.") {
                        Picker("Websites", selection: $store.settings.websiteLimit) {
                            ForEach(websiteOptions, id: \.self) { value in
                                Text(value == 0 ? "All enabled (\(store.enabledWebsites.count))" : "First \(value)").tag(value)
                            }
                            if !websiteOptions.contains(store.settings.websiteLimit) {
                                Text("First \(store.settings.websiteLimit)").tag(store.settings.websiteLimit)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Field(title: "Record type", help: store.settings.recordType.summary) {
                        Picker("Record type", selection: $store.settings.recordType) {
                            ForEach(DNSRecordType.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Field(title: "Timeout", help: "How long to wait for an answer before counting the lookup as failed.") {
                        Picker("Timeout", selection: $store.settings.timeoutMs) {
                            ForEach(timeoutOptions, id: \.self) { Text(String(format: "%g s", Double($0) / 1000)).tag($0) }
                            if !timeoutOptions.contains(store.settings.timeoutMs) {
                                Text("\(store.settings.timeoutMs) ms").tag(store.settings.timeoutMs)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Field(title: "Parallel", help: "How many websites are looked up at the same time. Lower is gentler on slow connections.") {
                        Stepper(value: $store.settings.parallelism, in: 1...16) {
                            Text("\(store.settings.parallelism)").monospacedDigit().frame(minWidth: 18)
                        }
                    }
                    Spacer(minLength: 0)
                    PresetsMenu()
                }
                // Rebuilt once the window is on a screen, and when it moves to one with another scale: pop-up menus
                // measured before that stay squeezed to just their arrows on a non-Retina display.
                .id(displayScale)
                .background(BackingScaleReader { displayScale = $0 })

                Label(store.settings.mode.detail, systemImage: store.settings.mode.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(engine.isRunning)
        }
        .card(padding: 20)
    }
}

private struct NetworkCheckLabel: View {
    @EnvironmentObject private var engine: BenchmarkEngine

    var body: some View {
        Group {
            switch engine.interception {
            case .unknown, .checking:
                Label("Checking your network…", systemImage: "network")
                    .foregroundStyle(.secondary)
            case .clean:
                Label("Network check: DNS is not intercepted", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            case .intercepted:
                Label("Network check: plain DNS is being intercepted", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.weight(.medium))
        .help("DNS Pulse sends one lookup to \(InterceptionCheck.probeAddress), an address where no server exists. If it is answered, something on your network is intercepting DNS.")
    }
}

private struct Field<Content: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content
        }
        .help(help ?? "")
    }
}

private struct RoundsControl: View {
    @Binding var rounds: Int
    @Environment(\.isActiveSection) private var isActiveSection

    var body: some View {
        let clamped = Binding(get: { rounds }, set: { rounds = min(max($0, 1), 100) })
        HStack(spacing: 8) {
            TextField("Rounds", value: clamped, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 48)
                // The page stays alive behind other sections; keep Tab from landing in this field meanwhile.
                .disabled(!isActiveSection)
            Stepper("Rounds", value: clamped, in: 1...100)
                .labelsHidden()
            ForEach([1, 3, 5, 10, 20], id: \.self) { value in
                Button("\(value)") { rounds = value }
                    .buttonStyle(ChipButtonStyle(isSelected: rounds == value))
            }
        }
    }
}

private struct PresetsMenu: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Menu {
            Button("Quick check — 1 round, 25 websites") { apply(rounds: 1, websites: 25, mode: .realWorld) }
            Button("Standard — 3 rounds, all websites") { apply(rounds: 3, websites: 0, mode: .realWorld) }
            Button("Thorough — 10 rounds, all websites") { apply(rounds: 10, websites: 0, mode: .realWorld) }
            Divider()
            Button("Network distance — cached, 5 rounds") { apply(rounds: 5, websites: 50, mode: .cached) }
            Button("Cache-miss speed — uncached, 3 rounds") { apply(rounds: 3, websites: 50, mode: .uncached) }
        } label: {
            Label("Presets", systemImage: "slider.horizontal.3")
        }
        .fixedSize()
        .padding(.top, 16)
    }

    private func apply(rounds: Int, websites: Int, mode: TestMode) {
        store.settings.rounds = rounds
        store.settings.websiteLimit = websites
        store.settings.mode = mode
    }
}

// MARK: - Progress

private struct ProgressPanel: View {
    @ObservedObject var progress: BenchmarkProgress
    @EnvironmentObject private var engine: BenchmarkEngine

    private var title: String {
        switch engine.phase {
        case .idle: ""
        case .preparing: "Preparing servers…"
        case .warmingUp: "Warming up resolvers…"
        case .running:
            "Testing — round \(max(progress.currentRound, 1)) of \(engine.run?.rounds ?? 1)"
        case .stopping: "Stopping…"
        case .finished: "Test complete"
        case .cancelled: "Test stopped"
        }
    }

    var body: some View {
        HStack(spacing: 18) {
            ProgressRing(progress: progress.fraction, isDone: engine.phase == .finished)
                .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(title).font(.headline)
                    if let trigger = engine.run?.runTrigger {
                        TagLabel(text: "AUTO", color: .purple)
                            .help(trigger.title)
                    }
                    Spacer()
                    if !engine.isRunning {
                        Button("Dismiss") { engine.dismissResult() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack(spacing: 16) {
                    Label("\(progress.completedLookups.formatted()) of \(progress.totalLookups.formatted()) lookups", systemImage: "number")
                    Label(Format.duration(engine.elapsed), systemImage: "clock")
                    if engine.phase == .running, let remaining = progress.estimatedRemaining {
                        Label("about \(Format.duration(remaining)) left", systemImage: "hourglass")
                    }
                    if engine.isRunning, !progress.currentDomain.isEmpty {
                        Label(progress.currentDomain, systemImage: "globe")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

private struct ProgressRing: View {
    let progress: Double
    let isDone: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 7)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(colors: [accent.opacity(0.55), accent], center: .center),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(accent)
            } else {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
            }
        }
        // No animation: progress changes a few times a second, so it would never stop animating and redrawing.
    }
}

// MARK: - First launch

private struct WelcomePanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it works").font(.title3.weight(.bold))
            HStack(alignment: .top, spacing: 14) {
                FeatureTile(icon: "server.rack", tint: .blue, title: "Pick DNS servers",
                            text: "Cloudflare, Google, Quad9 and many more are ready to go. Add your own or your ISP's.")
                FeatureTile(icon: "globe", tint: .green, title: "Choose websites",
                            text: "The top 100 websites are included. Edit, remove or add any site you visit.")
                FeatureTile(icon: "repeat", tint: .purple, title: "Run several rounds",
                            text: "Every server is queried at the same moment, round after round, for a fair average.")
                FeatureTile(icon: "trophy.fill", tint: .orange, title: "See the winner",
                            text: "Leaderboard, charts, a per-website heatmap and CSV export.")
            }
            Text("Press **Start Test** or **⌘R** to begin.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct FeatureTile: View {
    let icon: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.gradient))
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
