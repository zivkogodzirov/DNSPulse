import SwiftUI

/// Offers the destination check for a finished test, shows its progress, then sums up what it found.
struct DestinationBar: View {
    let run: BenchmarkRun
    let ranked: [ServerResult]

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: BenchmarkEngine
    @ObservedObject private var checker = DestinationChecker.shared
    @AppStorage("resultsTab") private var tab: ResultsTab = .leaderboard
    @AppStorage("websites.source") private var source: GridSource = .lookup

    var body: some View {
        let report = run.destinations
        if report.canCheck {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.teal.gradient))
                if let progress = checker.progress[run.id] {
                    checking(progress)
                } else if let check = report.check {
                    summary(report, check: check)
                } else {
                    offer(report)
                }
            }
            .card(padding: 14)
        }
    }

    private func offer(_ report: DestinationReport) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 3) {
                Text("Where does each DNS send you?").font(.headline)
                Text("DNS also picks which of a website's servers you connect to, and a farther one makes every connection slower. This connects to the \(report.addressCount) servers the answers pointed to, usually in under a minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button { checker.check(run, store: store) } label: {
                Label("Check Where They Send You", systemImage: "location.north.line")
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.isRunning)
        }
    }

    private func checking(_ progress: DestinationChecker.Progress) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Checking where each DNS sends you…").font(.headline)
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 360)
                Text("Connected to \(progress.done) of \(progress.total) servers")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Stop") { checker.stop(run) }
        }
    }

    private func summary(_ report: DestinationReport, check: DestinationCheck) -> some View {
        let best = report.bestServer(among: ranked)
        let bestText = best.flatMap { server in
            report.summaries[server.id].map { " **\(server.name)** chose the nearest servers most often: the nearest on \($0.nearest) of \($0.websites) websites." }
        } ?? ""
        return Group {
            VStack(alignment: .leading, spacing: 3) {
                Text("Where each DNS sends you").font(.headline)
                Text(.init("Connected to the \(check.serverCount) servers the answers pointed to, \(Format.date(check.date)).\(bestText)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Show Connection Times") {
                source = .connection
                tab = .websites
            }
            Button("Check Again") { checker.check(run, store: store) }
                .disabled(engine.isRunning)
        }
    }
}

/// One line under a leaderboard row: how near the servers this DNS sent you to were.
struct DestinationLine: View {
    let summary: DestinationReport.Summary
    /// Plain DNS on a network that intercepts it: the interceptor answered, so it chose these servers.
    let isInterceptorsChoice: Bool
    /// Clearly farther than the other servers (see `DestinationReport.sendsFartherThanOthers`).
    let isFartherThanOthers: Bool

    var body: some View {
        let extra = summary.averageExtra < 0.5 ? "" : " · +\(Format.ms(summary.averageExtra)) on average"
        let whose = isInterceptorsChoice ? " · your network's choice" : ""
        Label("Nearest server on \(summary.nearest) of \(summary.websites) websites\(extra)\(whose)", systemImage: "location.north.line")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(isFartherThanOthers ? Color.orange : .secondary)
            .lineLimit(1)
            .help("Connection time to the servers this DNS sent you to, compared with the nearest any DNS found for each website. Sent farther on \(summary.farther) website\(summary.farther == 1 ? "" : "s"): at least \(Int(DestinationReport.fartherByMs)) ms and \(Int((DestinationReport.fartherByRatio - 1) * 100))% slower to connect to.")
    }
}

/// What the website grid shows.
enum GridSource: String, CaseIterable, Identifiable {
    case lookup, connection
    /// The website's lookup time plus three trips to the server it pointed to, as in `RankingMetric.lookupAndConnection`.
    case combined

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lookup: "Lookup time"
        case .connection: "Connection time"
        case .combined: "Lookup + connection"
        }
    }

    var usesConnections: Bool { self != .lookup }
}

/// Above the Leaderboard and Charts once a test's destinations are checked: switches the ranking between lookup
/// speed alone and the connection-based rankings, and names each one's winner.
struct RankingSwitch: View {
    let run: BenchmarkRun

    @EnvironmentObject private var store: AppStore
    /// The lookup ranking to go back to (Overall score unless another was picked).
    @AppStorage("ranking.lookupMetric") private var lookupMetric: RankingMetric = .score

    private enum Choice: Hashable {
        case lookup, combined, distance
    }

    var body: some View {
        let lookup = store.settings.rankingMetric.needsConnections ? lookupMetric : store.settings.rankingMetric
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Rank by").font(.callout).foregroundStyle(.secondary)
                Picker("Rank by", selection: choice) {
                    Text("Lookup only").tag(Choice.lookup)
                    Text("Lookup + connection").tag(Choice.combined)
                    Text("Server distance").tag(Choice.distance)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Lookup only: how fast each DNS answers. Lookup + connection: that plus three trips to the server it sent you to, the closest to which DNS gets pages started soonest. Server distance: only how near those servers are.")
            }
            Text(.init(winners(lookup: lookup)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var choice: Binding<Choice> {
        Binding {
            switch store.settings.rankingMetric {
            case .lookupAndConnection: .combined
            case .serverDistance: .distance
            default: .lookup
            }
        } set: { choice in
            let current = store.settings.rankingMetric
            if !current.needsConnections { lookupMetric = current }
            switch choice {
            case .lookup: store.settings.rankingMetric = lookupMetric
            case .combined: store.settings.rankingMetric = .lookupAndConnection
            case .distance: store.settings.rankingMetric = .serverDistance
            }
        }
    }

    /// "Overall score: Quad9 DoH (17.6 ms) · Lookup + connection: Cloudflare DoH (141 ms) · Server distance: OpenDNS DoT (40.3 ms)".
    private func winners(lookup: RankingMetric) -> String {
        let parts: [(String, RankingMetric)] = [(lookup.title, lookup), ("Lookup + connection", .lookupAndConnection), ("Server distance", .serverDistance)]
        return parts.compactMap { label, metric in
            run.winner(by: metric).map { "\(label): **\($0.name)** (\(Format.ms($0.value(for: metric))))" }
        }.joined(separator: "  ·  ")
    }
}
