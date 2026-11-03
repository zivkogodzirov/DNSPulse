import Foundation

/// The failed lookups of a test that can be tried again: each website only on the servers where it failed,
/// as many times as it failed there.
struct RetestPlan {
    struct Job: Sendable {
        let domain: String
        let serverIDs: [UUID]
        /// 1 for each website's first retry, 2 for those that failed twice, and so on.
        let pass: Int
    }

    /// The servers to ask, all still in the list at the same address as when they were tested.
    private(set) var servers: [DNSServer] = []
    private(set) var jobs: [Job] = []
    /// Failed lookups left out because their server has since been removed or changed.
    private(set) var skippedLookups = 0

    var lookups: Int { jobs.reduce(0) { $0 + $1.serverIDs.count } }

    init(run: BenchmarkRun, servers known: [DNSServer]) {
        let byID = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var failures: [String: [UUID: Int]] = [:]
        for result in run.results where result.failures > 0 {
            guard let server = byID[result.id], server.matchKey == result.matchKey else {
                skippedLookups += result.failures
                continue
            }
            servers.append(server)
            for (domain, stat) in result.domainStats where stat.failures > 0 {
                failures[domain, default: [:]][result.id] = stat.failures
            }
        }
        // A website's retries on different servers go out together, as a test's lookups do.
        let passes = failures.values.flatMap(\.values).max() ?? 0
        for pass in stride(from: 1, through: passes, by: 1) {
            for domain in run.domains {
                let ids = (failures[domain] ?? [:]).filter { $0.value >= pass }.keys
                if !ids.isEmpty { jobs.append(Job(domain: domain, serverIDs: Array(ids), pass: pass)) }
            }
        }
    }
}
