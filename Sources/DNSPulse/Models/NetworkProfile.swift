import Foundation

/// A network DNS Pulse has seen, so tests can be compared per place (home, office…).
struct NetworkProfile: Identifiable, Codable, Hashable {
    /// The network fingerprint (see NetworkIdentity).
    var id: String
    /// Earlier fingerprints of this network, from before its router's hardware address was known.
    var aliases: [String] = []
    var name: String
    var kind: NetworkKind
    var firstSeen: Date
    var lastSeen: Date
    var router: String?
    var subnet: String?
    /// False while the name is still the automatic one, so it can follow the SSID if that becomes known.
    var hasCustomName = false
    /// The "New network detected" banner was closed for this network.
    var promptDismissed = false

    init(identity: NetworkIdentity, date: Date = Date()) {
        id = identity.fingerprint
        name = identity.defaultName
        kind = identity.kind
        firstSeen = date
        lastSeen = date
        router = identity.router
        subnet = identity.subnet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        aliases = c.value(.aliases, default: [])
        name = c.value(.name, default: "Unnamed network")
        kind = c.value(.kind, default: .other)
        firstSeen = c.value(.firstSeen, default: Date())
        lastSeen = c.value(.lastSeen, default: firstSeen)
        router = try? c.decodeIfPresent(String.self, forKey: .router)
        subnet = try? c.decodeIfPresent(String.self, forKey: .subnet)
        hasCustomName = c.value(.hasCustomName, default: false)
        promptDismissed = c.value(.promptDismissed, default: false)
    }

    var detail: String {
        [kind.title, router.map { "router \($0)" }, subnet].compactMap { $0 }.joined(separator: " · ")
    }

    static let nameSuggestions = ["Home", "Office", "Hotspot", "Café"]
}

extension BenchmarkRun {
    static let unknownNetworkName = "Unknown network"
}

/// Which saved tests a list uses, by network.
enum NetworkScope: String, CaseIterable, Identifiable {
    case thisNetwork, all

    var id: String { rawValue }
    var title: String { self == .thisNetwork ? "This network" : "All networks" }
}
