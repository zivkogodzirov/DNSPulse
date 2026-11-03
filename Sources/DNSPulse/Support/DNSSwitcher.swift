import AppKit
import Foundation
import SystemConfiguration

/// Points the Mac's active network connection at other DNS servers, and back again.
/// Changing DNS needs an administrator password; macOS asks for it itself.
enum DNSSwitcher {
    /// What `networksetup` takes for "no manual servers": DNS then comes from the router (DHCP).
    static let automatic = "empty"

    private static let networksetup = "/usr/sbin/networksetup"
    private static let previousKey = "DNSSwitcher.previousServers"
    private static let appliedKey = "DNSSwitcher.appliedServers"

    /// A network service ("Wi-Fi", "USB 10/100/1000 LAN" …) and the DNS servers set on it by hand.
    struct Service: Equatable, Sendable {
        let name: String
        /// Empty means automatic.
        let servers: [String]

        var isAutomatic: Bool { servers.isEmpty }
        /// False when a server can't be set again with `networksetup` (such as a scoped "fe80::1%en0"),
        /// so Restore couldn't put this setting back.
        var canBeRestored: Bool { servers.allSatisfy(DNSSwitcher.isSettableAddress) }
    }

    enum Outcome {
        case changed
        case cancelled
        case failed(String)
    }

    // MARK: Reading the current setup

    /// The primary network service and its manual DNS servers, or nil when there is no active connection.
    /// Runs `networksetup`, so call it off the main thread.
    static func primaryService() -> Service? {
        guard let name = primaryServiceName(), let servers = manualServers(for: name) else { return nil }
        return Service(name: name, servers: servers)
    }

    /// The service macOS routes through right now, e.g. "Wi-Fi".
    static func primaryServiceName() -> String? {
        var interface: String?
        if let store = SCDynamicStoreCreate(nil, "DNSPulse" as CFString, nil, nil),
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            if let id = global["PrimaryService"] as? String,
               let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(id)" as CFString) as? [String: Any],
               let name = setup["UserDefinedName"] as? String, !name.isEmpty {
                return name
            }
            interface = global["PrimaryInterface"] as? String
        }
        // Fall back to the service order, matched on the device that carries the default route.
        guard let device = interface ?? defaultRouteInterface(),
              let order = run(networksetup, ["-listnetworkserviceorder"]) else { return nil }
        return parseServiceOrder(order).first { $0.device == device && $0.isEnabled }?.name
    }

    /// The DNS servers set by hand on `service`; empty when it is automatic, nil when the service is unknown.
    static func manualServers(for service: String) -> [String]? {
        guard let output = run(networksetup, ["-getdnsservers", service]) else { return nil }
        if output.contains("There aren't any DNS Servers set") { return [] }
        let servers = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { SocketAddress.isIPAddress($0) }
        return servers.isEmpty ? nil : servers
    }

    /// The names of every network service, enabled or not; nil when they can't be read.
    static func serviceNames() -> Set<String>? {
        guard let order = run(networksetup, ["-listnetworkserviceorder"]) else { return nil }
        let names = Set(parseServiceOrder(order).map(\.name))
        return names.isEmpty ? nil : names
    }

    /// Parses `networksetup -listnetworkserviceorder`:
    /// "(1) Wi-Fi" followed by "(Hardware Port: Wi-Fi, Device: en0)"; disabled services start with "(*)".
    static func parseServiceOrder(_ text: String) -> [(name: String, device: String?, isEnabled: Bool)] {
        var services: [(name: String, device: String?, isEnabled: Bool)] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("(Hardware Port:"), let marker = line.range(of: "Device: ", options: .backwards), !services.isEmpty {
                let device = line[marker.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                services[services.count - 1].device = device.isEmpty ? nil : device
            } else if line.hasPrefix("("), let close = line.firstIndex(of: ")") {
                let tag = line[line.index(after: line.startIndex)..<close]
                let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard tag == "*" || Int(tag) != nil, !name.isEmpty else { continue }
                services.append((name, nil, tag != "*"))
            }
        }
        return services
    }

    private static func defaultRouteInterface() -> String? {
        guard let output = run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "interface" { return parts[1] }
        }
        return nil
    }

    // MARK: Building the command

    /// An address `networksetup` accepts: a plain IPv4 or IPv6 literal (no port, brackets or zone).
    static func isSettableAddress(_ text: String) -> Bool {
        !text.contains("%") && !text.contains("[") && SocketAddress.isIPAddress(text)
    }

    /// Wraps `text` in single quotes for /bin/sh; a quote inside becomes '\''.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The privileged shell command that sets `servers` (or `automatic`) on `service` and flushes the DNS cache.
    static func command(service: String, servers: [String]) -> String? {
        let hasControlCharacters = service.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard !service.isEmpty, !hasControlCharacters, !servers.isEmpty,
              servers == [automatic] || servers.allSatisfy(isSettableAddress) else { return nil }
        return "\(networksetup) -setdnsservers \(shellQuoted(service)) \(servers.joined(separator: " "))"
            + " && /usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
    }

    /// An AppleScript string literal: backslashes and double quotes escaped.
    static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func appleScriptSource(command: String, prompt: String) -> String {
        "do shell script \(appleScriptLiteral(command)) with prompt \(appleScriptLiteral(prompt)) with administrator privileges"
    }

    // MARK: Changing DNS

    /// Sets `servers` on `service`. macOS shows its own password prompt; this blocks until it is answered.
    /// NSAppleScript is only safe on the main thread.
    @MainActor
    static func apply(_ servers: [String], to service: String) -> Outcome {
        guard let command = command(service: service, servers: servers) else {
            return .failed("DNS Pulse can't build a safe command for “\(service)”.")
        }
        let prompt = "DNS Pulse wants to change the DNS servers for \(service)."
        guard let script = NSAppleScript(source: appleScriptSource(command: command, prompt: prompt)) else {
            return .failed("The system script could not be prepared.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .changed }
        // -128 is "User canceled", -60005/-60006 are authorisation failures.
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        if number == -128 { return .cancelled }
        let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error (\(number))"
        return .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What macOS reports after a change, plus one test lookup sent straight to the new main server.
    struct Check: Sendable {
        let systemServers: [String]
        let probed: String?
        let probe: ProbeResult?
    }

    /// Gives macOS a moment to apply the change, then re-reads the system DNS and probes the new server.
    static func check(after servers: [String]) async -> Check {
        let expected = servers == [automatic] ? nil : servers.first
        var system: [String] = []
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            system = SystemDNS.servers(maxAge: 0)
            if expected == nil || system.first == expected { break }
        }
        guard let address = expected ?? system.first,
              case .success(let target) = DNSProber.prepare(DNSServer(name: "Check", address: address)) else {
            return Check(systemServers: system, probed: nil, probe: nil)
        }
        let probe = await DNSProber.probe(target, name: BenchmarkCore.warmUpName, type: .a, timeout: 2)
        return Check(systemServers: system, probed: address, probe: probe)
    }

    // MARK: Previous settings

    /// The user's own setting for each service that DNS Pulse changed, which Restore puts back ("empty" = automatic).
    static var savedPrevious: [String: [String]] {
        UserDefaults.standard.dictionary(forKey: previousKey) as? [String: [String]] ?? [:]
    }

    /// What DNS Pulse last set on each service.
    private static var savedApplied: [String: [String]] {
        UserDefaults.standard.dictionary(forKey: appliedKey) as? [String: [String]] ?? [:]
    }

    /// Records that DNS Pulse changed `service` (as it was before) to `servers`, so Restore always goes back to
    /// the user's own choice: the setting from before DNS Pulse's first change, or a newer one when the user
    /// changed DNS by hand after DNS Pulse last did.
    static func rememberSwitch(of service: Service, to servers: [String]) {
        var saved = savedPrevious
        var applied = savedApplied
        let current = service.isAutomatic ? [automatic] : service.servers
        let changedByHand = applied[service.name].map { normalized($0) != normalized(current) } ?? false
        if saved[service.name] == nil || changedByHand {
            saved[service.name] = current
        }
        applied[service.name] = servers
        UserDefaults.standard.set(saved, forKey: previousKey)
        UserDefaults.standard.set(applied, forKey: appliedKey)
    }

    static func forgetPrevious(for service: String) {
        var saved = savedPrevious
        var applied = savedApplied
        saved[service] = nil
        applied[service] = nil
        UserDefaults.standard.set(saved, forKey: previousKey)
        UserDefaults.standard.set(applied, forKey: appliedKey)
    }

    /// One spelling per address ("2606:4700:4700:0:0:0:0:1111" becomes "2606:4700:4700::1111"), so lists compare reliably.
    private static func normalized(_ servers: [String]) -> [String] {
        servers.map { server in
            var address = in6_addr()
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_pton(AF_INET6, server, &address) == 1,
                  inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return server.lowercased() }
            return String(cString: text)
        }
    }

    // MARK: Helpers

    /// Runs a read-only tool and returns its standard output, or nil if it failed.
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
