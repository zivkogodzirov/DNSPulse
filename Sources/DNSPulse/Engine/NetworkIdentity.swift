import CoreWLAN
import CryptoKit
import Foundation
import SystemConfiguration

enum NetworkKind: String, Codable, CaseIterable, Sendable {
    case wifi, ethernet, other

    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .other: "Other"
        }
    }

    var icon: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "cable.connector.horizontal"
        case .other: "network"
        }
    }
}

/// Recognises the network the Mac is on without Location permission: the primary interface type plus the
/// router's hardware address, or the router's IP address and subnet when the hardware address can't be read.
struct NetworkIdentity: Equatable, Sendable {
    let fingerprint: String
    let kind: NetworkKind
    /// BSD name of the primary interface, e.g. "en0".
    let interface: String
    let router: String?
    /// e.g. "192.168.1.0/24".
    let subnet: String?
    let routerMAC: String?
    /// Only known when macOS shares it without Location permission, which is rare.
    let ssid: String?

    var defaultName: String {
        if let ssid, !ssid.isEmpty { return ssid }
        let place = router ?? subnet ?? interface
        return kind == .other ? "Network (\(place))" : "\(kind.title) network (\(place))"
    }

    /// True when the fingerprint is based on the router's IP address rather than its hardware address.
    var isAddressBased: Bool { routerMAC == nil }

    /// Reads the current network. Can briefly run `arp`, so call it off the main thread.
    /// Returns nil when there is no primary IPv4 network (offline).
    static func current() -> NetworkIdentity? {
        guard let store = SCDynamicStoreCreate(nil, "DNSPulse.network" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = global["PrimaryInterface"] as? String else { return nil }

        var service: [String: Any] = [:]
        if let serviceID = global["PrimaryService"] as? String,
           let value = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/IPv4" as CFString) as? [String: Any] {
            service = value
        } else if let value = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/IPv4" as CFString) as? [String: Any] {
            service = value
        }

        let router = (global["Router"] as? String) ?? (service["Router"] as? String)
        let address = (service["Addresses"] as? [String])?.first
        let mask = (service["SubnetMasks"] as? [String])?.first
        let subnet = address.flatMap { address in mask.flatMap { subnetDescription(address: address, mask: $0) } }

        // configd records the router's hardware address once it has been resolved; `arp` is the unprivileged fallback.
        var mac = (service["ARPResolvedHardwareAddress"] as? String).flatMap(normalizedMAC)
        if mac == nil, let router, isIPv4(router) {
            mac = arpLookup(router)
        }

        let kind = interfaceKind(bsdName: interface)
        guard let fingerprint = fingerprint(kind: kind, routerMAC: mac, router: router, subnet: subnet) else { return nil }
        return NetworkIdentity(
            fingerprint: fingerprint,
            kind: kind,
            interface: interface,
            router: router,
            subnet: subnet,
            routerMAC: mac,
            ssid: kind == .wifi ? currentSSID(interface: interface) : nil
        )
    }

    /// hash(type + router MAC), or hash(type + router IP + subnet) when the MAC is unknown.
    static func fingerprint(kind: NetworkKind, routerMAC: String?, router: String?, subnet: String?) -> String? {
        let source: String
        if let routerMAC {
            source = "\(kind.rawValue)|mac|\(routerMAC)"
        } else if router != nil || subnet != nil {
            source = "\(kind.rawValue)|ip|\(router ?? "-")|\(subnet ?? "-")"
        } else {
            return nil
        }
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Helpers

    static func interfaceKind(bsdName: String) -> NetworkKind {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
              let match = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }),
              let type = SCNetworkInterfaceGetInterfaceType(match) else { return .other }
        if type == kSCNetworkInterfaceTypeIEEE80211 { return .wifi }
        if type == kSCNetworkInterfaceTypeEthernet { return .ethernet }
        return .other
    }

    /// "0:0:5e:0:53:1" → "00:00:5e:00:53:01". Rejects incomplete and broadcast entries.
    static func normalizedMAC(_ text: String) -> String? {
        let parts = text.lowercased().split(separator: ":")
        guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) && UInt8($0, radix: 16) != nil }) else { return nil }
        let mac = parts.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
        return mac == "ff:ff:ff:ff:ff:ff" || mac == "00:00:00:00:00:00" ? nil : mac
    }

    /// "192.168.1.59" + "255.255.255.0" → "192.168.1.0/24".
    static func subnetDescription(address: String, mask: String) -> String? {
        guard let ip = ipv4Value(address), let bits = ipv4Value(mask) else { return nil }
        let network = ip & bits
        let octets = [24, 16, 8, 0].map { String((network >> UInt32($0)) & 0xFF) }
        return "\(octets.joined(separator: "."))/\(bits.nonzeroBitCount)"
    }

    static func isIPv4(_ text: String) -> Bool { ipv4Value(text) != nil }

    private static func ipv4Value(_ text: String) -> UInt32? {
        var value = in_addr()
        guard inet_pton(AF_INET, text, &value) == 1 else { return nil }
        return UInt32(bigEndian: value.s_addr)
    }

    /// Parses "? (192.168.1.1) at 0:0:5e:0:53:1 on en0 ifscope [ethernet]".
    static func parseARP(_ output: String) -> String? {
        guard let range = output.range(of: " at ") else { return nil }
        let rest = output[range.upperBound...]
        return rest.split(separator: " ").first.flatMap { normalizedMAC(String($0)) }
    }

    private static func arpLookup(_ router: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", router]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8).flatMap(parseARP)
    }

    /// macOS only reveals the SSID to apps with Location permission, which DNS Pulse never asks for,
    /// so this is usually nil. It is used for the default name when it does happen to be available.
    private static func currentSSID(interface: String) -> String? {
        let ssid = CWWiFiClient.shared().interface(withName: interface)?.ssid()
        return ssid?.isEmpty == false ? ssid : nil
    }
}
