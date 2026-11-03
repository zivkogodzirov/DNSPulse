import Charts
import SwiftUI

/// Who really answers a server's lookups, and a live view of its response times.
struct ResolverDiagnosticsSheet: View {
    let server: DNSServer

    @Environment(\.dismiss) private var dismiss
    @StateObject private var monitor = ResolverMonitor()
    @State private var identity: ResolverIdentity?
    @State private var isDiagnosing = false
    @State private var showRaw = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WhoAnsweredCard(server: server, identity: identity, isDiagnosing: isDiagnosing)
                    if let identity, !identity.probes.isEmpty, !isDiagnosing {
                        RawResultsCard(probes: identity.probes, isExpanded: $showRaw)
                    }
                    LiveMonitorCard(monitor: monitor, server: server)
                }
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            footer
        }
        .frame(width: 720, height: 700)
        .task(id: attempt) { await diagnose() }
        .onDisappear { monitor.stop() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ServerAvatar(name: server.avatarName, color: server.color, isSystem: server.isSystem, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.title3.weight(.bold)).lineLimit(1)
                HStack(spacing: 6) {
                    ProtocolBadge(proto: server.proto)
                    Text(server.displayAddress)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !server.provider.isEmpty, !server.isSystem {
                        Text("· \(server.provider)").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                attempt += 1
            } label: {
                Label("Diagnose Again", systemImage: "arrow.clockwise")
            }
            .disabled(isDiagnosing)
            .help("Ask the server who it is again")
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Label("Ordinary DNS lookups, sent only to this server.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func diagnose() async {
        isDiagnosing = true
        let result = await ResolverDiagnostics.run(server)
        guard !Task.isCancelled else { return }
        identity = result
        isDiagnosing = false
    }
}

// MARK: - Who answered

private struct WhoAnsweredCard: View {
    let server: DNSServer
    let identity: ResolverIdentity?
    let isDiagnosing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Who answered", subtitle: "Asks the server to identify itself, and which address its lookups come from", icon: "person.text.rectangle")
            if let identity, !isDiagnosing {
                verdict(identity)
                if identity.verdict != .unreachable {
                    Divider()
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 14) {
                        ForEach(facts(identity), id: \.title) { fact in
                            FactCell(fact: fact)
                        }
                    }
                    networkCheck(identity)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Asking \(server.name) who it is…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }

    private func verdict(_ identity: ResolverIdentity) -> some View {
        let style = Self.style(for: identity.verdict)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: style.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(style.tint.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(identity.headline).font(.title3.weight(.semibold))
                Text(identity.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func style(for verdict: ResolverIdentity.Verdict) -> (icon: String, tint: Color) {
        switch verdict {
        case .confirmed: ("checkmark.seal.fill", .green)
        case .answered: ("checkmark.circle.fill", .blue)
        case .forwarded: ("exclamationmark.shield.fill", .orange)
        case .unknown: ("questionmark.circle.fill", .gray)
        case .unreachable: ("xmark.octagon.fill", .red)
        }
    }

    private func facts(_ identity: ResolverIdentity) -> [Fact] {
        let egressDetail: String? = {
            switch (identity.googleEgress, identity.akamaiEgress) {
            case let (google?, akamai?): google == akamai ? "Seen by Google and Akamai" : "Seen by Google · Akamai saw \(akamai)"
            case (.some, nil): "Seen by Google"
            case (nil, .some): "Seen by Akamai"
            case (nil, nil): nil
            }
        }()
        return [
            Fact(title: "Operator", icon: "building.2", value: identity.operatorName ?? "Unknown",
                 detail: identity.operatorEvidence ?? "No reverse DNS name or known network"),
            Fact(title: "Location", icon: "mappin.and.ellipse", value: identity.location?.title ?? "Unknown",
                 detail: identity.locationEvidence ?? "No airport-style code in the server’s names"),
            Fact(title: "Outgoing address", icon: "arrow.up.right.circle", value: identity.egressIP ?? "Not reported",
                 detail: egressDetail, monospaced: identity.egressIP != nil),
            Fact(title: "Reverse DNS", icon: "arrow.uturn.backward.circle", value: identity.reverseName ?? "None",
                 detail: "Name registered for the outgoing address", monospaced: identity.reverseName != nil),
            Fact(title: "Server instance", icon: "server.rack", value: identity.instance ?? "Not reported",
                 detail: "From id.server or hostname.bind", monospaced: identity.instance != nil),
            Fact(title: "Client subnet (ECS)", icon: "person.crop.circle.badge.questionmark", value: identity.ecsSubnet ?? "Not sent",
                 detail: identity.ecsSubnet == nil ? "Your address isn’t passed on to websites’ DNS servers"
                     : "Part of your address is passed on so websites can pick a nearby server",
                 monospaced: identity.ecsSubnet != nil),
        ]
    }

    @ViewBuilder
    private func networkCheck(_ identity: ResolverIdentity) -> some View {
        Group {
            if identity.isEncrypted {
                Label("Encrypted (\(server.proto.shortTitle)): lookups can’t be intercepted on the way.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            } else if identity.interceptionDetected == true {
                Label("Network check: plain DNS is intercepted on this network.", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            } else if identity.interceptionDetected == false {
                Label("Network check: plain DNS is not intercepted.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .help("DNS Pulse sends one lookup to \(InterceptionCheck.probeAddress), an address where no server exists. If it is answered, something on your network is intercepting DNS.")
    }
}

private struct Fact {
    let title: String
    let icon: String
    let value: String
    var detail: String?
    var monospaced = false
}

private struct FactCell: View {
    let fact: Fact

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: fact.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(fact.value)
                    .font(fact.monospaced ? .callout.monospaced().weight(.medium) : .body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(fact.value)
                if let detail = fact.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Raw results

private struct RawResultsCard: View {
    let probes: [IdentityProbe]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(probes) { probe in
                    ProbeRow(probe: probe)
                    if probe.id != probes.last?.id { Divider() }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                Text("Raw results").font(.headline)
                Text("\(probes.count) quer\(probes.count == 1 ? "y" : "ies")").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.toggle() } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }
}

private struct ProbeRow: View {
    let probe: IdentityProbe

    private var tint: Color {
        switch probe.result.status {
        case .ok: probe.records.isEmpty ? .orange : .green
        case .nxdomain, .serverError: .orange
        case .timeout, .networkError: .red
        case .cancelled: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(probe.purpose).font(.caption).foregroundStyle(.secondary)
                Spacer()
                TagLabel(text: probe.statusText.uppercased(), color: tint)
                Text(probe.result.latencyMs > 0 ? Format.ms(probe.result.latencyMs) : "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            Text(probe.queryText)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if probe.records.isEmpty {
                Text("No answer records").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(probe.records.enumerated()), id: \.offset) { _, record in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(record.typeName)
                            .font(.caption2.weight(.bold).monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Text(record.displayValue)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Live monitor

/// Sends one lookup a second, alternating names the resolver has cached with random ones it can't have.
@MainActor
final class ResolverMonitor: ObservableObject {
    struct Sample: Identifiable {
        let id: Int
        let date: Date
        let isCached: Bool
        let name: String
        /// nil when the lookup was lost (timed out or failed).
        let latencyMs: Double?

        var series: String { isCached ? "Cached" : "Uncached" }
    }

    struct Totals {
        var sent = 0
        var lost = 0
        var sum = 0.0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var cachedSum = 0.0
        var cachedCount = 0
        var uncachedSum = 0.0
        var uncachedCount = 0

        var answered: Int { sent - lost }
        var average: Double { answered > 0 ? sum / Double(answered) : .nan }
        var cachedAverage: Double { cachedCount > 0 ? cachedSum / Double(cachedCount) : .nan }
        var uncachedAverage: Double { uncachedCount > 0 ? uncachedSum / Double(uncachedCount) : .nan }
        var lossRate: Double { sent > 0 ? Double(lost) / Double(sent) : 0 }
    }

    static let window: TimeInterval = 60
    static let cachedNames = ["apple.com", "google.com", "cloudflare.com", "microsoft.com", "wikipedia.org"]

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var totals = Totals()
    @Published private(set) var isRunning = false
    @Published private(set) var now = Date()
    @Published private(set) var problem: String?

    private var loop: Task<Void, Never>?
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var session = 0

    func start(server: DNSServer) {
        guard !isRunning else { return }
        session += 1
        let session = session
        isRunning = true
        samples = []
        totals = Totals()
        problem = nil
        now = Date()

        loop = Task { [weak self] in
            let prepared = await Task.detached { DNSProber.prepare(server) }.value
            guard case .success(let target) = prepared else {
                if case .failure(let error) = prepared { self?.fail(error.localizedDescription) }
                return
            }
            let timeout: TimeInterval = server.proto.isEncrypted ? 3 : 2
            let clock = ContinuousClock()
            var next = clock.now
            var tick = 0
            while !Task.isCancelled {
                self?.launch(tick: tick, session: session, target: target, timeout: timeout)
                tick += 1
                next += .seconds(1)
                // After the Mac sleeps or the loop stalls, carry on from now instead of sending every missed lookup at once.
                if next < clock.now { next = clock.now + .seconds(1) }
                try? await Task.sleep(until: next, clock: clock)
                guard let self else { return }
                self.prune()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        isRunning = false
    }

    private func fail(_ message: String) {
        problem = message
        stop()
    }

    private func launch(tick: Int, session: Int, target: ProbeTarget, timeout: TimeInterval) {
        let isCached = tick % 2 == 0
        let base = Self.cachedNames[(tick / 2) % Self.cachedNames.count]
        let name = isCached ? base : BenchmarkCore.queryName(for: base, mode: .uncached)
        let date = Date()
        inFlight[tick] = Task { [weak self] in
            let result = await DNSProber.probe(target, name: name, type: .a, timeout: timeout, dot: .diagnostics, doh: .diagnostics)
            guard result.status != .cancelled else { return }
            let latency = result.status.isSuccess ? result.latencyMs : nil
            self?.record(Sample(id: tick, date: date, isCached: isCached, name: name, latencyMs: latency), session: session)
        }
    }

    private func record(_ sample: Sample, session: Int) {
        guard session == self.session, isRunning else { return }
        inFlight[sample.id] = nil
        let index = samples.firstIndex { $0.id > sample.id } ?? samples.endIndex
        samples.insert(sample, at: index)

        totals.sent += 1
        if let ms = sample.latencyMs {
            totals.sum += ms
            totals.minimum = min(totals.minimum, ms)
            totals.maximum = max(totals.maximum, ms)
            if sample.isCached {
                totals.cachedSum += ms
                totals.cachedCount += 1
            } else {
                totals.uncachedSum += ms
                totals.uncachedCount += 1
            }
        } else {
            totals.lost += 1
        }
        prune()
    }

    private func prune() {
        now = Date()
        let cutoff = now.addingTimeInterval(-Self.window - 2)
        if let first = samples.first, first.date < cutoff {
            samples.removeAll { $0.date < cutoff }
        }
    }
}

private struct LiveMonitorCard: View {
    @ObservedObject var monitor: ResolverMonitor
    let server: DNSServer

    private static let colors: KeyValuePairs<String, Color> = ["Cached": .teal, "Uncached": .purple, "Lost": .red]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                SectionHeader(title: "Live monitor", subtitle: "One lookup a second, alternating cached names with random uncached ones", icon: "waveform.path.ecg")
                Spacer()
                if monitor.isRunning {
                    Button {
                        monitor.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop sending lookups")
                } else {
                    Button {
                        monitor.start(server: server)
                    } label: {
                        Label(monitor.totals.sent > 0 ? "Start Again" : "Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Send one lookup a second to this server and chart the response times")
                }
            }

            if let problem = monitor.problem {
                NoticeBanner(text: problem)
            }

            chart
                .frame(height: 200)

            stats
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }

    @ViewBuilder
    private var chart: some View {
        let start = monitor.now.addingTimeInterval(-ResolverMonitor.window)
        let shown = monitor.samples.filter { $0.date >= start }
        if shown.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text(monitor.isRunning ? "Waiting for the first answer…" : "Press Start to watch response times live.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
        } else {
            Chart {
                ForEach(shown) { sample in
                    if let ms = sample.latencyMs {
                        LineMark(x: .value("Time", sample.date), y: .value("Milliseconds", ms), series: .value("Lookup", sample.series))
                            .foregroundStyle(by: .value("Lookup", sample.series))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Time", sample.date), y: .value("Milliseconds", ms))
                            .foregroundStyle(by: .value("Lookup", sample.series))
                            .symbolSize(16)
                    } else {
                        RuleMark(x: .value("Time", sample.date))
                            .foregroundStyle(by: .value("Lookup", "Lost"))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    }
                }
            }
            .chartForegroundStyleScale(Self.colors)
            .chartXScale(domain: start...monitor.now)
            .chartXAxis {
                AxisMarks(values: stride(from: 60, through: 0, by: -15).map { monitor.now.addingTimeInterval(-Double($0)) }) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            let ago = Int(monitor.now.timeIntervalSince(date).rounded())
                            Text(ago == 0 ? "now" : "\(ago)s ago")
                        }
                    }
                }
            }
            .chartYAxisLabel("milliseconds")
            .chartLegend(position: .top, alignment: .leading)
            .accessibilityLabel("Response times over the last minute")
        }
    }

    private var stats: some View {
        let totals = monitor.totals
        return HStack(spacing: 0) {
            stat("Average", totals.answered > 0 ? Format.ms(totals.average) : "—")
            Divider().frame(height: 30)
            stat("Fastest", totals.answered > 0 ? Format.ms(totals.minimum) : "—")
            Divider().frame(height: 30)
            stat("Slowest", totals.answered > 0 ? Format.ms(totals.maximum) : "—")
            Divider().frame(height: 30)
            stat("Lost", totals.sent > 0 ? Format.percent(totals.lossRate) : "—",
                 detail: totals.sent > 0 ? "\(totals.lost) of \(totals.sent)" : nil,
                 tint: totals.lost > 0 ? .red : nil)
            Divider().frame(height: 30)
            stat("Cached avg", totals.cachedCount > 0 ? Format.ms(totals.cachedAverage) : "—", tint: .teal)
            Divider().frame(height: 30)
            stat("Uncached avg", totals.uncachedCount > 0 ? Format.ms(totals.uncachedAverage) : "—", tint: .purple)
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func stat(_ title: String, _ value: String, detail: String? = nil, tint: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(tint ?? .secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
