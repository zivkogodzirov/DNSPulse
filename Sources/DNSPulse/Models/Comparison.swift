import Foundation

/// The servers the Compare tab shows for each test: up to five, one of them the baseline the others are measured
/// against. Until the user changes it, a suggested set is shown. Kept in memory, so every tab and page sees the same.
@MainActor
final class CompareSelection: ObservableObject {
    static let shared = CompareSelection()
    static let limit = 5

    private struct Choice: Equatable {
        var ids: [UUID]
        var baseline: UUID?
    }

    /// Only tests the user has changed the selection for, by test.
    @Published private var choices: [UUID: Choice] = [:]

    /// The servers being compared, best first by `metric`.
    func servers(in run: BenchmarkRun, metric: RankingMetric) -> [ServerResult] {
        let ids = choice(for: run, metric: metric).ids
        return run.ranked(by: metric).filter { ids.contains($0.id) }
    }

    /// The chosen baseline, otherwise your current DNS, otherwise the best of `servers`.
    func baseline(among servers: [ServerResult], in run: BenchmarkRun) -> ServerResult? {
        if let id = choices[run.id]?.baseline, let chosen = servers.first(where: { $0.id == id }) { return chosen }
        return servers.first(where: \.isSystem) ?? servers.first
    }

    func contains(_ result: ServerResult, in run: BenchmarkRun, metric: RankingMetric) -> Bool {
        choice(for: run, metric: metric).ids.contains(result.id)
    }

    func isFull(_ run: BenchmarkRun, metric: RankingMetric) -> Bool {
        choice(for: run, metric: metric).ids.count >= Self.limit
    }

    func isChanged(_ run: BenchmarkRun) -> Bool { choices[run.id] != nil }

    func add(_ result: ServerResult, in run: BenchmarkRun, metric: RankingMetric) {
        var choice = choice(for: run, metric: metric)
        guard !choice.ids.contains(result.id), choice.ids.count < Self.limit else { return }
        choice.ids.append(result.id)
        choices[run.id] = choice
    }

    func remove(_ result: ServerResult, in run: BenchmarkRun, metric: RankingMetric) {
        var choice = choice(for: run, metric: metric)
        choice.ids.removeAll { $0 == result.id }
        if choice.baseline == result.id { choice.baseline = nil }
        choices[run.id] = choice
    }

    func makeBaseline(_ id: UUID, in run: BenchmarkRun, metric: RankingMetric) {
        var choice = choice(for: run, metric: metric)
        guard choice.ids.contains(id) else { return }
        choice.baseline = id
        choices[run.id] = choice
    }

    /// Back to the suggested servers.
    func reset(_ run: BenchmarkRun) {
        choices[run.id] = nil
    }

    private func choice(for run: BenchmarkRun, metric: RankingMetric) -> Choice {
        choices[run.id] ?? Choice(ids: Self.suggested(for: run, metric: metric))
    }

    /// Your current DNS and the best other servers. Where plain DNS is intercepted, encrypted servers come first:
    /// the plain DNS rows there mostly measure the same interceptor, so they'd only repeat your current DNS.
    static func suggested(for run: BenchmarkRun, metric: RankingMetric) -> [UUID] {
        let answered = run.ranked(by: metric).filter { $0.successes > 0 }
        let current = answered.first(where: \.isSystem)
        let others = answered.filter { !run.isCurrentDNS($0) }
        let ordered = run.interceptionDetected == true
            ? others.filter(\.proto.isEncrypted) + others.filter { !$0.proto.isEncrypted }
            : others
        return ([current].compactMap { $0 } + ordered).prefix(limit).map(\.id)
    }
}

/// How one server did against the baseline in a test, and whether the difference is more than measurement noise.
struct ComparisonVerdict {
    enum Kind {
        /// Clearly faster or slower: the same tests that decide ties say it's a real difference, and it's at least 3%.
        case faster, slower
        /// Within measurement noise, or under 3% apart.
        case same
        /// There's no test for the fastest response, a single best answer.
        case untested
    }

    let kind: Kind
    /// How much less time than the baseline, as a share of the baseline's (negative when it takes more).
    let change: Double
    /// Milliseconds less than the baseline (negative when more).
    let difference: Double

    /// Below this, a difference is too small to matter, as on the winner banner.
    static let smallChange = 0.03

    init?(_ result: ServerResult, against baseline: ServerResult, metric: RankingMetric, in run: BenchmarkRun) {
        let value = result.value(for: metric)
        let base = baseline.value(for: metric)
        guard result.successes > 0, baseline.successes > 0, value.isFinite, base.isFinite, base > 0 else { return nil }
        difference = base - value
        change = difference / base
        if abs(change) < Self.smallChange {
            kind = .same
        } else if let tied = run.isTied(result, baseline, by: metric) {
            kind = tied ? .same : value < base ? .faster : .slower
        } else {
            kind = .untested
        }
    }

    var isSmall: Bool { abs(change) < Self.smallChange }

    /// "33% faster", "20% slower" or "About the same".
    var headline: String {
        if isSmall { return "About the same" }
        let percent = Int((abs(change) * 100).rounded())
        return change > 0 ? "\(percent)% faster" : "\(percent)% slower"
    }
}

extension BenchmarkRun {
    /// How many websites each of `servers` was fastest on, counting only websites at least two of them answered.
    func websiteWins(among servers: [ServerResult]) -> (wins: [UUID: Int], websites: Int) {
        var wins: [UUID: Int] = [:]
        var websites = 0
        for domain in domains {
            let times = servers.compactMap { server in server.domainStats[domain]?.mean.map { (server.id, $0) } }
            guard times.count >= 2, let fastest = times.min(by: { $0.1 < $1.1 }) else { continue }
            wins[fastest.0, default: 0] += 1
            websites += 1
        }
        return (wins, websites)
    }

    /// The websites `servers` differ most on: the biggest gap between the fastest and slowest average.
    func biggestDifferences(among servers: [ServerResult], count: Int) -> [String] {
        let gaps = domains.compactMap { domain -> (String, Double)? in
            let times = servers.compactMap { $0.domainStats[domain]?.mean }
            guard times.count >= 2, let low = times.min(), let high = times.max() else { return nil }
            return (domain, high - low)
        }
        return gaps.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
    }
}

/// How the compared servers did against each other across saved tests.
struct ComparisonHistory {
    struct Record {
        /// Tests with this server and at least one other compared server.
        var tests = 0
        /// Of those, the tests where it was the fastest of the compared servers.
        var fastest = 0
        /// Against the baseline, in tests with both.
        var faster = 0
        var same = 0
        var slower = 0

        var againstBaseline: Int { faster + same + slower }
    }

    /// By `ServerResult.matchKey`, which follows a server from test to test.
    private(set) var records: [String: Record] = [:]
    /// Tests with at least two of the compared servers.
    private(set) var tests = 0
    private(set) var modes: [TestMode] = []

    init(servers: [ServerResult], baseline: ServerResult?, runs: [BenchmarkRun], metric: RankingMetric) {
        let keys = servers.map(\.matchKey)
        for run in runs {
            var found: [String: ServerResult] = [:]
            for result in run.results where result.successes > 0 && keys.contains(result.matchKey) && found[result.matchKey] == nil {
                found[result.matchKey] = result
            }
            guard found.count >= 2 else { continue }
            tests += 1
            if !modes.contains(run.mode) { modes.append(run.mode) }
            let fastest = found.min { $0.value.value(for: metric) < $1.value.value(for: metric) }?.key
            let base = baseline.flatMap { found[$0.matchKey] }
            for (key, result) in found {
                var record = records[key, default: Record()]
                record.tests += 1
                if key == fastest { record.fastest += 1 }
                if let base, key != base.matchKey, let verdict = ComparisonVerdict(result, against: base, metric: metric, in: run) {
                    switch verdict.kind {
                    case .faster: record.faster += 1
                    case .slower: record.slower += 1
                    case .same: record.same += 1
                    case .untested: if verdict.difference > 0 { record.faster += 1 } else { record.slower += 1 }
                    }
                }
                records[key] = record
            }
        }
    }

    func record(for result: ServerResult) -> Record? { records[result.matchKey] }
}
