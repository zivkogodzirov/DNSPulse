import Foundation

/// How the score charges failed lookups.
///
/// Every network loses the odd lookup, and with losses that rare, how many a server lost is mostly luck: 0 of 1,000
/// against 5 of 1,000 is no real difference, yet counted as 2-second timeouts it outweighs the speed differences
/// between servers and decides the ranking. So the failures of the servers that lost a usual number of lookups are
/// pooled and charged to each of them at the same rate. Only a server that failed significantly more or less often
/// than the most reliable half of the servers (Fisher's exact test at 5%) is charged its own rate.
enum FailureCharge {
    static func apply(to results: [ServerResult]) -> [ServerResult] {
        let tested = results.indices.filter { results[$0].attempts > 0 }
        guard tested.count > 1 else { return results }
        let rates = tested.map { results[$0].failureRate }.sorted()
        let median = rates[rates.count / 2]
        let reliableHalf = tested.filter { results[$0].failureRate <= median }
        let usual = tested.filter { index in
            let others = reliableHalf.filter { $0 != index }
            guard !others.isEmpty else { return false }
            let p = Statistics.fisherExactPValue(
                results[index].failures, of: results[index].attempts,
                others.reduce(0) { $0 + results[$1].failures }, of: others.reduce(0) { $0 + results[$1].attempts }
            )
            return p >= 0.05
        }
        guard !usual.isEmpty else { return results }
        let rate = Double(usual.reduce(0) { $0 + results[$1].failures }) / Double(usual.reduce(0) { $0 + results[$1].attempts })
        var charged = results
        for index in usual { charged[index].chargedFailureRate = rate }
        return charged
    }
}
