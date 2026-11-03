import SwiftUI

enum DNSProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case udp
    case dot
    case doh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .udp: "Standard DNS (UDP)"
        case .dot: "DNS-over-TLS"
        case .doh: "DNS-over-HTTPS"
        }
    }

    var shortTitle: String {
        switch self {
        case .udp: "UDP"
        case .dot: "DoT"
        case .doh: "DoH"
        }
    }

    var tint: Color {
        switch self {
        case .udp: .blue
        case .dot: .teal
        case .doh: .purple
        }
    }

    var defaultPort: UInt16 {
        switch self {
        case .udp: 53
        case .dot: 853
        case .doh: 443
        }
    }

    /// DoT and DoH are encrypted, so nothing on the way can intercept or change the lookups.
    var isEncrypted: Bool { self != .udp }
}

struct DNSServer: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var provider = ""
    /// An IP address or hostname for UDP and DoT (DoT checks the server's certificate against it), an https:// URL for DoH.
    var address: String
    var port: UInt16 = 53
    var proto: DNSProtocol = .udp
    var isEnabled = true
    /// Follows whatever DNS server macOS is currently using.
    var isSystem = false
    var colorHex: String?
    var notes = ""

    init(
        id: UUID = UUID(),
        name: String,
        provider: String = "",
        address: String,
        port: UInt16 = 53,
        proto: DNSProtocol = .udp,
        isEnabled: Bool = true,
        isSystem: Bool = false,
        colorHex: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.address = address
        self.port = port
        self.proto = proto
        self.isEnabled = isEnabled
        self.isSystem = isSystem
        self.colorHex = colorHex
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        name = c.value(.name, default: "Unnamed server")
        provider = c.value(.provider, default: "")
        address = c.value(.address, default: "")
        port = c.value(.port, default: 53)
        proto = c.value(.proto, default: .udp)
        isEnabled = c.value(.isEnabled, default: true)
        isSystem = c.value(.isSystem, default: false)
        colorHex = try? c.decodeIfPresent(String.self, forKey: .colorHex)
        notes = c.value(.notes, default: "")
    }

    var avatarName: String { provider.isEmpty ? name : provider }
    var resolvedColorHex: String { colorHex ?? Palette.automaticHex(for: avatarName) }
    var color: Color { Color(hex: resolvedColorHex) }

    var displayAddress: String {
        if isSystem {
            let detected = SystemDNS.servers()
            return detected.isEmpty ? "Not detected" : detected.joined(separator: ", ")
        }
        if proto != .doh, port != proto.defaultPort {
            return address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
        }
        return address
    }

    /// Used to skip duplicates when importing.
    var dedupeKey: String { "\(proto.rawValue)|\(address.lowercased())|\(port)|\(isSystem)" }
}
