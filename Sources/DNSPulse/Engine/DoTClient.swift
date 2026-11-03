import Foundation
import Network
import Security

// MARK: - DNS-over-TLS

/// Keeps TLS connections to each DoT server (RFC 7858) open between lookups, so the handshake happens once per
/// connection, as it does for a resolver set up on the Mac.
///
/// Each lookup gets a connection of its own when it can. Some servers (AdGuard, Mullvad) answer a connection's
/// queries in the order they arrived, so a slow lookup would hold up quick ones sent after it and make the server
/// look slower than it is. Past `maxConnectionsPerServer` lookups share connections, matched to answers by message ID.
final class DoTClient: @unchecked Sendable {
    static let shared = DoTClient()
    /// Used by the diagnostics sheet, so a benchmark starting (which resets `shared`) never cancels its lookups.
    static let diagnostics = DoTClient()

    static let maxConnectionsPerServer = 8

    private let lock = NSLock()
    private var pools: [String: [DoTConnection]] = [:]

    func reset() {
        lock.lock()
        let open = pools.values.flatMap { $0 }
        pools.removeAll()
        lock.unlock()
        open.forEach { $0.close() }
    }

    /// An idle open connection to the server, else a new one while there's room, else the least busy one.
    /// The connection counts the lookup as in flight until `exchange` returns.
    private func connection(host: String, port: UInt16) -> DoTConnection {
        let key = "\(host.lowercased()):\(port)"
        lock.lock()
        defer { lock.unlock() }
        var pool = (pools[key] ?? []).filter(\.isUsable)
        let chosen: DoTConnection
        if let idle = pool.first(where: { $0.inFlight == 0 }) {
            chosen = idle
        } else if pool.count < Self.maxConnectionsPerServer {
            chosen = DoTConnection(host: host, port: port)
            pool.append(chosen)
        } else {
            chosen = pool.min { $0.inFlight < $1.inFlight }!
        }
        chosen.reserve()
        pools[key] = pool
        return chosen
    }

    func perform(host: String, port: UInt16, packet: [UInt8], timeout: TimeInterval) async -> ProbeResult {
        await connection(host: host, port: port).exchange(packet, timeout: timeout, keepsResponse: false).result
    }

    /// Same lookup, also handing back the reply's bytes for diagnostics.
    func performKeepingResponse(host: String, port: UInt16, packet: [UInt8], timeout: TimeInterval) async -> (result: ProbeResult, response: [UInt8]?) {
        await connection(host: host, port: port).exchange(packet, timeout: timeout, keepsResponse: true)
    }
}

/// One TLS connection and the lookups waiting on it. Everything except `closed` and `reserved` is touched only on `queue`.
private final class DoTConnection: @unchecked Sendable {
    typealias Outcome = (result: ProbeResult, response: [UInt8]?)

    private static let root = DispatchQueue(label: "app.dnspulse.dot", qos: .userInteractive, attributes: .concurrent)

    private final class Lookup {
        let continuation: CheckedContinuation<Outcome, Never>
        /// The query with its two-byte length prefix and the ID this connection gave it.
        let framed: Data
        let keepsResponse: Bool
        /// The clock starts when the lookup is made, so the first one on a new connection includes the handshake,
        /// the same as DoH and as a real resolver would see it. The warm-up lookups take that hit before timing starts.
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var timer: DispatchSourceTimer?

        init(continuation: CheckedContinuation<Outcome, Never>, framed: Data, keepsResponse: Bool) {
            self.continuation = continuation
            self.framed = framed
            self.keepsResponse = keepsResponse
        }
    }

    /// Lets a cancelled task find its lookup, which only gets an ID once it reaches the queue (the only place it's touched).
    private final class Ticket: @unchecked Sendable {
        var id: UInt16?
        var isCancelled = false
    }

    private let queue = DispatchQueue(label: "app.dnspulse.dot.connection", qos: .userInteractive, target: DoTConnection.root)
    private let connection: NWConnection
    private let stateLock = NSLock()
    private var closed = false
    /// Lookups handed this connection whose `exchange` hasn't returned yet.
    private var reserved = 0
    private var closeReason = "The connection closed"
    private var isReady = false
    /// IDs of lookups made before the handshake finished, sent once it does.
    private var unsent: [UInt16] = []
    private var pending: [UInt16: Lookup] = [:]
    private var buffer: [UInt8] = []

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // The certificate is checked against `host`, whether it's a name or an IP address.
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 853, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.start(queue: queue)
    }

    var isUsable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !closed
    }

    var inFlight: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return reserved
    }

    func reserve() {
        stateLock.lock()
        reserved += 1
        stateLock.unlock()
    }

    private func release() {
        stateLock.lock()
        reserved -= 1
        stateLock.unlock()
    }

    func close() {
        queue.async { self.fail(.cancelled, "Cancelled") }
    }

    /// Sends one query and waits for its answer. Call `reserve()` first; this releases it.
    func exchange(_ packet: [UInt8], timeout: TimeInterval, keepsResponse: Bool) async -> Outcome {
        defer { release() }
        let ticket = Ticket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { self.start(ticket, packet: packet, timeout: timeout, keepsResponse: keepsResponse, continuation: continuation) }
            }
        } onCancel: {
            queue.async {
                ticket.isCancelled = true
                if let id = ticket.id { self.finish(id, (.failure(.cancelled), nil)) }
            }
        }
    }

    private func start(_ ticket: Ticket, packet: [UInt8], timeout: TimeInterval, keepsResponse: Bool, continuation: CheckedContinuation<Outcome, Never>) {
        guard !ticket.isCancelled else { return continuation.resume(returning: (.failure(.cancelled), nil)) }
        guard isUsable else { return continuation.resume(returning: (.failure(.networkError, closeReason), nil)) }
        guard packet.count >= 12, packet.count <= Int(UInt16.max) else {
            return continuation.resume(returning: (.failure(.networkError, "Invalid query"), nil))
        }

        var id = UInt16.random(in: .min ... .max)
        while pending[id] != nil { id = UInt16.random(in: .min ... .max) }
        ticket.id = id
        var framed = [UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)] + packet
        framed[2] = UInt8(id >> 8)
        framed[3] = UInt8(id & 0xFF)

        let lookup = Lookup(continuation: continuation, framed: Data(framed), keepsResponse: keepsResponse)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.finish(id, (.failure(.timeout), nil)) }
        lookup.timer = timer
        pending[id] = lookup
        timer.resume()

        if isReady { send(id) } else { unsent.append(id) }
    }

    private func send(_ id: UInt16) {
        guard let lookup = pending[id] else { return }
        connection.send(content: lookup.framed, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.fail(.networkError, Self.describe(error))
        })
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            let waiting = unsent
            unsent.removeAll()
            waiting.forEach(send)
            receive()
        case .waiting(let error), .failed(let error):
            // `.waiting` means the server can't be reached right now (refused, no route); fail now rather than hang.
            fail(.networkError, Self.describe(error))
        case .cancelled:
            fail(.networkError, closeReason)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            if let data, !data.isEmpty {
                buffer.append(contentsOf: data)
                deliver(receivedAt: receivedAt)
            }
            if let error { return fail(.networkError, Self.describe(error)) }
            if isComplete { return fail(.networkError, "The server closed the connection") }
            receive()
        }
    }

    /// Hands every complete message in the buffer to the lookup with its ID. Answers to lookups that already
    /// timed out are dropped.
    private func deliver(receivedAt: UInt64) {
        while buffer.count >= 2 {
            let length = Int(buffer[0]) << 8 | Int(buffer[1])
            guard buffer.count >= 2 + length else { return }
            let message = Array(buffer[2..<(2 + length)])
            buffer.removeFirst(2 + length)
            let header = message.withUnsafeBytes { DNSPacket.parseHeader($0) }
            guard let header, header.isResponse, let lookup = pending[header.id] else { continue }
            let latency = Double(receivedAt &- lookup.startedAt) / 1_000_000
            finish(header.id, (.answered(rcode: header.rcode, latencyMs: latency), lookup.keepsResponse ? message : nil))
        }
    }

    private func finish(_ id: UInt16, _ outcome: Outcome) {
        guard let lookup = pending.removeValue(forKey: id) else { return }
        unsent.removeAll { $0 == id }
        lookup.timer?.cancel()
        lookup.continuation.resume(returning: outcome)
    }

    /// Ends every waiting lookup and closes the connection, so the next lookup opens a new one.
    private func fail(_ status: ProbeStatus, _ reason: String) {
        stateLock.lock()
        let wasClosed = closed
        closed = true
        stateLock.unlock()
        if !wasClosed {
            closeReason = reason
            connection.cancel()
        }
        unsent.removeAll()
        for id in Array(pending.keys) { finish(id, (.failure(status, reason), nil)) }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .tls(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "TLS failed: \(message)"
        case .posix(let code):
            return String(cString: strerror(code.rawValue))
        case .dns(let code):
            return "Couldn't look up the server's address (error \(code))"
        default:
            return error.localizedDescription
        }
    }
}
