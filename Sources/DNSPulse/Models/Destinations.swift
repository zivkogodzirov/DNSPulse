import Foundation

// DNS also decides which of a website's servers you connect to: big websites run copies in many places, and the
// answer picks one. A DNS that answers quickly can still send you to a far server. The destination check connects to
// the server each DNS pointed to for each website and compares how near they are.

extension DNSRecordType {
    /// Answers to these lookups are addresses you could connect to.
    var carriesAddresses: Bool { self == .a || self == .aaaa }
}

/// Connection times to the servers a test's answers pointed to (see `DestinationChecker`).
struct DestinationCheck: Codable, Hashable {
    var date = Date()
    /// Best connection time in milliseconds, per address.
    var times: [String: Double] = [:]
    /// Addresses that never connected.
    var unreachable: [String] = []

    var serverCount: Int { times.count + unreachable.count }
}

/// What the destination check found, per server and website.
struct DestinationReport {
    struct Summary {
        /// Websites with a measured connection.
        let websites: Int
        /// Websites where this server's choice was clearly farther than the nearest any server found.
        let farther: Int
        /// Average milliseconds more than the nearest server, over `websites`.
        let averageExtra: Double
        /// Median connection time to the servers it chose.
        let medianTime: Double

        var nearest: Int { websites - farther }
        /// Farther on more than a couple of websites, and either on at least a fifth of them or by 10 ms or more per
        /// connection on average (a few far-away servers add up).
        var sendsFartherOften: Bool { farther >= 3 && (farther * 5 >= websites || averageExtra >= 10) }
    }

    /// The smallest average extra distance any server has: the yardstick for "farther than the others".
    var leastAverageExtra: Double { summaries.values.map(\.averageExtra).min() ?? 0 }

    /// Worth pointing out: farther often, and by `fartherByMs` or more per connection than the server with the
    /// nearest picks. Every server is farther on some websites, so on its own that says little.
    func sendsFartherThanOthers(_ id: UUID) -> Bool {
        guard let summary = summaries[id] else { return false }
        return summary.sendsFartherOften && summary.averageExtra - leastAverageExtra >= Self.fartherByMs
    }

    /// The server whose picks are nearest on average.
    func nearestOnAverage(among results: [ServerResult]) -> ServerResult? {
        results.filter { summaries[$0.id] != nil }.min { summaries[$0.id]!.averageExtra < summaries[$1.id]!.averageExtra }
    }

    /// A choice counts as farther only when it is both this many milliseconds and this much slower than the
    /// nearest, so the small jitter between two equally near servers doesn't count.
    static let fartherByMs = 5.0
    static let fartherByRatio = 1.3
    /// A new website costs one lookup, then about three trips to its server: connecting, securing the connection and
    /// asking for the page.
    static let tripsPerNewWebsite = 3.0

    let check: DestinationCheck?
    /// Connection time per server and website: the average over the addresses that server gave for it.
    private let times: [UUID: [String: Double]]
    /// Websites where none of a server's addresses connected.
    private let unreachable: [UUID: Set<String>]
    /// The nearest server any DNS found, per website.
    private let nearest: [String: Double]
    let summaries: [UUID: Summary]
    /// The test kept the addresses its answers gave, so it can be checked.
    let canCheck: Bool
    /// Different addresses to connect to.
    let addressCount: Int

    var isChecked: Bool { check != nil }

    init(run: BenchmarkRun) {
        check = run.destinationCheck
        let results = run.results
        let addresses = Set(results.flatMap { ($0.destinations ?? [:]).values.flatMap { $0 } })
        canCheck = !addresses.isEmpty
        addressCount = addresses.count

        var times: [UUID: [String: Double]] = [:]
        var unreachable: [UUID: Set<String>] = [:]
        var nearest: [String: Double] = [:]
        if let check {
            for result in results {
                let perSite = Self.siteTimes(of: result, in: check)
                if !perSite.isEmpty { times[result.id] = perSite }
                for (domain, time) in perSite { nearest[domain] = min(nearest[domain] ?? .infinity, time) }
                for (domain, given) in result.destinations ?? [:] where perSite[domain] == nil && given.contains(where: check.unreachable.contains) {
                    unreachable[result.id, default: []].insert(domain)
                }
            }
        }

        var summaries: [UUID: Summary] = [:]
        for (id, perSite) in times {
            var extras: [Double] = []
            var farther = 0
            for (domain, time) in perSite {
                guard let best = nearest[domain] else { continue }
                extras.append(time - best)
                if Self.isFarther(time, than: best) { farther += 1 }
            }
            let sorted = perSite.values.sorted()
            summaries[id] = Summary(websites: perSite.count, farther: farther,
                                    averageExtra: extras.isEmpty ? 0 : extras.reduce(0, +) / Double(extras.count),
                                    medianTime: LatencyStats.percentile(sorted, 0.5))
        }

        self.times = times
        self.unreachable = unreachable
        self.nearest = nearest
        self.summaries = summaries
    }

    /// Per website, the time to connect to the server `result` sent you to: the average over the addresses it gave
    /// that connected.
    static func siteTimes(of result: ServerResult, in check: DestinationCheck) -> [String: Double] {
        var times: [String: Double] = [:]
        for (domain, given) in result.destinations ?? [:] {
            let measured = given.compactMap { check.times[$0] }
            if !measured.isEmpty { times[domain] = measured.reduce(0, +) / Double(measured.count) }
        }
        return times
    }

    /// The average over every website of `siteTimes`, or nil when none connected.
    static func averageConnectionTime(of result: ServerResult, in check: DestinationCheck) -> Double? {
        let times = siteTimes(of: result, in: check)
        return times.isEmpty ? nil : times.values.reduce(0, +) / Double(times.count)
    }

    static func isFarther(_ time: Double, than nearest: Double) -> Bool {
        time - nearest >= fartherByMs && time >= nearest * fartherByRatio
    }

    /// Milliseconds to connect to the server `server` chose for `domain`; `.infinity` when it never connected, nil when
    /// there's nothing to show (no address kept, or not checked yet).
    func time(_ server: UUID, _ domain: String) -> Double? {
        if let time = times[server]?[domain] { return time }
        return unreachable[server]?.contains(domain) == true ? .infinity : nil
    }

    func nearestTime(_ domain: String) -> Double? { nearest[domain] }

    /// The server with the nearest choices: fewest farther websites, then the smallest average extra.
    func bestServer(among results: [ServerResult]) -> ServerResult? {
        results.filter { (summaries[$0.id]?.websites ?? 0) > 0 }.min { a, b in
            let x = summaries[a.id]!, y = summaries[b.id]!
            let shareA = Double(x.farther) / Double(x.websites), shareB = Double(y.farther) / Double(y.websites)
            return shareA != shareB ? shareA < shareB : x.averageExtra < y.averageExtra
        }
    }
}

extension BenchmarkRun {
    /// Every different address the test's answers gave.
    var destinationAddresses: [String] {
        Array(Set(results.flatMap { ($0.destinations ?? [:]).values.flatMap { $0 } })).sorted()
    }
}

// MARK: - Measuring

/// Times TCP handshakes. A handshake takes one round trip and asks nothing of the website, so it measures how far
/// away the server is and not how busy it is.
enum DestinationProbe {
    /// Milliseconds to connect to `address` on `port`, or nil if it doesn't connect within `timeout`. Blocks, so call it
    /// off the main thread.
    static func connectTime(to address: String, port: UInt16 = 443, timeout: TimeInterval) -> Double? {
        guard let resolved = SocketAddress.resolve(host: address, port: port) else { return nil }
        let fd = socket(resolved.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let start = DispatchTime.now().uptimeNanoseconds
        let connected = resolved.address.withUnsafeBytes { raw in
            connect(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, Int32(timeout * 1000)) == 1 else { return nil }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return nil }
        }
        return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
    }

    /// The best of `tries` handshakes, so a passing delay on one doesn't count.
    static func bestConnectTime(to address: String, tries: Int = 3, timeout: TimeInterval = 2) -> Double? {
        var best: Double?
        for _ in 0..<tries {
            guard let time = connectTime(to: address, timeout: timeout) else {
                // One that never connects won't on the next try either; don't wait twice more.
                if best == nil { return nil }
                continue
            }
            best = min(best ?? .infinity, time)
        }
        return best
    }
}

/// Runs destination checks and saves them into the tests they belong to. One instance, so every page sees the
/// same progress.
@MainActor
final class DestinationChecker: ObservableObject {
    static let shared = DestinationChecker()
    /// Servers connected to at once. Low enough not to crowd the connection being measured.
    static let parallelism = 8

    struct Progress: Equatable {
        var done = 0
        var total = 0

        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    /// Checks in progress, by test.
    @Published private(set) var progress: [UUID: Progress] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isChecking(_ run: BenchmarkRun) -> Bool { tasks[run.id] != nil }

    /// Connects to every address `run` kept and saves the times into the saved copy of the test.
    func check(_ run: BenchmarkRun, store: AppStore) {
        guard tasks[run.id] == nil else { return }
        let addresses = run.destinationAddresses
        guard !addresses.isEmpty else { return }
        let id = run.id
        progress[id] = Progress(total: addresses.count)
        tasks[id] = Task { [weak self, weak store] in
            var check = DestinationCheck()
            await withTaskGroup(of: (String, Double?).self) { group in
                var pending = addresses.makeIterator()
                for _ in 0..<Self.parallelism {
                    guard let address = pending.next() else { break }
                    group.addTask { (address, await Self.measure(address)) }
                }
                for await (address, time) in group {
                    if let time { check.times[address] = time } else { check.unreachable.append(address) }
                    self?.progress[id]?.done += 1
                    if Task.isCancelled {
                        group.cancelAll()
                        continue
                    }
                    if let address = pending.next() {
                        group.addTask { (address, await Self.measure(address)) }
                    }
                }
            }
            guard let self else { return }
            tasks[id] = nil
            progress[id] = nil
            guard !Task.isCancelled, var saved = store?.history.first(where: { $0.id == id }) else { return }
            check.date = Date()
            check.unreachable.sort()
            saved.destinationCheck = check
            store?.updateRun(saved)
        }
    }

    /// After a test someone started, when Settings asks for it and the test kept addresses.
    func checkAfterTest(_ run: BenchmarkRun, store: AppStore, isQuiet: Bool) {
        guard store.settings.checkDestinations, !isQuiet, run.status == .completed else { return }
        check(run, store: store)
    }

    func stop(_ run: BenchmarkRun) {
        tasks[run.id]?.cancel()
    }

    /// A DNS test is starting: its lookups would disturb the connection times, and the check would disturb its lookups.
    func stopAll() {
        tasks.values.forEach { $0.cancel() }
    }

    nonisolated private static func measure(_ address: String) async -> Double? {
        await Task.detached(priority: .userInitiated) { DestinationProbe.bestConnectTime(to: address) }.value
    }
}
