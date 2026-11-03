import SwiftUI

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, green, teal

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        }
    }
}

enum TestMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case realWorld, cached, uncached

    var id: String { rawValue }

    var title: String {
        switch self {
        case .realWorld: "Real-world"
        case .cached: "Cached"
        case .uncached: "Uncached"
        }
    }

    var icon: String {
        switch self {
        case .realWorld: "globe"
        case .cached: "bolt.fill"
        case .uncached: "arrow.triangle.branch"
        }
    }

    var detail: String {
        switch self {
        case .realWorld:
            "Looks up each website the way your browser does. Popular sites are usually already cached by the resolver, rarer ones are not."
        case .cached:
            "Primes every resolver with every website first, then measures pure response time — mostly the network distance to the server."
        case .uncached:
            "Adds a random sub-domain to every lookup so the resolver must do a full recursive lookup. Shows how fast it is on a cache miss. If a server refuses a made-up name but answers the real website, that lookup is left out."
        }
    }
}

enum RankingMetric: String, Codable, CaseIterable, Identifiable {
    case score, average, median, p95, minimum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .score: "Overall score"
        case .average: "Average"
        case .median: "Median"
        case .p95: "95th percentile"
        case .minimum: "Fastest response"
        }
    }

    var shortTitle: String {
        switch self {
        case .score: "score"
        case .average: "average"
        case .median: "median"
        case .p95: "95th pct"
        case .minimum: "best"
        }
    }

    var help: String {
        switch self {
        case .score: "Average response time where failed lookups count as a full timeout. Rewards servers that are both fast and reliable. The odd lost lookup is shared equally by every server, so luck doesn't pick the winner; a server is charged for its own failures only when it fails clearly more (or less) often than the others."
        case .average: "Mean of all answered lookups."
        case .median: "The middle answer time — ignores occasional slow outliers."
        case .p95: "95% of lookups were at least this fast. Good for spotting servers with bad slow spikes."
        case .minimum: "The single quickest answer — roughly the network round-trip to the server."
        }
    }
}

struct AppSettings: Codable, Equatable {
    var theme: AppTheme = .system
    var accent: AccentChoice = .blue
    var rounds = 3
    /// 0 means every enabled website.
    var websiteLimit = 0
    var timeoutMs = 2000
    var parallelism = 4
    var delayMs = 0
    var recordType: DNSRecordType = .a
    var mode: TestMode = .realWorld
    var shuffle = true
    var rankingMetric: RankingMetric = .score
    var historyLimit = 30
    var schedule: CheckSchedule = .off
    var notifyOnProblems = false
    var playSound = true
    /// The `DefaultData.serverCatalog` the saved server list has caught up with.
    var serverCatalog = DefaultData.serverCatalog

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        theme = c.value(.theme, default: d.theme)
        accent = c.value(.accent, default: d.accent)
        rounds = c.value(.rounds, default: d.rounds)
        websiteLimit = c.value(.websiteLimit, default: d.websiteLimit)
        timeoutMs = c.value(.timeoutMs, default: d.timeoutMs)
        parallelism = c.value(.parallelism, default: d.parallelism)
        delayMs = c.value(.delayMs, default: d.delayMs)
        recordType = c.value(.recordType, default: d.recordType)
        mode = c.value(.mode, default: d.mode)
        shuffle = c.value(.shuffle, default: d.shuffle)
        rankingMetric = c.value(.rankingMetric, default: d.rankingMetric)
        historyLimit = c.value(.historyLimit, default: d.historyLimit)
        schedule = c.value(.schedule, default: d.schedule)
        notifyOnProblems = c.value(.notifyOnProblems, default: d.notifyOnProblems)
        playSound = c.value(.playSound, default: d.playSound)
        // Settings saved before this was recorded go with a server list from before any additions.
        serverCatalog = c.value(.serverCatalog, default: 0)
    }

    /// Restores everything on the Testing tab, keeping appearance choices.
    mutating func resetTesting() {
        let d = AppSettings()
        rounds = d.rounds
        websiteLimit = d.websiteLimit
        timeoutMs = d.timeoutMs
        parallelism = d.parallelism
        delayMs = d.delayMs
        recordType = d.recordType
        mode = d.mode
        shuffle = d.shuffle
        rankingMetric = d.rankingMetric
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to a default when it is missing or unreadable,
    /// so files saved by older versions keep loading.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
