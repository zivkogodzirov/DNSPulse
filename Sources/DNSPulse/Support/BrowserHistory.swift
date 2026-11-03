import Foundation
import SQLite3

/// Browsers whose history DNS Pulse can read.
enum BrowserKind: String, CaseIterable, Identifiable, Sendable {
    case safari, chrome, brave, edge, arc, vivaldi, opera, firefox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .firefox: "Firefox"
        }
    }

    var icon: String {
        switch self {
        case .safari: "safari"
        case .firefox: "flame"
        default: "globe"
        }
    }

    /// Where the browser keeps its data, relative to the home folder.
    var dataFolder: String {
        switch self {
        case .safari: "Library/Safari"
        case .chrome: "Library/Application Support/Google/Chrome"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge: "Library/Application Support/Microsoft Edge"
        case .arc: "Library/Application Support/Arc/User Data"
        case .vivaldi: "Library/Application Support/Vivaldi"
        case .opera: "Library/Application Support/com.operasoftware.Opera"
        case .firefox: "Library/Application Support/Firefox/Profiles"
        }
    }

    var isChromium: Bool {
        switch self {
        case .chrome, .brave, .edge, .arc, .vivaldi, .opera: true
        case .safari, .firefox: false
        }
    }
}

/// How often a site (registrable domain) was visited.
struct SiteVisits: Identifiable, Hashable, Sendable {
    let domain: String
    var visits: Int
    var lastVisit: Date?

    var id: String { domain }
}

/// What reading one browser's history found.
struct BrowserHistoryReport: Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        case ok
        case noHistory
        case needsFullDiskAccess
        case unreadable(String)
    }

    let browser: BrowserKind
    let status: Status
    /// Ranked by visits, most visited first.
    let sites: [SiteVisits]

    var id: BrowserKind { browser }
    var totalVisits: Int { sites.reduce(0) { $0 + $1.visits } }
}

/// One URL row read from a history database.
struct BrowserHistoryRow: Sendable {
    let url: String
    let visits: Int
    let lastVisit: Date?
}

/// Reads browser history on this Mac, strictly read-only and always from a temporary copy:
/// browsers keep their databases locked while they run, and the originals are never opened.
enum BrowserHistory {
    static let days = 90

    /// Reads every installed browser. `home` is the folder that holds `Library`; tests pass a fake one.
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> [BrowserHistoryReport] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        return installedBrowsers(home: home).map { read($0, home: home, since: since) }
    }

    /// Browsers with a data folder. Safari is always listed: it comes with macOS, and without
    /// Full Disk Access its folder can't even be seen.
    static func installedBrowsers(home: URL) -> [BrowserKind] {
        BrowserKind.allCases.filter { browser in
            browser == .safari || FileManager.default.fileExists(atPath: home.appendingPathComponent(browser.dataFolder).path)
        }
    }

    static func read(_ browser: BrowserKind, home: URL, since: Date) -> BrowserHistoryReport {
        let folder = home.appendingPathComponent(browser.dataFolder, isDirectory: true)
        let databases = databaseFiles(for: browser, in: folder)

        if databases.isEmpty {
            // Without Full Disk Access, Safari's folder can't be listed, so its history looks missing.
            if browser == .safari, isPermissionDenied(folder) {
                return BrowserHistoryReport(browser: browser, status: .needsFullDiskAccess, sites: [])
            }
            return BrowserHistoryReport(browser: browser, status: .noHistory, sites: [])
        }

        var rows: [BrowserHistoryRow] = []
        var readAny = false
        var firstError: BrowserHistoryReport.Status?
        for database in databases {
            do {
                rows += try readRows(browser, database: database, since: since)
                readAny = true
            } catch let error as ReadError {
                firstError = firstError ?? error.status
            } catch {
                firstError = firstError ?? .unreadable(error.localizedDescription)
            }
        }
        guard readAny else {
            return BrowserHistoryReport(browser: browser, status: firstError ?? .noHistory, sites: [])
        }
        let sites = aggregate(rows, since: since)
        return BrowserHistoryReport(browser: browser, status: sites.isEmpty ? .noHistory : .ok, sites: sites)
    }

    /// Sites from several browsers, visits added together.
    static func combine(_ reports: [BrowserHistoryReport]) -> [SiteVisits] {
        var bySite: [String: SiteVisits] = [:]
        for report in reports {
            for site in report.sites {
                merge(site, into: &bySite)
            }
        }
        return ranked(bySite)
    }

    // MARK: Aggregation

    /// Groups URLs by site and adds up their visits, skipping anything older than `since` (when the row has a date).
    static func aggregate(_ rows: [BrowserHistoryRow], since: Date?) -> [SiteVisits] {
        var bySite: [String: SiteVisits] = [:]
        for row in rows where row.visits > 0 {
            if let since, let last = row.lastVisit, last < since { continue }
            guard let domain = siteName(forURL: row.url) else { continue }
            merge(SiteVisits(domain: domain, visits: row.visits, lastVisit: row.lastVisit), into: &bySite)
        }
        return ranked(bySite)
    }

    /// "https://www.bbc.co.uk/news" → "bbc.co.uk". Nil for local addresses, IP addresses and anything that isn't http(s).
    static func siteName(forURL text: String) -> String? {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = (components.encodedHost ?? components.host)?.lowercased() else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty, !SocketAddress.isIPAddress(host), !isLocal(host) else { return nil }
        let domain = DomainParser.registrableDomain(host)
        return DomainParser.isValid(domain) ? domain : nil
    }

    private static let localSuffixes = ["localhost", "local", "lan", "home", "internal", "home.arpa", "arpa", "test", "invalid", "example"]

    private static func isLocal(_ host: String) -> Bool {
        localSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func merge(_ site: SiteVisits, into bySite: inout [String: SiteVisits]) {
        var entry = bySite[site.domain] ?? SiteVisits(domain: site.domain, visits: 0, lastVisit: nil)
        entry.visits += site.visits
        if let last = site.lastVisit, last > (entry.lastVisit ?? .distantPast) { entry.lastVisit = last }
        bySite[site.domain] = entry
    }

    private static func ranked(_ bySite: [String: SiteVisits]) -> [SiteVisits] {
        bySite.values.sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.domain < $1.domain }
    }

    // MARK: Finding databases

    static func databaseFiles(for browser: BrowserKind, in folder: URL) -> [URL] {
        let manager = FileManager.default
        switch browser {
        case .safari:
            let file = folder.appendingPathComponent("History.db")
            return manager.fileExists(atPath: file.path) ? [file] : []
        case .firefox:
            let profiles = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return profiles
                .map { $0.appendingPathComponent("places.sqlite") }
                .filter { manager.fileExists(atPath: $0.path) }
                .sorted { $0.path < $1.path }
        default:
            // "Default", "Profile 1", "Profile 2"…; some Opera versions keep History in the top folder.
            var candidates = [folder.appendingPathComponent("History")]
            let children = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for child in children.sorted(by: { $0.path < $1.path }) {
                let name = child.lastPathComponent
                if name == "Default" || name.hasPrefix("Profile ") {
                    candidates.append(child.appendingPathComponent("History"))
                }
            }
            return candidates.filter { manager.fileExists(atPath: $0.path) }
        }
    }

    private static func isPermissionDenied(_ folder: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return false
        } catch {
            return isPermissionError(error)
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    // MARK: Reading

    enum ReadError: Error {
        case permission
        case database(String)

        var status: BrowserHistoryReport.Status {
            switch self {
            case .permission: .needsFullDiskAccess
            case .database(let message): .unreadable(message)
            }
        }
    }

    private static let copyPrefix = "DNSPulse-history-"

    /// Deletes copies left behind when the app quit or crashed in the middle of a scan.
    static func removeLeftoverCopies() {
        let manager = FileManager.default
        let items = (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(copyPrefix) {
            try? manager.removeItem(at: item)
        }
    }

    /// Copies the database (plus any -wal / -shm files, which hold the newest visits) to a private temporary
    /// folder, reads the copy and deletes it again.
    static func readRows(_ browser: BrowserKind, database: URL, since: Date) throws -> [BrowserHistoryRow] {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(copyPrefix + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }

        let copy = folder.appendingPathComponent(database.lastPathComponent)
        do {
            try manager.copyItem(at: database, to: copy)
        } catch {
            throw isPermissionError(error) ? ReadError.permission : ReadError.database(error.localizedDescription)
        }
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: database.path + suffix)
            if manager.fileExists(atPath: source.path) {
                try? manager.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        switch browser {
        case .safari:
            // visit_time is seconds since 1 January 2001.
            let convert: (Double) -> Date = { Date(timeIntervalSinceReferenceDate: $0) }
            do {
                return try query(copy, """
                    SELECT i.url, COUNT(v.id), MAX(v.visit_time)
                    FROM history_items i JOIN history_visits v ON v.history_item = i.id
                    WHERE v.visit_time >= ?1
                    GROUP BY i.id
                    """, cutoff: since.timeIntervalSinceReferenceDate, date: convert)
            } catch ReadError.database(_) {
                // Older or unusual layouts: lifetime visit counts without dates.
                return try query(copy, "SELECT url, visit_count, NULL FROM history_items", cutoff: nil, date: convert)
            }
        case .firefox:
            // moz_places.visit_count covers years of history, so count the visits in the window instead.
            // visit_date is microseconds since 1970; embeds, downloads, framed links and reloads aren't
            // counted, the same as Firefox's own visit_count.
            return try query(copy, """
                SELECT p.url, COUNT(*), MAX(v.visit_date)
                FROM moz_places p JOIN moz_historyvisits v ON v.place_id = p.id
                WHERE v.visit_date >= ?1 AND v.visit_type NOT IN (0, 4, 7, 8, 9)
                GROUP BY p.id
                """, cutoff: since.timeIntervalSince1970 * 1_000_000) { Date(timeIntervalSince1970: $0 / 1_000_000) }
        default:
            // urls.visit_count includes anything older the browser hasn't expired yet, so count the visits in the
            // window here too. visit_time is microseconds since 1 January 1601 (the WebKit / Windows epoch);
            // reloads aren't counted, the same as Chromium's own visit_count.
            let offset = 11_644_473_600.0
            return try query(copy, """
                SELECT u.url, COUNT(*), MAX(v.visit_time)
                FROM urls u JOIN visits v ON v.url = u.id
                WHERE v.visit_time >= ?1 AND (v.transition & 255) != 8
                GROUP BY u.id
                """, cutoff: (since.timeIntervalSince1970 + offset) * 1_000_000) { Date(timeIntervalSince1970: $0 / 1_000_000 - offset) }
        }
    }

    private static func query(_ file: URL, _ sql: String, cutoff: Double?, date: (Double) -> Date) throws -> [BrowserHistoryRow] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ReadError.database(message(db))
        }
        sqlite3_busy_timeout(db, 500)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError.database(message(db))
        }
        if let cutoff { sqlite3_bind_double(statement, 1, cutoff) }

        var rows: [BrowserHistoryRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ReadError.database(message(db)) }
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let visits = Int(sqlite3_column_int64(statement, 1))
            let last = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : date(sqlite3_column_double(statement, 2))
            rows.append(BrowserHistoryRow(url: String(cString: text), visits: visits, lastVisit: last))
        }
        return rows
    }

    private static func message(_ db: OpaquePointer?) -> String {
        guard let db, let text = sqlite3_errmsg(db) else { return "Couldn’t open the history database" }
        let raw = String(cString: text)
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
