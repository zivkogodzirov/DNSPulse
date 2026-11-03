import AppKit
import Foundation
import UniformTypeIdentifiers

/// Builds a configuration profile that turns on encrypted DNS (DNS-over-TLS or DNS-over-HTTPS) for the whole Mac.
/// The user opens and approves it in System Settings; DNS Pulse never installs profiles itself.
enum DNSProfile {
    static var contentType: UTType { UTType(filenameExtension: "mobileconfig") ?? .xml }

    /// Addresses that serve the TLS certificate of well-known DoT and DoH hosts. With these the Mac can reach the
    /// server without first looking up its name, which matters on networks that tamper with plain DNS.
    private static let knownAddresses: [String: [String]] = [
        "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
        "one.one.one.one": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
        "dns.google": ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"],
        "dns.quad9.net": ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"],
        "dns.adguard-dns.com": ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"],
        "dns.mullvad.net": ["194.242.2.2", "2a07:e340::2"],
    ]

    /// The server's addresses when they are known: an IP written as the host itself, or a well-known provider.
    static func serverAddresses(forHost host: String) -> [String] {
        let host = host.lowercased()
        if SocketAddress.isIPAddress(host) { return [host] }
        return knownAddresses[host] ?? []
    }

    /// The DNSSettings for an encrypted server: an https:// URL for DoH, or for DoT (RFC 7858) the host name its
    /// certificate is checked against. macOS profiles have no port setting, so DoT has to be on port 853.
    static func dnsSettings(proto: DNSProtocol, address: String, port: UInt16) -> [String: Any]? {
        let address = address.trimmingCharacters(in: .whitespaces)
        var settings: [String: Any]
        let host: String
        switch proto {
        case .udp:
            return nil
        case .dot:
            guard !address.isEmpty, port == DNSProtocol.dot.defaultPort else { return nil }
            host = address
            settings = ["DNSProtocol": "TLS", "ServerName": address]
        case .doh:
            guard let url = URL(string: address), url.scheme?.lowercased() == "https", let urlHost = url.host else { return nil }
            host = urlHost
            settings = ["DNSProtocol": "HTTPS", "ServerURL": url.absoluteString]
        }
        let addresses = serverAddresses(forHost: host)
        if !addresses.isEmpty { settings["ServerAddresses"] = addresses }
        return settings
    }

    /// An unsigned .mobileconfig with one com.apple.dnsSettings.managed payload.
    /// Identifiers and UUIDs are new every time, so each saved profile is its own install.
    static func make(name: String, proto: DNSProtocol, address: String, port: UInt16) -> Data? {
        guard let dnsSettings = dnsSettings(proto: proto, address: address, port: port) else { return nil }
        let over = proto == .dot ? "TLS" : "HTTPS"
        let profileUUID = UUID().uuidString
        let identifier = "app.dnspulse.encrypted-dns.\(profileUUID.lowercased())"
        let displayName = "DNS Pulse – \(name)"

        let dnsPayload: [String: Any] = [
            "DNSSettings": dnsSettings,
            "PayloadDescription": "Sends this Mac's DNS lookups to \(name) over \(over), encrypted.",
            "PayloadDisplayName": displayName,
            "PayloadIdentifier": "\(identifier).dns",
            "PayloadType": "com.apple.dnsSettings.managed",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
        ]
        let profile: [String: Any] = [
            "PayloadContent": [dnsPayload],
            "PayloadDescription": "Encrypted DNS (\(proto.title)) with \(name), created by DNS Pulse. Remove it in System Settings to go back to your normal DNS.",
            "PayloadDisplayName": displayName,
            "PayloadIdentifier": identifier,
            "PayloadOrganization": "DNS Pulse",
            "PayloadRemovalDisallowed": false,
            "PayloadScope": "System",
            "PayloadType": "Configuration",
            "PayloadUUID": profileUUID,
            "PayloadVersion": 1,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// Splits an address the way `DNSServer.displayAddress` writes it: "host", "host:port" or "[IPv6]:port".
    static func split(_ address: String, defaultPort: UInt16) -> (host: String, port: UInt16) {
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            let host = String(address[address.index(after: address.startIndex)..<close])
            let rest = address[address.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = UInt16(parts[1]) { return (String(parts[0]), port) }
        return (address, defaultPort) // a host name, or an IPv6 address on the default port
    }

    static func fileName(for name: String) -> String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return "DNS Pulse - \(safe).mobileconfig"
    }

    /// Asks where to save the profile for a DoT or DoH result. Returns the saved file, or nil if cancelled.
    @MainActor
    static func save(for result: ServerResult) throws -> URL? {
        let (address, port) = result.proto == .dot ? split(result.address, defaultPort: DNSProtocol.dot.defaultPort) : (result.address, 443)
        guard let data = make(name: result.name, proto: result.proto, address: address, port: port) else {
            let reason = result.proto == .dot && port != DNSProtocol.dot.defaultPort
                ? "macOS profiles only support DNS-over-TLS on port \(DNSProtocol.dot.defaultPort)."
                : "“\(result.address)” isn't a valid \(result.proto.title) address."
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = fileName(for: result.name)
        panel.canCreateDirectories = true
        panel.message = "Save the profile, then open it to approve it in System Settings."
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
