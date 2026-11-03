import SwiftUI
import UniformTypeIdentifiers

enum ResultsTab: String, CaseIterable, Identifiable {
    case leaderboard = "Leaderboard"
    case charts = "Charts"
    case statistics = "Statistics"
    case websites = "Websites"
    case compare = "Compare"

    var id: String { rawValue }
}

/// Everything about one benchmark run. Used live on the dashboard and for saved runs in History.
struct ResultsView: View {
    let run: BenchmarkRun
    var isLive = false
    var isPrevious = false
    /// Offers to retest failed lookups (see `RetestFailuresBar`).
    var allowsRetest = false

    @EnvironmentObject private var store: AppStore

    var body: some View {
        let chosen = store.settings.rankingMetric
        // The connection-based rankings need the destination check; until then this test ranks by the score.
        let metric = chosen.needsConnections && !run.destinations.isChecked ? .score : chosen
        let ranked = run.ranked(by: metric)
        let hasAnswers = ranked.contains { $0.successes > 0 }
        let tied = isLive ? [] : run.tiedWithWinner(by: metric)

        VStack(alignment: .leading, spacing: 16) {
            header(metric: metric)

            if run.interceptionDetected == true {
                InterceptionBanner()
            }
            if !isLive, let winner = ranked.first, winner.successes > 0 {
                WinnerBanner(run: run, winner: winner, metric: metric, tied: tied)
                if run.status != .running {
                    RecommendationPanel(run: run, ranked: ranked, metric: metric, tied: tied)
                }
            }
            if hasAnswers {
                InsightsGrid(run: run, ranked: ranked, metric: metric)
            }
            if !isLive, run.status != .running {
                DestinationBar(run: run, ranked: ranked)
                if chosen != metric {
                    Label(fallbackReason(for: chosen), systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ResultsTabPicker()

            ShownResultsTab { tab in
                switch tab {
                case .leaderboard:
                    VStack(alignment: .leading, spacing: 12) {
                        if !isLive, run.destinations.isChecked { RankingSwitch(run: run) }
                        LeaderboardView(run: run, ranked: ranked, metric: metric, isLive: isLive)
                    }
                case .charts:
                    VStack(alignment: .leading, spacing: 12) {
                        if !isLive, run.destinations.isChecked { RankingSwitch(run: run) }
                        ChartsView(run: run, ranked: ranked, metric: metric)
                    }
                case .statistics:
                    StatisticsTable(ranked: ranked, destinations: isLive ? nil : run.destinations)
                case .websites:
                    DomainMatrixView(run: run, servers: ranked, isLive: isLive, allowsRetest: allowsRetest)
                case .compare:
                    CompareView(run: run, ranked: ranked, metric: metric, isLive: isLive)
                }
            }
        }
        .dnsActionSheets()
    }

    /// Why this test ranks by the score instead of a connection-based ranking.
    private func fallbackReason(for chosen: RankingMetric) -> String {
        let start = "Ranked by Overall score"
        if run.destinations.canCheck {
            return "\(start) for now: ranking by \(chosen.title) needs this test's connection check. Click Check Where They Send You above."
        } else if run.mode == .uncached {
            return "\(start): ranking by \(chosen.title) needs a Real-world or Cached test, as Uncached lookups use made-up names that don't point to real servers."
        } else if !run.recordType.carriesAddresses {
            return "\(start): ranking by \(chosen.title) needs a test with record type A or AAAA, whose answers are server addresses."
        }
        return "\(start): this test is from before DNS Pulse kept the addresses its answers pointed to. Run a new test to rank by \(chosen.title)."
    }

    private func header(metric: RankingMetric) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(isLive ? "Live results" : isPrevious ? "Last test" : "Results")
                        .font(.title3.weight(.bold))
                    if isLive {
                        TagLabel(text: "LIVE", color: .red)
                    } else if run.status == .cancelled {
                        TagLabel(text: "STOPPED EARLY", color: .orange)
                    }
                }
                Text("\(Format.date(run.date)) · \(run.summaryLine)\(run.duration > 0 ? " · took \(Format.duration(run.duration))" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Rank by", selection: $store.settings.rankingMetric) {
                ForEach(RankingMetric.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .help(metric.help)
            ExportMenu(run: run, metric: metric)
                .disabled(isLive)
        }
    }
}

// MARK: - Tabs

private struct ResultsTabPicker: View {
    @AppStorage("resultsTab") private var tab: ResultsTab = .leaderboard

    var body: some View {
        Picker("View", selection: $tab) {
            ForEach(ResultsTab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 560)
    }
}

/// Builds `content` for the results tab this page shows. Benchmark and History share the tab setting: the page on
/// screen follows it, and the hidden one keeps the tab it was showing until it's shown again, rather than rebuilding
/// every tab change in the background. Only these small views hold the setting, so a change doesn't re-run whole pages.
private struct ShownResultsTab<Content: View>: View {
    @ViewBuilder let content: (ResultsTab) -> Content

    @AppStorage("resultsTab") private var tab: ResultsTab = .leaderboard
    @Environment(\.isActiveSection) private var isActiveSection
    @State private var hiddenTab: ResultsTab?

    var body: some View {
        content(isActiveSection ? tab : hiddenTab ?? tab)
            .onChange(of: isActiveSection, initial: true) { _, isActive in
                hiddenTab = isActive ? nil : tab
            }
    }
}

extension View {
    /// Caps the width of a page that shows results. The website grid uses extra width on large windows.
    func resultsPageWidth(_ width: CGFloat, allowsWide: Bool = true) -> some View {
        modifier(ResultsPageWidth(width: width, allowsWide: allowsWide))
    }
}

private struct ResultsPageWidth: ViewModifier {
    let width: CGFloat
    let allowsWide: Bool

    func body(content: Content) -> some View {
        ShownResultsTab { tab in
            content.frame(maxWidth: allowsWide && tab == .websites ? 1680 : width)
        }
    }
}

// MARK: - Winner

private struct WinnerBanner: View {
    let run: BenchmarkRun
    let winner: ServerResult
    let metric: RankingMetric
    /// Servers statistically tied with the winner.
    let tied: [ServerResult]

    @ObservedObject private var actions = DNSActionCenter.shared
    @State private var copied = false
    @State private var showHelp = false

    private var comparison: String? {
        guard let system = run.systemResult, system.successes > 0 else { return nil }
        if run.isCurrentDNS(winner) { return "Your current DNS is already the fastest — no change needed." }
        if tied.contains(where: { $0.id == system.id }) { return "No measurable difference from your current DNS (\(system.address))." }
        let mine = system.value(for: metric)
        let best = winner.value(for: metric)
        guard mine.isFinite, best.isFinite, mine > 0 else { return nil }
        let faster = (mine - best) / mine
        if faster < 0.03 { return "About the same speed as your current DNS (\(system.address))." }
        return "\(Int((faster * 100).rounded()))% faster than your current DNS (\(system.address), \(Format.ms(mine)))."
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle().fill(.white.opacity(0.16)).frame(width: 70, height: 70)
                Image(systemName: "trophy.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: "#FFE38A"), Color(hex: "#F5B400")], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("FASTEST DNS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .opacity(0.75)
                HStack(spacing: 10) {
                    Text(winner.name)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    ServerAvatar(name: winner.avatarName, color: winner.color, isSystem: winner.isSystem, size: 26)
                }
                Text("\(winner.address)  ·  \(Format.ms(winner.value(for: metric))) \(metric.shortTitle)  ·  \(Format.percent(winner.successRate)) answered")
                    .font(.callout.monospacedDigit())
                    .opacity(0.9)
                if let comparison {
                    Text(comparison)
                        .font(.callout.weight(.semibold))
                        .padding(.top, 2)
                }
                if !tied.isEmpty {
                    HStack(spacing: 10) {
                        Label("Statistically tied with \(TieText.names(tied))", systemImage: "equal.circle.fill")
                            .font(.callout.weight(.semibold))
                            .help("The differences are within measurement noise (95% confidence). Re-test with more rounds to separate them.")
                        RetestButton(run: run, contenders: [winner] + tied)
                            .buttonStyle(BannerChipButtonStyle())
                    }
                }
                if run.interceptionDetected == true, winner.proto == .udp {
                    Label("Plain DNS is intercepted on this network, so this may not be the real provider's speed.", systemImage: "exclamationmark.shield")
                        .font(.caption.weight(.medium))
                        .opacity(0.85)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 8) {
                if winner.canBeSystemDNS, !run.isCurrentDNS(winner) {
                    Button { actions.proposeSwitch(to: winner, in: run, metric: metric) } label: {
                        Label("Use This DNS…", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(BannerPrimaryButtonStyle())
                    .disabled(actions.isWorking)
                } else if winner.proto.isEncrypted {
                    Button { actions.saveProfile(for: winner) } label: {
                        Label("Install as Encrypted DNS Profile…", systemImage: "lock.shield.fill")
                    }
                    .buttonStyle(BannerPrimaryButtonStyle())
                }
                Button {
                    Exporter.copy(winner.address)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied!" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button { SystemLinks.openNetworkSettings() } label: {
                    Label("Open Network Settings", systemImage: "network")
                }
                Button { showHelp.toggle() } label: {
                    Label("How to switch DNS", systemImage: "questionmark.circle")
                }
                .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                    SwitchDNSHelp(winner: winner, isCurrent: run.isCurrentDNS(winner))
                }
                if actions.canRestore {
                    Button { Task { await actions.proposeRestore() } } label: {
                        Label("Restore Previous DNS", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(actions.isWorking)
                }
            }
            .buttonStyle(GlassButtonStyle())
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#2563EB"), Color(hex: "#6D28D9")], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(RadialGradient(colors: [.white.opacity(0.18), .clear], center: .topLeading, startRadius: 10, endRadius: 420))
                .allowsHitTesting(false)
        )
        .shadow(color: Color(hex: "#4338CA").opacity(0.3), radius: 12, y: 6)
    }
}

private struct SwitchDNSHelp: View {
    let winner: ServerResult
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Switch to \(winner.name)").font(.headline)
            if winner.proto == .dot {
                Text("This is a DNS-over-TLS server. macOS network settings only take plain DNS addresses, and browsers only offer DoH, so use it for the whole Mac instead:")
                    .fixedSize(horizontal: false, vertical: true)
                Text("1. Click **Install as Encrypted DNS Profile…** and save the profile.\n2. Open the saved file, then approve it in **System Settings → General → Device Management**.\n\nServer name: \(winner.address)")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if winner.proto == .doh {
                Text("This is a DNS-over-HTTPS server. macOS network settings only take IP addresses, so use it for the whole Mac as a profile:")
                    .fixedSize(horizontal: false, vertical: true)
                Text("1. Click **Install as Encrypted DNS Profile…** and save the profile.\n2. Open the saved file, then approve it in **System Settings → General → Device Management**.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Or use it in just your browser:")
                    .fixedSize(horizontal: false, vertical: true)
                Text("• Chrome / Edge / Brave: Settings → Privacy → Use secure DNS → Custom\n• Firefox: Settings → Privacy → DNS over HTTPS → Custom\n\nPaste: \(winner.address)")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if isCurrent {
                Text("Your Mac is already using this server. Nothing to change.")
            } else {
                Text("1. Open **System Settings → Network**.\n2. Select **Wi-Fi** or **Ethernet** and click **Details…**\n3. Choose **DNS**, click **+** and enter **\(winner.address)**.\n4. Remove the old entries you don't want, then click **OK**.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tip: add the provider's secondary address as well, so you have a backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

// MARK: - Interception

struct InterceptionBanner: View {
    @EnvironmentObject private var store: AppStore
    @State private var showHelp = false

    var body: some View {
        let encryptedOff = store.servers.filter { $0.proto.isEncrypted && !$0.isEnabled }.count
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your network is intercepting DNS").font(.headline)
                Text("A test lookup sent to \(InterceptionCheck.probeAddress) — an address where no DNS server exists — still got an answer. Something on your network (router, ISP, or a VPN / filter app) answers all plain DNS itself, so the **UDP** results mostly measure that, not the providers. Encrypted **DoT** and **DoH** servers bypass it and show real provider speeds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if encryptedOff > 0 {
                        Button("Switch On \(encryptedOff) Encrypted Servers") { store.enableEncryptedServers() }
                    }
                    Button("What can I do?") { showHelp.toggle() }
                        .popover(isPresented: $showHelp, arrowEdge: .bottom) { InterceptionHelp() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }
}

private struct InterceptionHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Getting real DNS results").font(.headline)
            Text("""
            • **Router:** look for settings such as *DNS hijacking*, *DNS redirect*, *Intercept DNS*, *Parental controls* or *Safe browsing*. Turn them off, or set your preferred DNS on the router itself.
            • **This Mac:** VPN, antivirus, ad-blocking or "secure DNS" apps can redirect DNS. Pause them and test again.
            • **ISP:** some providers redirect all plain DNS. Encrypted DNS (DoH) in your browser, or a DoH/DoT profile, gets around it.
            """)
            .fixedSize(horizontal: false, vertical: true)
            Text("Run another test after changing something. This warning disappears when the network stops intercepting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 420)
    }
}

// MARK: - Insights

private struct InsightsGrid: View {
    let run: BenchmarkRun
    let ranked: [ServerResult]
    let metric: RankingMetric

    var body: some View {
        let answered = ranked.filter { $0.successes > 0 }
        let fastest = answered.first
        let mostReliable = answered.max { a, b in
            a.successRate == b.successRate ? a.score > b.score : a.successRate < b.successRate
        }
        let steady = answered.filter { $0.successRate >= 0.9 && $0.successes >= 3 }
        let mostConsistent = steady.min { $0.stats.stdDev < $1.stats.stdDev }
        let system = run.systemResult

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            if let fastest {
                InsightTile(icon: "bolt.fill", tint: .orange, title: "Fastest",
                            value: fastest.name, detail: "\(Format.ms(fastest.value(for: metric))) \(metric.shortTitle)")
            }
            if let mostReliable {
                InsightTile(icon: "checkmark.shield.fill", tint: .green, title: "Most reliable",
                            value: mostReliable.name, detail: "\(Format.percent(mostReliable.successRate)) of lookups answered")
            }
            if let mostConsistent {
                InsightTile(icon: "waveform.path.ecg", tint: .purple, title: "Most consistent",
                            value: mostConsistent.name, detail: "±\(Format.ms(mostConsistent.stats.stdDev)) jitter")
            }
            if let system {
                let rank = (ranked.firstIndex { $0.id == system.id } ?? 0) + 1
                InsightTile(icon: "house.fill", tint: .blue, title: "Your current DNS",
                            value: system.successes > 0 ? "Rank \(rank) of \(ranked.count)" : "No answers",
                            detail: system.successes > 0 ? "\(system.address) · \(Format.ms(system.value(for: metric)))" : system.failureSummary)
            } else if let slowest = answered.last, answered.count > 1 {
                InsightTile(icon: "tortoise.fill", tint: .red, title: "Slowest",
                            value: slowest.name, detail: "\(Format.ms(slowest.value(for: metric))) \(metric.shortTitle)")
            }
        }
    }
}

// MARK: - Leaderboard

private struct LeaderboardView: View {
    let run: BenchmarkRun
    let ranked: [ServerResult]
    let metric: RankingMetric
    let isLive: Bool

    var body: some View {
        let maxValue = ranked.map { $0.value(for: metric) }.filter(\.isFinite).max() ?? 1
        let destinations = isLive ? nil : run.destinations
        VStack(spacing: 0) {
            ForEach(Array(ranked.enumerated()), id: \.element.id) { index, result in
                LeaderboardRow(run: run, rank: index + 1, result: result, metric: metric, maxValue: max(maxValue, 0.001), isLive: isLive,
                               destination: destinations?.summaries[result.id],
                               isFartherThanOthers: destinations?.sendsFartherThanOthers(result.id) ?? false)
                if index < ranked.count - 1 {
                    Divider().padding(.leading, 70)
                }
            }
        }
        .card(padding: 4)
        // Not while a test runs: close servers trade places on almost every update, and animating each of those
        // keeps the whole page redrawing.
        .animation(isLive ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: ranked.map(\.id))
    }
}

private struct LeaderboardRow: View {
    let run: BenchmarkRun
    let rank: Int
    let result: ServerResult
    let metric: RankingMetric
    let maxValue: Double
    let isLive: Bool
    /// How near the servers it sent you to were, once the test's destinations have been checked.
    var destination: DestinationReport.Summary?
    var isFartherThanOthers = false

    var body: some View {
        let stats = result.stats
        let value = result.value(for: metric)
        HStack(spacing: 14) {
            RankBadge(rank: rank)
            ServerAvatar(name: result.avatarName, color: result.color, isSystem: result.isSystem, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.name).font(.headline).lineLimit(1)
                    ProtocolBadge(proto: result.proto)
                    if result.isSystem { TagLabel(text: "CURRENT", color: .blue) }
                }
                Text(result.address)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(width: 215, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                if value.isFinite {
                    LatencyBar(fraction: value / maxValue, color: result.color)
                    let average = Format.ms(stats.mean, margin: stats.marginOfError)
                    ViewThatFits(in: .horizontal) {
                        Text("average \(average)  ·  median \(Format.ms(stats.median))  ·  best \(Format.ms(stats.minimum))  ·  95% \(Format.ms(stats.p95))  ·  jitter ±\(Format.ms(stats.stdDev))")
                        Text("average \(average)  ·  median \(Format.ms(stats.median))  ·  best \(Format.ms(stats.minimum))")
                        Text("average \(average)  ·  median \(Format.ms(stats.median))")
                        Text("average \(average)")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Average ± its 95% margin of error: the true average is very likely in this range. More rounds make it narrower.")
                    if let destination {
                        DestinationLine(summary: destination,
                                        isInterceptorsChoice: run.interceptionDetected == true && result.proto == .udp && !result.isSystem,
                                        isFartherThanOthers: isFartherThanOthers)
                    }
                } else if isLive && result.attempts == 0 && result.lastError == nil {
                    Text("Waiting for answers…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(result.failureSummary, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.ms(value))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(value.isFinite ? .primary : .secondary)
                ReliabilityLabel(rate: result.successRate, attempts: result.attempts)
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contextMenu {
            Button("Copy Address") { Exporter.copy(result.address) }
            Button("Copy Name") { Exporter.copy(result.name) }
            if !isLive, result.canBeSystemDNS {
                Divider()
                Button("Use This DNS…") { DNSActionCenter.shared.proposeSwitch(to: result, in: run, metric: metric) }
            } else if !isLive, result.proto.isEncrypted {
                Divider()
                Button("Install as Encrypted DNS Profile…") { DNSActionCenter.shared.saveProfile(for: result) }
            }
            if !isLive, result.successes > 0 {
                Divider()
                CompareMenuItem(run: run, result: result, metric: metric)
            }
            Divider()
            FutureTestsToggle(result: result)
        }
    }
}

/// Adds the row's server to the Compare tab and shows it. Only this item watches the selection, so changing it
/// doesn't re-render every leaderboard row.
private struct CompareMenuItem: View {
    let run: BenchmarkRun
    let result: ServerResult
    let metric: RankingMetric

    @ObservedObject private var selection = CompareSelection.shared
    @AppStorage("resultsTab") private var tab: ResultsTab = .leaderboard

    var body: some View {
        if selection.contains(result, in: run, metric: metric) {
            Button("Show in Compare") { tab = .compare }
        } else if selection.isFull(run, metric: metric) {
            Button("Compare Is Full (\(CompareSelection.limit) Servers)") {}
                .disabled(true)
        } else {
            Button("Add to Compare") {
                selection.add(result, in: run, metric: metric)
                tab = .compare
            }
        }
    }
}

/// Switches the row's server off or back on for future tests. Only this item watches the server list, so changing
/// any setting doesn't re-render every leaderboard row.
private struct FutureTestsToggle: View {
    let result: ServerResult
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let server = store.servers.first { $0.id == result.id } ?? store.servers.first { $0.matchKey == result.matchKey }
        if let server, server.isEnabled {
            Button("Switch Off for Future Tests") { store.setServers([server.id], enabled: false) }
        } else if let server {
            Button("Switch Back On for Future Tests") { store.setServers([server.id], enabled: true) }
        }
    }
}

// MARK: - Export

struct ExportMenu: View {
    let run: BenchmarkRun
    let metric: RankingMetric

    var body: some View {
        Menu {
            Button("Save Results as CSV…") {
                Exporter.save(Exporter.resultsCSV(run, metric: metric), name: Exporter.fileName(for: run, suffix: ".csv"), type: .commaSeparatedText)
            }
            Button("Save Per-Website Times as CSV…") {
                Exporter.save(Exporter.websitesCSV(run, metric: metric), name: Exporter.fileName(for: run, suffix: " websites.csv"), type: .commaSeparatedText)
            }
            Button("Save Full Run as JSON…") {
                Exporter.save(Exporter.json(run), name: Exporter.fileName(for: run, suffix: ".json"), type: .json)
            }
            Divider()
            Button("Copy Summary") { Exporter.copy(Exporter.summary(run, metric: metric)) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .fixedSize()
    }
}
