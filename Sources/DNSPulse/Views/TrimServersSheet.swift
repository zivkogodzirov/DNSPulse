import SwiftUI

enum TrimAction: String, CaseIterable, Identifiable {
    case switchOff, delete

    var id: String { rawValue }
    var title: String { self == .switchOff ? "Switch Off" : "Delete" }
}

/// Lists servers from slowest to fastest (using saved tests) so the slow ones can be removed in one go.
struct TrimServersSheet: View {
    let rows: [ServerRow]
    let scope: HistoryScope
    let network: NetworkScope
    let onApply: (Set<UUID>, TrimAction) -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var action: TrimAction = .switchOff
    @State private var slowestCount = 3
    @State private var includeOff = false

    private var candidates: [ServerRow] {
        rows.filter { $0.record != nil && (includeOff || $0.server.isEnabled) }
            .sorted { $0.averageSort > $1.averageSort }
    }

    private var untested: [ServerRow] {
        rows.filter { $0.record == nil && $0.server.isEnabled }
    }

    /// Rows "Select" may pick: switched on, and never your current system DNS (kept as a baseline).
    private var selectable: [ServerRow] {
        candidates.filter { $0.server.isEnabled && !$0.server.isSystem }
    }

    /// Only rows on screen can be acted on, so hiding switched-off servers also drops them from the selection.
    private var effectiveSelection: Set<UUID> {
        selected.intersection((candidates + untested).map(\.id))
    }

    var body: some View {
        let list = candidates
        let averages = list.compactMap { $0.record?.average }.filter(\.isFinite)
        let low = averages.min() ?? 1
        let high = averages.max() ?? 1

        VStack(spacing: 0) {
            header
            quickSelectBar(list)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Slowest first · \(scope.summary(on: network))")
                    ForEach(list) { row in
                        TrimRow(row: row, isSelected: binding(row.id), low: low, high: high)
                        Divider().padding(.leading, 52)
                    }
                    if !untested.isEmpty {
                        sectionTitle(scope.notTestedLabel(on: network))
                        ForEach(untested) { row in
                            TrimRow(row: row, isSelected: binding(row.id), low: low, high: high)
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 700, height: 640)
        .onAppear {
            slowestCount = slowestCount.clamped(1, max(1, selectable.count))
            selectSlowest()
        }
        .onChange(of: includeOff) { _, _ in
            selected = effectiveSelection
            slowestCount = slowestCount.clamped(1, max(1, selectable.count))
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "scissors")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.red.gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text("Trim Slowest Servers").font(.title3.weight(.bold))
                Text("Ranked by average response time across your saved tests\(network == .thisNetwork ? " on this network" : ""). Remove the slow ones so your next tests are quicker and easier to read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private func quickSelectBar(_ list: [ServerRow]) -> some View {
        HStack(spacing: 10) {
            Stepper(value: $slowestCount, in: 1...max(1, selectable.count)) {
                Text("Slowest \(slowestCount)").monospacedDigit()
            }
            .fixedSize()
            .disabled(selectable.isEmpty)
            Button("Select") { selectSlowest() }
                .disabled(selectable.isEmpty)
            Button("Add Unreliable") {
                selected.formUnion(list.filter { row in
                    !row.server.isSystem && (row.record.map { $0.successRate < 0.95 } ?? false)
                }.map(\.id))
            }
            .help("Also select servers that answered less than 95% of lookups")
            Button("Clear") { selected.removeAll() }
                .disabled(effectiveSelection.isEmpty)
            Spacer()
            Toggle("Include switched-off servers", isOn: $includeOff)
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private var footer: some View {
        let chosen = effectiveSelection
        let remaining = store.servers.filter { $0.isEnabled && !chosen.contains($0.id) }.count
        let websites = store.testDomains.count
        let rounds = store.settings.rounds
        let before = store.enabledServers.count * websites * rounds
        let after = remaining * websites * rounds

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Action", selection: $action) {
                    ForEach(TrimAction.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Text(action == .switchOff
                    ? "Switched-off servers stay in your list; turn them back on any time."
                    : "Deleted servers are removed. Built-in ones can be brought back with Restore Default Servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if before > 0 {
                    Label("Next test: \(remaining) server\(remaining == 1 ? "" : "s") · \(after.formatted()) lookups (now \(before.formatted()))", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.callout)
                        .foregroundStyle(remaining == 0 ? .red : .secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(applyTitle, role: action == .delete ? .destructive : nil) {
                    onApply(chosen, action)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(16)
    }

    private var applyTitle: String {
        let count = effectiveSelection.count
        return "\(action.title) \(count) Server\(count == 1 ? "" : "s")"
    }

    /// Picks the slowest switched-on servers; your current system DNS is kept as a baseline.
    private func selectSlowest() {
        selected = Set(selectable.prefix(slowestCount).map(\.id))
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }
}

private struct TrimRow: View {
    let row: ServerRow
    @Binding var isSelected: Bool
    let low: Double
    let high: Double

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Remove \(row.server.name)", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
            ServerAvatar(name: row.server.avatarName, color: row.server.color, isSystem: row.server.isSystem, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.server.name).fontWeight(.medium).lineLimit(1)
                    ProtocolBadge(proto: row.server.proto)
                    if row.server.isSystem { TagLabel(text: "CURRENT", color: .blue) }
                    if !row.server.isEnabled { TagLabel(text: "OFF") }
                }
                Text(row.server.displayAddress)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let record = row.record {
                if record.hasAnswers {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(Format.ms(record.average)).font(.body.monospacedDigit().weight(.semibold))
                        LatencyBar(fraction: Heat.barFraction(for: record.average, low: low, high: high), color: Heat.logColor(for: record.average, low: low, high: high))
                            .frame(width: 120)
                    }
                    .frame(width: 130, alignment: .trailing)
                } else {
                    Label(record.lookups == 0 ? "Couldn't connect" : "No answers", systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(width: 130, alignment: .trailing)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    ReliabilityLabel(rate: record.successRate, attempts: record.lookups)
                    Text("\(record.tests) test\(record.tests == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 90, alignment: .trailing)
            } else {
                Text("No data")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(width: 228, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(isSelected ? Color.red.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
    }
}
