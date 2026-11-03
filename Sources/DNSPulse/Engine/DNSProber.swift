import Darwin
import Foundation

enum ProbeStatus: String, Codable, Sendable {
    case ok
    case nxdomain
    case timeout
    case serverError
    case networkError
    case cancelled

    /// The resolver answered (an NXDOMAIN is still a valid, timed answer).
    var isSuccess: Bool { self == .ok || self == .nxdomain }

    init(rcode: UInt8) {
        switch rcode {
        case 0: self = .ok
        case 3: self = .nxdomain
        default: self = .serverError
        }
    }
}

struct ProbeResult: Sendable {
    var status: ProbeStatus
    var latencyMs: Double
    var detail: String?

    static func failure(_ status: ProbeStatus, _ detail: String? = nil) -> ProbeResult {
        ProbeResult(status: status, latencyMs: 0, detail: detail)
    }

    static func answered(rcode: UInt8, latencyMs: Double) -> ProbeResult {
        let status = ProbeStatus(rcode: rcode)
        return ProbeResult(status: status, latencyMs: latencyMs, detail: status == .serverError ? DNSPacket.rcodeName(rcode) : nil)
    }
}

/// A server that has been resolved into something we can send packets to.
struct ProbeTarget: Sendable {
    enum Endpoint: Sendable {
        case udp(address: Data, family: Int32)
        /// A host name or IP address; the server's certificate must match it.
        case dot(host: String, port: UInt16)
        case doh(URL)
    }

    let serverID: UUID
    let endpoint: Endpoint
    /// The address actually queried (the system DNS entry is resolved when a run starts).
    let resolvedAddress: String
}

enum ProbeSetupError: LocalizedError {
    case noSystemDNS
    case invalidAddress(String)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .noSystemDNS: "No system DNS server detected"
        case .invalidAddress(let address): "Can't use the address “\(address)”"
        case .invalidURL(let url): "Invalid DNS-over-HTTPS URL “\(url)”"
        }
    }
}

enum DNSProber {
    static func prepare(_ server: DNSServer) -> Result<ProbeTarget, ProbeSetupError> {
        switch server.proto {
        case .udp:
            var host = server.address.trimmingCharacters(in: .whitespaces)
            if server.isSystem {
                guard let first = SystemDNS.servers(maxAge: 0).first else { return .failure(.noSystemDNS) }
                host = first
            }
            guard let resolved = SocketAddress.resolve(host: host, port: server.port) else {
                return .failure(.invalidAddress(host))
            }
            return .success(ProbeTarget(
                serverID: server.id,
                endpoint: .udp(address: resolved.address, family: resolved.family),
                resolvedAddress: host
            ))
        case .dot:
            var host = server.address.trimmingCharacters(in: .whitespaces)
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            // Resolving now catches typos before a test starts; the connection itself looks the name up again.
            guard SocketAddress.resolve(host: host, port: server.port) != nil else {
                return .failure(.invalidAddress(host))
            }
            return .success(ProbeTarget(serverID: server.id, endpoint: .dot(host: host, port: server.port), resolvedAddress: host))
        case .doh:
            let text = server.address.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else {
                return .failure(.invalidURL(text))
            }
            return .success(ProbeTarget(serverID: server.id, endpoint: .doh(url), resolvedAddress: text))
        }
    }

    static func probe(_ target: ProbeTarget, name: String, type: DNSRecordType, timeout: TimeInterval,
                      dot: DoTClient = .shared, doh: DoHClient = .shared) async -> ProbeResult {
        switch target.endpoint {
        case let .udp(address, family):
            let id = UInt16.random(in: 1...UInt16.max)
            guard let packet = DNSPacket.makeQuery(id: id, name: name, type: type) else {
                return .failure(.networkError, "Invalid domain name")
            }
            return await UDPExchange.perform(address: address, family: family, packet: packet, expectedID: id, timeout: timeout)
        case let .dot(host, port):
            // The connection gives each query its own ID, so lookups can share it.
            guard let packet = DNSPacket.makeQuery(id: 0, name: name, type: type) else {
                return .failure(.networkError, "Invalid domain name")
            }
            return await dot.perform(host: host, port: port, packet: packet, timeout: timeout)
        case let .doh(url):
            // RFC 8484 recommends ID 0 for DoH so responses are cache friendly.
            guard let packet = DNSPacket.makeQuery(id: 0, name: name, type: type) else {
                return .failure(.networkError, "Invalid domain name")
            }
            return await doh.perform(url: url, packet: packet, timeout: timeout)
        }
    }

    /// Like `probe`, but also returns the addresses in the answer (A and AAAA records), for the destination check.
    /// The reply is copied only after the clock has stopped, so the time is the same as `probe`'s.
    static func probeKeepingAddresses(_ target: ProbeTarget, name: String, type: DNSRecordType, timeout: TimeInterval,
                                      dot: DoTClient = .shared, doh: DoHClient = .shared) async -> (result: ProbeResult, addresses: [String]) {
        let result: ProbeResult
        let answers: [DNSRecord]
        switch target.endpoint {
        case let .udp(address, family):
            let id = UInt16.random(in: 1...UInt16.max)
            guard let packet = DNSPacket.makeQuery(id: id, name: name, type: type) else {
                return (.failure(.networkError, "Invalid domain name"), [])
            }
            let (answered, response) = await UDPExchange.performKeepingResponse(address: address, family: family, packet: packet, expectedID: id, timeout: timeout)
            result = answered
            answers = response.flatMap { DNSPacket.parseResponse($0)?.answers } ?? []
        case let .dot(host, port):
            guard let packet = DNSPacket.makeQuery(id: 0, name: name, type: type) else {
                return (.failure(.networkError, "Invalid domain name"), [])
            }
            let (answered, response) = await dot.performKeepingResponse(host: host, port: port, packet: packet, timeout: timeout)
            result = answered
            answers = response.flatMap { DNSPacket.parseResponse($0)?.answers } ?? []
        case let .doh(url):
            guard let packet = DNSPacket.makeQuery(id: 0, name: name, type: type) else {
                return (.failure(.networkError, "Invalid domain name"), [])
            }
            let (answered, response) = await doh.performKeepingResponse(url: url, packet: packet, timeout: timeout)
            result = answered
            answers = response.flatMap { DNSPacket.parseResponse($0)?.answers } ?? []
        }
        let addresses = answers.compactMap { record -> String? in
            guard record.type == DNSRecordType.a.code || record.type == DNSRecordType.aaaa.code,
                  case .address(let text) = record.value else { return nil }
            return text
        }
        return (result, addresses)
    }

    /// Like `probe`, but keeps the reply and decodes its answers. Used by diagnostics, which want every record;
    /// the benchmark uses `probe`, or `probeKeepingAddresses` when it needs the addresses.
    static func lookup(_ target: ProbeTarget, name: String, type: DNSLookupType, qclass: DNSClass = .internet, timeout: TimeInterval,
                       dot: DoTClient = .diagnostics, doh: DoHClient = .diagnostics) async -> (result: ProbeResult, records: [DNSRecord]) {
        switch target.endpoint {
        case let .udp(address, family):
            let id = UInt16.random(in: 1...UInt16.max)
            guard let packet = DNSPacket.makeQuery(id: id, name: name, typeCode: type.rawValue, qclass: qclass) else {
                return (.failure(.networkError, "Invalid domain name"), [])
            }
            let (result, response) = await UDPExchange.performKeepingResponse(address: address, family: family, packet: packet, expectedID: id, timeout: timeout)
            return (result, response.flatMap { DNSPacket.parseResponse($0)?.answers } ?? [])
        case let .dot(host, port):
            guard let packet = DNSPacket.makeQuery(id: 0, name: name, typeCode: type.rawValue, qclass: qclass) else {
                return (.failure(.networkError, "Invalid domain name"), [])
            }
            let (result, response) = await dot.performKeepingResponse(host: host, port: port, packet: packet, timeout: timeout)
            return (result, response.flatMap { DNSPacket.parseResponse($0)?.answers } ?? [])
        case let .doh(url):
            guard let packet = DNSPacket.makeQuery(id: 0, name: name, typeCode: type.rawValue, qclass: qclass) else {
                return (.failure(.networkError, "Invalid domain name"), [])
            }
            let (result, response) = await doh.performKeepingResponse(url: url, packet: packet, timeout: timeout)
            return (result, response.flatMap { DNSPacket.parseResponse($0)?.answers } ?? [])
        }
    }
}

// MARK: - Interception check

/// Detects networks that hijack plain DNS: routers, ISPs or local filter apps that answer every
/// port-53 query themselves, whichever server it was sent to.
enum InterceptionCheck {
    /// 192.0.2.0/24 is reserved for documentation (RFC 5737) and never routed, so no DNS server can live here.
    static let probeAddress = "192.0.2.53"

    /// True when something answers a query sent to `probeAddress`.
    static func run(timeout: TimeInterval = 1.5) async -> Bool {
        guard let resolved = SocketAddress.resolve(host: probeAddress, port: 53) else { return false }
        let target = ProbeTarget(serverID: UUID(), endpoint: .udp(address: resolved.address, family: resolved.family), resolvedAddress: probeAddress)
        let result = await DNSProber.probe(target, name: "example.com", type: .a, timeout: timeout)
        // Any DNS reply counts, even REFUSED: a real reply can only come from an interceptor.
        return result.status.isSuccess || (result.status == .serverError && result.latencyMs > 0)
    }
}

// MARK: - Socket addresses

enum SocketAddress {
    static func resolve(host rawHost: String, port: UInt16) -> (address: Data, family: Int32)? {
        var host = rawHost
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return nil }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        hints.ai_flags = AI_NUMERICSERV

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        guard let address = first.pointee.ai_addr else { return nil }
        return (Data(bytes: address, count: Int(first.pointee.ai_addrlen)), first.pointee.ai_family)
    }

    static func isIPAddress(_ text: String) -> Bool {
        var host = text.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}

// MARK: - UDP

/// One query/response exchange over a connected, non-blocking UDP socket.
/// The clock starts right before `send` and stops as soon as the matching response is read.
private final class UDPExchange: @unchecked Sendable {
    private static let root = DispatchQueue(label: "app.dnspulse.udp", qos: .userInteractive, attributes: .concurrent)

    private let queue = DispatchQueue(label: "app.dnspulse.udp.exchange", qos: .userInteractive, target: UDPExchange.root)
    private let expectedID: UInt16
    private let keepsResponse: Bool
    /// The matching reply's bytes, kept only for diagnostics.
    private var response: [UInt8]?
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var startedAt: UInt64 = 0
    private var continuation: CheckedContinuation<ProbeResult, Never>?
    private var isFinished = false

    private init(expectedID: UInt16, keepsResponse: Bool = false) {
        self.expectedID = expectedID
        self.keepsResponse = keepsResponse
    }

    static func perform(address: Data, family: Int32, packet: [UInt8], expectedID: UInt16, timeout: TimeInterval) async -> ProbeResult {
        await UDPExchange(expectedID: expectedID).run(address: address, family: family, packet: packet, timeout: timeout)
    }

    /// Same exchange, also handing back the reply's bytes.
    static func performKeepingResponse(address: Data, family: Int32, packet: [UInt8], expectedID: UInt16, timeout: TimeInterval) async -> (ProbeResult, [UInt8]?) {
        let exchange = UDPExchange(expectedID: expectedID, keepsResponse: true)
        let result = await exchange.run(address: address, family: family, packet: packet, timeout: timeout)
        // `response` is written on the exchange queue before the continuation resumes, so it is safe to read here.
        return (result, exchange.response)
    }

    private func run(address: Data, family: Int32, packet: [UInt8], timeout: TimeInterval) async -> ProbeResult {
        let exchange = self
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                exchange.queue.async {
                    exchange.start(continuation, address: address, family: family, packet: packet, timeout: timeout)
                }
            }
        } onCancel: {
            exchange.queue.async { exchange.finish(.failure(.cancelled)) }
        }
    }

    private func start(_ continuation: CheckedContinuation<ProbeResult, Never>, address: Data, family: Int32, packet: [UInt8], timeout: TimeInterval) {
        guard !isFinished else {
            // Cancelled before the exchange got going.
            continuation.resume(returning: .failure(.cancelled))
            return
        }
        self.continuation = continuation

        fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return finish(.failure(.networkError, Self.lastError())) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let connected = address.withUnsafeBytes { raw in
            connect(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
        }
        guard connected == 0 else { return finish(.failure(.networkError, Self.lastError())) }

        let socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { self.receive() }
        source.setCancelHandler { close(socketFD) }
        readSource = source

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout, leeway: .milliseconds(1))
        timer.setEventHandler { self.finish(.failure(.timeout)) }
        self.timer = timer

        source.resume()
        timer.resume()

        startedAt = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { send(socketFD, $0.baseAddress, $0.count, 0) }
        if sent < 0 { finish(.failure(.networkError, Self.lastError())) }
    }

    private func receive() {
        guard !isFinished else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            let code = errno
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            if count < 0 {
                if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return }
                return finish(.failure(.networkError, String(cString: strerror(code))))
            }
            let header = buffer.withUnsafeBytes { DNSPacket.parseHeader(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            guard let header, header.isResponse, header.id == expectedID else { continue }
            let latency = Double(receivedAt &- startedAt) / 1_000_000
            if keepsResponse { response = Array(buffer.prefix(count)) }
            return finish(.answered(rcode: header.rcode, latencyMs: latency))
        }
    }

    private func finish(_ result: ProbeResult) {
        guard !isFinished else { return }
        isFinished = true
        timer?.cancel()
        timer = nil
        if let source = readSource {
            source.cancel() // the cancel handler closes the socket
            readSource = nil
        } else if fd >= 0 {
            close(fd)
        }
        fd = -1
        continuation?.resume(returning: result)
        continuation = nil
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }
}

// MARK: - DNS-over-HTTPS

/// Keeps one URLSession per DoH host so connections (and TLS) are reused between queries,
/// the same way a browser would.
final class DoHClient: @unchecked Sendable {
    static let shared = DoHClient()
    /// Used by the diagnostics sheet, so a benchmark starting (which resets `shared`) never cancels its lookups.
    static let diagnostics = DoHClient()

    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]

    func reset() {
        lock.lock()
        sessions.values.forEach { $0.invalidateAndCancel() }
        sessions.removeAll()
        lock.unlock()
    }

    private func session(for url: URL) -> URLSession {
        let key = "\(url.host ?? ""):\(url.port ?? 443)"
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[key] { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        sessions[key] = session
        return session
    }

    func perform(url: URL, packet: [UInt8], timeout: TimeInterval) async -> ProbeResult {
        await performKeepingResponse(url: url, packet: packet, timeout: timeout).result
    }

    /// Same request, also handing back the DNS message for diagnostics.
    func performKeepingResponse(url: URL, packet: [UInt8], timeout: TimeInterval) async -> (result: ProbeResult, response: Data?) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = Data(packet)

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let (data, response) = try await session(for: url).data(for: request)
            let latency = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
            guard let http = response as? HTTPURLResponse else {
                return (.failure(.networkError, "Not an HTTP response"), nil)
            }
            guard http.statusCode == 200 else {
                return (.failure(.serverError, "HTTP \(http.statusCode)"), nil)
            }
            guard let header = DNSPacket.parseHeader(data), header.isResponse else {
                return (.failure(.serverError, "Malformed DNS response"), nil)
            }
            return (.answered(rcode: header.rcode, latencyMs: latency), data)
        } catch let error as URLError where error.code == .timedOut {
            return (.failure(.timeout), nil)
        } catch let error as URLError where error.code == .cancelled {
            return (.failure(.cancelled), nil)
        } catch is CancellationError {
            return (.failure(.cancelled), nil)
        } catch {
            return (.failure(.networkError, error.localizedDescription), nil)
        }
    }
}
