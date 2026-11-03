import Foundation

extension BenchmarkRun {
    /// Servers this run can't tell apart from the winner for `metric`, at the usual 5% level, best first.
    ///
    /// - Average: Welch's t-test on the answered lookups; p ≥ 0.05 means tied.
    /// - Score: speed and reliability each tested on their own, since a handful of 2-second timeouts swamps a
    ///   t-test: tied when the answered lookups are tied by the t-test above and Fisher's exact test finds no
    ///   significant difference in how often each failed.
    /// - Median and 95th percentile: a t-test compares means, so these use distribution-free confidence
    ///   intervals for the quantile itself (order statistics). Overlapping 83% intervals mean tied, which is
    ///   roughly a 5% test and, like the median, ignores how far the outliers are. Too few lookups to bound
    ///   the quantile (such as a 95th percentile from 20 lookups) also means tied.
    /// - Fastest response: a single best answer has no spread to test, so nothing is reported as tied.
    /// - Lookup + connection and server distance: compared website by website (see `connectionsTied`).
    ///
    /// When the winner is the DNS the Mac already uses, the other row for that same server is left out.
    func findTies(by metric: RankingMetric) -> [ServerResult] {
        let metric = usableMetric(metric)
        guard metric.hasNoiseTest else { return [] }
        let answered = ranked(by: metric).filter { $0.successes > 0 && $0.value(for: metric).isFinite }
        guard let winner = answered.first, winner.successes >= 2 else { return [] }
        let winnerIsCurrent = isCurrentDNS(winner)
        let others = answered.dropFirst().filter { !(winnerIsCurrent && isCurrentDNS($0)) }
        if metric.needsConnections {
            return others.filter { connectionsTied(winner, $0, by: metric) }
        }
        let reference = TieSample(winner, metric: metric)
        return others.filter { reference.isTied(with: TieSample($0, metric: metric)) }
    }

    /// Whether this test can't tell `a` and `b` apart for `metric`, by the rules `findTies(by:)` uses. Nil for the
    /// fastest response, which has no spread to test.
    func isTied(_ a: ServerResult, _ b: ServerResult, by metric: RankingMetric) -> Bool? {
        let metric = usableMetric(metric)
        guard metric.hasNoiseTest else { return nil }
        if metric.needsConnections { return connectionsTied(a, b, by: metric) }
        return TieSample(a, metric: metric).isTied(with: TieSample(b, metric: metric))
    }

    /// The ranking this test can use: the connection-based ones need its destination check, and rank by the score
    /// without it (see `ServerResult.value(for:)`).
    func usableMetric(_ metric: RankingMetric) -> RankingMetric {
        metric.needsConnections && !destinations.isChecked ? .score : metric
    }

    /// Compares two servers website by website: for each website both reached, the difference between their values,
    /// then whether those differences average out to more than noise (a paired t-test). Pairing takes out what the
    /// websites themselves add, as a far-away website is far for both. Lookup + connection also needs failures
    /// tied, as the score does. Too few websites to compare counts as tied.
    private func connectionsTied(_ a: ServerResult, _ b: ServerResult, by metric: RankingMetric) -> Bool {
        let report = destinations
        let trips = metric == .lookupAndConnection ? DestinationReport.tripsPerNewWebsite : 1
        var differences: [Double] = []
        for domain in domains {
            guard let connectA = report.time(a.id, domain), let connectB = report.time(b.id, domain),
                  connectA.isFinite, connectB.isFinite else { continue }
            var difference = trips * (connectA - connectB)
            if metric == .lookupAndConnection {
                guard let lookupA = a.domainStats[domain]?.mean, let lookupB = b.domainStats[domain]?.mean else { continue }
                difference += lookupA - lookupB
            }
            differences.append(difference)
        }
        guard let p = Statistics.pairedPValue(differences) else { return true }
        let failuresTied = metric != .lookupAndConnection
            || Statistics.fisherExactPValue(a.failures, of: a.attempts, b.failures, of: b.attempts) >= 0.05
        return p >= 0.05 && failuresTied
    }

    /// Rounds for a follow-up test of tied servers: at least 5, and twice what this run used.
    var retestRounds: Int { max(5, rounds * 2) }

    /// A follow-up test that measures what this run measured (same websites, mode, record type and timeout),
    /// only with more rounds.
    var retestOverrides: TestOverrides {
        TestOverrides(rounds: retestRounds, mode: mode, recordType: recordType, domains: domains, timeoutMs: timeoutMs)
    }
}

/// What the tie rules need from one server, computed once.
private struct TieSample {
    let result: ServerResult
    let metric: RankingMetric
    let stats: LatencyStats
    let interval: ClosedRange<Double>?

    init(_ result: ServerResult, metric: RankingMetric) {
        self.result = result
        self.metric = metric
        stats = result.stats
        switch metric {
        case .median: interval = result.medianInterval
        case .p95: interval = result.p95Interval
        default: interval = nil
        }
    }

    func isTied(with other: TieSample) -> Bool {
        switch metric {
        case .average:
            return meansTied(other)
        case .score:
            return meansTied(other) && failuresTied(other)
        case .median, .p95:
            guard let interval, let otherInterval = other.interval else { return false }
            return interval.overlaps(otherInterval)
        case .minimum, .lookupAndConnection, .serverDistance:
            return false
        }
    }

    private func meansTied(_ other: TieSample) -> Bool {
        guard let p = Statistics.welchPValue(stats, other.stats) else { return false }
        return p >= 0.05
    }

    private func failuresTied(_ other: TieSample) -> Bool {
        Statistics.fisherExactPValue(result.failures, of: result.attempts,
                                     other.result.failures, of: other.result.attempts) >= 0.05
    }
}
