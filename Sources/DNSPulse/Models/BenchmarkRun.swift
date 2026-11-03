import SwiftUI

enum RunStatus: String, Codable {
    case running, completed, cancelled
}

/// Running totals for one bucket of lookups (one website, or one round).
struct BucketStat: Codable, Hashable {
    var sum: Double = 0
    var successes = 0
    var failures = 0

    var attempts: Int { successes + failures }
    var mean: Double? { successes > 0 ? sum / Double(successes) : nil }

    mutating func add(_ result: ProbeResult) {
        if result.status.isSuccess {
            sum += result.latencyMs
            successes += 1
        } else {
            failures += 1
        }
    }

    mutating func replaceFailure(with answer: ProbeResult) {
        failures -= 1
        add(answer)
    }
}

/// What a retried lookup did to the failure it was retrying.
enum RetestOutcome {
    case answered, leftOut, failedAgain
}

struct LatencyStats {
    let count: Int
    let mean: Double
    let median: Double
    let minimum: Double
    let maximum: Double
    let p95: Double
    let stdDev: Double

    init(_ values: [Double]) {
        self.init(sorted: values.sorted())
    }

    /// `sorted` must be in ascending order.
    init(sorted: [Double]) {
        count = sorted.count
        guard !sorted.isEmpty else {
            mean = .infinity
            median = .infinity
            minimum = .infinity
            maximum = .infinity
            p95 = .infinity
            stdDev = .infinity
            return
        }
        let average = sorted.reduce(0, +) / Double(sorted.count)
        mean = average
        median = Self.percentile(sorted, 0.5)
        minimum = sorted[0]
        maximum = sorted[sorted.count - 1]
        p95 = Self.percentile(sorted, 0.95)
        stdDev = sorted.count > 1
            ? (sorted.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(sorted.count - 1)).squareRoot()
            : 0
    }

    /// Half-width of the 95% confidence interval for the mean ("12.4 ± 0.8 ms"); infinite below two samples.
    var marginOfError: Double {
        guard count > 1, stdDev.isFinite else { return .infinity }
        return Self.tCritical95(degreesOfFreedom: count - 1) * stdDev / Double(count).squareRoot()
    }

    /// Two-sided 95% critical value of Student's t: exact table up to 30 degrees of freedom, then the
    /// Cornish–Fisher expansion around 1.96 (within 0.001 of the exact value), which tends to 1.96 for large samples.
    static func tCritical95(degreesOfFreedom df: Int) -> Double {
        let table: [Double] = [
            12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
            2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
            2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042,
        ]
        guard df > table.count else { return table[Swift.max(df, 1) - 1] }
        let z = 1.959964
        let n = Double(df)
        return z + (z * z * z + z) / (4 * n) + (5 * pow(z, 5) + 16 * z * z * z + 3 * z) / (96 * n * n)
    }

    /// Linear-interpolated percentile of an already sorted array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .infinity }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Swift.min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}

/// What the latest retest of a test's failed lookups did.
struct RunRetest: Codable, Hashable {
    var date = Date()
    /// Failed lookups tried again, and how many of them answered.
    var tried = 0
    var answered = 0
    /// Of those tried, how many turned out not to count (see `BenchmarkCore.isLeftOut`).
    var leftOut: Int?
    /// How many failed lookups all this test's retests have replaced with answers.
    var recovered = 0
    /// The best overall score before this retest, and the server that had it.
    var bestScoreBefore: Double?
    var bestServerBefore: String?
}

struct ServerResult: Identifiable, Codable {
    var id: UUID
    var name: String
    var provider: String
    var address: String
    var proto: DNSProtocol
    var colorHex: String
    var isSystem: Bool
    private(set) var timeoutMs: Int
    /// Response times of every answered lookup, in milliseconds.
    private(set) var latencies: [Double] = []
    var nxdomain = 0
    private(set) var timeouts = 0
    private(set) var serverErrors = 0
    private(set) var networkErrors = 0
    var lastError: String?
    var domainStats: [String: BucketStat] = [:]
    var roundStats: [BucketStat] = []
    /// Lookups per website that count neither way (see `BenchmarkCore.isLeftOut`). Nil until there is one.
    private(set) var leftOut: [String: Int]?
    /// Per website, the first address of each answer: up to three different ones, as answers can rotate. Nil when the
    /// test didn't keep them (Uncached mode, record types without addresses, or tests from before they were kept).
    private(set) var destinations: [String: [String]]?
    /// The failure rate the score charges, set by the run (see `FailureCharge`); nil charges the server's own.
    var chargedFailureRate: Double?
    /// Set by the run once its destinations are checked: the average time to connect to the servers this one sent
    /// you to, nil when none of them connected.
    var connectionTime: Double?
    var isConnectionChecked = false
    /// Statistics worked out from the lookups above; `record(_:)` replaces it whenever they change.
    private var cache = ResultStatsCache()

    /// Every stored property except the ones the run sets and `cache`, so saved files stay exactly as they were.
    private enum CodingKeys: String, CodingKey {
        case id, name, provider, address, proto, colorHex, isSystem, timeoutMs, latencies, nxdomain, timeouts,
             serverErrors, networkErrors, lastError, domainStats, roundStats, leftOut, destinations
    }

    init(server: DNSServer, address: String, timeoutMs: Int) {
        id = server.id
        name = server.name
        provider = server.provider
        self.address = address
        proto = server.proto
        colorHex = server.resolvedColorHex
        isSystem = server.isSystem
        self.timeoutMs = timeoutMs
    }

    mutating func record(_ sample: BenchmarkSample) {
        if sample.isLeftOut { return leaveOut(sample.domain) }
        let result = sample.result
        switch result.status {
        case .ok:
            latencies.append(result.latencyMs)
        case .nxdomain:
            latencies.append(result.latencyMs)
            nxdomain += 1
        case .timeout:
            timeouts += 1
        case .serverError:
            serverErrors += 1
            lastError = result.detail ?? "Server error"
        case .networkError:
            networkErrors += 1
            lastError = result.detail ?? "Network error"
        case .cancelled:
            return
        }
        cache = ResultStatsCache()
        domainStats[sample.domain, default: BucketStat()].add(result)
        while roundStats.count < sample.round { roundStats.append(BucketStat()) }
        roundStats[sample.round - 1].add(result)
        keepDestination(of: sample)
    }

    private mutating func keepDestination(of sample: BenchmarkSample) {
        guard let address = sample.addresses.first else { return }
        var kept = destinations ?? [:]
        var addresses = kept[sample.domain] ?? []
        guard !addresses.contains(address), addresses.count < 3 else { return }
        addresses.append(address)
        kept[sample.domain] = addresses
        destinations = kept
    }

    /// Applies a retried lookup to one of its website's failures. One that answered takes the failure's place, and one
    /// that's left out removes it. One that fails again changes nothing, as it already counts as failed.
    ///
    /// A test saves failures per website, per round and per kind, but not which round or kind each website's were.
    /// So this takes the earliest round with a failure. An answer takes timeouts before errors, as they're what a
    /// dropout causes, and a lookup left out takes server errors, as that's what it was. The totals are exact either way.
    mutating func applyRetest(_ sample: BenchmarkSample) -> RetestOutcome {
        let result = sample.result
        guard let stat = domainStats[sample.domain], stat.failures > 0 else { return .failedAgain }
        let round = roundStats.firstIndex { $0.failures > 0 }
        if sample.isLeftOut {
            removeFailure(serverErrorsFirst: true)
            domainStats[sample.domain]?.failures -= 1
            if let round { roundStats[round].failures -= 1 }
            leaveOut(sample.domain)
            return .leftOut
        }
        guard result.status.isSuccess else { return .failedAgain }
        latencies.append(result.latencyMs)
        if result.status == .nxdomain { nxdomain += 1 }
        removeFailure(serverErrorsFirst: false)
        cache = ResultStatsCache()
        domainStats[sample.domain]?.replaceFailure(with: result)
        if let round { roundStats[round].replaceFailure(with: result) }
        keepDestination(of: sample)
        return .answered
    }

    private mutating func removeFailure(serverErrorsFirst: Bool) {
        if serverErrorsFirst, serverErrors > 0 {
            serverErrors -= 1
        } else if timeouts > 0 {
            timeouts -= 1
        } else if networkErrors > 0 {
            networkErrors -= 1
        } else if serverErrors > 0 {
            serverErrors -= 1
        }
        if failures == 0 { lastError = nil }
    }

    private mutating func leaveOut(_ domain: String) {
        var counts = leftOut ?? [:]
        counts[domain, default: 0] += 1
        leftOut = counts
    }

    var leftOutLookups: Int { leftOut?.values.reduce(0, +) ?? 0 }

    var successes: Int { latencies.count }
    var failures: Int { timeouts + serverErrors + networkErrors }
    var attempts: Int { successes + failures }
    var successRate: Double { attempts == 0 ? 0 : Double(successes) / Double(attempts) }
    var stats: LatencyStats { sortedSummary.stats }

    var failureRate: Double { attempts == 0 ? 0 : Double(failures) / Double(attempts) }

    /// Average time per lookup, with failed lookups counted as a full timeout at the rate the run charges.
    var score: Double {
        guard successes > 0 else { return .infinity }
        let rate = chargedFailureRate ?? failureRate
        return (1 - rate) * stats.mean + rate * Double(timeoutMs)
    }

    /// The 83% order-statistic intervals that tie detection compares for the median and 95th percentile.
    var medianInterval: ClosedRange<Double>? { sortedSummary.medianInterval }
    var p95Interval: ClosedRange<Double>? { sortedSummary.p95Interval }

    /// Everything that needs the lookups in order, from a single sort.
    private var sortedSummary: ResultStatsCache.SortedSummary {
        cache.value(\.sortedSummary) {
            let sorted = latencies.sorted()
            return ResultStatsCache.SortedSummary(
                stats: LatencyStats(sorted: sorted),
                medianInterval: Statistics.quantileInterval(sorted, q: 0.5, z: Statistics.overlapZ),
                p95Interval: Statistics.quantileInterval(sorted, q: 0.95, z: Statistics.overlapZ)
            )
        }
    }

    func value(for metric: RankingMetric) -> Double {
        switch metric {
        case .score: return score
        case .average: return stats.mean
        case .median: return stats.median
        case .p95: return stats.p95
        case .minimum: return stats.minimum
        // Without the check there's nothing to add, so these rank by the score, as the results page says.
        case .lookupAndConnection:
            guard isConnectionChecked else { return score }
            return connectionTime.map { score + DestinationReport.tripsPerNewWebsite * $0 } ?? .infinity
        case .serverDistance:
            guard isConnectionChecked else { return score }
            return connectionTime ?? .infinity
        }
    }

    var color: Color { Color(hex: colorHex) }
    var avatarName: String { provider.isEmpty ? name : provider }
    var shortAddress: String { proto == .doh ? (URL(string: address)?.host ?? address) : address }
    var chartLabel: String { "\(name) · \(shortAddress)" }

    var failureSummary: String {
        if let lastError { return lastError }
        if timeouts > 0 { return "No answer (timed out)" }
        return "No answers"
    }
}

/// A result's statistics, computed on first use: a page reads them many times per render, and each one sorts or
/// sums every lookup. Copies of a `ServerResult` share one cache only while their lookups are the same, because
/// `record(_:)` gives the result a fresh cache whenever they change.
private final class ResultStatsCache: @unchecked Sendable {
    struct SortedSummary {
        let stats: LatencyStats
        let medianInterval: ClosedRange<Double>?
        let p95Interval: ClosedRange<Double>?
    }

    private let lock = NSLock()
    var sortedSummary: SortedSummary?

    func value<Value>(_ slot: ReferenceWritableKeyPath<ResultStatsCache, Value?>, _ make: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let value = self[keyPath: slot] { return value }
        let value = make()
        self[keyPath: slot] = value
        return value
    }
}

/// A run's charged results and rankings by metric, computed on first use. `BenchmarkRun` replaces it whenever its
/// results change, so copies of a run share one only while their results are the same.
private final class RunCache: @unchecked Sendable {
    private let lock = NSLock()
    private var charged: [ServerResult]?
    private var destinations: DestinationReport?
    var ranked: [RankingMetric: [ServerResult]] = [:]
    var ties: [RankingMetric: [ServerResult]] = [:]

    func charged(_ make: () -> [ServerResult]) -> [ServerResult] {
        lock.lock()
        defer { lock.unlock() }
        if let charged { return charged }
        let value = make()
        charged = value
        return value
    }

    /// Computes outside the lock: the report reads the charged results, which use this cache too.
    func destinations(_ make: () -> DestinationReport) -> DestinationReport {
        lock.lock()
        let cached = destinations
        lock.unlock()
        if let cached { return cached }
        let value = make()
        lock.lock()
        destinations = value
        lock.unlock()
        return value
    }

    /// Computes outside the lock: finding ties ranks the run, which uses this cache too.
    func value(_ slot: ReferenceWritableKeyPath<RunCache, [RankingMetric: [ServerResult]]>, _ metric: RankingMetric,
               _ make: () -> [ServerResult]) -> [ServerResult] {
        lock.lock()
        let cached = self[keyPath: slot][metric]
        lock.unlock()
        if let cached { return cached }
        let value = make()
        lock.lock()
        self[keyPath: slot][metric] = value
        lock.unlock()
        return value
    }
}

struct BenchmarkRun: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var duration: TimeInterval = 0
    var status: RunStatus = .running
    var rounds: Int
    var mode: TestMode
    var recordType: DNSRecordType
    var timeoutMs: Int
    var domains: [String]
    /// What each server measured, as saved.
    private var recorded: [ServerResult] = [] {
        didSet { cache = RunCache() }
    }
    /// True when the network answered a DNS query sent to an address where no server exists.
    var interceptionDetected: Bool?
    /// Fingerprint and name of the network the test ran on (nil for tests saved before networks were tracked).
    var networkID: String?
    var networkName: String?
    /// What started the test when the user didn't: "scheduled" or "network-change" (see RunTrigger).
    var trigger: String?
    /// Set once the test's failed lookups have been tried again.
    var retest: RunRetest?
    /// How near the servers its answers pointed to were (see `DestinationChecker`).
    var destinationCheck: DestinationCheck? {
        didSet { cache = RunCache() }
    }
    /// Rankings and ties worked out from `results`, replaced whenever they change.
    private var cache = RunCache()

    /// Every stored property except `cache`, so saved files stay exactly as they were.
    private enum CodingKeys: String, CodingKey {
        case id, date, duration, status, rounds, mode, recordType, timeoutMs, domains, interceptionDetected,
             networkID, networkName, trigger, retest, destinationCheck
        case recorded = "results"
    }

    init(rounds: Int, mode: TestMode, recordType: DNSRecordType, timeoutMs: Int, domains: [String]) {
        self.rounds = rounds
        self.mode = mode
        self.recordType = recordType
        self.timeoutMs = timeoutMs
        self.domains = domains
    }

    /// Every server's results, each scored at the failure rate `FailureCharge` decides for it, with its connection time
    /// once the destinations are checked.
    var results: [ServerResult] {
        cache.charged {
            var results = FailureCharge.apply(to: recorded)
            if let destinationCheck {
                for index in results.indices {
                    results[index].isConnectionChecked = true
                    results[index].connectionTime = DestinationReport.averageConnectionTime(of: results[index], in: destinationCheck)
                }
            }
            return results
        }
    }

    mutating func add(_ result: ServerResult) {
        recorded.append(result)
    }

    mutating func record(_ sample: BenchmarkSample, at index: Int) {
        recorded[index].record(sample)
    }

    /// Starts a new retest, remembering the score it may improve on.
    mutating func beginRetest() {
        let best = winner(by: .score)
        retest = RunRetest(recovered: retest?.recovered ?? 0, bestScoreBefore: best?.score, bestServerBefore: best?.name)
    }

    mutating func recordRetest(_ sample: BenchmarkSample, at index: Int) {
        retest?.tried += 1
        switch recorded[index].applyRetest(sample) {
        case .answered:
            retest?.answered += 1
            retest?.recovered += 1
        case .leftOut:
            let leftOut = (retest?.leftOut ?? 0) + 1
            retest?.leftOut = leftOut
        case .failedAgain:
            break
        }
    }

    var totalLookups: Int { recorded.reduce(0) { $0 + $1.attempts } }
    /// Lookups that failed and haven't been answered by a retest.
    var failedLookups: Int { recorded.reduce(0) { $0 + $1.failures } }
    var leftOutLookups: Int { recorded.reduce(0) { $0 + $1.leftOutLookups } }
    var systemResult: ServerResult? { results.first(where: \.isSystem) }

    /// The destination check's findings, worked out once.
    var destinations: DestinationReport {
        cache.destinations { DestinationReport(run: self) }
    }

    /// Computed once per metric. Returning the same array each time also lets SwiftUI see that views built from it
    /// haven't changed.
    func ranked(by metric: RankingMetric) -> [ServerResult] {
        cache.value(\.ranked, metric) {
            let values = Dictionary(results.map { ($0.id, $0.value(for: metric)) }, uniquingKeysWith: { first, _ in first })
            return results.sorted { a, b in
                let va = values[a.id] ?? .infinity
                let vb = values[b.id] ?? .infinity
                if va == vb { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return va < vb
            }
        }
    }

    /// Servers this run can't tell apart from the winner for `metric` (see `findTies(by:)`), computed once per metric.
    func tiedWithWinner(by metric: RankingMetric) -> [ServerResult] {
        cache.value(\.ties, metric) { findTies(by: metric) }
    }

    func winner(by metric: RankingMetric) -> ServerResult? {
        ranked(by: metric).first { $0.successes > 0 }
    }

    var summaryLine: String {
        "\(rounds) round\(rounds == 1 ? "" : "s") · \(mode.title) · \(recordType.rawValue) · \(domains.count) websites · \(results.count) servers"
            + (retest == nil ? "" : " · failed lookups retested")
    }
}
