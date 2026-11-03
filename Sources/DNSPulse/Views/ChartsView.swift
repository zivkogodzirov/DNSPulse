import Charts
import SwiftUI

struct ChartsView: View {
    let run: BenchmarkRun
    let ranked: [ServerResult]
    let metric: RankingMetric

    var body: some View {
        let answered = ranked.filter { $0.successes > 0 }
        VStack(spacing: 16) {
            if answered.isEmpty {
                ContentUnavailableView("No answers yet", systemImage: "chart.bar", description: Text("Charts appear as soon as servers start answering."))
                    .frame(height: 220)
                    .card()
            } else {
                ChartCard(title: "\(metric.title)", subtitle: "Lower is better", icon: "chart.bar.fill") {
                    MetricBarChart(results: answered, metric: metric)
                }
                ChartCard(title: "Consistency", subtitle: "Bar runs from the fastest answer to the 95th percentile · dot is the median", icon: "waveform.path.ecg") {
                    ConsistencyChart(results: answered)
                }
                if run.rounds > 1 {
                    let top = Array(answered.prefix(8))
                    ChartCard(title: "Average per round", subtitle: "Top \(top.count) servers · a flat line means steady performance", icon: "chart.xyaxis.line") {
                        RoundTrendChart(results: top, rounds: run.rounds)
                    }
                }
                ChartCard(title: "Reliability", subtitle: "What happened to every lookup", icon: "checkmark.shield") {
                    ReliabilityChart(results: ranked)
                }
            }
        }
    }
}

private struct ChartCard<Content: View>: View {
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

private func chartHeight(_ count: Int) -> CGFloat {
    max(140, CGFloat(count) * 30 + 36)
}

private struct MetricBarChart: View {
    let results: [ServerResult]
    let metric: RankingMetric

    var body: some View {
        Chart(results) { result in
            let value = result.value(for: metric)
            BarMark(
                x: .value("Milliseconds", value),
                y: .value("Server", result.chartLabel)
            )
            .foregroundStyle(result.color.gradient)
            .cornerRadius(5)
            .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                Text(Format.ms(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxisLabel("milliseconds")
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel() }
        }
        .frame(height: chartHeight(results.count))
    }
}

private struct ConsistencyChart: View {
    let results: [ServerResult]

    var body: some View {
        Chart(results) { result in
            let stats = result.stats
            BarMark(
                xStart: .value("Fastest", stats.minimum),
                xEnd: .value("95th percentile", stats.p95),
                y: .value("Server", result.chartLabel),
                height: 10
            )
            .foregroundStyle(result.color.opacity(0.4))
            .cornerRadius(5)
            PointMark(
                x: .value("Median", stats.median),
                y: .value("Server", result.chartLabel)
            )
            .foregroundStyle(result.color)
            .symbolSize(80)
        }
        .chartXAxisLabel("milliseconds")
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel() }
        }
        .frame(height: chartHeight(results.count))
    }
}

private struct RoundTrendChart: View {
    let results: [ServerResult]
    let rounds: Int

    private struct Point: Identifiable {
        let id: String
        let label: String
        let round: Int
        let value: Double
    }

    var body: some View {
        let points = results.flatMap { result in
            result.roundStats.enumerated().compactMap { index, bucket in
                bucket.mean.map { Point(id: "\(result.id)-\(index)", label: result.chartLabel, round: index + 1, value: $0) }
            }
        }
        Chart(points) { point in
            LineMark(
                x: .value("Round", point.round),
                y: .value("Milliseconds", point.value),
                series: .value("Server", point.label)
            )
            .foregroundStyle(by: .value("Server", point.label))
            .interpolationMethod(.monotone)
            PointMark(
                x: .value("Round", point.round),
                y: .value("Milliseconds", point.value)
            )
            .foregroundStyle(by: .value("Server", point.label))
            .symbolSize(28)
        }
        .chartForegroundStyleScale(domain: results.map(\.chartLabel), range: results.map(\.color))
        .chartXScale(domain: 1...max(rounds, 2))
        .chartXAxis {
            AxisMarks(values: Array(1...max(rounds, 1))) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartYAxisLabel("milliseconds")
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 260)
    }
}

private struct ReliabilityChart: View {
    let results: [ServerResult]

    private struct Entry: Identifiable {
        let id: String
        let label: String
        let outcome: String
        let count: Int
    }

    var body: some View {
        let entries = results.flatMap { result -> [Entry] in
            [
                ("Answered", result.successes),
                ("Timed out", result.timeouts),
                ("Error", result.serverErrors + result.networkErrors),
            ]
            .filter { $0.1 > 0 }
            .map { Entry(id: "\(result.id)-\($0.0)", label: result.chartLabel, outcome: $0.0, count: $0.1) }
        }
        Chart(entries) { entry in
            BarMark(
                x: .value("Lookups", entry.count),
                y: .value("Server", entry.label)
            )
            .foregroundStyle(by: .value("Outcome", entry.outcome))
        }
        .chartForegroundStyleScale([
            "Answered": Color.green.opacity(0.75),
            "Timed out": Color.orange,
            "Error": Color.red,
        ])
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel() }
        }
        .chartXAxisLabel("lookups")
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: chartHeight(results.count) + 20)
    }
}
