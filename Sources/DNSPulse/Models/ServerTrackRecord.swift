import Foundation

/// How one server performed across saved tests.
struct ServerTrackRecord: Equatable {
    var tests = 0
    var lookups = 0
    var answered = 0
    var latencySum: Double = 0
    var wins = 0
    var placementSum: Double = 0
    var placementCount = 0
    /// Tests where the server couldn't even be set up (e.g. a host name that doesn't resolve).
    var setupFailures = 0
    var lastProblem: String?
    var lastTested: Date?

    /// Mean response time of every answered lookup, across all tests.
    var average: Double { answered > 0 ? latencySum / Double(answered) : .infinity }
    var successRate: Double { lookups > 0 ? Double(answered) / Double(lookups) : 0 }
    var hasAnswers: Bool { answered > 0 }

    /// Where the server usually finishes: 0 = always first, 1 = always last.
    var placement: Double? { placementCount > 0 ? placementSum / Double(placementCount) : nil }

    /// Builds a record for every server in `servers` that appears in `runs`.
    /// Wins follow `metric`, the same ranking History and the winner banner use.
    static func build(for servers: [DNSServer], from runs: [BenchmarkRun], metric: RankingMetric) -> [UUID: ServerTrackRecord] {
        var currentKey: [UUID: String] = [:]
        var idByKey: [String: UUID] = [:]
        for server in servers {
            currentKey[server.id] = server.matchKey
            if idByKey[server.matchKey] == nil { idByKey[server.matchKey] = server.id }
        }

        var records: [UUID: ServerTrackRecord] = [:]
        for run in runs {
            let ranked = run.ranked(by: metric)
            let answeredCount = ranked.filter { $0.successes > 0 }.count
            let idsInRun = Set(run.results.map(\.id))
            var credited = Set<UUID>()

            for (position, result) in ranked.enumerated() {
                // Same id and still the same endpoint: it's this server. If the address was edited since, the old
                // results belong to a different resolver. Results saved under an id that no longer exists (e.g. after
                // restoring defaults) are matched by address instead, unless that server has its own result here.
                let id: UUID?
                if currentKey[result.id] == result.matchKey {
                    id = result.id
                } else if let fallback = idByKey[result.matchKey], !idsInRun.contains(fallback) {
                    id = fallback
                } else {
                    id = nil
                }
                guard let id, credited.insert(id).inserted else { continue }

                let setupFailed = result.attempts == 0 && result.lastError != nil
                guard result.attempts > 0 || setupFailed else { continue }

                var record = records[id, default: ServerTrackRecord()]
                record.tests += 1
                record.lookups += result.attempts
                record.answered += result.successes
                record.latencySum += result.latencies.reduce(0, +)
                if setupFailed {
                    record.setupFailures += 1
                }
                if result.successes == 0, let problem = result.lastError {
                    record.lastProblem = problem
                }
                if result.successes > 0, answeredCount > 1 {
                    if position == 0 { record.wins += 1 }
                    record.placementSum += Double(position) / Double(answeredCount - 1)
                    record.placementCount += 1
                }
                if record.lastTested.map({ run.date > $0 }) ?? true { record.lastTested = run.date }
                records[id] = record
            }
        }
        return records
    }
}

/// Which saved tests the server list summarises.
enum HistoryScope: String, CaseIterable, Identifiable {
    case all, lastFive, lastOne

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All saved tests"
        case .lastFive: "Last 5 tests"
        case .lastOne: "Last test only"
        }
    }

    /// Short label for servers that don't appear in the chosen tests.
    func notTestedLabel(on network: NetworkScope) -> String {
        switch self {
        case .all: network == .thisNetwork ? "Not tested on this network" : "Not tested yet"
        case .lastFive: "Not in last 5 tests"
        case .lastOne: "Not in last test"
        }
    }

    /// The chosen tests in words, e.g. "last 5 tests on this network".
    func summary(on network: NetworkScope) -> String {
        let tests = switch self {
        case .all: "all saved tests"
        case .lastFive: "last 5 tests"
        case .lastOne: network == .thisNetwork ? "last test" : "last test only"
        }
        return network == .thisNetwork ? "\(tests) on this network" : tests
    }

    /// History is stored newest first.
    func runs(from history: [BenchmarkRun]) -> [BenchmarkRun] {
        switch self {
        case .all: history
        case .lastFive: Array(history.prefix(5))
        case .lastOne: Array(history.prefix(1))
        }
    }
}

extension DNSServer {
    /// Links a server to results saved before its ID changed, e.g. after restoring the default list.
    var matchKey: String { isSystem ? "system" : "\(proto.rawValue)|\(displayAddress.lowercased())" }
}

extension ServerResult {
    var matchKey: String { isSystem ? "system" : "\(proto.rawValue)|\(address.lowercased())" }
}
