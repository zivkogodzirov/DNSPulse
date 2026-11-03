import Darwin
import Foundation

/// A city worked out from an airport-style code in a server name, e.g. "SYD" or "res100.syd.rrdns.pch.net".
struct ResolverLocation: Hashable, Sendable {
    let code: String
    let city: String
    let country: String

    var title: String { "\(city), \(country)" }
}

/// One identity query and what came back.
struct IdentityProbe: Identifiable, Sendable {
    enum Kind: Sendable {
        case idServer, hostnameBind, googleEgress, akamaiEgress, reverse
    }

    let id = UUID()
    let kind: Kind
    let name: String
    let type: DNSLookupType
    let qclass: DNSClass
    let result: ProbeResult
    let records: [DNSRecord]

    var purpose: String {
        switch kind {
        case .idServer: "Server instance"
        case .hostnameBind: "Server host name"
        case .googleEgress: "Outgoing address seen by Google"
        case .akamaiEgress: "Outgoing address seen by Akamai"
        case .reverse: "Reverse DNS of the outgoing address"
        }
    }

    var queryText: String { "\(name) \(qclass.name) \(type.name)" }
    var answered: Bool { result.status.isSuccess }

    var statusText: String {
        switch result.status {
        case .ok: records.isEmpty ? "No records" : "\(records.count) record\(records.count == 1 ? "" : "s")"
        case .nxdomain: "No such name"
        case .timeout: "Timed out"
        case .serverError: result.detail.map { $0 == "REFUSED" ? "Refused" : $0 } ?? "Server error"
        case .networkError: result.detail ?? "Network error"
        case .cancelled: "Cancelled"
        }
    }

    /// TXT answers, with long values put back together.
    var texts: [String] { records.compactMap(\.joinedText) }

    var addresses: [String] {
        records.compactMap { if case .address(let text) = $0.value { text } else { nil } }
    }

    /// PTR targets only: a classless (RFC 2317) reverse zone answers with a CNAME before the PTR.
    var ptrNames: [String] {
        records.compactMap { record in
            guard record.type == DNSLookupType.ptr.rawValue, case .name(let text) = record.value else { return nil }
            return text
        }
    }
}

/// Who actually answered a server's lookups, and from where.
struct ResolverIdentity: Sendable {
    enum Verdict: Sendable, Equatable {
        /// The outgoing resolver belongs to the provider you asked.
        case confirmed
        /// No provider to compare with (system DNS or an unknown provider); this is who answered.
        case answered
        /// The outgoing resolver belongs to someone else.
        case forwarded
        /// It answered, but nothing says whose resolver it is.
        case unknown
        /// None of the identity queries were answered.
        case unreachable
    }

    var probes: [IdentityProbe] = []
    var setupError: String?
    /// From id.server or hostname.bind.
    var instance: String?
    var googleEgress: String?
    var akamaiEgress: String?
    var ecsSubnet: String?
    var reverseNames: [String: String] = [:]
    var operatorName: String?
    /// False when the operator is only the reverse-DNS domain of an unrecognised network, e.g. an ISP.
    var operatorIsKnown = false
    var operatorEvidence: String?
    var location: ResolverLocation?
    var locationEvidence: String?
    /// The provider of the server that was asked, when DNS Pulse recognises it.
    var expectedOperator: String?
    var isSystem = false
    /// DoT or DoH.
    var isEncrypted = false
    /// The app's interception check (plain DNS only).
    var interceptionDetected: Bool?
    var verdict: Verdict = .unreachable

    var egressIP: String? { googleEgress ?? akamaiEgress }
    var reverseName: String? { egressIP.flatMap { reverseNames[$0] } ?? reverseNames.values.sorted().first }

    var headline: String {
        switch verdict {
        case .confirmed, .answered:
            "Answered by \(operatorName ?? "an unknown resolver")" + (location.map { " in \($0.city)" } ?? "")
        case .forwarded:
            "Forwarded or intercepted"
        case .unknown:
            location.map { "Answered from \($0.city)" } ?? "Couldn’t tell who answered"
        case .unreachable:
            "No answer"
        }
    }

    var explanation: String {
        let actual = operatorName ?? egressIP.map { "another network (\($0))" } ?? "another network"
        switch verdict {
        case .confirmed:
            var text = "The resolver that looked up names on the internet belongs to \(actual), the provider you asked."
            if interceptionDetected == true {
                text += " Plain DNS is intercepted on this network, but these lookups still end up at \(actual)."
            }
            return text
        case .answered:
            return isSystem
                ? "Your Mac’s DNS server (usually your router) passes lookups on to this resolver, which looks them up on the internet."
                : "This is the resolver that looked up names on the internet for this server."
        case .forwarded:
            let expected = expectedOperator ?? "the provider"
            var text = "You asked \(expected), but the lookups reached the internet from \(actual)."
            if isEncrypted {
                text += " Encrypted DNS can’t be intercepted on the way, so \(expected) itself passes lookups on to this network."
            } else if interceptionDetected == true {
                text += " This matches the network check: plain DNS on this network is intercepted, so another resolver answers in its place."
            } else if interceptionDetected == false {
                text += " The network check found no interception, so \(expected) may pass lookups on to another network or use addresses registered to someone else."
            }
            return text
        case .unknown:
            if let name = operatorName, let expected = expectedOperator {
                return "The lookups reached the internet from \(name), a network DNS Pulse can’t link to \(expected). \(expected) may run resolvers there, so this doesn’t show that lookups were passed on."
            }
            return "The server answered, but its outgoing address has no recognisable reverse DNS name and isn’t in a network DNS Pulse knows."
        case .unreachable:
            return setupError ?? "None of the identity queries were answered. Check the server’s address and your connection, then try again."
        }
    }
}

// MARK: - Running the probes

enum ResolverDiagnostics {
    static func run(_ server: DNSServer) async -> ResolverIdentity {
        let prepared = await Task.detached { DNSProber.prepare(server) }.value
        let target: ProbeTarget
        switch prepared {
        case .success(let value):
            target = value
        case .failure(let error):
            var identity = ResolverIdentity(isSystem: server.isSystem, isEncrypted: server.proto.isEncrypted)
            identity.setupError = error.localizedDescription
            return identity
        }

        // The first encrypted query also sets up TLS, so allow it a little longer.
        let timeout: TimeInterval = server.proto.isEncrypted ? 4 : 2.5
        async let intercepted: Bool? = server.proto == .udp ? await InterceptionCheck.run() : nil
        async let idServer = probe(target, .idServer, "id.server", .txt, .chaos, timeout)
        async let hostname = probe(target, .hostnameBind, "hostname.bind", .txt, .chaos, timeout)
        async let google = probe(target, .googleEgress, "o-o.myaddr.l.google.com", .txt, .internet, timeout)
        async let akamai = probe(target, .akamaiEgress, "whoami.akamai.net", .a, .internet, timeout)
        var probes = await [idServer, hostname, google, akamai]

        let egress = ResolverIdentity.egressAddresses(in: probes)
        let reverse = await withTaskGroup(of: (Int, IdentityProbe)?.self) { group in
            for (index, address) in egress.enumerated() {
                guard let name = ResolverIdentity.reverseLookupName(for: address) else { continue }
                group.addTask { (index, await probe(target, .reverse, name, .ptr, .internet, timeout)) }
            }
            var collected: [(Int, IdentityProbe)] = []
            for await item in group { if let item { collected.append(item) } }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        probes += reverse
        return ResolverIdentity.interpret(server: server, probes: probes, intercepted: await intercepted)
    }

    private static func probe(_ target: ProbeTarget, _ kind: IdentityProbe.Kind, _ name: String, _ type: DNSLookupType, _ qclass: DNSClass, _ timeout: TimeInterval) async -> IdentityProbe {
        let (result, records) = await DNSProber.lookup(target, name: name, type: type, qclass: qclass, timeout: timeout)
        return IdentityProbe(kind: kind, name: name, type: type, qclass: qclass, result: result, records: records)
    }
}

// MARK: - Interpreting the answers

extension ResolverIdentity {
    /// Unique outgoing addresses, Google's view first.
    static func egressAddresses(in probes: [IdentityProbe]) -> [String] {
        var seen: [String] = []
        for probe in probes where probe.kind == .googleEgress || probe.kind == .akamaiEgress {
            let candidates = probe.kind == .googleEgress ? probe.texts : probe.addresses
            for text in candidates where SocketAddress.isIPAddress(text) && !seen.contains(text) {
                seen.append(text)
            }
        }
        return seen
    }

    static func interpret(server: DNSServer, probes: [IdentityProbe], intercepted: Bool?) -> ResolverIdentity {
        var identity = ResolverIdentity(probes: probes, isSystem: server.isSystem, isEncrypted: server.proto.isEncrypted, interceptionDetected: intercepted)

        let instances = [IdentityProbe.Kind.idServer, .hostnameBind].compactMap { kind in
            probes.first { $0.kind == kind }?.texts.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        identity.instance = instances.first

        for text in probes.first(where: { $0.kind == .googleEgress })?.texts ?? [] {
            if text.lowercased().hasPrefix("edns0-client-subnet") {
                identity.ecsSubnet = text.dropFirst("edns0-client-subnet".count).trimmingCharacters(in: .whitespaces)
            } else if SocketAddress.isIPAddress(text), identity.googleEgress == nil {
                identity.googleEgress = text
            }
        }
        identity.akamaiEgress = probes.first { $0.kind == .akamaiEgress }?.addresses.first

        for probe in probes where probe.kind == .reverse {
            guard let ip = Self.address(fromReverseName: probe.name), let name = probe.ptrNames.first else { continue }
            identity.reverseNames[ip] = name.hasSuffix(".") ? String(name.dropLast()) : name
        }

        // Who: the outgoing resolver's reverse DNS, then its address range, then the server's own name for itself.
        let egress = [identity.googleEgress, identity.akamaiEgress].compactMap { $0 }
        let reverse = egress.compactMap { identity.reverseNames[$0] }
        if let match = reverse.lazy.compactMap({ name in ResolverOperators.match(host: name).map { (name, $0) } }).first {
            identity.operatorName = match.1
            identity.operatorIsKnown = true
            identity.operatorEvidence = "Reverse DNS: \(match.0)"
        } else if let match = egress.lazy.compactMap({ ip in ResolverOperators.match(address: ip).map { (ip, $0) } }).first {
            identity.operatorName = match.1
            identity.operatorIsKnown = true
            identity.operatorEvidence = "\(match.0) is in \(match.1)’s network"
        } else if let first = reverse.first {
            identity.operatorName = DomainParser.registrableDomain(first)
            identity.operatorEvidence = "Reverse DNS: \(first)"
        } else if let match = instances.lazy.compactMap({ text in ResolverOperators.match(host: text).map { (text, $0) } }).first {
            identity.operatorName = match.1
            identity.operatorIsKnown = true
            identity.operatorEvidence = "Server name: \(match.0)"
        }

        // Where: airport codes in the server's own name, then in the outgoing resolver's reverse DNS.
        for text in instances {
            if let location = AirportCodes.find(in: text, skippingDomain: false) {
                identity.location = location
                identity.locationEvidence = "“\(location.code.uppercased())” in \(text)"
                break
            }
        }
        if identity.location == nil {
            for name in reverse {
                if let location = AirportCodes.find(in: name, skippingDomain: true) {
                    identity.location = location
                    identity.locationEvidence = "“\(location.code.uppercased())” in \(name)"
                    break
                }
            }
        }

        if !server.isSystem {
            identity.expectedOperator = ResolverOperators.match(text: [server.provider, server.name, Self.host(of: server)].joined(separator: " "))
        }

        // An unrecognised outgoing address is still telling when the provider's own addresses are all known,
        // or when the network check already caught plain DNS being intercepted.
        let unrecognisedIsTelling = identity.expectedOperator.map {
            ResolverOperators.publishesAllAddresses.contains($0) || intercepted == true
        } ?? false

        let anyAnswer = probes.contains { $0.answered }
        if !anyAnswer {
            identity.verdict = .unreachable
        } else if let actual = identity.operatorName {
            if let expected = identity.expectedOperator {
                if expected == actual {
                    identity.verdict = .confirmed
                } else if identity.operatorIsKnown || unrecognisedIsTelling {
                    identity.verdict = .forwarded
                } else {
                    // A reverse domain DNS Pulse doesn't recognise may still be where the provider hosts its resolvers.
                    identity.verdict = .unknown
                }
            } else {
                identity.verdict = .answered
            }
        } else if let expected = identity.expectedOperator, let ip = identity.egressIP, unrecognisedIsTelling {
            identity.verdict = .forwarded
            identity.operatorEvidence = ResolverOperators.publishesAllAddresses.contains(expected)
                ? "\(ip) isn’t one of \(expected)’s addresses" : "\(ip) has no reverse DNS name"
        } else {
            identity.verdict = .unknown
        }
        return identity
    }

    private static func host(of server: DNSServer) -> String {
        server.proto == .doh ? (URL(string: server.address)?.host ?? server.address) : server.address
    }

    /// "1.2.3.4" → "4.3.2.1.in-addr.arpa"; IPv6 addresses become 32 nibbles under ip6.arpa.
    static func reverseLookupName(for address: String) -> String? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa"
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let nibbles = withUnsafeBytes(of: &v6) { Array($0) }.flatMap { [$0 >> 4, $0 & 0x0F] }
            return nibbles.reversed().map { String($0, radix: 16) }.joined(separator: ".") + ".ip6.arpa"
        }
        return nil
    }

    /// The inverse of `reverseLookupName(for:)`.
    static func address(fromReverseName name: String) -> String? {
        let labels = name.lowercased().split(separator: ".").map(String.init)
        if labels.count == 6, labels.suffix(2) == ["in-addr", "arpa"] {
            let octets = labels.prefix(4).reversed()
            guard octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
            return octets.joined(separator: ".")
        }
        if labels.count == 34, labels.suffix(2) == ["ip6", "arpa"] {
            let nibbles = labels.prefix(32).reversed()
            guard nibbles.allSatisfy({ $0.count == 1 && UInt8($0, radix: 16) != nil }) else { return nil }
            let groups = stride(from: 0, to: 32, by: 4).map { nibbles.dropFirst($0).prefix(4).joined() }
            var raw = in6_addr()
            guard inet_pton(AF_INET6, groups.joined(separator: ":"), &raw) == 1 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
        return nil
    }
}

// MARK: - Operators

/// Recognises the big public resolver operators from names and addresses. Built in; nothing is looked up online.
enum ResolverOperators {
    /// Matched against host names (whole domains for dotted keys, otherwise anywhere in a label) and provider names.
    private static let names: [(key: String, name: String)] = [
        ("cloudflare", "Cloudflare"),
        ("1e100.net", "Google"), ("google", "Google"),
        ("quad9", "Quad9"), ("pch.net", "Quad9"), ("packetclearinghouse", "Quad9"),
        ("opendns", "Cisco OpenDNS"), ("umbrella", "Cisco OpenDNS"),
        ("adguard", "AdGuard"),
        ("nextdns", "NextDNS"),
        ("controld", "Control D"),
        ("akamai", "Akamai"),
        ("cleanbrowsing", "CleanBrowsing"),
        ("mullvad", "Mullvad"),
        ("dns.sb", "DNS.SB"),
        ("he.net", "Hurricane Electric"), ("hurricaneelectric", "Hurricane Electric"),
        ("ultradns", "UltraDNS"), ("neustar", "UltraDNS"), ("vercara", "UltraDNS"),
        ("comodo", "Comodo"),
        ("level3", "Lumen"), ("lumen", "Lumen"),
        ("gcore", "Gcore"),
        ("yandex", "Yandex"),
        ("dns4eu", "DNS4EU"),
        ("quad101", "Quad101"), ("twnic", "Quad101"),
        ("alternatedns", "Alternate DNS"),
    ]

    /// Operators whose resolvers only ever use the addresses below, so an outgoing address outside them
    /// means someone else did the lookup.
    static let publishesAllAddresses: Set<String> = ["Cloudflare", "Google"]

    /// Published address ranges of the largest anycast resolvers.
    private static let ranges: [(prefix: String, name: String)] = [
        ("1.1.1.0/24", "Cloudflare"), ("1.0.0.0/24", "Cloudflare"), ("173.245.48.0/20", "Cloudflare"), ("103.21.244.0/22", "Cloudflare"),
        ("103.22.200.0/22", "Cloudflare"), ("103.31.4.0/22", "Cloudflare"), ("141.101.64.0/18", "Cloudflare"), ("108.162.192.0/18", "Cloudflare"),
        ("190.93.240.0/20", "Cloudflare"), ("188.114.96.0/20", "Cloudflare"), ("197.234.240.0/22", "Cloudflare"), ("198.41.128.0/17", "Cloudflare"),
        ("162.158.0.0/15", "Cloudflare"), ("104.16.0.0/13", "Cloudflare"), ("104.24.0.0/14", "Cloudflare"), ("172.64.0.0/13", "Cloudflare"),
        ("131.0.72.0/22", "Cloudflare"), ("2400:cb00::/32", "Cloudflare"), ("2606:4700::/32", "Cloudflare"), ("2803:f800::/32", "Cloudflare"),
        ("2405:b500::/32", "Cloudflare"), ("2405:8100::/32", "Cloudflare"), ("2a06:98c0::/29", "Cloudflare"), ("2c0f:f248::/32", "Cloudflare"),

        ("8.8.8.0/24", "Google"), ("8.8.4.0/24", "Google"), ("172.217.0.0/16", "Google"), ("172.253.0.0/16", "Google"),
        ("173.194.0.0/16", "Google"), ("74.125.0.0/16", "Google"), ("108.177.0.0/17", "Google"), ("142.250.0.0/15", "Google"),
        ("209.85.128.0/17", "Google"), ("216.239.32.0/19", "Google"), ("64.233.160.0/19", "Google"), ("66.102.0.0/20", "Google"),
        ("66.249.64.0/19", "Google"), ("192.178.0.0/15", "Google"), ("74.114.28.0/22", "Google"), ("34.64.0.0/22", "Google"),
        ("34.101.0.0/22", "Google"), ("34.116.32.0/24", "Google"), ("34.153.64.0/22", "Google"),
        ("2001:4860::/32", "Google"), ("2404:6800::/32", "Google"), ("2607:f8b0::/32", "Google"), ("2800:3f0::/32", "Google"),
        ("2a00:1450::/32", "Google"), ("2c0f:fb50::/32", "Google"), ("2404:f340::/32", "Google"), ("2600:1900::/48", "Google"),
        ("2600:1900:4260::/54", "Google"),

        ("9.9.9.0/24", "Quad9"), ("149.112.112.0/24", "Quad9"), ("2620:fe::/48", "Quad9"),

        ("208.67.216.0/21", "Cisco OpenDNS"), ("146.112.0.0/16", "Cisco OpenDNS"), ("204.194.232.0/21", "Cisco OpenDNS"),
        ("2620:119::/32", "Cisco OpenDNS"),

        ("94.140.14.0/23", "AdGuard"), ("2a10:50c0::/32", "AdGuard"),
        ("76.76.2.0/24", "Control D"), ("76.76.10.0/24", "Control D"),
    ]

    /// Free text such as a provider or server name ("Control D", "OpenDNS Home", "dns.quad9.net").
    static func match(text: String) -> String? {
        let squashed = text.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        return names.first { squashed.contains($0.key) }?.name
    }

    /// A host name such as "res100.syd.rrdns.pch.net" or "dns.google".
    static func match(host: String) -> String? {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".").map { $0.replacingOccurrences(of: "-", with: "") }
        return names.first { entry in
            if entry.key.contains(".") {
                return host == entry.key || host.hasSuffix("." + entry.key)
            }
            return labels.contains { $0.contains(entry.key) }
        }?.name
    }

    static func match(address: String) -> String? {
        guard let bytes = IPAddressBytes(address) else { return nil }
        return ranges.first { entry in
            let parts = entry.prefix.split(separator: "/")
            guard parts.count == 2, let length = Int(parts[1]), let network = IPAddressBytes(String(parts[0])),
                  network.count == bytes.count else { return false }
            return bytes.matches(network, prefixLength: length)
        }?.name
    }
}

private struct IPAddressBytes {
    let raw: [UInt8]
    var count: Int { raw.count }

    init?(_ text: String) {
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            raw = withUnsafeBytes(of: &v4) { Array($0) }
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            raw = withUnsafeBytes(of: &v6) { Array($0) }
        } else {
            return nil
        }
    }

    func matches(_ network: IPAddressBytes, prefixLength: Int) -> Bool {
        var remaining = prefixLength.clamped(0, raw.count * 8)
        for index in raw.indices where remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if raw[index] & mask != network.raw[index] & mask { return false }
            remaining -= bits
        }
        return true
    }
}

// MARK: - Airport codes

/// About 160 common IATA codes, as used by anycast operators to name their sites.
/// Codes that are also everyday hostname words ("man", "nat", "doh", "can", "aus"…) are left out on purpose.
enum AirportCodes {
    static let table: [String: (String, String)] = [
        // Oceania
        "syd": ("Sydney", "Australia"), "mel": ("Melbourne", "Australia"), "bne": ("Brisbane", "Australia"),
        "per": ("Perth", "Australia"), "adl": ("Adelaide", "Australia"), "cbr": ("Canberra", "Australia"),
        "hba": ("Hobart", "Australia"), "drw": ("Darwin", "Australia"), "akl": ("Auckland", "New Zealand"),
        "wlg": ("Wellington", "New Zealand"), "chc": ("Christchurch", "New Zealand"),
        // Asia
        "sin": ("Singapore", "Singapore"), "hkg": ("Hong Kong", "China"), "tpe": ("Taipei", "Taiwan"),
        "nrt": ("Tokyo", "Japan"), "hnd": ("Tokyo", "Japan"), "tyo": ("Tokyo", "Japan"), "kix": ("Osaka", "Japan"),
        "icn": ("Seoul", "South Korea"), "pek": ("Beijing", "China"), "pvg": ("Shanghai", "China"), "szx": ("Shenzhen", "China"),
        "mnl": ("Manila", "Philippines"), "bkk": ("Bangkok", "Thailand"), "kul": ("Kuala Lumpur", "Malaysia"),
        "cgk": ("Jakarta", "Indonesia"), "sgn": ("Ho Chi Minh City", "Vietnam"), "han": ("Hanoi", "Vietnam"),
        "bom": ("Mumbai", "India"), "del": ("New Delhi", "India"), "maa": ("Chennai", "India"), "blr": ("Bengaluru", "India"),
        "hyd": ("Hyderabad", "India"), "ccu": ("Kolkata", "India"), "cmb": ("Colombo", "Sri Lanka"), "dac": ("Dhaka", "Bangladesh"),
        "khi": ("Karachi", "Pakistan"), "lhe": ("Lahore", "Pakistan"), "ktm": ("Kathmandu", "Nepal"),
        // Middle East
        "dxb": ("Dubai", "United Arab Emirates"), "bah": ("Manama", "Bahrain"), "ruh": ("Riyadh", "Saudi Arabia"),
        "jed": ("Jeddah", "Saudi Arabia"), "tlv": ("Tel Aviv", "Israel"), "amm": ("Amman", "Jordan"), "kwi": ("Kuwait City", "Kuwait"),
        "mct": ("Muscat", "Oman"), "ist": ("Istanbul", "Turkey"),
        // Africa
        "jnb": ("Johannesburg", "South Africa"), "cpt": ("Cape Town", "South Africa"), "dur": ("Durban", "South Africa"),
        "los": ("Lagos", "Nigeria"), "nbo": ("Nairobi", "Kenya"), "cai": ("Cairo", "Egypt"), "cmn": ("Casablanca", "Morocco"),
        // Europe
        "lhr": ("London", "United Kingdom"), "lon": ("London", "United Kingdom"), "edi": ("Edinburgh", "United Kingdom"),
        "dub": ("Dublin", "Ireland"), "cdg": ("Paris", "France"), "par": ("Paris", "France"), "mrs": ("Marseille", "France"),
        "fra": ("Frankfurt", "Germany"), "muc": ("Munich", "Germany"), "ber": ("Berlin", "Germany"), "txl": ("Berlin", "Germany"),
        "ham": ("Hamburg", "Germany"), "dus": ("Düsseldorf", "Germany"), "ams": ("Amsterdam", "Netherlands"),
        "bru": ("Brussels", "Belgium"), "lux": ("Luxembourg", "Luxembourg"), "zrh": ("Zurich", "Switzerland"),
        "gva": ("Geneva", "Switzerland"), "vie": ("Vienna", "Austria"), "prg": ("Prague", "Czechia"), "waw": ("Warsaw", "Poland"),
        "bud": ("Budapest", "Hungary"), "otp": ("Bucharest", "Romania"), "sof": ("Sofia", "Bulgaria"), "ath": ("Athens", "Greece"),
        "mad": ("Madrid", "Spain"), "bcn": ("Barcelona", "Spain"), "lis": ("Lisbon", "Portugal"), "mxp": ("Milan", "Italy"),
        "fco": ("Rome", "Italy"), "pmo": ("Palermo", "Italy"), "cph": ("Copenhagen", "Denmark"), "osl": ("Oslo", "Norway"),
        "arn": ("Stockholm", "Sweden"), "hel": ("Helsinki", "Finland"), "rix": ("Riga", "Latvia"), "tll": ("Tallinn", "Estonia"),
        "vno": ("Vilnius", "Lithuania"), "kbp": ("Kyiv", "Ukraine"), "svo": ("Moscow", "Russia"), "dme": ("Moscow", "Russia"),
        "beg": ("Belgrade", "Serbia"), "zag": ("Zagreb", "Croatia"),
        // North America
        "iad": ("Ashburn", "United States"), "dca": ("Washington", "United States"), "ewr": ("Newark", "United States"),
        "jfk": ("New York", "United States"), "lga": ("New York", "United States"), "nyc": ("New York", "United States"),
        "bos": ("Boston", "United States"), "phl": ("Philadelphia", "United States"), "bwi": ("Baltimore", "United States"),
        "atl": ("Atlanta", "United States"), "mia": ("Miami", "United States"), "mco": ("Orlando", "United States"),
        "tpa": ("Tampa", "United States"), "clt": ("Charlotte", "United States"), "rdu": ("Raleigh", "United States"),
        "bna": ("Nashville", "United States"), "ord": ("Chicago", "United States"), "mdw": ("Chicago", "United States"),
        "dtw": ("Detroit", "United States"), "cle": ("Cleveland", "United States"), "cmh": ("Columbus", "United States"),
        "pit": ("Pittsburgh", "United States"), "stl": ("St. Louis", "United States"), "mci": ("Kansas City", "United States"),
        "msp": ("Minneapolis", "United States"), "oma": ("Omaha", "United States"), "dfw": ("Dallas", "United States"),
        "iah": ("Houston", "United States"), "den": ("Denver", "United States"), "phx": ("Phoenix", "United States"),
        "slc": ("Salt Lake City", "United States"), "las": ("Las Vegas", "United States"), "lax": ("Los Angeles", "United States"),
        "sjc": ("San Jose", "United States"), "sfo": ("San Francisco", "United States"), "smf": ("Sacramento", "United States"),
        "pdx": ("Portland", "United States"), "sea": ("Seattle", "United States"), "anc": ("Anchorage", "United States"),
        "hnl": ("Honolulu", "United States"),
        "yyz": ("Toronto", "Canada"), "yul": ("Montréal", "Canada"), "yvr": ("Vancouver", "Canada"), "yyc": ("Calgary", "Canada"),
        "yeg": ("Edmonton", "Canada"), "yow": ("Ottawa", "Canada"), "ywg": ("Winnipeg", "Canada"), "yhz": ("Halifax", "Canada"),
        "mex": ("Mexico City", "Mexico"), "gdl": ("Guadalajara", "Mexico"), "mty": ("Monterrey", "Mexico"), "qro": ("Querétaro", "Mexico"),
        // Central and South America
        "gru": ("São Paulo", "Brazil"), "gig": ("Rio de Janeiro", "Brazil"), "poa": ("Porto Alegre", "Brazil"),
        "eze": ("Buenos Aires", "Argentina"), "scl": ("Santiago", "Chile"), "bog": ("Bogotá", "Colombia"), "lim": ("Lima", "Peru"),
        "uio": ("Quito", "Ecuador"), "pty": ("Panama City", "Panama"), "sjo": ("San José", "Costa Rica"), "mvd": ("Montevideo", "Uruguay"),
    ]

    /// Finds the first known code in `text`: a whole 3-letter token, or 3 letters followed by digits ("fra06").
    /// For reverse-DNS names, the registrable domain at the end ("example.net") is skipped.
    static func find(in text: String, skippingDomain: Bool) -> ResolverLocation? {
        var host = text.lowercased()
        if skippingDomain {
            let domain = DomainParser.registrableDomain(host)
            if host.hasSuffix(domain) { host = String(host.dropLast(domain.count)) }
        }
        let tokens = host.split { !$0.isLetter && !$0.isNumber }
        for token in tokens {
            let letters = token.prefix { $0.isLetter }
            guard letters.count == 3, token.dropFirst(3).allSatisfy(\.isNumber) else { continue }
            let code = String(letters)
            if let (city, country) = table[code] {
                return ResolverLocation(code: code, city: city, country: country)
            }
        }
        return nil
    }
}
