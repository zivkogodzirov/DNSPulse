import AppKit
import Foundation
import UserNotifications

/// Something worth telling the user about after an automatic check.
enum DNSProblem: Equatable {
    /// The system DNS answered in a median `now` ms against a usual `usual` ms (the median of earlier checks).
    case slower(now: Double, usual: Double, address: String)
    case failures(failed: Int, total: Int, address: String)
    /// The system DNS couldn't be used at all.
    case unavailable(reason: String)
    case addressChanged(from: String, to: String)

    static let slowdownFactor = 1.5
    /// Differences smaller than this are noise, whatever the ratio (2 ms → 3 ms is not a problem).
    static let minimumSlowdownMs = 5.0
    static let failureThreshold = 0.05
    /// One lost lookup is ordinary packet loss, even in a short check.
    static let minimumFailures = 2
    static let baselineSize = 5
    /// How many earlier checks are needed before "slower than usual" can be judged.
    static let minimumBaseline = 3

    /// Checks an automatic run against the earlier automatic runs on the same network.
    /// `history` is every saved run (it may include `run` itself). Pure, so it can be tested with made-up runs.
    static func find(in run: BenchmarkRun, history: [BenchmarkRun]) -> [DNSProblem] {
        guard run.trigger != nil, let networkID = run.networkID, let system = run.systemResult else { return [] }
        let earlier = history
            .filter { $0.id != run.id && $0.trigger != nil && $0.networkID == networkID && $0.status == .completed && $0.date < run.date }
            .sorted { $0.date > $1.date }
            .compactMap(\.systemResult)
            .filter(\.wasSetUp)
        var problems: [DNSProblem] = []

        // Judged on answered lookups only (failures are reported on their own), against earlier checks of the
        // same DNS server.
        let now = system.stats.median
        let baseline = earlier
            .filter { $0.address.caseInsensitiveCompare(system.address) == .orderedSame }
            .prefix(baselineSize)
            .map(\.stats.median)
            .filter(\.isFinite)
            .sorted()
        if baseline.count >= minimumBaseline, now.isFinite {
            let usual = LatencyStats.percentile(baseline, 0.5)
            if now >= usual * slowdownFactor, now - usual >= minimumSlowdownMs {
                problems.append(.slower(now: now, usual: usual, address: system.address))
            }
        }

        if !system.wasSetUp {
            problems.append(.unavailable(reason: system.lastError ?? "Unknown problem"))
        } else if system.failures >= minimumFailures, Double(system.failures) / Double(system.attempts) >= failureThreshold {
            problems.append(.failures(failed: system.failures, total: system.attempts, address: system.address))
        }

        if system.wasSetUp, let previous = earlier.first,
           previous.address.caseInsensitiveCompare(system.address) != .orderedSame {
            problems.append(.addressChanged(from: previous.address, to: system.address))
        }
        return problems
    }

    /// One notification for everything found, or nil when there is nothing to report.
    static func alert(for problems: [DNSProblem], networkName: String?) -> (title: String, body: String)? {
        guard let first = problems.first else { return nil }
        let place = networkName ?? BenchmarkRun.unknownNetworkName
        if problems.count == 1 {
            return (first.title, first.detail(on: place))
        }
        return ("\(problems.count) DNS problems on \(place)", problems.map { $0.detail(on: place) }.joined(separator: " "))
    }

    var title: String {
        switch self {
        case .slower: "Your DNS is slower than usual"
        case .failures: "Your DNS is missing lookups"
        case .unavailable: "Your DNS couldn't be tested"
        case .addressChanged: "Your DNS server changed"
        }
    }

    func detail(on network: String) -> String {
        switch self {
        case let .slower(now, usual, address):
            return "Your system DNS (\(address)) typically took \(Format.ms(now)) to answer on \(network), \(String(format: "%.1f", now / usual))× its usual \(Format.ms(usual))."
        case let .failures(failed, total, address):
            return "Your system DNS (\(address)) failed \(failed) of \(total) lookup\(total == 1 ? "" : "s") (\(Format.percent(Double(failed) / Double(total)))) on \(network)."
        case let .unavailable(reason):
            return "DNS Pulse couldn't use your system DNS on \(network): \(reason)."
        case let .addressChanged(from, to):
            return "On \(network), your Mac now uses \(to) for DNS instead of \(from). If you didn't change this, check your router or VPN."
        }
    }
}

private extension ServerResult {
    /// False when the server couldn't be used at all, e.g. no system DNS was detected.
    var wasSetUp: Bool { !(attempts == 0 && lastError != nil) }
}

// MARK: - Notifications

@MainActor
enum Notifier {
    enum Permission {
        /// This build has no app bundle (e.g. `swift run`), so macOS won't deliver notifications.
        case unavailable
        case notDetermined, denied, allowed
    }

    private static let delegate = NotificationDelegate()

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Lets a click on an alert bring DNS Pulse forward. Doesn't ask for permission.
    static func configure() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func permission() async -> Permission {
        guard isAvailable else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .allowed
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    /// Asks macOS for permission: when the user turns alerts on or asks again, or when an alert is due and
    /// macOS hasn't asked yet.
    static func requestPermission() async -> Permission {
        guard isAvailable else { return .unavailable }
        configure()
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        return granted ? .allowed : await permission()
    }

    static func post(title: String, body: String, id: String) {
        guard isAvailable else { return }
        configure()
        Task {
            // Alerts may have been switched on where macOS couldn't ask (e.g. `swift run`), or the request was ignored.
            var permission = await permission()
            if permission == .notDetermined { permission = await requestPermission() }
            guard permission == .allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = "dns-problems"
            let request = UNNotificationRequest(identifier: "dns-problem-\(id)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { MainWindow.show() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
