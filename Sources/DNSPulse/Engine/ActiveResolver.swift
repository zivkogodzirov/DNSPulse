import Foundation
import dnssd

/// A resolver the Mac's lookups really come from, as seen from the outside.
struct ActiveResolver: Identifiable, Hashable, Sendable {
    let address: String
    /// Who the address is registered to.
    let organisation: String?
    /// "Amsterdam, NL", or just the country when that's all that's known.
    let location: String?

    var id: String { address }

    /// The provider's everyday name when DNS Pulse knows it, otherwise who the address is registered to.
    var name: String {
        ResolverOperators.match(address: address) ?? organisation.flatMap(ResolverOperators.match(text:)) ?? organisation ?? address
    }

    /// Reads one line of dnscheck.tools' answer: `FROM: 192.0.2.10#62997 (UDP) - Some Company - Amsterdam, NL`.
    /// The organisation and location are each optional, and the organisation can contain " - " itself.
    init?(record: String) {
        guard record.hasPrefix("FROM: ") else { return nil }
        var parts = record.dropFirst("FROM: ".count).components(separatedBy: " - ")
        let source = parts.removeFirst().prefix { $0 != " " }
        guard let port = source.lastIndex(of: "#") else { return nil }
        address = source[..<port].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard SocketAddress.isIPAddress(address) else { return nil }
        location = parts.last.flatMap { Self.isPlace($0) ? parts.removeLast() : nil }
        organisation = parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    /// Places end in a two-letter country code: "NL", "Frankfurt am Main, Hesse, DE".
    private static func isPlace(_ text: String) -> Bool {
        let country = text.components(separatedBy: ", ").last ?? text
        return country.count == 2 && country.allSatisfy(\.isUppercase)
    }
}

/// Finds out which resolvers answer for this Mac, the way dnscheck.tools does in a browser. Each lookup is for a
/// made-up name under dnscheck.tools. Nothing can have it cached, so a resolver has to ask that site's own name
/// server, which replies with the address that asked it and who that address belongs to. It goes through the Mac's
/// own DNS rather than to a server of our choosing, so it covers whatever the Mac really uses: a router,
/// an interception by the ISP, an encrypted DNS profile or a VPN.
enum ActiveResolverCheck {
    /// Most-seen first. An ISP often has several, so one lookup could miss some. Empty if nothing could be found.
    static func run(lookups: Int = 8, timeout: TimeInterval = 4) async -> [ActiveResolver] {
        let seen = await withTaskGroup(of: ActiveResolver?.self) { group in
            for _ in 0..<lookups {
                group.addTask {
                    let name = "\(Int.random(in: 1...99_999_999)).test.dnscheck.tools"
                    return await SystemTXTLookup.perform(name, timeout: timeout).lazy.compactMap(ActiveResolver.init(record:)).first
                }
            }
            var counts: [ActiveResolver: Int] = [:]
            for await resolver in group {
                if let resolver { counts[resolver, default: 0] += 1 }
            }
            return counts
        }
        return seen.sorted { ($0.value, $1.key.address) > ($1.value, $0.key.address) }.map(\.key)
    }
}

/// One TXT lookup through the Mac's own DNS (mDNSResponder), which follows profiles and VPNs as every app does.
/// `res_query` and direct queries wouldn't: they only know the addresses in the network settings.
private final class SystemTXTLookup: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.dnspulse.systemlookup")
    private var service: DNSServiceRef?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<[String], Never>?
    private var texts: [String] = []

    /// The answer's records, or none if it failed or timed out.
    static func perform(_ name: String, timeout: TimeInterval) async -> [String] {
        let lookup = SystemTXTLookup()
        return await withCheckedContinuation { continuation in
            lookup.queue.async { lookup.start(name, timeout: timeout, continuation) }
        }
    }

    private func start(_ name: String, timeout: TimeInterval, _ continuation: CheckedContinuation<[String], Never>) {
        self.continuation = continuation
        // The timer's handler keeps this object alive until the lookup finishes.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { self.finish() }
        self.timer = timer
        timer.resume()

        let status = DNSServiceQueryRecord(&service, 0, 0, name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN), { _, flags, _, error, _, _, _, length, data, _, context in
            guard let context else { return }
            Unmanaged<SystemTXTLookup>.fromOpaque(context).takeUnretainedValue()
                .received(data, length: Int(length), flags: flags, error: error)
        }, Unmanaged.passUnretained(self).toOpaque())
        guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let service else { return finish() }
        DNSServiceSetDispatchQueue(service, queue)
    }

    private func received(_ data: UnsafeRawPointer?, length: Int, flags: DNSServiceFlags, error: DNSServiceErrorType) {
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let data else { return finish() }
        // A TXT record is a run of strings, each after a length byte.
        let bytes = UnsafeRawBufferPointer(start: data, count: length)
        var text = ""
        var index = 0
        while index < bytes.count {
            let end = min(index + 1 + Int(bytes[index]), bytes.count)
            text += String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
            index = end
        }
        texts.append(text)
        if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { finish() }
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        continuation?.resume(returning: texts)
        continuation = nil
    }
}

@MainActor
final class ActiveResolverMonitor: ObservableObject {
    enum State: Equatable {
        case checking
        case found([ActiveResolver])
        case unavailable
    }

    @Published private(set) var state = State.checking

    func refresh() async {
        state = .checking
        let resolvers = await ActiveResolverCheck.run()
        guard !Task.isCancelled else { return }
        state = resolvers.isEmpty ? .unavailable : .found(resolvers)
    }
}
