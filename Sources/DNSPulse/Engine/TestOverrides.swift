import Foundation

/// Extras for one run that aren't user settings.
struct RunOptions {
    /// Filled in by the engine when the run starts.
    var network: NetworkProfile?
    var trigger: RunTrigger?
    /// No sound or Dock bounce when it finishes, for checks that run in the background.
    var isQuiet = false

    func tag(_ run: inout BenchmarkRun) {
        run.networkID = network?.id
        run.networkName = network?.name
        run.trigger = trigger?.rawValue
    }
}

/// A one-off variation of the user's settings, so quick and scheduled tests never change what they chose.
struct TestOverrides {
    var rounds: Int?
    /// Uses the first N enabled websites, whatever the "websites per test" setting says.
    var websiteCount: Int?
    var mode: TestMode?
    var recordType: DNSRecordType?
    /// Exactly these websites, enabled or not, instead of `websiteCount` or the setting.
    var domains: [String]?
    var timeoutMs: Int?

    /// 1 round of the first 20 websites, real-world mode, A records.
    static let light = TestOverrides(rounds: 1, websiteCount: 20, mode: .realWorld, recordType: .a)

    func applied(to settings: AppSettings) -> AppSettings {
        var copy = settings
        if let rounds { copy.rounds = rounds }
        if let mode { copy.mode = mode }
        if let recordType { copy.recordType = recordType }
        if let timeoutMs { copy.timeoutMs = timeoutMs }
        return copy
    }

    var summary: String {
        var parts: [String] = []
        if let rounds { parts.append("\(rounds) round\(rounds == 1 ? "" : "s")") }
        if let websiteCount { parts.append("\(websiteCount) websites") }
        return parts.joined(separator: ", ")
    }
}

extension BenchmarkEngine {
    /// Starts a test with the enabled servers, or only `onlyServers` when given, using `overrides` instead of the
    /// saved settings where given.
    func start(store: AppStore, overrides: TestOverrides, onlyServers: Set<UUID>? = nil, options: RunOptions = RunOptions(), onSaved: ((BenchmarkRun) -> Void)? = nil) {
        let settings = overrides.applied(to: store.settings)
        let domains = overrides.domains
            ?? overrides.websiteCount.map { Array(store.enabledWebsites.map(\.domain).prefix(max(1, $0))) }
            ?? store.testDomains
        let servers = onlyServers.map { ids in store.servers.filter { ids.contains($0.id) } } ?? store.enabledServers
        pendingOptions = options
        defer { pendingOptions = RunOptions() }
        start(servers: servers, domains: domains, settings: settings) { [weak store] run in
            store?.addRun(run)
            onSaved?(run)
        }
    }
}
