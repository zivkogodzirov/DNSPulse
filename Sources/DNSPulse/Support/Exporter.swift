import AppKit
import UniformTypeIdentifiers

/// Saving and loading results and lists.
@MainActor
enum Exporter {
    // MARK: Results

    static func resultsCSV(_ run: BenchmarkRun, metric: RankingMetric) -> String {
        var lines = ["Rank,Server,Provider,Address,Protocol,Score (ms),Average (ms),Median (ms),Min (ms),95th pct (ms),Max (ms),Jitter (ms),Answered (%),Lookups,Timeouts,Errors"]
        for (index, result) in run.ranked(by: metric).enumerated() {
            let s = result.stats
            lines.append([
                "\(index + 1)", result.name, result.provider, result.address, result.proto.shortTitle,
                number(result.score), number(s.mean), number(s.median), number(s.minimum), number(s.p95), number(s.maximum), number(s.stdDev),
                String(format: "%.2f", result.successRate * 100), "\(result.attempts)", "\(result.timeouts)", "\(result.serverErrors + result.networkErrors)",
            ].map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func websitesCSV(_ run: BenchmarkRun, metric: RankingMetric) -> String {
        let servers = run.ranked(by: metric)
        var lines = [(["Website"] + servers.map(\.name)).map(csvField).joined(separator: ",")]
        for domain in run.domains {
            let cells = servers.map { $0.domainStats[domain]?.mean.map(number) ?? "" }
            lines.append(([domain] + cells).map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func summary(_ run: BenchmarkRun, metric: RankingMetric) -> String {
        var lines = ["DNS Pulse — \(Format.date(run.date))", run.summaryLine, ""]
        for (index, result) in run.ranked(by: metric).enumerated() {
            let value = result.successes > 0 ? "\(Format.ms(result.value(for: metric))) \(metric.shortTitle), \(Format.percent(result.successRate)) answered" : result.failureSummary
            lines.append(String(format: "%2d. ", index + 1) + "\(result.name) (\(result.address)) — \(value)")
        }
        return lines.joined(separator: "\n")
    }

    static func json(_ run: BenchmarkRun) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(run)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func fileName(for run: BenchmarkRun, suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "DNS Pulse \(formatter.string(from: run.date))\(suffix)"
    }

    // MARK: Lists

    static func serversJSON(_ servers: [DNSServer]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(servers)) ?? Data()
    }

    /// Reads servers from an exported JSON file, or from plain text with one server per line:
    /// `1.1.1.1`, `Cloudflare, 1.1.1.1`, `My DoT, tls://dns.example.com` or `My DoH, https://example.com/dns-query`.
    static func parseServers(_ data: Data) -> [DNSServer] {
        if let decoded = try? JSONDecoder().decode([DNSServer].self, from: data) {
            return decoded.map { server in
                var copy = server
                copy.id = UUID()
                return copy
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var servers: [DNSServer] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: ",;\t="))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let address = parts.first(where: {
                SocketAddress.isIPAddress($0) || $0.lowercased().hasPrefix("https://") || $0.lowercased().hasPrefix("tls://")
            }) else { continue }
            let name = parts.first { $0 != address } ?? address
            if address.lowercased().hasPrefix("tls://") {
                // tls://host or tls://host:port, the usual way to write a DoT server.
                guard let url = URL(string: address), let host = url.host, !host.isEmpty else { continue }
                let port = url.port.flatMap { UInt16(exactly: $0) } ?? DNSProtocol.dot.defaultPort
                servers.append(DNSServer(name: name == address ? host : name, address: host, port: port, proto: .dot))
                continue
            }
            let isDoH = address.lowercased().hasPrefix("https://")
            servers.append(DNSServer(name: name, address: address, port: isDoH ? 443 : 53, proto: isDoH ? .doh : .udp))
        }
        return servers
    }

    // MARK: Panels

    static func save(_ text: String, name: String, type: UTType) {
        save(Data(text.utf8), name: name, type: type)
    }

    static func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func open(types: [UTType]) -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Helpers

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.2f", value) : ""
    }

    private static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

enum SystemLinks {
    @MainActor
    static func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
