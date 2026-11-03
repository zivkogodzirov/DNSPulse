import Foundation

/// DNS record types the benchmark can ask for.
enum DNSRecordType: String, Codable, CaseIterable, Identifiable, Sendable {
    case a = "A"
    case aaaa = "AAAA"
    case https = "HTTPS"
    case mx = "MX"
    case txt = "TXT"
    case ns = "NS"

    var id: String { rawValue }

    var code: UInt16 {
        switch self {
        case .a: 1
        case .ns: 2
        case .mx: 15
        case .txt: 16
        case .aaaa: 28
        case .https: 65
        }
    }

    var summary: String {
        switch self {
        case .a: "IPv4 address — what browsers ask for most"
        case .aaaa: "IPv6 address"
        case .https: "HTTPS service binding, used by modern browsers"
        case .mx: "Mail servers"
        case .txt: "Text records"
        case .ns: "Name servers"
        }
    }
}

/// Minimal RFC 1035 wire-format helpers: enough to build a query and read a response header.
enum DNSPacket {
    struct Header: Sendable {
        let id: UInt16
        let isResponse: Bool
        let isTruncated: Bool
        let rcode: UInt8
        let answerCount: UInt16
    }

    /// Builds a recursive query for `name` with an EDNS(0) OPT record.
    static func makeQuery(id: UInt16, name: String, type: DNSRecordType, qclass: DNSClass = .internet) -> [UInt8]? {
        makeQuery(id: id, name: name, typeCode: type.code, qclass: qclass)
    }

    static func makeQuery(id: UInt16, name: String, typeCode: UInt16, qclass: DNSClass = .internet) -> [UInt8]? {
        var packet: [UInt8] = [
            UInt8(id >> 8), UInt8(id & 0xFF),
            0x01, 0x00, // flags: recursion desired
            0x00, 0x01, // QDCOUNT
            0x00, 0x00, // ANCOUNT
            0x00, 0x00, // NSCOUNT
            0x00, 0x01, // ARCOUNT (the OPT record below)
        ]

        var fqdn = name
        while fqdn.hasSuffix(".") { fqdn.removeLast() }
        guard !fqdn.isEmpty, fqdn.utf8.count <= 253 else { return nil }

        for label in fqdn.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count) else { return nil }
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0)
        packet += [UInt8(typeCode >> 8), UInt8(typeCode & 0xFF), UInt8(qclass.rawValue >> 8), UInt8(qclass.rawValue & 0xFF)]

        // OPT pseudo-record: root owner, TYPE 41, 1232-byte UDP payload, no extended flags, empty RDATA.
        packet += [0x00, 0x00, 0x29, 0x04, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        return packet
    }

    static func parseHeader(_ bytes: UnsafeRawBufferPointer) -> Header? {
        guard bytes.count >= 12 else { return nil }
        let flags = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        return Header(
            id: UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
            isResponse: flags & 0x8000 != 0,
            isTruncated: flags & 0x0200 != 0,
            rcode: UInt8(flags & 0x000F),
            answerCount: UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        )
    }

    static func parseHeader(_ data: Data) -> Header? {
        data.withUnsafeBytes { parseHeader($0) }
    }

    static func rcodeName(_ rcode: UInt8) -> String {
        switch rcode {
        case 0: "NOERROR"
        case 1: "FORMERR"
        case 2: "SERVFAIL"
        case 3: "NXDOMAIN"
        case 4: "NOTIMP"
        case 5: "REFUSED"
        default: "RCODE \(rcode)"
        }
    }
}

// MARK: - Diagnostics queries

/// The query class. Chaos (CH) is used by servers to report their own identity, e.g. "id.server".
enum DNSClass: UInt16, Sendable {
    case internet = 1
    case chaos = 3

    var name: String { self == .internet ? "IN" : "CH" }
}

/// Record types used by diagnostics. Kept apart from `DNSRecordType`, which lists what a benchmark can ask for.
enum DNSLookupType: UInt16, Sendable {
    case a = 1
    case ns = 2
    case cname = 5
    case ptr = 12
    case txt = 16
    case aaaa = 28

    var name: String {
        switch self {
        case .a: "A"
        case .ns: "NS"
        case .cname: "CNAME"
        case .ptr: "PTR"
        case .txt: "TXT"
        case .aaaa: "AAAA"
        }
    }
}

/// One record from the answer section of a response.
struct DNSRecord: Hashable, Sendable {
    enum Value: Hashable, Sendable {
        /// A or AAAA, as printable text.
        case address(String)
        /// TXT: every character-string in the record, in order.
        case text([String])
        /// PTR, CNAME or NS target.
        case name(String)
        /// A type this parser doesn't decode; the RDATA length.
        case other(length: Int)
    }

    let name: String
    let type: UInt16
    let rclass: UInt16
    let ttl: UInt32
    let value: Value

    var typeName: String {
        DNSLookupType(rawValue: type)?.name ?? DNSRecordType.allCases.first { $0.code == type }?.rawValue ?? "TYPE\(type)"
    }

    /// The record's data as one line of text.
    var displayValue: String {
        switch value {
        case .address(let text), .name(let text): text
        case .text(let strings): strings.map { "\"\($0)\"" }.joined(separator: " ")
        case .other(let length): "\(length) byte\(length == 1 ? "" : "s") of data"
        }
    }

    /// TXT strings joined the way most tools show them (long values are split into 255-byte pieces on the wire).
    var joinedText: String? {
        if case .text(let strings) = value { return strings.joined() }
        return nil
    }
}

extension DNSPacket {
    struct Response: Sendable {
        let header: Header
        let answers: [DNSRecord]
    }

    /// Parses a full response: header, question (skipped) and answer records.
    /// Every read is bounds-checked, so malformed input returns nil (or the answers read before the damage) and never traps.
    static func parseResponse(_ data: Data) -> Response? {
        parseResponse([UInt8](data))
    }

    static func parseResponse(_ bytes: [UInt8]) -> Response? {
        guard let header = bytes.withUnsafeBytes({ parseHeader($0) }) else { return nil }
        var reader = WireReader(bytes: bytes, offset: 4)
        guard let questions = reader.u16(), reader.u16() != nil, reader.u16() != nil, reader.u16() != nil else { return nil }

        for _ in 0..<questions {
            guard reader.skipName(), reader.skip(4) else { return nil }
        }

        var answers: [DNSRecord] = []
        for _ in 0..<header.answerCount {
            guard let record = reader.record() else { break }
            answers.append(record)
        }
        return Response(header: header, answers: answers)
    }

    /// Reads a possibly compressed name starting at `start`. Returns the name and the offset just after it
    /// (after the first pointer, when the name is compressed).
    static func readName(_ bytes: [UInt8], at start: Int) -> (name: String, end: Int)? {
        var labels: [String] = []
        var offset = start
        var end: Int?
        var jumps = 0
        var length = 0

        while true {
            guard offset >= 0, offset < bytes.count else { return nil }
            let count = Int(bytes[offset])
            switch count & 0xC0 {
            case 0x00:
                if count == 0 {
                    return (labels.isEmpty ? "." : labels.joined(separator: "."), end ?? offset + 1)
                }
                guard offset + 1 + count <= bytes.count else { return nil }
                length += count + 1
                guard length <= 255 else { return nil }
                labels.append(String(decoding: bytes[(offset + 1)...(offset + count)], as: UTF8.self))
                offset += 1 + count
            case 0xC0:
                guard offset + 1 < bytes.count else { return nil }
                let target = (count & 0x3F) << 8 | Int(bytes[offset + 1])
                if end == nil { end = offset + 2 }
                // Pointers must go backwards; the jump limit stops loops between labels and pointers.
                jumps += 1
                guard target < offset, jumps <= 64 else { return nil }
                offset = target
            default:
                // 0x40 / 0x80 label types are obsolete or reserved.
                return nil
            }
        }
    }
}

/// Bounds-checked cursor over a DNS message.
private struct WireReader {
    let bytes: [UInt8]
    var offset: Int

    mutating func u16() -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func u32() -> UInt32? {
        guard let high = u16(), let low = u16() else { return nil }
        return UInt32(high) << 16 | UInt32(low)
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, offset + count <= bytes.count else { return false }
        offset += count
        return true
    }

    mutating func name() -> String? {
        guard let (name, end) = DNSPacket.readName(bytes, at: offset) else { return nil }
        offset = end
        return name
    }

    mutating func skipName() -> Bool {
        name() != nil
    }

    mutating func record() -> DNSRecord? {
        guard let owner = name(), let type = u16(), let rclass = u16(), let ttl = u32(), let length = u16() else { return nil }
        let start = offset
        let end = start + Int(length)
        guard end <= bytes.count else { return nil }
        offset = end

        let value: DNSRecord.Value
        switch DNSLookupType(rawValue: type) {
        case .a where length == 4:
            value = .address(bytes[start..<end].map(String.init).joined(separator: "."))
        case .aaaa where length == 16:
            value = .address(Self.ipv6Text(Array(bytes[start..<end])))
        case .txt:
            var strings: [String] = []
            var cursor = start
            while cursor < end {
                let count = Int(bytes[cursor])
                guard cursor + 1 + count <= end else { return nil }
                strings.append(String(decoding: bytes[(cursor + 1)..<(cursor + 1 + count)], as: UTF8.self))
                cursor += 1 + count
            }
            value = .text(strings)
        case .ptr, .cname, .ns:
            // The target may point anywhere earlier in the message, but must start inside this record.
            guard let (target, nameEnd) = DNSPacket.readName(bytes, at: start), nameEnd <= end else { return nil }
            value = .name(target)
        default:
            value = .other(length: Int(length))
        }
        return DNSRecord(name: owner, type: type, rclass: rclass, ttl: ttl, value: value)
    }

    private static func ipv6Text(_ raw: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: raw) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return String(cString: buffer)
    }
}
