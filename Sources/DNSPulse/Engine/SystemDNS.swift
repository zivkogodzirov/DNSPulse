import Foundation
import SystemConfiguration

/// Reads the DNS servers macOS is currently using (usually your router or ISP).
enum SystemDNS {
    private static let lock = NSLock()
    private static var cached: (date: Date, servers: [String])?

    static func servers(maxAge: TimeInterval = 5) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.date) < maxAge {
            return cached.servers
        }
        let fresh = fetch()
        cached = (Date(), fresh)
        return fresh
    }

    private static func fetch() -> [String] {
        if let store = SCDynamicStoreCreate(nil, "DNSPulse" as CFString, nil, nil),
           let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
           let addresses = value["ServerAddresses"] as? [String],
           !addresses.isEmpty {
            return addresses
        }

        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "nameserver" else { return nil }
            return String(parts[1])
        }
    }
}
