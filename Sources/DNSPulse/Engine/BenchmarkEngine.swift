import AppKit
import Foundation

struct BenchmarkConfig: Sendable {
    var rounds: Int
    var timeout: TimeInterval
    var parallelism: Int
    var delayMs: Int
    var recordType: DNSRecordType
    var mode: TestMode
    var shuffle: Bool

    init(settings: AppSettings) {
        rounds = max(1, settings.rounds)
        timeout = Double(max(100, settings.timeoutMs)) / 1000
        parallelism = max(1, settings.parallelism)
        delayMs = max(0, settings.delayMs)
        recordType = settings.recordType
        mode = settings.mode
        shuffle = settings.shuffle
    }
}

struct BenchmarkJob: Sendable {
    let round: Int
    let domain: String
}

struct BenchmarkSample: Sendable {
    let serverID: UUID
    let round: Int
    let domain: String
    let result: ProbeResult
    /// Says nothing about the server, so it counts neither way (see `BenchmarkCore.isLeftOut`).
    var isLeftOut = false
    /// The addresses the answer gave, when the test keeps them for the destination check.
    var addresses: [String] = []
}

/// The parts of a benchmark that don't touch UI state, shared by the app and the command-line mode.
enum BenchmarkCore {
    /// Neutral name used to open sockets / TLS sessions before timing starts.
    static let warmUpName = "example.com"

    static func makeJobs(domains: [String], config: BenchmarkConfig) -> [BenchmarkJob] {
        (1...config.rounds).flatMap { round in
            (config.shuffle ? domains.shuffled() : domains).map { BenchmarkJob(round: round, domain: $0) }
        }
    }

    static func queryName(for domain: String, mode: TestMode) -> String {
        guard mode == .uncached else { return domain }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let label = String((0..<12).map { _ in alphabet.randomElement()! })
        return "\(label).\(domain)"
    }

    /// Looks up one website on every server at the same moment, so every server sees the same network conditions.
    /// Answers to real website names carry the addresses the destination check connects to. Uncached mode's made-up
    /// names don't point anywhere real.
    static func keepsAddresses(_ config: BenchmarkConfig) -> Bool {
        config.mode != .uncached && config.recordType.carriesAddresses
    }

    /// Waits for the job's turn when the test spaces websites out (see `LookupPacer`), then looks it up.
    static func perform(_ job: BenchmarkJob, targets: [ProbeTarget], config: BenchmarkConfig, pacer: LookupPacer?) async -> [BenchmarkSample] {
        await pacer?.waitTurn()
        guard !Task.isCancelled else { return [] }
        return await withTaskGroup(of: BenchmarkSample.self) { group in
            for target in targets {
                group.addTask {
                    let name = queryName(for: job.domain, mode: config.mode)
                    let (result, addresses) = keepsAddresses(config)
                        ? await DNSProber.probeKeepingAddresses(target, name: name, type: config.recordType, timeout: config.timeout)
                        : (await DNSProber.probe(target, name: name, type: config.recordType, timeout: config.timeout), [])
                    let leftOut = await isLeftOut(result, for: job.domain, on: target, config: config)
                    return BenchmarkSample(serverID: target.serverID, round: job.round, domain: job.domain, result: result,
                                           isLeftOut: leftOut, addresses: addresses)
                }
            }
            var collected: [BenchmarkSample] = []
            collected.reserveCapacity(targets.count)
            for await sample in group { collected.append(sample) }
            return collected
        }
    }

    /// Uncached mode's made-up names aren't real websites, and some servers refuse them under a few websites (Cloudflare
    /// under cloudflare.com, OpenDNS under discord.com) while answering the website itself. Nobody would ever meet that
    /// failure, so such a lookup is left out. Timeouts and lost connections always count: they aren't about the name.
    private static func isLeftOut(_ result: ProbeResult, for domain: String, on target: ProbeTarget, config: BenchmarkConfig) async -> Bool {
        guard config.mode == .uncached, result.status == .serverError else { return false }
        let real = await DNSProber.probe(target, name: domain, type: config.recordType, timeout: config.timeout)
        return real.status == .ok
    }

    /// Untimed queries before the real test, as many at once as the test sends, so every connection an encrypted
    /// server will need is already open. In cached mode every website is primed on every server.
    static func warmUp(targets: [ProbeTarget], domains: [String], config: BenchmarkConfig) async {
        let names = config.mode == .cached ? domains : Array(repeating: warmUpName, count: config.parallelism)
        // Priming websites in cached mode is spaced out like the test, so a dropped burst doesn't leave some unprimed.
        // The other warm-up has to go at once: it opens as many connections to each encrypted server as the test uses.
        let pacer = config.mode == .cached ? LookupPacer(delayMs: config.delayMs) : nil
        var index = 0
        while index < names.count, !Task.isCancelled {
            let chunk = names[index..<min(index + config.parallelism, names.count)]
            index += chunk.count
            await withTaskGroup(of: Void.self) { group in
                for name in chunk {
                    await pacer?.waitTurn()
                    for target in targets {
                        group.addTask {
                            _ = await DNSProber.probe(target, name: name, type: config.recordType, timeout: config.timeout)
                        }
                    }
                }
            }
        }
    }
}

/// Starts each website's lookups at least the test's pause apart, counted across every website in flight. Each website
/// goes to every server at once, so several websites starting together send a burst that some routers and ISPs drop
/// part of; on such networks the lost lookups show up as timeouts that a retest then answers.
actor LookupPacer {
    private let interval: UInt64
    private var nextStart: UInt64 = 0

    /// Nil when there's no pause, so nothing waits.
    init?(delayMs: Int) {
        guard delayMs > 0 else { return nil }
        interval = UInt64(delayMs) * 1_000_000
    }

    /// Returns at this caller's turn. The turn is taken before waiting, so callers keep their order and spacing.
    func waitTurn() async {
        let now = DispatchTime.now().uptimeNanoseconds
        let start = max(now, nextStart)
        nextStart = start + interval
        if start > now { try? await Task.sleep(nanoseconds: start - now) }
    }
}

@MainActor
final class BenchmarkEngine: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, warmingUp, running, stopping, finished, cancelled
    }

    enum InterceptionState: Equatable {
        case unknown, checking, clean, intercepted
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var interception: InterceptionState = .unknown
    @Published private(set) var run: BenchmarkRun?
    /// How far the test has got, published on its own (see `BenchmarkProgress`).
    let progress = BenchmarkProgress()
    /// The latest run is a retest of failed lookups (see `retestFailures`), not a new test.
    @Published private(set) var isRetest = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published var notice: String?

    /// The network new runs are tagged with (set by NetworkStore).
    var networkProvider: (() -> NetworkProfile?)?
    /// Options for the next `start`, set by `start(store:overrides:)`.
    var pendingOptions = RunOptions()
    private var activeOptions = RunOptions()

    /// Set while the page showing the live results is being scrolled. Those results then stay as they are, so
    /// scrolling stays smooth, and catch up as soon as it stops.
    var holdsResults = false {
        didSet { if oldValue, !holdsResults, isRunning, !isRetest { publishResults() } }
    }

    // Results accumulate here. Progress is published a few times a second; the results, which redraw the whole
    // results page, once a second.
    private var working: BenchmarkRun?
    private var resultIndex: [UUID: Int] = [:]
    private var completedCount = 0
    private var latestDomain = ""
    private var latestRound = 0
    private var runTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .preparing, .warmingUp, .running, .stopping: true
        default: false
        }
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    func start(servers: [DNSServer], domains: [String], settings: AppSettings, onFinish: @escaping (BenchmarkRun) -> Void) {
        guard !isRunning else { return }
        guard !servers.isEmpty else {
            notice = "Turn on at least one DNS server to start a test."
            return
        }
        guard !domains.isEmpty else {
            notice = "Turn on at least one website to start a test."
            return
        }

        isRetest = false
        DestinationChecker.shared.stopAll()
        prepareToRun()
        activeOptions = pendingOptions
        activeOptions.network = networkProvider?()

        let config = BenchmarkConfig(settings: settings)
        let timeoutMs = settings.timeoutMs
        let playSound = settings.playSound
        runTask = Task { [weak self] in
            await self?.execute(servers: servers, domains: domains, config: config, timeoutMs: timeoutMs, playSound: playSound, onFinish: onFinish)
        }
    }

    /// Tries a test's failed lookups again with the test's own settings, in case they were a passing problem such as
    /// a Wi-Fi dropout. Answers replace the failures in that test, so its score and ranking update. The results
    /// on screen stay as they are until it finishes, so the page doesn't move under whoever pressed the button.
    func retestFailures(of run: BenchmarkRun, store: AppStore) {
        guard !isRunning else { return }
        let plan = RetestPlan(run: run, servers: store.servers)
        guard plan.lookups > 0 else { return }

        var settings = store.settings
        settings.timeoutMs = run.timeoutMs
        settings.recordType = run.recordType
        settings.mode = run.mode
        let config = BenchmarkConfig(settings: settings)
        let playSound = settings.playSound

        isRetest = true
        DestinationChecker.shared.stopAll()
        prepareToRun()
        activeOptions = RunOptions()
        runTask = Task { [weak self, weak store] in
            await self?.executeRetest(plan, of: run, config: config, playSound: playSound) { store?.updateRun($0) }
        }
    }

    func stop() {
        guard isRunning else { return }
        phase = .stopping
        runTask?.cancel()
    }

    /// Checks whether this network hijacks plain DNS. Runs on first launch and before every test.
    func checkInterception() {
        guard interception != .checking else { return }
        interception = .checking
        Task {
            interception = await InterceptionCheck.run() ? .intercepted : .clean
        }
    }

    /// Clears the finished state so the dashboard shows the latest saved result again.
    func dismissResult() {
        guard !isRunning else { return }
        run = nil
        phase = .idle
    }

    private func prepareToRun() {
        notice = nil
        holdsResults = false
        phase = .preparing
        working = nil
        completedCount = 0
        latestDomain = ""
        latestRound = 0
        progress.reset()
        startedAt = Date()
        finishedAt = nil
    }

    private func execute(servers: [DNSServer], domains: [String], config: BenchmarkConfig, timeoutMs: Int, playSound: Bool, onFinish: @escaping (BenchmarkRun) -> Void) async {
        DoHClient.shared.reset()
        DoTClient.shared.reset()
        let usesUDP = servers.contains { $0.proto == .udp }
        async let intercepted = usesUDP ? InterceptionCheck.run() : false
        let prepared = await Task.detached(priority: .userInitiated) {
            servers.map { ($0, DNSProber.prepare($0)) }
        }.value

        var run = BenchmarkRun(rounds: config.rounds, mode: config.mode, recordType: config.recordType, timeoutMs: timeoutMs, domains: domains)
        activeOptions.tag(&run)
        if usesUDP {
            let detected = await intercepted
            run.interceptionDetected = detected
            interception = detected ? .intercepted : .clean
        }
        var targets: [ProbeTarget] = []
        for (server, outcome) in prepared {
            switch outcome {
            case .success(let target):
                let shown = server.isSystem ? target.resolvedAddress : server.displayAddress
                run.add(ServerResult(server: server, address: shown, timeoutMs: timeoutMs))
                targets.append(target)
            case .failure(let error):
                var result = ServerResult(server: server, address: server.isSystem ? "Not detected" : server.displayAddress, timeoutMs: timeoutMs)
                result.lastError = error.localizedDescription
                run.add(result)
            }
        }
        resultIndex = Dictionary(run.results.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

        let jobs = BenchmarkCore.makeJobs(domains: domains, config: config)
        progress.totalLookups = jobs.count * targets.count
        working = run
        publish()

        guard !targets.isEmpty else {
            notice = "None of the selected servers could be used. Check their addresses."
            finalize(cancelled: true, playSound: false, onFinish: onFinish)
            return
        }

        phase = .warmingUp
        await BenchmarkCore.warmUp(targets: targets, domains: domains, config: config)

        if !Task.isCancelled {
            await runLookups(jobs.map { ($0, targets) }, config: config)
        }
        finalize(cancelled: Task.isCancelled, playSound: playSound, onFinish: onFinish)
    }

    private func executeRetest(_ plan: RetestPlan, of original: BenchmarkRun, config: BenchmarkConfig, playSound: Bool, onFinish: @escaping (BenchmarkRun) -> Void) async {
        DoHClient.shared.reset()
        DoTClient.shared.reset()
        let servers = plan.servers
        let prepared = await Task.detached(priority: .userInitiated) {
            servers.compactMap { try? DNSProber.prepare($0).get() }
        }.value
        let targets = Dictionary(prepared.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
        let jobs = plan.jobs.compactMap { job -> (job: BenchmarkJob, targets: [ProbeTarget])? in
            let asked = job.serverIDs.compactMap { targets[$0] }
            return asked.isEmpty ? nil : (BenchmarkJob(round: job.pass, domain: job.domain), asked)
        }

        var run = original
        run.beginRetest()
        resultIndex = Dictionary(run.results.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        progress.totalLookups = jobs.reduce(0) { $0 + $1.targets.count }
        working = run
        publishProgress()

        phase = .warmingUp
        await BenchmarkCore.warmUp(targets: Array(targets.values), domains: Array(Set(jobs.map(\.job.domain))), config: config)
        if !Task.isCancelled {
            await runLookups(jobs, config: config)
        }
        // Stopped before anything was retried: the test stays as it was.
        if working?.retest?.tried == 0 { working = original }
        finalize(cancelled: Task.isCancelled, playSound: playSound, onFinish: onFinish)
    }

    /// Runs the jobs, `config.parallelism` at a time, recording what comes back.
    private func runLookups(_ jobs: [(job: BenchmarkJob, targets: [ProbeTarget])], config: BenchmarkConfig) async {
        phase = .running
        progress.runningSince = Date()
        startTicker()
        let pacer = LookupPacer(delayMs: config.delayMs)
        await withTaskGroup(of: [BenchmarkSample].self) { group in
            var pending = jobs.makeIterator()
            for _ in 0..<config.parallelism {
                guard let next = pending.next() else { break }
                group.addTask { await BenchmarkCore.perform(next.job, targets: next.targets, config: config, pacer: pacer) }
            }
            for await samples in group {
                record(samples)
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if let next = pending.next() {
                    group.addTask { await BenchmarkCore.perform(next.job, targets: next.targets, config: config, pacer: pacer) }
                }
            }
        }
    }

    private func record(_ samples: [BenchmarkSample]) {
        for sample in samples where sample.result.status != .cancelled {
            guard let index = resultIndex[sample.serverID] else { continue }
            if isRetest {
                working?.recordRetest(sample, at: index)
            } else {
                working?.record(sample, at: index)
            }
            completedCount += 1
        }
        if let latest = samples.first {
            latestDomain = latest.domain
            latestRound = latest.round
        }
    }

    private func finalize(cancelled: Bool, playSound: Bool, onFinish: (BenchmarkRun) -> Void) {
        stopTicker()
        guard var finished = working else {
            phase = .idle
            return
        }
        if !isRetest {
            finished.status = cancelled ? .cancelled : .completed
            finished.duration = Date().timeIntervalSince(startedAt ?? Date())
        }
        working = finished
        finishedAt = Date()
        publish()
        phase = cancelled ? .cancelled : .finished
        if finished.totalLookups > 0 { onFinish(finished) }
        if !cancelled, !activeOptions.isQuiet {
            if playSound { NSSound(named: "Glass")?.play() }
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    private func publish() {
        publishResults()
        publishProgress()
    }

    private func publishResults() {
        run = working
    }

    private func publishProgress() {
        progress.update(completed: completedCount, domain: latestDomain, round: latestRound)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                tick += 1
                guard let self else { return }
                self.publishProgress()
                if tick % 4 == 0, !self.holdsResults, !self.isRetest { self.publishResults() }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}

extension BenchmarkEngine {
    /// Starts a test with the enabled servers and websites, or only `onlyServers` when given.
    func start(store: AppStore, onlyServers: Set<UUID>? = nil) {
        let servers = onlyServers.map { ids in store.servers.filter { ids.contains($0.id) } } ?? store.enabledServers
        start(servers: servers, domains: store.testDomains, settings: store.settings) { [weak store] run in
            guard let store else { return }
            store.addRun(run)
            DestinationChecker.shared.checkAfterTest(run, store: store, isQuiet: false)
        }
    }
}

/// How far the running test has got. Published apart from the engine, which every page watches, so that only the few
/// views showing progress redraw a few times a second.
@MainActor
final class BenchmarkProgress: ObservableObject {
    @Published private(set) var completedLookups = 0
    @Published fileprivate(set) var totalLookups = 0
    @Published private(set) var currentDomain = ""
    @Published private(set) var currentRound = 0
    /// When the timed lookups started, after warming up.
    fileprivate(set) var runningSince: Date?

    var fraction: Double {
        totalLookups == 0 ? 0 : min(1, Double(completedLookups) / Double(totalLookups))
    }

    var estimatedRemaining: TimeInterval? {
        guard completedLookups > 0, let runningSince else { return nil }
        let spent = Date().timeIntervalSince(runningSince)
        return spent / Double(completedLookups) * Double(max(0, totalLookups - completedLookups))
    }

    fileprivate func update(completed: Int, domain: String, round: Int) {
        if completedLookups != completed { completedLookups = completed }
        if currentDomain != domain { currentDomain = domain }
        if currentRound != round { currentRound = round }
    }

    fileprivate func reset() {
        update(completed: 0, domain: "", round: 0)
        totalLookups = 0
        runningSince = nil
    }
}
