import SwiftUI

// MARK: - Benchmark page

/// "Network: Home" chip in the Benchmark control panel.
struct NetworkChip: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var networks: NetworkStore
    @State private var naming: NetworkProfile?
    @State private var showNetworks = false

    private var title: String {
        if let current = networks.current { return current.name }
        return networks.hasChecked ? "Offline" : "Checking…"
    }

    var body: some View {
        let current = networks.current
        Menu {
            if let current {
                Section(current.detail) {
                    Button("Name This Network…") { naming = current }
                }
                let tests = store.history.filter { $0.networkID == current.id }.count
                Text(tests == 0 ? "No saved tests on this network yet" : "\(tests) saved test\(tests == 1 ? "" : "s") on this network")
            } else {
                Text(networks.hasChecked ? "Not connected to a network" : "Checking your network…")
            }
            Divider()
            Button("All Networks…") { showNetworks = true }
        } label: {
            Label("Network: \(title)", systemImage: current?.kind.icon ?? "network.slash")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption.weight(.medium))
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .help("Tests are tagged with the network they ran on, so you can compare home, office and other networks.")
        .accessibilityLabel("Network: \(title)")
        .sheet(item: $naming) { NameNetworkSheet(profile: $0) }
        .sheet(isPresented: $showNetworks) { NetworksSheet() }
    }
}

/// Suggests a quick test the first time DNS Pulse sees a network.
struct NewNetworkBanner: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: BenchmarkEngine
    @EnvironmentObject private var networks: NetworkStore
    @Environment(\.accent) private var accent
    @State private var naming: NetworkProfile?

    var body: some View {
        if let current = networks.current, !current.promptDismissed, !store.history.isEmpty, !engine.isRunning,
           !store.history.contains(where: { $0.networkID == current.id }) {
            HStack(spacing: 12) {
                Image(systemName: current.kind.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(accent.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New network detected — run a quick test?")
                        .fontWeight(.semibold)
                    Text("You haven't tested DNS on “\(current.name)” yet. A quick test runs \(TestOverrides.light.summary) and leaves your settings as they are.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Name Network…") { naming = current }
                Button("Quick Test") { engine.start(store: store, overrides: .light) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.enabledServers.isEmpty || store.enabledWebsites.isEmpty)
                Button { networks.dismissPrompt(for: current.id) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Don't suggest a test for this network again")
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent.opacity(0.18)))
            .sheet(item: $naming) { NameNetworkSheet(profile: $0) }
        }
    }
}

// MARK: - Naming

struct NameNetworkSheet: View {
    let profile: NetworkProfile
    @EnvironmentObject private var networks: NetworkStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                NetworkIcon(kind: profile.kind, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name This Network").font(.title3.weight(.bold))
                    Text(profile.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $name, prompt: Text(profile.name))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack(spacing: 6) {
                    ForEach(NetworkProfile.nameSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { name = suggestion }
                            .buttonStyle(ChipButtonStyle(isSelected: name == suggestion))
                    }
                }
            }

            Text("Tests are tagged with this name, so you can compare networks in History and DNS Servers. First seen \(Format.date(profile.firstSeen)).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = profile.hasCustomName ? profile.name : "" }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        networks.rename(profile.id, to: name)
        dismiss()
    }
}

struct NetworkIcon: View {
    let kind: NetworkKind
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: kind.icon)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Color.teal.gradient))
            .accessibilityHidden(true)
    }
}

// MARK: - Network list (Settings tab and sheet)

/// Known networks with rename and forget.
struct NetworksForm: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var networks: NetworkStore
    @State private var naming: NetworkProfile?
    @State private var forgetting: NetworkProfile?

    var body: some View {
        let counts = Dictionary(grouping: store.history.compactMap(\.networkID), by: { $0 }).mapValues(\.count)
        let others = networks.networks.filter { $0.id != networks.currentID }.sorted { $0.lastSeen > $1.lastSeen }

        Form {
            Section("This network") {
                if let current = networks.current {
                    NetworkListRow(profile: current, tests: counts[current.id] ?? 0, isCurrent: true,
                                   rename: { naming = current }, forget: nil)
                } else {
                    Label(networks.hasChecked ? "Not connected to a network" : "Checking your network…", systemImage: "network.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if others.isEmpty {
                    Text("Networks you use DNS Pulse on will appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(others) { profile in
                    NetworkListRow(profile: profile, tests: counts[profile.id] ?? 0, isCurrent: false,
                                   rename: { naming = profile }, forget: { forgetting = profile })
                }
            } header: {
                Text("Other networks")
            } footer: {
                Text("DNS Pulse recognises a network by its router, without needing Location access. Every test is tagged with the network it ran on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $naming) { NameNetworkSheet(profile: $0) }
        .confirmationDialog(
            "Forget “\(forgetting?.name ?? "")”?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            presenting: forgetting
        ) { profile in
            Button("Forget Network", role: .destructive) { networks.forget(profile.id) }
        } message: { _ in
            Text("Its saved tests stay in History. If you join it again, it will show up as a new network.")
        }
    }
}

private struct NetworkListRow: View {
    let profile: NetworkProfile
    let tests: Int
    let isCurrent: Bool
    let rename: () -> Void
    let forget: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            NetworkIcon(kind: profile.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).fontWeight(.medium).lineLimit(1)
                    if isCurrent { TagLabel(text: "CONNECTED", color: .green) }
                }
                Group {
                    Text(profile.detail)
                    Text("\(tests == 0 ? "No saved tests" : "\(tests) saved test\(tests == 1 ? "" : "s")")\(isCurrent ? "" : " · last seen \(Format.date(profile.lastSeen))")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Rename…", action: rename)
            if let forget {
                Button("Forget…", action: forget)
            }
        }
    }
}

struct NetworksSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NetworksForm()
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: - History

/// One entry in the History network filter.
struct NetworkFilterOption: Identifiable, Hashable {
    static let all = "all"
    static let unknown = "unknown"

    let id: String
    let name: String
    let count: Int

    /// "All networks", then every network that has saved tests (current network first), then "Unknown network".
    @MainActor
    static func options(history: [BenchmarkRun], networks: NetworkStore) -> [NetworkFilterOption] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var fallbackNames: [String: String] = [:]
        var unknown = 0
        for run in history {
            guard let id = run.networkID else {
                unknown += 1
                continue
            }
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
            if fallbackNames[id] == nil { fallbackNames[id] = run.networkName }
        }
        if let current = networks.currentID, let index = order.firstIndex(of: current) {
            order.insert(order.remove(at: index), at: 0)
        }
        var options = [NetworkFilterOption(id: all, name: "All networks", count: history.count)]
        options += order.map { NetworkFilterOption(id: $0, name: networks.name(forID: $0, fallback: fallbackNames[$0]), count: counts[$0] ?? 0) }
        if unknown > 0 { options.append(NetworkFilterOption(id: Self.unknown, name: BenchmarkRun.unknownNetworkName, count: unknown)) }
        return options
    }

    static func matches(_ run: BenchmarkRun, filter: String) -> Bool {
        switch filter {
        case all: true
        case unknown: run.networkID == nil
        default: run.networkID == filter
        }
    }
}
