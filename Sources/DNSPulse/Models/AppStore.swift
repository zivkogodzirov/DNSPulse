import Combine
import Foundation

/// Everything the user can customise, saved as JSON in ~/Library/Application Support/DNS Pulse.
@MainActor
final class AppStore: ObservableObject {
    @Published var servers: [DNSServer]
    @Published var websites: [Website]
    @Published var settings: AppSettings
    @Published var history: [BenchmarkRun] = []
    /// Maps a network's earlier fingerprint to its current one (set by NetworkStore), so saved tests stay with a
    /// network whose fingerprint changed.
    var resolveNetworkID: ((String) -> String?)? {
        didSet { updateNetworkIDs() }
    }

    private var subscriptions = Set<AnyCancellable>()

    enum Files {
        static let servers = "servers.json"
        static let websites = "websites.json"
        static let settings = "settings.json"
        static let history = "history.json"
    }

    nonisolated static let folder: URL = {
        if let override = ProcessInfo.processInfo.environment["DNSPULSE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DNS Pulse", isDirectory: true)
    }()

    private nonisolated static let ioQueue = DispatchQueue(label: "app.dnspulse.store", qos: .utility)

    init() {
        servers = Self.storedValue([DNSServer].self, file: Files.servers) ?? DefaultData.servers
        websites = Self.storedValue([Website].self, file: Files.websites) ?? DefaultData.websites
        settings = Self.storedValue(AppSettings.self, file: Files.settings) ?? AppSettings()
        addNewDefaultServers()

        // Save the default lists on first launch so server and website IDs stay the same from launch to launch
        // (saved results refer to servers by ID), and the settings, which record how current the server list is.
        if Self.storedValue([DNSServer].self, file: Files.servers) == nil { Self.write(servers, file: Files.servers) }
        if Self.storedValue([Website].self, file: Files.websites) == nil { Self.write(websites, file: Files.websites) }
        if Self.storedValue(AppSettings.self, file: Files.settings) == nil { Self.write(settings, file: Files.settings) }

        persist($servers, to: Files.servers)
        persist($websites, to: Files.websites)
        persist($settings, to: Files.settings)
        // `@Published` sends the new value before it's stored, so trim on the next turn, once the new limit is set.
        $settings.map(\.historyLimit).removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.trimHistory() }
            .store(in: &subscriptions)

        // History can be large, so load it off the main thread.
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.storedValue([BenchmarkRun].self, file: Files.history) ?? []
            }.value
            history = loaded + history.filter { run in !loaded.contains { $0.id == run.id } }
            persist($history, to: Files.history, pretty: false)
            updateNetworkIDs()
        }
    }

    // MARK: Derived lists

    var enabledServers: [DNSServer] { servers.filter(\.isEnabled) }
    var enabledWebsites: [Website] { websites.filter(\.isEnabled) }

    /// The websites the next test will use, honouring the "websites per run" limit.
    var testDomains: [String] {
        let domains = enabledWebsites.map(\.domain)
        return settings.websiteLimit > 0 ? Array(domains.prefix(settings.websiteLimit)) : domains
    }

    // MARK: Servers

    func upsert(_ server: DNSServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
    }

    func deleteServers(_ ids: Set<UUID>) {
        servers.removeAll { ids.contains($0.id) }
    }

    func setServers(_ ids: Set<UUID>, enabled: Bool) {
        for index in servers.indices where ids.contains(servers[index].id) {
            servers[index].isEnabled = enabled
        }
    }

    /// Adds servers, skipping any that are already in the list. Returns how many were added.
    @discardableResult
    func addServers(_ newServers: [DNSServer]) -> Int {
        var keys = Set(servers.map(\.dedupeKey))
        var added = 0
        for server in newServers where keys.insert(server.dedupeKey).inserted {
            servers.append(server)
            added += 1
        }
        return added
    }

    func resetServers() {
        servers = DefaultData.servers
    }

    func enableEncryptedServers() {
        for index in servers.indices where servers[index].proto.isEncrypted {
            servers[index].isEnabled = true
        }
    }

    /// Gives a list saved by an earlier version the servers added to the defaults since, once, so deleting them
    /// sticks. They go in with the other encrypted servers, before the DoH ones.
    private func addNewDefaultServers() {
        guard settings.serverCatalog < DefaultData.serverCatalog else { return }
        var keys = Set(servers.map(\.dedupeKey))
        let added = DefaultData.serversAdded(after: settings.serverCatalog).filter { keys.insert($0.dedupeKey).inserted }
        servers.insert(contentsOf: added, at: servers.firstIndex { $0.proto == .doh } ?? servers.endIndex)
        settings.serverCatalog = DefaultData.serverCatalog
        if !added.isEmpty, Self.storedValue([DNSServer].self, file: Files.servers) != nil { Self.write(servers, file: Files.servers) }
        Self.write(settings, file: Files.settings)
    }

    // MARK: Websites

    func upsert(_ website: Website) {
        if let index = websites.firstIndex(where: { $0.id == website.id }) {
            websites[index] = website
        } else {
            websites.append(website)
        }
    }

    func deleteWebsites(_ ids: Set<UUID>) {
        websites.removeAll { ids.contains($0.id) }
    }

    func setWebsites(_ ids: Set<UUID>, enabled: Bool) {
        for index in websites.indices where ids.contains(websites[index].id) {
            websites[index].isEnabled = enabled
        }
    }

    func setWebsites(_ ids: Set<UUID>, category: WebsiteCategory) {
        for index in websites.indices where ids.contains(websites[index].id) {
            websites[index].category = category
        }
    }

    /// Adds domains that aren't in the list yet. Returns (added, duplicates).
    @discardableResult
    func addDomains(_ domains: [String], category: WebsiteCategory, enabled: Bool = true) -> (added: Int, duplicates: Int) {
        var existing = Set(websites.map(\.domain))
        var added = 0
        var duplicates = 0
        for domain in domains {
            if existing.insert(domain).inserted {
                websites.append(Website(domain: domain, category: category, isEnabled: enabled))
                added += 1
            } else {
                duplicates += 1
            }
        }
        return (added, duplicates)
    }

    /// Keeps only the top `count` built-in websites switched on. Your own websites are left as they are.
    func enableTopWebsites(_ count: Int) {
        for index in websites.indices {
            guard let rank = websites[index].rank else { continue }
            websites[index].isEnabled = rank <= count
        }
    }

    func resetWebsites() {
        websites = DefaultData.websites
    }

    // MARK: History

    func addRun(_ run: BenchmarkRun) {
        var run = run
        if let id = run.networkID, let current = resolveNetworkID?(id) { run.networkID = current }
        history.removeAll { $0.id == run.id }
        history.insert(run, at: 0)
        trimHistory()
    }

    /// Replaces a saved test with a newer version of it, such as one with its failed lookups retried.
    func updateRun(_ run: BenchmarkRun) {
        guard let index = history.firstIndex(where: { $0.id == run.id }) else { return }
        history[index] = run
    }

    func deleteRuns(_ ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
    }

    /// Points saved tests at their network's current fingerprint (see NetworkStore.apply).
    func updateNetworkIDs() {
        guard let resolveNetworkID else { return }
        var updated = history
        var changed = false
        for index in updated.indices {
            guard let id = updated[index].networkID, let current = resolveNetworkID(id), current != id else { continue }
            updated[index].networkID = current
            changed = true
        }
        if changed { history = updated }
    }

    /// Keeps the newest `historyLimit` tests you started and, separately, the newest `historyLimit` automatic
    /// checks, so background checks never push your own tests out of History.
    func trimHistory() {
        let limit = max(1, settings.historyLimit)
        let kept = Set(history.filter { $0.trigger == nil }.prefix(limit).map(\.id))
            .union(history.filter { $0.trigger != nil }.prefix(limit).map(\.id))
        if kept.count < history.count { history.removeAll { !kept.contains($0.id) } }
    }

    // MARK: Persistence

    private func persist<Value: Encodable>(_ publisher: Published<Value>.Publisher, to file: String, pretty: Bool = true) {
        publisher
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { value in Self.write(value, file: file, pretty: pretty) }
            .store(in: &subscriptions)
    }

    nonisolated static func storedValue<Value: Decodable>(_ type: Value.Type, file: String) -> Value? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    nonisolated static func write<Value: Encodable>(_ value: Value, file: String, pretty: Bool = true) {
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
                try encoder.encode(value).write(to: folder.appendingPathComponent(file), options: .atomic)
            } catch {
                NSLog("DNS Pulse: could not save \(file): \(error.localizedDescription)")
            }
        }
    }
}
