import SwiftUI

/// Under the website grid: a test's failed lookups and the way to try them again, since a brief Wi-Fi dropout can fail
/// lookups that normally work. Where a retest isn't offered, it just says what an earlier one did.
struct RetestFailuresBar: View {
    let run: BenchmarkRun
    var allowsRetest = false

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: BenchmarkEngine
    @EnvironmentObject private var networks: NetworkStore

    var body: some View {
        if allowsRetest, engine.isRetest, engine.isRunning {
            RetestProgressRow(progress: engine.progress, isStopping: engine.phase == .stopping) { engine.stop() }
                .card(padding: 14)
        } else if run.retest != nil || (allowsRetest && run.failedLookups > 0) {
            summary.card(padding: 14)
        }
    }

    private var summary: some View {
        let failed = run.failedLookups
        let plan = RetestPlan(run: run, servers: store.servers)
        let blocked = allowsRetest ? blockedReason(plan) : nil
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: failed > 0 ? "arrow.clockwise.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(failed > 0 ? .orange : .green)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(failed: failed)).font(.headline)
                if allowsRetest, failed > 0, blocked == nil {
                    Text("A brief Wi-Fi dropout can fail lookups that normally work. This tries each one again on the same server: answers replace the failures and the score updates.")
                }
                if let retest = run.retest {
                    Text(outcome(of: retest))
                }
                if let blocked {
                    Text(blocked)
                } else if allowsRetest, plan.skippedLookups > 0 {
                    Text("\(plan.skippedLookups.formatted()) \(lookups(plan.skippedLookups)) can't be retried: their servers were removed or changed.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(failed > 0 ? failureDetails : "")
            Spacer(minLength: 12)
            if allowsRetest, failed > 0 {
                Button { engine.retestFailures(of: run, store: store) } label: {
                    Label("Retest Failed Websites", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocked != nil || engine.isRunning)
                .help("Tries \(plan.lookups.formatted()) failed \(lookups(plan.lookups)) again.")
            }
        }
    }

    private func title(failed: Int) -> String {
        guard failed > 0 else { return "No failed lookups left" }
        let sites = Set(run.results.flatMap { result in result.domainStats.filter { $0.value.failures > 0 }.keys }).count
        return "\(failed.formatted()) failed \(lookups(failed)) on \(sites.formatted()) website\(sites == 1 ? "" : "s")"
    }

    private func outcome(of retest: RunRetest) -> String {
        var text = "Last retest: \(retest.answered.formatted()) of \(retest.tried.formatted()) answered when tried again."
        if let leftOut = retest.leftOut, leftOut > 0 {
            text += " \(leftOut.formatted()) left out: the server refuses a made-up name under that website, but answers the real one."
        }
        if let before = retest.bestScoreBefore, let best = run.winner(by: .score) {
            let name = retest.bestServerBefore.map { $0 == best.name ? "" : "\($0) " } ?? ""
            text += " Best score: \(name)\(Format.ms(before)) → \(best.name) \(Format.ms(best.score))."
        }
        return text
    }

    /// For hovering over the summary: each website with failed lookups and the servers they failed on, most first.
    private var failureDetails: String {
        var sites: [String: [(server: ServerResult, count: Int)]] = [:]
        for result in run.results {
            for (domain, stat) in result.domainStats where stat.failures > 0 {
                sites[domain, default: []].append((result, stat.failures))
            }
        }
        let ordered = sites.map { (domain: $0.key, servers: $0.value.sorted { $0.count > $1.count }) }
            .sorted { a, b in
                let x = a.servers.reduce(0) { $0 + $1.count }, y = b.servers.reduce(0) { $0 + $1.count }
                return x != y ? x > y : a.domain < b.domain
            }
        let shownSites = 12, shownServers = 6
        var lines = ordered.prefix(shownSites).map { site in
            let names = site.servers.prefix(shownServers).map { "\($0.server.name)\($0.count > 1 ? " ×\($0.count)" : "") (\(Self.failureKind(of: $0.server)))" }
            let more = site.servers.count > shownServers ? " and \(site.servers.count - shownServers) more" : ""
            return "\(site.domain): " + names.joined(separator: ", ") + more
        }
        if ordered.count > shownSites { lines.append("…and \(ordered.count - shownSites) more websites") }
        let plainFailed = ordered.contains { $0.servers.contains { $0.server.proto == .udp } }
        if run.interceptionDetected == true, plainFailed {
            lines.append("")
            lines.append("Plain DNS is intercepted on this network, so its failures were your network's own resolver not answering, whichever server they were sent to.")
        }
        return lines.joined(separator: "\n")
    }

    /// What went wrong. A test counts failures per website, but keeps their kind only per server.
    private static func failureKind(of result: ServerResult) -> String {
        if result.timeouts == result.failures { return "timed out" }
        if result.serverErrors == result.failures || result.networkErrors == result.failures { return result.lastError ?? "error" }
        return "timed out or error"
    }

    private func lookups(_ count: Int) -> String { count == 1 ? "lookup" : "lookups" }

    /// Retesting on another network would mix two networks' results in one test.
    private func blockedReason(_ plan: RetestPlan) -> String? {
        guard run.failedLookups > 0 else { return nil }
        guard let current = networks.currentID else { return "Connect to a network to retest." }
        if let tested = run.networkID, tested != current {
            return "This test ran on \(run.networkName ?? "another network"). Connect to it to retest, so both tries measure the same network."
        }
        return plan.lookups == 0 ? "The servers behind these lookups were removed or changed, so they can't be retried." : nil
    }
}

/// Redraws a few times a second without touching the page around it.
private struct RetestProgressRow: View {
    @ObservedObject var progress: BenchmarkProgress
    let isStopping: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 6) {
                Text(isStopping ? "Stopping…" : "Retesting failed websites…").font(.headline)
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
                Text("\(progress.completedLookups.formatted()) of \(progress.totalLookups.formatted()) lookups\(progress.currentDomain.isEmpty ? "" : " · \(progress.currentDomain)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Stop", action: onStop).disabled(isStopping)
        }
    }
}
