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
