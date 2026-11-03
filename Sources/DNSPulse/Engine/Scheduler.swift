import AppKit
import Combine
import Foundation

enum CheckSchedule: String, Codable, CaseIterable, Identifiable {
    case off, hourly, everySixHours, daily, networkChange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .hourly: "Every hour"
        case .everySixHours: "Every 6 hours"
        case .daily: "Daily"
        case .networkChange: "When the network changes"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .hourly: 3600
        case .everySixHours: 6 * 3600
        case .daily: 24 * 3600
        case .off, .networkChange: nil
        }
    }
}

/// Why a test ran without the user starting it. Saved as `BenchmarkRun.trigger`.
enum RunTrigger: String {
    case scheduled
    case networkChange = "network-change"

    var title: String {
        switch self {
        case .scheduled: "Scheduled check"
        case .networkChange: "Check after the network changed"
        }
    }
}

extension BenchmarkRun {
    var runTrigger: RunTrigger? { trigger.flatMap(RunTrigger.init) }
}

/// Runs a light test on a schedule while DNS Pulse is open, saves it to History and raises alerts.
@MainActor
final class Scheduler: ObservableObject {
    struct Skip: Equatable {
        let date: Date
        let reason: String
    }

    /// Don't catch up on a missed check in the first minute after launch.
    nonisolated static let launchGrace: TimeInterval = 60
    /// Give a new network a moment to settle (DHCP, DNS settings) before testing it.
    static let networkSettleDelay: TimeInterval = 10
    /// How soon a skipped timed check is tried again.
    static let retryDelay: TimeInterval = 5 * 60

    @Published private(set) var nextCheck: Date?
    @Published private(set) var lastSkip: Skip?

    private weak var store: AppStore?
    private weak var engine: BenchmarkEngine?
    private weak var networks: NetworkStore?
    private let launchedAt = Date()
    /// When the schedule last started a check or was changed; the next check counts from here.
    private var lastAttempt: Date?
    /// Set when a due check was skipped, so it is tried again soon rather than a whole interval later.
    private var retryAt: Date?
    /// No timed checks while the Mac sleeps, nor for a moment after it wakes while its network comes back.
    private var pausedUntil: Date?
    private var timer: Timer?
    private var pendingNetworkCheck: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    var schedule: CheckSchedule { store?.settings.schedule ?? .off }

    /// While a schedule is on, closing the window keeps DNS Pulse running in the Dock.
    var keepsAppRunning: Bool { schedule != .off }

    func attach(store: AppStore, engine: BenchmarkEngine, networks: NetworkStore) {
        guard self.store == nil else { return }
        self.store = store
        self.engine = engine
        self.networks = networks

        store.$settings
            .map(\.schedule)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] schedule in
                guard let self else { return }
                lastAttempt = Date()
                retryAt = nil
                lastSkip = nil
                pendingNetworkCheck?.cancel()
                updateNextCheck(schedule: schedule)
            }
            .store(in: &subscriptions)
        networks.switched
            .sink { [weak self] profile in self?.networkSwitched(to: profile) }
            .store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.pausedUntil = .distantFuture }
            .store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.pausedUntil = Date().addingTimeInterval(Self.networkSettleDelay) }
            .store(in: &subscriptions)

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        if store.settings.notifyOnProblems { Notifier.configure() }
        updateNextCheck(schedule: store.settings.schedule)
    }

    /// When the next timed check is due: one interval after the last scheduled run (or the last time the
    /// schedule fired or changed), but never sooner than a minute after launch.
    nonisolated static func nextDue(schedule: CheckSchedule, lastScheduledRun: Date?, lastAttempt: Date?, launchedAt: Date) -> Date? {
        guard let interval = schedule.interval else { return nil }
        let base = [lastScheduledRun, lastAttempt].compactMap { $0 }.max() ?? launchedAt
        return max(base.addingTimeInterval(interval), launchedAt.addingTimeInterval(launchGrace))
    }

    /// Runs one light check now, unless a test is already running.
    func runCheck(_ trigger: RunTrigger) {
        guard let store, let engine, let networks else { return }
        defer { updateNextCheck(schedule: store.settings.schedule) }

        if engine.isRunning {
            skip(because: "a test was already running")
        } else if networks.current == nil {
            skip(because: "the Mac wasn't connected to a network")
        } else if store.enabledServers.isEmpty || store.enabledWebsites.isEmpty {
            skip(because: "no servers or websites are switched on")
        } else {
            lastSkip = nil
            retryAt = nil
            if trigger == .scheduled { lastAttempt = Date() }
            engine.start(store: store, overrides: .light, options: RunOptions(trigger: trigger, isQuiet: true)) { [weak self] run in
                self?.finished(run)
            }
        }
    }

    private func skip(because reason: String) {
        lastSkip = Skip(date: Date(), reason: reason)
        retryAt = Date().addingTimeInterval(Self.retryDelay)
    }

    private func tick() {
        guard let store else { return }
        updateNextCheck(schedule: store.settings.schedule)
        if let nextCheck, Date() >= nextCheck, Date() >= pausedUntil ?? .distantPast {
            runCheck(.scheduled)
        }
    }

    private func updateNextCheck(schedule: CheckSchedule) {
        let lastScheduled = store?.history.first { $0.runTrigger == .scheduled }?.date
        var due = Self.nextDue(schedule: schedule, lastScheduledRun: lastScheduled, lastAttempt: lastAttempt, launchedAt: launchedAt)
        if let scheduled = due, let retryAt { due = max(scheduled, retryAt) }
        if nextCheck != due { nextCheck = due }
    }

    private func networkSwitched(to profile: NetworkProfile) {
        guard schedule == .networkChange else { return }
        pendingNetworkCheck?.cancel()
        pendingNetworkCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.networkSettleDelay * 1_000_000_000))
            // A new network's ID can change while it settles (see NetworkStore.apply), so match it by profile.
            guard !Task.isCancelled, let self, schedule == .networkChange, let current = networks?.current,
                  networks?.profile(profile.id)?.id == current.id else { return }
            runCheck(.networkChange)
        }
    }

    private func finished(_ run: BenchmarkRun) {
        guard let store else { return }
        updateNextCheck(schedule: store.settings.schedule)
        // The saved copy carries the network's current ID, which may have changed while the check ran.
        let run = store.history.first { $0.id == run.id } ?? run
        guard store.settings.notifyOnProblems, run.status == .completed else { return }
        let problems = DNSProblem.find(in: run, history: store.history)
        guard let alert = DNSProblem.alert(for: problems, networkName: networks?.name(for: run) ?? run.networkName) else { return }
        Notifier.post(title: alert.title, body: alert.body, id: run.id.uuidString)
    }
}
