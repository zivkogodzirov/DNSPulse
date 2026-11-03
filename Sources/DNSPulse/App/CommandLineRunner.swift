import Foundation

/// Headless mode: `DNSPulse --cli [--rounds N] [--sites N] [--mode real|cached|uncached] [--all]`
/// Uses the same servers and websites you configured in the app.
enum CommandLineRunner {
    static let usage = """
    DNS Pulse command-line mode

      --cli               run a benchmark in the terminal
      --rounds N          rounds to run (default: your app setting)
      --sites N           only use the first N enabled websites
      --mode MODE         real | cached | uncached
      --all               include servers that are switched off in the app
      --help              show this help
    """

    static func run(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--help") {
            print(usage)
            return 0
        }

        var settings = AppStore.storedValue(AppSettings.self, file: AppStore.Files.settings) ?? AppSettings()
        if let rounds = intOption("--rounds", in: arguments) { settings.rounds = max(1, rounds) }
        if let mode = option("--mode", in: arguments) {
            switch mode.lowercased() {
            case "cached": settings.mode = .cached
            case "uncached": settings.mode = .uncached
            default: settings.mode = .realWorld
            }
        }

        let includeAll = arguments.contains("--all")
        let servers = (AppStore.storedValue([DNSServer].self, file: AppStore.Files.servers) ?? DefaultData.servers)
            .filter { includeAll || $0.isEnabled }
        var domains = (AppStore.storedValue([Website].self, file: AppStore.Files.websites) ?? DefaultData.websites)
            .filter(\.isEnabled).map(\.domain)
        if let limit = intOption("--sites", in: arguments) ?? (settings.websiteLimit > 0 ? settings.websiteLimit : nil) {
            domains = Array(domains.prefix(max(1, limit)))
        }
        guard !servers.isEmpty, !domains.isEmpty else {
            print("Nothing to test: no servers or websites are enabled.")
            return 1
        }

        let config = BenchmarkConfig(settings: settings)
        var results: [UUID: ServerResult] = [:]
        var targets: [ProbeTarget] = []
        for server in servers {
            switch DNSProber.prepare(server) {
            case .success(let target):
                targets.append(target)
                results[server.id] = ServerResult(server: server, address: server.isSystem ? target.resolvedAddress : server.displayAddress, timeoutMs: settings.timeoutMs)
            case .failure(let error):
                print("Skipping \(server.name): \(error.localizedDescription)")
            }
        }

        if await InterceptionCheck.run() {
            print("⚠️  DNS interception detected: a query sent to \(InterceptionCheck.probeAddress), where no server exists, was answered.")
            print("   Plain (UDP) results measure whatever is intercepting your DNS, not the servers listed. Encrypted (DoT and DoH) results are unaffected.\n")
        }

        let jobs = BenchmarkCore.makeJobs(domains: domains, config: config)
        print("Testing \(targets.count) servers × \(domains.count) websites × \(config.rounds) rounds (\(settings.mode.title), \(settings.recordType.rawValue))…")
        let started = Date()
        await BenchmarkCore.warmUp(targets: targets, domains: domains, config: config)

        var done = 0
        let pacer = LookupPacer(delayMs: config.delayMs)
        await withTaskGroup(of: [BenchmarkSample].self) { group in
            var pending = jobs.makeIterator()
            for _ in 0..<config.parallelism {
                guard let job = pending.next() else { break }
                group.addTask { await BenchmarkCore.perform(job, targets: targets, config: config, pacer: pacer) }
            }
            for await samples in group {
                for sample in samples { results[sample.serverID]?.record(sample) }
                done += 1
                if done % max(1, jobs.count / 10) == 0 {
                    print("  \(Int(Double(done) / Double(jobs.count) * 100))%")
                }
                if let job = pending.next() {
                    group.addTask { await BenchmarkCore.perform(job, targets: targets, config: config, pacer: pacer) }
                }
            }
        }

        let ranked = FailureCharge.apply(to: Array(results.values)).sorted { $0.score < $1.score }
        print("")
        print(pad("#", 3) + pad("Server", 28) + pad("Address", 20) + pad("Score", 11) + pad("Average", 11) + pad("Median", 11) + pad("Min", 11) + "Answered")
        for (index, result) in ranked.enumerated() {
            let stats = result.stats
            print(pad("\(index + 1)", 3) + pad(result.name, 28) + pad(result.shortAddress, 20)
                + pad(Format.ms(result.score), 11) + pad(Format.ms(stats.mean), 11) + pad(Format.ms(stats.median), 11)
                + pad(Format.ms(stats.minimum), 11) + Format.percent(result.successRate)
                + (result.successes == 0 ? "  (\(result.failureSummary))" : ""))
        }
        print("")
        print("Finished in \(Format.duration(Date().timeIntervalSince(started))).")
        return 0
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func intOption(_ name: String, in arguments: [String]) -> Int? {
        option(name, in: arguments).flatMap(Int.init)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count >= width ? String(text.prefix(width - 1)) : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
