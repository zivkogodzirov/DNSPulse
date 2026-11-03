import SwiftUI

enum WebsiteCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case search, social, streaming, shopping, news, tech, ai, communication, travel, gaming, finance, reference, other
    /// Sites imported from your own browser history. Keep new cases last so saved lists still decode.
    case personal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .social: "Social"
        case .streaming: "Streaming"
        case .shopping: "Shopping"
        case .news: "News"
        case .tech: "Tech"
        case .ai: "AI"
        case .communication: "Communication"
        case .travel: "Travel"
        case .gaming: "Gaming"
        case .finance: "Finance"
        case .reference: "Reference"
        case .other: "Other"
        case .personal: "My Sites"
        }
    }

    var icon: String {
        switch self {
        case .search: "magnifyingglass"
        case .social: "person.2.fill"
        case .streaming: "play.tv.fill"
        case .shopping: "cart.fill"
        case .news: "newspaper.fill"
        case .tech: "laptopcomputer"
        case .ai: "sparkles"
        case .communication: "bubble.left.and.bubble.right.fill"
        case .travel: "airplane"
        case .gaming: "gamecontroller.fill"
        case .finance: "creditcard.fill"
        case .reference: "books.vertical.fill"
        case .other: "square.grid.2x2.fill"
        case .personal: "person.crop.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .search: .blue
        case .social: .pink
        case .streaming: .red
        case .shopping: .orange
        case .news: .teal
        case .tech: .indigo
        case .ai: .purple
        case .communication: .green
        case .travel: .cyan
        case .gaming: .mint
        case .finance: .yellow
        case .reference: .brown
        case .other: .gray
        case .personal: Color(hex: "#3D5A80")
        }
    }
}

struct Website: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var domain: String
    var category: WebsiteCategory = .other
    /// Popularity rank for the built-in list; nil for websites you added yourself.
    var rank: Int?
    var isEnabled = true

    init(id: UUID = UUID(), domain: String, category: WebsiteCategory = .other, rank: Int? = nil, isEnabled: Bool = true) {
        self.id = id
        self.domain = domain
        self.category = category
        self.rank = rank
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        domain = c.value(.domain, default: "")
        category = c.value(.category, default: .other)
        rank = try? c.decodeIfPresent(Int.self, forKey: .rank)
        isEnabled = c.value(.isEnabled, default: true)
    }

    var isCustom: Bool { rank == nil }
    var sortRank: Int { rank ?? Int.max }
    var sourceTitle: String { isCustom ? "Custom" : "Top 100" }
}

enum DomainParser {
    /// Turns user input such as "https://www.Example.com/path" into "www.example.com".
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[]"))
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let end = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<end]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        while text.hasSuffix(".") { text.removeLast() }
        return isValid(text) ? text : nil
    }

    static func isValid(_ domain: String) -> Bool {
        guard domain.utf8.count <= 253, domain.contains(".") else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard let tld = labels.last, tld.contains(where: \.isLetter) else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count)
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }
        }
    }

    /// Common two-level public suffixes. Not the full public suffix list, but enough to group most sites sensibly.
    static let twoLevelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "com.br", "net.br", "org.br", "gov.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "com.hk", "com.tw", "com.sg", "com.my",
        "co.in", "net.in", "org.in", "gov.in", "co.za", "org.za", "co.kr", "or.kr",
        "com.mx", "com.ar", "com.co", "com.pe", "com.tr", "com.ua", "com.pl",
        "co.id", "co.il", "co.th", "com.sa", "com.eg", "com.pk", "com.ph", "com.vn", "com.ng", "co.ke",
    ]

    /// Second levels that country domains commonly register names under, as in "tsinghua.edu.cn" or "huji.ac.il".
    static let countrySecondLevels: Set<String> = [
        "ac", "co", "com", "edu", "go", "gob", "gouv", "gov", "govt", "ltd", "mil", "ne", "net", "nic", "or", "org", "plc", "sch",
    ]

    /// The part of a host name a person would call "the site": "news.bbc.co.uk" → "bbc.co.uk", "mail.google.com" → "google.com".
    static func registrableDomain(_ host: String) -> String {
        var text = host.lowercased()
        while text.hasSuffix(".") { text.removeLast() }
        let labels = text.split(separator: ".")
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let tld = labels[labels.count - 1], second = labels[labels.count - 2]
        let isTwoLevelSuffix = twoLevelSuffixes.contains("\(second).\(tld)")
            || (tld.count == 2 && countrySecondLevels.contains(String(second)))
        return labels.suffix(isTwoLevelSuffix ? 3 : 2).joined(separator: ".")
    }

    /// Pulls every domain out of free text (one per line, comma separated, CSV exports, URLs…).
    /// Pure numbers such as rank columns are ignored.
    static func extract(from text: String) -> (valid: [String], invalid: [String]) {
        var valid: [String] = []
        var invalid: [String] = []
        var seen = Set<String>()
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|"))
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            if token.allSatisfy(\.isNumber) { continue }
            if let domain = normalize(token) {
                if seen.insert(domain).inserted { valid.append(domain) }
            } else {
                invalid.append(token)
            }
        }
        return (valid, invalid)
    }
}
