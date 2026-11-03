import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var networks: NetworkStore
    @State private var selection: BenchmarkRun.ID?
    @State private var networkFilter = NetworkFilterOption.all
    @State private var showClearConfirm = false
    /// The newest saved test when History was last on screen.
    @State private var newestSeen: BenchmarkRun.ID?
    @State private var listWidth: CGFloat = 260

    var body: some View {
        Group {
            if store.history.isEmpty {
                ContentUnavailableView(
                    "No tests yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Every finished test is saved here so you can compare results over time.")
                )
            } else {
                let options = NetworkFilterOption.options(history: store.history, networks: networks)
                let filter = options.contains { $0.id == networkFilter } ? networkFilter : NetworkFilterOption.all
                let runs = store.history.filter { NetworkFilterOption.matches($0, filter: filter) }
                // Not `HSplitView`: AppKit re-lays out a split view's panes on every window resize, even while History
                // is kept alive behind another section.
                HistorySplit(listWidth: listWidth, minListWidth: 230, minDetailWidth: 520) {
                    List(selection: $selection) {
                        Picker("Network", selection: Binding(get: { filter }, set: { networkFilter = $0 })) {
                            ForEach(options) { option in
                                Text(option.id == NetworkFilterOption.all ? option.name : "\(option.name) (\(option.count))").tag(option.id)
                            }
                        }
                        .help("Show tests from one network only")
                        .listRowSeparator(.hidden)
                        if runs.count > 1 {
                            Section {
                                HistoryTrend(history: runs, metric: store.settings.rankingMetric)
                                    .listRowSeparator(.hidden)
                            }
                        }
                        Section("\(runs.count) saved test\(runs.count == 1 ? "" : "s")") {
                            ForEach(runs) { run in
                                HistoryRow(run: run, metric: store.settings.rankingMetric)
                                    .tag(run.id)
                                    .contextMenu {
                                        ExportMenu(run: run, metric: store.settings.rankingMetric)
                                        Divider()
                                        Button("Delete", role: .destructive) { delete(run.id, from: runs) }
                                    }
                            }
                        }
                    }
                    .sectionDeleteCommand { if let selection { delete(selection, from: runs) } }
                    .onChange(of: filter) { _, _ in
                        if !runs.contains(where: { $0.id == selection }) { selection = runs.first?.id }
                    }

                    SplitDivider(width: $listWidth, range: 230...320)
                        .zIndex(1)

                    ScrollView {
                        if let run = store.history.first(where: { $0.id == selection }) {
                            ResultsView(run: run)
                                .padding(24)
                                .resultsPageWidth(1200)
                                .frame(maxWidth: .infinity)
                        } else {
                            ContentUnavailableView("Select a test", systemImage: "list.bullet.rectangle")
                                .padding(.top, 120)
                        }
                    }
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .providesContentWidthLimit(padding: 24)
                }
                .coordinateSpace(.named(SplitDivider.space))
            }
        }
        .sectionChrome(title: "History") {
            ToolbarItem(placement: .primaryAction) {
                Button { showClearConfirm = true } label: { Label("Clear History", systemImage: "trash") }
                    .disabled(store.history.isEmpty)
                    .help("Delete all saved tests")
            }
        }
        .confirmationDialog("Delete all \(store.history.count) saved tests?", isPresented: $showClearConfirm) {
            Button("Delete All", role: .destructive) {
                store.history.removeAll()
                selection = nil
            }
        }
        .onSectionActivated(perform: showNewestIfNeeded)
    }

    /// The page stays alive while another section is shown. Coming back, it keeps your place, unless a test was
    /// saved in the meantime or the selected one is gone: then it shows the newest test from every network.
    private func showNewestIfNeeded() {
        let newest = store.history.first?.id
        defer { newestSeen = newest }
        guard newest != newestSeen || selection == nil || !store.history.contains(where: { $0.id == selection }) else { return }
        networkFilter = NetworkFilterOption.all
        selection = newest
    }

    /// Deletes a test; if it was selected, selects its neighbour in the list as filtered (`runs`).
    private func delete(_ id: UUID, from runs: [BenchmarkRun]) {
        let index = runs.firstIndex { $0.id == id }
        store.deleteRuns([id])
        if selection == id {
            let remaining = runs.filter { $0.id != id }
            selection = index.flatMap { remaining.indices.contains($0) ? remaining[$0].id : remaining.last?.id }
        }
    }
}

/// The list, its divider and the detail side by side. Like a split view, it narrows the list (down to its minimum)
/// rather than push the detail out of a narrow window.
private struct HistorySplit: Layout {
    let listWidth: CGFloat
    let minListWidth: CGFloat
    let minDetailWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let minWidth = minListWidth + SplitDivider.width + minDetailWidth
        let size = proposal.replacingUnspecifiedDimensions()
        return CGSize(width: max(proposal.width ?? minWidth, minWidth), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let list = max(min(listWidth, bounds.width - SplitDivider.width - minDetailWidth), minListWidth)
        var x = bounds.minX
        for (subview, width) in zip(subviews, [list, SplitDivider.width, bounds.width - list - SplitDivider.width]) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }
}

/// A split view's divider: a hairline you can drag a few points either side of, or adjust with VoiceOver.
private struct SplitDivider: View {
    static let width: CGFloat = 1
    static let space = "historySplit"
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: Self.width)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        // Follows the pointer, so the divider stays under it even where the window is too narrow
                        // for the list to grow.
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                            .onChanged { drag in setWidth(drag.location.x) }
                    )
            }
            .background(SplitterAccessibility(value: width) { setWidth(width + $0) })
    }

    private func setWidth(_ value: CGFloat) {
        width = min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The divider as VoiceOver sees it: an adjustable splitter, as `HSplitView`'s was. SwiftUI has no splitter role.
private struct SplitterAccessibility: NSViewRepresentable {
    let value: CGFloat
    let adjust: (CGFloat) -> Void

    func makeNSView(context: Context) -> SplitterView { SplitterView() }

    func updateNSView(_ view: SplitterView, context: Context) {
        view.value = value
        view.adjust = adjust
    }

    final class SplitterView: NSView {
        var value: CGFloat = 0
        var adjust: (CGFloat) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
        override func accessibilityLabel() -> String? { "Test list width" }
        override func accessibilityValue() -> Any? { NSNumber(value: Double(value)) }
        override func accessibilityOrientation() -> NSAccessibilityOrientation { .vertical }
        override func accessibilityPerformIncrement() -> Bool { adjust(10); return true }
        override func accessibilityPerformDecrement() -> Bool { adjust(-10); return true }
    }
}

private struct HistoryRow: View {
    let run: BenchmarkRun
    let metric: RankingMetric
    @EnvironmentObject private var networks: NetworkStore

    var body: some View {
        let winner = run.winner(by: metric)
        HStack(spacing: 10) {
            if let winner {
                ServerAvatar(name: winner.avatarName, color: winner.color, isSystem: winner.isSystem, size: 30)
            } else {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(winner?.name ?? "No answers").fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    if let winner {
                        Text(Format.ms(winner.value(for: metric)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(Format.date(run.date)).font(.caption)
                    if let trigger = run.runTrigger {
                        TagLabel(text: "AUTO", color: .purple)
                            .help(trigger.title)
                    }
                }
                Label(networks.name(for: run), systemImage: run.networkID.flatMap { networks.profile($0)?.kind.icon } ?? "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(run.results.count) servers · \(run.domains.count) sites · \(run.rounds) rnd · \(run.mode.title)")
                    if run.status == .cancelled { TagLabel(text: "STOPPED", color: .orange) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A small sparkline of the winning time across saved tests (oldest → newest).
private struct HistoryTrend: View {
    let history: [BenchmarkRun]
    let metric: RankingMetric

    var body: some View {
        let values = history.reversed().compactMap { $0.winner(by: metric)?.value(for: metric) }.filter(\.isFinite)
        VStack(alignment: .leading, spacing: 6) {
            Text("BEST TIME PER TEST")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            if values.count > 1, let low = values.min(), let high = values.max() {
                Sparkline(values: values, low: low, high: high)
                    .frame(height: 38)
                HStack {
                    Text("best \(Format.ms(low))")
                    Spacer()
                    Text("latest \(Format.ms(values.last ?? 0))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct Sparkline: View {
    let values: [Double]
    let low: Double
    let high: Double
    @Environment(\.accent) private var accent

    var body: some View {
        GeometryReader { geometry in
            let span = max(high - low, 0.001)
            let step = geometry.size.width / CGFloat(max(values.count - 1, 1))
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step, y: geometry.size.height * (1 - CGFloat((value - low) / span)) * 0.9 + 2)
            }
            ZStack {
                Path { path in
                    path.addLines(points)
                }
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle().fill(accent).frame(width: 6, height: 6).position(last)
                }
            }
        }
    }
}
