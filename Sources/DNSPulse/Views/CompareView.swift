import Charts
import SwiftUI

/// Up to five servers side by side, each measured against a baseline (your current DNS unless you pick another),
/// with whether each difference is real or within measurement noise.
struct CompareView: View {
    let run: BenchmarkRun
    let ranked: [ServerResult]
    let metric: RankingMetric
    let isLive: Bool

    @ObservedObject private var selection = CompareSelection.shared

    var body: some View {
        let servers = selection.servers(in: run, metric: metric)
        let baseline = selection.baseline(among: servers, in: run)
        VStack(alignment: .leading, spacing: 16) {
            CompareControls(run: run, ranked: ranked, metric: metric, servers: servers, baseline: baseline, isLive: isLive)

            if let baseline, servers.count >= 2 {
                if isLive {
                    Label("Verdicts appear when the test finishes.", systemImage: "hourglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VerdictCards(run: run, servers: servers, baseline: baseline, metric: metric)
                }
                CompareTable(servers: servers, baseline: baseline, destinations: isLive ? nil : run.destinations)
                if servers.filter({ $0.successes > 0 }).count >= 2 {
                    CompareCard(title: "How quickly lookups finish", subtitle: "Share of lookups answered within each time · higher and further left is better · hover to read any time", icon: "chart.line.uptrend.xyaxis") {
                        SpeedCurveChart(servers: servers.filter { $0.successes > 0 })
                    }
                }
                CompareCard(title: "Websites", subtitle: "Average time per website among these servers", icon: "globe") {
                    WebsiteComparison(run: run, servers: servers)
                }
                if !isLive {
                    PastTestsCard(run: run, servers: servers, baseline: baseline, metric: metric)
                }
            } else {
                ContentUnavailableView("Pick at least two servers", systemImage: "rectangle.split.3x1",
                                       description: Text("Add servers with Add Server above, or right-click a server in the Leaderboard."))
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .card()
            }
        }
    }
}

private struct CompareCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title, subtitle: subtitle, icon: icon)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }
}

// MARK: - Picking servers

private struct CompareControls: View {
    let run: BenchmarkRun
    let ranked: [ServerResult]
    let metric: RankingMetric
    let servers: [ServerResult]
    let baseline: ServerResult?
    let isLive: Bool

    @ObservedObject private var selection = CompareSelection.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Comparing \(servers.count) of up to \(CompareSelection.limit)")
                    .font(.callout.weight(.medium))
                if servers.count >= 2 {
                    Picker("Baseline", selection: baselineBinding) {
                        ForEach(servers) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .fixedSize()
                    .help("Every other server is compared with this one. Your current DNS is the baseline unless you pick another.")
                }
                Spacer()
                addMenu
                if !isLive, servers.count >= 2 {
                    RetestButton(run: run, contenders: servers, limit: CompareSelection.limit, title: "Re-test These")
                }
            }
            FlowLayout(spacing: 8) {
                ForEach(servers) { server in
                    CompareChip(result: server, isBaseline: server.id == baseline?.id) {
                        selection.remove(server, in: run, metric: metric)
                    }
                }
            }
        }
    }

    private var baselineBinding: Binding<UUID?> {
        Binding(get: { baseline?.id }, set: { id in
            if let id { selection.makeBaseline(id, in: run, metric: metric) }
        })
    }

    private var addMenu: some View {
        let isFull = servers.count >= CompareSelection.limit
        let candidates = ranked.filter { result in result.successes > 0 && !servers.contains { $0.id == result.id } }
        return Menu {
            if isFull {
                Text("Remove a server to add another")
            }
            ForEach(candidates) { result in
                Button("\(result.name) · \(Format.ms(result.value(for: metric)))") {
                    selection.add(result, in: run, metric: metric)
                }
                .disabled(isFull)
            }
            Divider()
            Button("Back to Suggested Servers") { selection.reset(run) }
                .disabled(!selection.isChanged(run))
        } label: {
            Label("Add Server", systemImage: "plus")
        }
        .fixedSize()
    }
}

private struct CompareChip: View {
    let result: ServerResult
    let isBaseline: Bool
    let remove: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 6) {
            ServerAvatar(name: result.avatarName, color: result.color, isSystem: result.isSystem, size: 18)
            Text(result.name).font(.callout).lineLimit(1)
            ProtocolBadge(proto: result.proto)
            if isBaseline { TagLabel(text: "BASELINE", color: accent) }
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from the comparison")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(isBaseline ? accent.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: isBaseline ? 1.5 : 1))
    }
}

/// Lays its views out in rows, starting a new row when the next one doesn't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(width: bounds.width, subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

// MARK: - Verdicts

private struct VerdictCards: View {
    let run: BenchmarkRun
    let servers: [ServerResult]
    let baseline: ServerResult
    let metric: RankingMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Compared with \(baseline.name)",
                          subtitle: "By \(metric.title.lowercased()), the Rank by setting · “clearly” means the difference is more than measurement noise",
                          icon: "arrow.left.arrow.right")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(servers.filter { $0.id != baseline.id }) { server in
                    VerdictCard(run: run, result: server, baseline: baseline, metric: metric)
                }
            }
        }
    }
}

private struct VerdictCard: View {
    let run: BenchmarkRun
    let result: ServerResult
    let baseline: ServerResult
    let metric: RankingMetric

    var body: some View {
        let verdict = ComparisonVerdict(result, against: baseline, metric: metric, in: run)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ServerAvatar(name: result.avatarName, color: result.color, isSystem: result.isSystem, size: 20)
                Text(result.name).font(.callout.weight(.medium)).lineLimit(1)
                ProtocolBadge(proto: result.proto)
            }
            if let verdict {
                Text(verdict.headline)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(verdict.kind == .same ? .secondary : .primary)
                Text("\(Format.ms(baseline.value(for: metric))) → \(Format.ms(result.value(for: metric))) \(metric.shortTitle)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                VerdictBadge(kind: verdict.kind)
                Text(explanation(verdict))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No answers in this test").font(.callout).foregroundStyle(.secondary)
            }
            if run.interceptionDetected == true, result.proto == .udp, !result.isSystem {
                Label("Plain DNS is intercepted here, so this mostly measures your router or ISP.", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(padding: 14)
    }

    private func explanation(_ verdict: ComparisonVerdict) -> String {
        let ms = Format.ms(abs(verdict.difference))
        switch verdict.kind {
        case .faster: return "About \(ms) less per lookup."
        case .slower: return "About \(ms) more per lookup."
        case .same: return verdict.isSmall ? "Less than 3% apart." : "Within measurement noise: more rounds could tell them apart."
        case .untested: return "A single fastest answer can't be tested for noise. Rank by another measure for a verdict."
        }
    }
}

private struct VerdictBadge: View {
    let kind: ComparisonVerdict.Kind

    var body: some View {
        let (text, icon, color): (String, String, Color) = switch kind {
        case .faster: ("Clearly faster", "checkmark.circle.fill", .green)
        case .slower: ("Clearly slower", "arrow.down.circle.fill", .orange)
        case .same: ("No real difference", "equal.circle.fill", .secondary)
        case .untested: ("Not tested for noise", "questionmark.circle.fill", .secondary)
        }
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Side by side

private struct CompareTable: View {
    let servers: [ServerResult]
    let baseline: ServerResult
    /// Adds rows on how near the servers each DNS sent you to were, once they've been checked.
    let destinations: DestinationReport?

    @Environment(\.accent) private var accent

    private struct Measure: Identifiable {
        enum Unit { case ms, rate, websites }

        let title: String
        let help: String
        let value: (ServerResult) -> Double
        var higherIsBetter = false
        var unit = Unit.ms
        var id: String { title }
    }

    private var measures: [Measure] {
        guard let destinations, destinations.isChecked else { return lookupMeasures }
        return lookupMeasures + [
            Measure(title: "Server distance", help: "Median time to connect to the servers this DNS sent you to. Lower means nearer copies of the websites.",
                    value: { destinations.summaries[$0.id]?.medianTime ?? .nan }),
            Measure(title: "Sent farther on", help: "Websites where this DNS sent you to a clearly farther server than the nearest any DNS found.",
                    value: { destinations.summaries[$0.id].map { Double($0.farther) } ?? .nan }, unit: .websites),
        ]
    }

    private let lookupMeasures: [Measure] = [
        Measure(title: "Overall score", help: RankingMetric.score.help, value: \.score),
        Measure(title: "Average", help: RankingMetric.average.help, value: { $0.stats.mean }),
        Measure(title: "Median", help: RankingMetric.median.help, value: { $0.stats.median }),
        Measure(title: "95th percentile", help: RankingMetric.p95.help, value: { $0.stats.p95 }),
        Measure(title: "Fastest", help: RankingMetric.minimum.help, value: { $0.stats.minimum }),
        Measure(title: "Slowest", help: "The slowest answered lookup.", value: { $0.stats.maximum }),
        Measure(title: "Jitter", help: "How much response times vary (standard deviation). Lower is steadier.", value: { $0.stats.stdDev }),
        Measure(title: "Answered", help: "Share of lookups that got an answer.", value: { $0.attempts > 0 ? $0.successRate : .nan },
                higherIsBetter: true, unit: .rate),
    ]

    var body: some View {
        CompareCard(title: "Side by side", subtitle: "Best in each row is highlighted · percentages are against the baseline", icon: "tablecells") {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1).gridColumnAlignment(.leading)
                    ForEach(servers) { server in
                        VStack(alignment: .trailing, spacing: 3) {
                            ServerAvatar(name: server.avatarName, color: server.color, isSystem: server.isSystem, size: 22)
                            Text(server.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.trailing)
                            if server.id == baseline.id { TagLabel(text: "BASELINE", color: accent) }
                        }
                        .frame(minWidth: 96, maxWidth: 170, alignment: .trailing)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(measures) { measure in
                    row(measure)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ measure: Measure) -> some View {
        let values = servers.map { measure.value($0) }
        let finite = values.filter(\.isFinite)
        // Nothing stands out when every server has the same value, such as all answering 100%.
        let best = Set(finite).count > 1 ? (measure.higherIsBetter ? finite.max() : finite.min()) : nil
        let base = measure.value(baseline)
        GridRow {
            Text(measure.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(measure.help)
            ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                let value = values[index]
                let isBest = value.isFinite && value == best
                VStack(alignment: .trailing, spacing: 1) {
                    Text(text(value, measure: measure, server: server))
                        .font(.callout.monospacedDigit().weight(isBest ? .bold : .regular))
                    if server.id != baseline.id, let change = change(value, from: base, measure: measure) {
                        Text(change).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isBest ? accent.opacity(0.12) : .clear))
            }
        }
    }

    private func text(_ value: Double, measure: Measure, server: ServerResult) -> String {
        guard value.isFinite else { return "—" }
        switch measure.unit {
        case .ms: return Format.ms(value)
        case .rate: return Format.percent(value)
        case .websites:
            let total = destinations?.summaries[server.id]?.websites ?? 0
            return "\(Int(value)) of \(total)"
        }
    }

    /// "33% less" or "20% more" time than the baseline; for the answered share, the difference in points; for
    /// websites, the difference in websites.
    private func change(_ value: Double, from base: Double, measure: Measure) -> String? {
        guard value.isFinite, base.isFinite else { return nil }
        switch measure.unit {
        case .rate:
            let points = (value - base) * 100
            return abs(points) < 0.05 ? "same" : String(format: "%+.1f pts", points)
        case .websites:
            let difference = Int(value - base)
            return difference == 0 ? "same" : String(format: "%+d", difference)
        case .ms:
            break
        }
        guard base > 0 else { return nil }
        let percent = Int(((value - base) / base * 100).rounded())
        if percent == 0 { return "same" }
        return percent < 0 ? "\(-percent)% less" : "\(percent)% more"
    }
}

// MARK: - Speed curve

/// For each server, the share of its lookups answered within each time. Failed lookups count as never answered, so
/// a curve tops out at the server's answered share.
private struct SpeedCurveChart: View {
    let servers: [ServerResult]

    @State private var hovered: Double?

    private struct Series: Identifiable {
        let id: UUID
        let name: String
        let color: Color
        let style: StrokeStyle
        let sorted: [Double]
        let attempts: Int

        /// Share of all lookups answered within `ms`.
        func share(within ms: Double) -> Double {
            guard attempts > 0 else { return 0 }
            var low = 0
            var high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if sorted[middle] <= ms { low = middle + 1 } else { high = middle }
            }
            return Double(low) / Double(attempts)
        }
    }

    private struct Point: Identifiable {
        let id: String
        let series: String
        let ms: Double
        let share: Double
    }

    /// Lines a solid, dashed or dotted stroke, so two servers with the same colour (such as one provider's DoT and
    /// DoH) still look different.
    private static let strokes: [StrokeStyle] = [
        StrokeStyle(lineWidth: 2, lineCap: .round),
        StrokeStyle(lineWidth: 2, lineCap: .round, dash: [7, 4]),
        StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 4]),
        StrokeStyle(lineWidth: 2, lineCap: .round, dash: [9, 4, 1, 4]),
        StrokeStyle(lineWidth: 2, lineCap: .round, dash: [14, 5]),
    ]

    var body: some View {
        let series = makeSeries()
        let limit = xLimit(series)
        let marked = min(max(hovered ?? defaultMark(limit), 0), limit)
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(series) { line in
                    ForEach(points(line, limit: limit)) { point in
                        LineMark(x: .value("Milliseconds", point.ms), y: .value("Answered", point.share), series: .value("Server", point.series))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(line.color)
                            .lineStyle(line.style)
                    }
                }
                RuleMark(x: .value("Within", marked))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXScale(domain: 0...limit)
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(Int(((value.as(Double.self) ?? 0) * 100).rounded()))%") }
                }
            }
            .chartXAxisLabel("milliseconds")
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame else { return }
                                let x = location.x - geometry[frame].origin.x
                                hovered = proxy.value(atX: x, as: Double.self).map { $0.rounded() }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 260)

            VStack(alignment: .leading, spacing: 6) {
                Text("Answered within \(Int(marked)) ms")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 16) {
                    ForEach(series) { line in
                        HStack(spacing: 6) {
                            LineSwatch(color: line.color, style: line.style)
                            Text(line.name).font(.caption)
                            Text(Format.percent(line.share(within: marked)))
                                .font(.caption.monospacedDigit().weight(.semibold))
                        }
                    }
                }
            }
        }
    }

    private func makeSeries() -> [Series] {
        var seenColors: [String: Int] = [:]
        return servers.map { server in
            let repeats = seenColors[server.colorHex.lowercased(), default: 0]
            seenColors[server.colorHex.lowercased()] = repeats + 1
            return Series(id: server.id, name: server.name, color: server.color, style: Self.strokes[repeats % Self.strokes.count],
                          sorted: server.latencies.sorted(), attempts: server.attempts)
        }
    }

    /// Wide enough for the bulk of every server's lookups: a little past the slowest server's 90th percentile,
    /// rounded up. The slow tail beyond it would squeeze the part where servers differ into the left edge; the
    /// readout still covers it.
    private func xLimit(_ series: [Series]) -> Double {
        let p90 = (series.map { LatencyStats.percentile($0.sorted, 0.9) }.filter(\.isFinite).max() ?? 100) * 1.25
        let step: Double = p90 <= 50 ? 10 : p90 <= 200 ? 25 : p90 <= 1000 ? 100 : 500
        return max(step, (p90 / step).rounded(.up) * step)
    }

    /// Where the readout points when the pointer isn't over the chart: 50 ms when that's in view.
    private func defaultMark(_ limit: Double) -> Double {
        limit > 60 ? 50 : (limit / 2).rounded()
    }

    /// The curve as steps, thinned to at most about 200 points per server, from 0 ms to the right edge.
    private func points(_ line: Series, limit: Double) -> [Point] {
        guard !line.sorted.isEmpty, line.attempts > 0 else { return [] }
        let stride = max(1, line.sorted.count / 200)
        var points = [Point(id: "\(line.id)-start", series: line.name, ms: 0, share: 0)]
        var index = stride - 1
        while index < line.sorted.count, line.sorted[index] <= limit {
            points.append(Point(id: "\(line.id)-\(index)", series: line.name, ms: line.sorted[index], share: Double(index + 1) / Double(line.attempts)))
            index += stride
        }
        points.append(Point(id: "\(line.id)-end", series: line.name, ms: limit, share: line.share(within: limit)))
        return points
    }
}

private struct LineSwatch: View {
    let color: Color
    let style: StrokeStyle

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 1, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
            context.stroke(path, with: .color(color), style: style)
        }
        .frame(width: 24, height: 8)
    }
}

// MARK: - Websites

private struct WebsiteComparison: View {
    let run: BenchmarkRun
    let servers: [ServerResult]

    var body: some View {
        let (wins, websites) = run.websiteWins(among: servers)
        let differences = run.biggestDifferences(among: servers, count: 6)
        if websites == 0 {
            Text("No website was answered by two of these servers yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 32) {
                    winsList(wins: wins, websites: websites).frame(width: 340)
                    differencesGrid(differences)
                }
                VStack(alignment: .leading, spacing: 20) {
                    winsList(wins: wins, websites: websites)
                    differencesGrid(differences)
                }
            }
        }
    }

    private func winsList(wins: [UUID: Int], websites: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fastest on each website").font(.callout.weight(.semibold))
            ForEach(servers.sorted { wins[$0.id, default: 0] > wins[$1.id, default: 0] }) { server in
                let count = wins[server.id, default: 0]
                HStack(spacing: 8) {
                    ServerAvatar(name: server.avatarName, color: server.color, isSystem: server.isSystem, size: 18)
                    Text(server.name).font(.caption).lineLimit(1).frame(width: 130, alignment: .leading)
                    LatencyBar(fraction: Double(count) / Double(websites), color: server.color)
                    Text("\(count)").font(.caption.monospacedDigit().weight(.semibold)).frame(width: 30, alignment: .trailing)
                }
            }
            Text("Out of \(websites) website\(websites == 1 ? "" : "s") at least two of them answered.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func differencesGrid(_ domains: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where they differ most").font(.callout.weight(.semibold))
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Website").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                    ForEach(servers) { server in
                        Text(server.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 110, alignment: .trailing)
                    }
                }
                ForEach(domains, id: \.self) { domain in
                    let times = servers.map { $0.domainStats[domain]?.mean ?? .infinity }
                    let best = times.min()
                    GridRow {
                        Text(domain).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                        ForEach(Array(times.enumerated()), id: \.offset) { _, time in
                            Text(Format.ms(time))
                                .font(.caption.monospacedDigit().weight(time == best && time.isFinite ? .bold : .regular))
                                .foregroundStyle(time.isFinite ? .primary : .secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Past tests

private struct PastTestsCard: View {
    let run: BenchmarkRun
    let servers: [ServerResult]
    let baseline: ServerResult
    let metric: RankingMetric

    @EnvironmentObject private var store: AppStore

    /// Saved tests on the network this test ran on, or every saved test when this one predates network tagging.
    private var runs: [BenchmarkRun] {
        guard let network = run.networkID else { return store.history }
        return store.history.filter { $0.networkID == network }
    }

    var body: some View {
        let history = ComparisonHistory(servers: servers, baseline: baseline, runs: runs, metric: metric)
        CompareCard(title: "Across your saved tests", subtitle: subtitle(history), icon: "clock.arrow.circlepath") {
            if history.tests < 2 {
                Text("Only one saved test has two or more of these servers so far. Run more tests to see whether these results hold up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text("Server")
                        Text("Fastest of these")
                        Text("Against \(baseline.name)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(servers) { server in
                        let record = history.record(for: server)
                        GridRow {
                            HStack(spacing: 8) {
                                ServerAvatar(name: server.avatarName, color: server.color, isSystem: server.isSystem, size: 18)
                                Text(server.name).font(.callout).lineLimit(1)
                            }
                            Text(record.map { "\($0.fastest) of \($0.tests) test\($0.tests == 1 ? "" : "s")" } ?? "Not in other tests")
                                .font(.callout.monospacedDigit())
                            if server.id == baseline.id {
                                Text("Baseline").font(.callout).foregroundStyle(.secondary)
                            } else if let record, record.againstBaseline > 0 {
                                AgainstBaseline(record: record)
                            } else {
                                Text("Never tested together").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Each test is judged on its own, by \(metric.title.lowercased()), with the same noise test as above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(_ history: ComparisonHistory) -> String {
        let place = run.networkID == nil ? "all networks" : run.networkName ?? "this network"
        let modes = history.modes.map(\.title).joined(separator: ", ")
        return "\(history.tests) test\(history.tests == 1 ? "" : "s") on \(place)" + (modes.isEmpty ? "" : " · \(modes)")
    }
}

private struct AgainstBaseline: View {
    let record: ComparisonHistory.Record

    var body: some View {
        HStack(spacing: 12) {
            count(record.faster, "faster", icon: "checkmark.circle.fill", color: .green)
            count(record.same, "same", icon: "equal.circle.fill", color: .secondary)
            count(record.slower, "slower", icon: "arrow.down.circle.fill", color: .orange)
        }
        .help("Clearly faster in \(record.faster), no real difference in \(record.same), clearly slower in \(record.slower) of the \(record.againstBaseline) tests with both.")
    }

    private func count(_ value: Int, _ label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(value > 0 ? color : Color.secondary.opacity(0.5))
            Text("\(value) \(label)").font(.callout.monospacedDigit()).foregroundStyle(value > 0 ? .primary : .secondary)
        }
    }
}
