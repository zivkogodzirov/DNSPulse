import SwiftUI
import UniformTypeIdentifiers

/// One line of the servers table: the server plus what saved tests say about it.
struct ServerRow: Identifiable {
    let server: DNSServer
    let record: ServerTrackRecord?
    /// 1 = fastest of the switched-on servers that answered in saved tests.
    let speedRank: Int?
    let rankedCount: Int

    var id: UUID { server.id }
    var name: String { server.name }
    var address: String { server.address }
    var protocolName: String { server.proto.rawValue }
    var provider: String { server.provider }
    var averageSort: Double { record?.average ?? .infinity }
    var successSort: Double { record?.successRate ?? -1 }
    var testsSort: Int { record?.tests ?? 0 }

    var isFastest: Bool { speedRank == 1 && rankedCount > 1 }
    /// One of the three slowest, once there are enough servers to compare.
    var isSlow: Bool {
        guard let speedRank, rankedCount >= 5 else { return false }
        return speedRank > rankedCount - 3
    }

    /// Ranks only switched-on servers, the ones the next test will use.
    static func build(servers: [DNSServer], records: [UUID: ServerTrackRecord]) -> [ServerRow] {
        let answered = servers
            .filter(\.isEnabled)
            .compactMap { server in records[server.id].flatMap { $0.hasAnswers ? (server.id, $0.average) : nil } }
            .sorted { $0.1 < $1.1 }
        var rankByID: [UUID: Int] = [:]
        for (index, entry) in answered.enumerated() { rankByID[entry.0] = index + 1 }
        return servers.map { ServerRow(server: $0, record: records[$0.id], speedRank: rankByID[$0.id], rankedCount: answered.count) }
    }
}

struct ServersView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var networks: NetworkStore

    @AppStorage("serverStatsScope") private var scope: HistoryScope = .all
    /// nil until the user picks (see `networkScope`).
    @State private var networkChoice: NetworkScope?
    @State private var records: [UUID: ServerTrackRecord] = [:]
    @State private var selection = Set<DNSServer.ID>()
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var sortOrder: [KeyPathComparator<ServerRow>] = []
    @State private var editing: EditingServer?
    @State private var diagnosing: DNSServer?
    @State private var pendingDelete: Set<DNSServer.ID> = []
    @State private var showDeleteConfirm = false
    @State private var showResetConfirm = false
    @State private var showTrim = false
    @State private var message: String?

    struct EditingServer: Identifiable {
        let server: DNSServer
        let isNew: Bool
        var id: UUID { server.id }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case enabled = "On"
        case disabled = "Off"
        case udp = "UDP"
        case dot = "DoT"
        case doh = "DoH"

        var id: String { rawValue }
    }

    private enum QuickSelect {
        case slowest(Int), unreliable, neverAnswered, untested
    }

    private struct RecordsKey: Hashable {
        let runs: [UUID]
        let scope: HistoryScope
        let metric: RankingMetric
        let servers: [String]
        let network: String?
    }

    private var recordsKey: RecordsKey {
        RecordsKey(runs: store.history.map(\.id), scope: scope, metric: store.settings.rankingMetric,
                   servers: store.servers.map { "\($0.id)|\($0.matchKey)" },
                   network: networkScope == .thisNetwork ? networks.currentID ?? "" : nil)
    }

    private func rebuildRecords() {
        records = ServerTrackRecord.build(for: store.servers, from: scope.runs(from: networkHistory), metric: store.settings.rankingMetric)
    }

    /// Until the user picks: "This network" when it has saved tests, unless some tests predate network tagging.
    /// Those could be from any network, so hiding them by default would make well-tested servers look untested.
    private var networkScope: NetworkScope {
        if let networkChoice { return networkChoice }
        guard let id = networks.currentID, !store.history.contains(where: { $0.networkID == nil }) else { return .all }
        return store.history.contains { $0.networkID == id } ? .thisNetwork : .all
    }

    /// Saved tests on the chosen network(s), newest first.
    private var networkHistory: [BenchmarkRun] {
        guard networkScope == .thisNetwork else { return store.history }
        guard let id = networks.currentID else { return [] }
        return store.history.filter { $0.networkID == id }
    }

    private func visible(_ rows: [ServerRow]) -> [ServerRow] {
        var list = rows.filter { row in
            switch filter {
            case .all: true
            case .enabled: row.server.isEnabled
            case .disabled: !row.server.isEnabled
            case .udp: row.server.proto == .udp
            case .dot: row.server.proto == .dot
            case .doh: row.server.proto == .doh
            }
        }
        if !search.isEmpty {
            list = list.filter {
                $0.server.name.localizedCaseInsensitiveContains(search)
                    || $0.server.address.localizedCaseInsensitiveContains(search)
                    || $0.server.provider.localizedCaseInsensitiveContains(search)
            }
        }
        if !sortOrder.isEmpty {
            list.sort(using: sortOrder)
            let statColumns: [PartialKeyPath<ServerRow>] = [\ServerRow.averageSort, \ServerRow.successSort, \ServerRow.testsSort]
            if let key = sortOrder.first?.keyPath, statColumns.contains(key) {
                list = list.filter { $0.record != nil } + list.filter { $0.record == nil }
            }
        }
        return list
    }

    var body: some View {
        let rows = ServerRow.build(servers: store.servers, records: records)
        let shown = visible(rows)
        let averages = rows.compactMap { $0.record?.average }.filter(\.isFinite)
        let low = averages.min() ?? 1
        let high = averages.max() ?? 1

        VStack(spacing: 0) {
            header
            Divider()
            if !store.history.isEmpty {
                speedBar(rows: rows)
                Divider()
            } else {
                Label("Run a test and each server's average speed across all your tests will appear here, so you can spot and remove the slow ones.", systemImage: "chart.bar.xaxis")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
            }
            LiteTable(shown, selection: $selection, sortOrder: $sortOrder, rowHeight: 36) {
                LiteColumn("On", width: .fixed(28)) { row in
                    Toggle("Include in tests", isOn: enabledBinding(row.id))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                LiteColumn("Name", value: \.name, width: .flexible(min: 190, ideal: 240)) { row in
                    HStack(spacing: 10) {
                        ServerAvatar(name: row.server.avatarName, color: row.server.color, isSystem: row.server.isSystem, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(row.server.name).fontWeight(.medium).lineLimit(1)
                                if row.server.isSystem { TagLabel(text: "AUTO", color: .blue) }
                            }
                            if !row.server.notes.isEmpty {
                                Text(row.server.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .opacity(row.server.isEnabled ? 1 : 0.55)
                }
                LiteColumn("Address", value: \.address, width: .flexible(min: 130, ideal: 220)) { row in
                    Text(row.server.displayAddress)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(row.server.isSystem ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(row.server.isEnabled ? 1 : 0.55)
                }
                LiteColumn("Protocol", value: \.protocolName, width: .fixed(64)) { row in
                    ProtocolBadge(proto: row.server.proto)
                }
                LiteColumn("Provider", value: \.provider, width: .flexible(min: 80, ideal: 120)) { row in
                    Text(row.server.provider.isEmpty ? "—" : row.server.provider)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                LiteColumn("Avg Speed", value: \.averageSort, width: .flexible(min: 140, ideal: 180)) { row in
                    AverageSpeedCell(row: row, low: low, high: high, scope: scope, network: networkScope)
                        .opacity(row.server.isEnabled ? 1 : 0.55)
                }
                LiteColumn("Answered", value: \.successSort, width: .flexible(min: 64, ideal: 78)) { row in
                    if let record = row.record, record.lookups > 0 {
                        Text(Format.percent(record.successRate))
                            .monospacedDigit()
                            .foregroundStyle(record.successRate >= 0.99 ? Color.secondary : record.successRate >= 0.95 ? .orange : .red)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                LiteColumn("Tests", value: \.testsSort, width: .flexible(min: 40, ideal: 48)) { row in
                    Text(row.record.map { "\($0.tests)" } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(row.record == nil ? .tertiary : .secondary)
                }
            }
            .rowContextMenu(primaryActionName: "Edit") { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                if let id = ids.first { edit(id) }
            }
            .rowAccessibilityLabel(accessibilityLabel)
            .emptyState { emptyState }
            .sectionDeleteCommand { requestDelete(selection) }
        }
        .sectionChrome(title: "DNS Servers") { toolbar }
        .onChange(of: recordsKey, initial: true) { _, _ in rebuildRecords() }
        .sheet(item: $editing) { item in
            ServerEditor(server: item.server, isNew: item.isNew) { store.upsert($0) }
        }
        .sheet(item: $diagnosing) { ResolverDiagnosticsSheet(server: $0) }
        .sheet(isPresented: $showTrim) {
            TrimServersSheet(rows: rows, scope: scope, network: networkScope) { ids, action in
                switch action {
                case .switchOff:
                    store.setServers(ids, enabled: false)
                case .delete:
                    store.deleteServers(ids)
                    selection.subtract(ids)
                }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                store.deleteServers(pendingDelete)
                selection.subtract(pendingDelete)
            }
        } message: {
            Text("Tip: switching a server off keeps it in the list for later. Built-in servers can be restored from the ⋯ menu.")
        }
        .confirmationDialog("Restore the default server list?", isPresented: $showResetConfirm) {
            Button("Restore Defaults", role: .destructive) {
                store.resetServers()
                selection.removeAll()
            }
        } message: {
            Text("Your own servers and changes will be replaced with the built-in list.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete this server?" : "Delete \(pendingDelete.count) servers?"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            // Hidden when even a collapsed search field leaves no room for it.
            ViewThatFits(in: .horizontal) {
                Text("\(store.enabledServers.count) of \(store.servers.count) switched on")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Color.clear.frame(width: 0, height: 0)
            }
            .layoutPriority(2)

            Spacer()

            Group {
                Button("All On") { store.setServers(Set(visible(ServerRow.build(servers: store.servers, records: records)).map(\.id)), enabled: true) }
                Button("All Off") { store.setServers(Set(visible(ServerRow.build(servers: store.servers, records: records)).map(\.id)), enabled: false) }
                TestOnlyButton(ids: selection) {
                    Label("Test Selected", systemImage: "play.fill")
                }
                .help("Run a test with only the selected servers")
            }
            .fixedSize()
            HeaderSearchField(prompt: "Search servers", text: $search)
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Summary of saved tests with tools to find and remove slow servers.
    private func speedBar(rows: [ServerRow]) -> some View {
        let ranked = rows.filter { $0.server.isEnabled && ($0.record?.hasAnswers ?? false) }.sorted { $0.averageSort < $1.averageSort }
        let history = networkHistory
        let testCount = scope.runs(from: history).count
        return HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(.secondary)
            Picker("Average speed from", selection: $scope) {
                ForEach(HistoryScope.allCases) { scope in
                    Text(scope == .all ? "All saved tests (\(history.count))" : scope.title).tag(scope)
                }
            }
            .fixedSize()
            .help("Which saved tests the Avg Speed column is based on (\(testCount) test\(testCount == 1 ? "" : "s")). Wins follow your “Rank by” setting.")
            Picker(selection: Binding(get: { networkScope }, set: { networkChoice = $0 })) {
                ForEach(NetworkScope.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("on")
            }
            .fixedSize()
            .accessibilityLabel("Network")
            .help(networks.current.map { "“This network” only counts tests run on \($0.name)." } ?? "You're not connected to a network right now.")

            if history.isEmpty {
                Text("No saved tests on this network yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            } else if records.isEmpty {
                Text("None of your current servers are in \(scope == .all ? "your saved tests" : scope.title.lowercased())\(networkScope == .thisNetwork ? " on this network" : "").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    if let fastest = ranked.first {
                        speedHighlight(icon: "bolt.fill", tint: .green, title: "Fastest", row: fastest)
                    }
                    if ranked.count > 1, let slowest = ranked.last {
                        speedHighlight(icon: "tortoise.fill", tint: .red, title: "Slowest", row: slowest)
                    }
                }
                if ranked.count > 1, let slowest = ranked.last {
                    speedHighlight(icon: "tortoise.fill", tint: .red, title: "Slowest", row: slowest)
                }
                Color.clear.frame(width: 0, height: 0)
            }
            .layoutPriority(-1)

            Spacer(minLength: 8)

            if !selection.isEmpty {
                Button("Switch Off \(selection.count)") { store.setServers(selection, enabled: false) }
                    .help("Keep the selected servers in the list but leave them out of tests")
                Button("Delete \(selection.count)…", role: .destructive) { requestDelete(selection) }
            }

            Menu("Select") {
                Button("Slowest 3") { quickSelect(.slowest(3), rows: rows) }
                Button("Slowest 5") { quickSelect(.slowest(5), rows: rows) }
                Button("Slowest 10") { quickSelect(.slowest(10), rows: rows) }
                Divider()
                Button("Unreliable (under 95% answered)") { quickSelect(.unreliable, rows: rows) }
                Button("Never Answered") { quickSelect(.neverAnswered, rows: rows) }
                Button(networkScope == .thisNetwork ? "Not Tested on This Network" : "Not Tested Yet") { quickSelect(.untested, rows: rows) }
                Divider()
                Button("Clear Selection") { selection.removeAll() }
                    .disabled(selection.isEmpty)
            }
            .fixedSize()
            .disabled(records.isEmpty)
            .help("Select servers that are switched on, so you can switch them off or delete them. Your current system DNS is never auto-selected.")

            Button {
                showTrim = true
            } label: {
                Label("Trim Slowest…", systemImage: "scissors")
            }
            .buttonStyle(.borderedProminent)
            .disabled(records.isEmpty)
            .help("Review your servers from slowest to fastest and remove the slow ones")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func speedHighlight(icon: String, tint: Color, title: String, row: ServerRow) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text("\(title):").foregroundStyle(.secondary)
            Text(row.server.name).fontWeight(.semibold).lineLimit(1)
            Text(Format.ms(row.averageSort)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize()
    }

    @ViewBuilder
    private var emptyState: some View {
        if search.isEmpty {
            ContentUnavailableView("No Servers", systemImage: "server.rack", description: Text("No servers match this filter."))
        } else {
            ContentUnavailableView.search(text: search)
        }
    }

    private func accessibilityLabel(_ row: ServerRow) -> String {
        var parts = [row.server.name, row.server.isSystem ? row.server.displayAddress : row.server.address,
                     row.server.isEnabled ? "switched on" : "switched off"]
        if let record = row.record, record.hasAnswers { parts.append("average \(Format.ms(record.average))") }
        return parts.joined(separator: ", ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { addNew() } label: { Label("Add Server", systemImage: "plus") }
                .help("Add a DNS server")
            Button { if let id = selection.first { edit(id) } } label: { Label("Edit", systemImage: "pencil") }
                .disabled(selection.count != 1)
                .help("Edit the selected server")
            Button { requestDelete(selection) } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
                .help("Delete the selected servers")
            Menu {
                Button("Trim Slowest Servers…") { showTrim = true }
                    .disabled(records.isEmpty)
                Button("Add Detected System DNS Servers") { addSystemServers() }
                Button("Diagnose Selected Server…") { diagnosing = store.servers.first { selection.count == 1 && selection.contains($0.id) } }
                    .disabled(selection.count != 1)
                Divider()
                Button("Import Servers…") { importServers() }
                Button("Export Servers…") {
                    Exporter.save(Exporter.serversJSON(store.servers), name: "DNS Pulse servers.json", type: .json)
                }
                Divider()
                Button("Restore Default Servers…") { showResetConfirm = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<DNSServer.ID>) -> some View {
        if ids.count == 1, let id = ids.first {
            Button("Edit…") { edit(id) }
            Button("Duplicate") { duplicate(id) }
            if let server = store.servers.first(where: { $0.id == id }) {
                Button("Copy Address") { Exporter.copy(server.isSystem ? server.displayAddress : server.address) }
                Button("Diagnose…") { diagnosing = server }
            }
            Divider()
        }
        if !ids.isEmpty {
            Button("Switch On") { store.setServers(ids, enabled: true) }
            Button("Switch Off") { store.setServers(ids, enabled: false) }
            TestOnlyButton(ids: ids) { Text("Test Only These") }
            Divider()
            Button("Delete…", role: .destructive) { requestDelete(ids) }
        }
    }

    private func quickSelect(_ kind: QuickSelect, rows: [ServerRow]) {
        let candidates = rows.filter { $0.server.isEnabled && !$0.server.isSystem }
        let picked: [ServerRow]
        switch kind {
        case .slowest(let count):
            picked = Array(candidates.filter { $0.record != nil }.sorted { $0.averageSort > $1.averageSort }.prefix(count))
        case .unreliable:
            picked = candidates.filter { row in row.record.map { $0.lookups > 0 && $0.successRate < 0.95 } ?? false }
        case .neverAnswered:
            picked = candidates.filter { row in row.record.map { !$0.hasAnswers } ?? false }
        case .untested:
            picked = candidates.filter { $0.record == nil }
        }
        guard !picked.isEmpty else {
            selection.removeAll()
            message = "No switched-on servers match that."
            return
        }
        selection = Set(picked.map(\.id))
        // Make sure the picks are on screen: switched-on servers, slowest first (untested ones sort last).
        filter = .enabled
        search = ""
        sortOrder = [KeyPathComparator(\ServerRow.averageSort, order: .reverse)]
    }

    private func enabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { store.servers.first { $0.id == id }?.isEnabled ?? false },
            set: { value in
                if let index = store.servers.firstIndex(where: { $0.id == id }) {
                    store.servers[index].isEnabled = value
                }
            }
        )
    }

    private func addNew() {
        editing = EditingServer(server: DNSServer(name: "", address: ""), isNew: true)
    }

    private func edit(_ id: UUID) {
        guard let server = store.servers.first(where: { $0.id == id }) else { return }
        editing = EditingServer(server: server, isNew: false)
    }

    private func duplicate(_ id: UUID) {
        guard var copy = store.servers.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name += " Copy"
        editing = EditingServer(server: copy, isNew: true)
    }

    private func requestDelete(_ ids: Set<DNSServer.ID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
        showDeleteConfirm = true
    }

    private func addSystemServers() {
        let detected = SystemDNS.servers(maxAge: 0)
        guard !detected.isEmpty else {
            message = "No system DNS servers were detected."
            return
        }
        let servers = detected.map {
            DNSServer(name: "Network DNS \($0)", provider: "My Network", address: $0, colorHex: "#8E8E93", notes: "Detected from your network settings")
        }
        let added = store.addServers(servers)
        message = added == 0 ? "Those servers are already in your list." : "Added \(added) server\(added == 1 ? "" : "s"): \(detected.joined(separator: ", "))"
    }

    private func importServers() {
        guard let data = Exporter.open(types: [.json, .plainText, .commaSeparatedText, .text]) else { return }
        let parsed = Exporter.parseServers(data)
        guard !parsed.isEmpty else {
            message = "No DNS servers were found in that file. Use an exported JSON file, or a text file with one address per line (optionally “Name, address”)."
            return
        }
        let added = store.addServers(parsed)
        message = "Imported \(added) server\(added == 1 ? "" : "s")\(parsed.count > added ? " (\(parsed.count - added) already in the list)" : "")."
    }
}

/// Runs a test with only the given servers.
/// It watches the engine on its own, so a running test doesn't re-render the whole servers page.
private struct TestOnlyButton<Title: View>: View {
    let ids: Set<DNSServer.ID>
    @ViewBuilder let title: Title

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: BenchmarkEngine
    @Environment(\.navigator) private var navigator

    var body: some View {
        Button {
            engine.start(store: store, onlyServers: ids)
            navigator?.show(.benchmark)
        } label: {
            title
        }
        .disabled(ids.isEmpty || engine.isRunning)
    }
}

/// Average response time across saved tests, with a bar and fastest/slowest markers.
struct AverageSpeedCell: View {
    let row: ServerRow
    let low: Double
    let high: Double
    let scope: HistoryScope
    let network: NetworkScope

    var body: some View {
        if let record = row.record {
            if record.hasAnswers {
                HStack(spacing: 8) {
                    Text(Format.ms(record.average))
                        .font(.body.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 62, alignment: .trailing)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(Heat.logColor(for: record.average, low: low, high: high))
                            .frame(width: 56 * CGFloat(Heat.barFraction(for: record.average, low: low, high: high)))
                    }
                    .frame(width: 56, height: 6)
                    if row.isFastest {
                        Image(systemName: "bolt.fill").foregroundStyle(.green).help("Fastest switched-on server in these tests")
                    } else if row.isSlow {
                        Image(systemName: "tortoise.fill").foregroundStyle(.red).help("One of the 3 slowest switched-on servers in these tests")
                    }
                }
                .help(tooltip(record))
            } else {
                Label(record.lookups == 0 ? "Couldn't connect" : "No answers", systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .help(failureHelp(record))
            }
        } else {
            Text(scope.notTestedLabel(on: network)).foregroundStyle(.tertiary)
        }
    }

    private func failureHelp(_ record: ServerTrackRecord) -> String {
        let tests = "\(record.tests) test\(record.tests == 1 ? "" : "s")"
        let reason = record.lastProblem.map { " Last problem: \($0)." } ?? ""
        if record.lookups == 0 { return "Couldn't be set up in \(tests).\(reason)" }
        return "Didn't answer any of \(record.lookups.formatted()) lookup\(record.lookups == 1 ? "" : "s") in \(tests).\(reason)"
    }

    private func tooltip(_ record: ServerTrackRecord) -> String {
        var parts = ["Average of \(record.answered.formatted()) answered lookup\(record.answered == 1 ? "" : "s") in \(record.tests) test\(record.tests == 1 ? "" : "s") (\(scope.summary(on: network)))"]
        if let rank = row.speedRank { parts.append("#\(rank) of \(row.rankedCount) by average") }
        parts.append("\(Format.percent(record.successRate)) answered")
        if record.wins > 0 { parts.append("won \(record.wins) test\(record.wins == 1 ? "" : "s")") }
        if let last = record.lastTested { parts.append("last tested \(Format.date(last))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Editor

struct ServerEditor: View {
    @State var server: DNSServer
    let isNew: Bool
    let onSave: (DNSServer) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var test: TestState = .idle

    enum TestState: Equatable {
        case idle
        case running
        case success(Double)
        case failure(String)
    }

    private var validationMessage: String? {
        if server.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the server a name." }
        if server.isSystem { return nil }
        let address = server.address.trimmingCharacters(in: .whitespaces)
        switch server.proto {
        case .udp:
            if address.isEmpty { return "Enter the server's IP address." }
            if !SocketAddress.isIPAddress(address), DomainParser.normalize(address) == nil {
                return "That doesn't look like an IP address or host name."
            }
        case .dot:
            if address.isEmpty { return "Enter the server's host name, e.g. dns.quad9.net." }
            if !SocketAddress.isIPAddress(address), DomainParser.normalize(address) == nil {
                return "That doesn't look like a host name or IP address."
            }
        case .doh:
            guard let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil else {
                return "Enter a full https:// URL, e.g. https://dns.example.com/dns-query"
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ServerAvatar(name: server.avatarName.isEmpty ? "?" : server.avatarName, color: server.color, isSystem: server.isSystem, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "Add DNS Server" : "Edit DNS Server").font(.title3.weight(.bold))
                    Text(server.isSystem ? "Follows the DNS server your Mac is using." : "Any public or private resolver you want to compare.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Form {
                Section {
                    TextField("Name", text: $server.name, prompt: Text("e.g. Cloudflare"))
                    TextField("Provider", text: $server.provider, prompt: Text("Used for grouping and the icon"))
                    LabeledContent("Colour") {
                        ColorSwatchPicker(hex: $server.colorHex, automaticHex: Palette.automaticHex(for: server.avatarName))
                    }
                }
                Section {
                    if server.isSystem {
                        LabeledContent("Address") {
                            Text(server.displayAddress).font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Protocol", selection: $server.proto) {
                            ForEach(DNSProtocol.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: server.proto) { _, proto in
                            server.port = proto.defaultPort
                        }
                        TextField(addressLabel, text: $server.address, prompt: Text(addressPrompt))
                            .font(.body.monospaced())
                        if server.proto != .doh {
                            TextField("Port", value: $server.port, format: .number.grouping(.never), prompt: Text(String(server.proto.defaultPort)))
                        }
                    }
                } footer: {
                    switch server.proto {
                    case .udp:
                        EmptyView()
                    case .dot:
                        Text("DNS-over-TLS is encrypted and as quick as plain DNS once connected. macOS network settings can't use it directly; install it as an encrypted DNS profile instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .doh:
                        Text("DNS-over-HTTPS is encrypted, but macOS network settings can't use it directly — it's mainly for browsers and DNS apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Notes", text: $server.notes, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(1...3)
                    Toggle("Include in tests", isOn: $server.isEnabled)
                }
                Section {
                    HStack {
                        Button {
                            runTest()
                        } label: {
                            Label("Test Connection", systemImage: "bolt.horizontal")
                        }
                        .disabled(validationMessage != nil || test == .running)
                        Spacer()
                        testStatus
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Server" : "Save") {
                    var saved = server
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.provider = saved.provider.trimmingCharacters(in: .whitespaces)
                    saved.address = saved.address.trimmingCharacters(in: .whitespaces)
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
    }

    private var addressLabel: String {
        switch server.proto {
        case .udp: "IP address"
        case .dot: "Host name"
        case .doh: "DoH URL"
        }
    }

    private var addressPrompt: String {
        switch server.proto {
        case .udp: "e.g. 1.1.1.1 or 2606:4700:4700::1111"
        case .dot: "e.g. dns.quad9.net"
        case .doh: "https://dns.example.com/dns-query"
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch test {
        case .idle:
            Text("Sends 3 lookups for apple.com").font(.caption).foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .success(let ms):
            Label("Answered in \(Format.ms(ms))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let reason):
            Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
        }
    }

    private func runTest() {
        let candidate = server
        test = .running
        Task {
            let prepared = await Task.detached { DNSProber.prepare(candidate) }.value
            switch prepared {
            case .failure(let error):
                test = .failure(error.localizedDescription)
            case .success(let target):
                // Its own connections, so a test running at the same time keeps its own.
                let dot = DoTClient(), doh = DoHClient()
                defer { dot.reset(); doh.reset() }
                var times: [Double] = []
                var lastFailure = "No answer"
                for _ in 0..<3 {
                    let result = await DNSProber.probe(target, name: "apple.com", type: .a, timeout: 3, dot: dot, doh: doh)
                    if result.status.isSuccess {
                        times.append(result.latencyMs)
                    } else {
                        lastFailure = result.detail ?? (result.status == .timeout ? "Timed out" : "Failed")
                    }
                }
                // The first encrypted lookup includes the TLS handshake, so report the best answer.
                test = times.min().map { .success($0) } ?? .failure(lastFailure)
            }
        }
    }
}
