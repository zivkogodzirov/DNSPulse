import Foundation

extension ServerResult {
    /// Plain DNS on the standard port at an IP address: something macOS network settings can use as it is.
    var canBeSystemDNS: Bool {
        proto == .udp && !isSystem && DNSSwitcher.isSettableAddress(address)
    }

    /// Servers from the same company share infrastructure, so a backup should come from a different one.
    var providerKey: String { avatarName.trimmingCharacters(in: .whitespaces).lowercased() }
}

extension BenchmarkRun {
    /// True for the server the Mac uses now: the Current System DNS row, or a plain DNS server at its address
    /// (after switching with DNS Pulse, both rows measure the same server).
    func isCurrentDNS(_ result: ServerResult) -> Bool {
        if result.isSystem { return true }
        guard result.proto == .udp, let system = systemResult else { return false }
        return system.address.caseInsensitiveCompare(result.address) == .orderedSame
    }

    /// The best answered server with the same protocol as `main` but from a different provider,
    /// so one company's outage doesn't take every lookup down. UDP backups must be settable in macOS.
    func backup(for main: ServerResult, metric: RankingMetric) -> ServerResult? {
        ranked(by: metric).first { candidate in
            candidate.id != main.id
                && candidate.successes > 0
                && candidate.proto == main.proto
                && !candidate.isSystem
                && candidate.providerKey != main.providerKey
                && (candidate.proto.isEncrypted || candidate.canBeSystemDNS)
        }
    }
}
