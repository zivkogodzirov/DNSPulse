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
    ///
    /// When the winner is the DNS the Mac already uses, the other row for that same server is left out.
    func findTies(by metric: RankingMetric) -> [ServerResult] {
        guard metric != .minimum else { return [] }
        let answered = ranked(by: metric).filter { $0.successes > 0 && $0.value(for: metric).isFinite }
        guard let winner = answered.first, winner.successes >= 2 else { return [] }
        let reference = TieSample(winner, metric: metric)
        let winnerIsCurrent = isCurrentDNS(winner)
        return answered.dropFirst().filter {
            !(winnerIsCurrent && isCurrentDNS($0)) && reference.isTied(with: TieSample($0, metric: metric))
        }
    }

    /// Rounds for a follow-up test of tied servers: at least 5, and twice what this run used.
    var retestRounds: Int { max(5, rounds * 2) }

    /// A follow-up test that measures what this run measured (same websites, mode, record type and timeout),
    /// only with more rounds.
    var retestOverrides: TestOverrides {
        TestOverrides(rounds: retestRounds, mode: mode, recordType: recordType, domains: domains, timeoutMs: timeoutMs)
    }
}

extension ServerResult {
    /// Whether a test can't tell this server and `other` apart for `metric`, by the rules `findTies(by:)` uses.
    /// Nil for the fastest response, which has no spread to test.
    func isTied(with other: ServerResult, by metric: RankingMetric) -> Bool? {
        guard metric != .minimum else { return nil }
        return TieSample(self, metric: metric).isTied(with: TieSample(other, metric: metric))
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
        case .minimum:
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
