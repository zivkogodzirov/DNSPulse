import SwiftUI

/// Plain-English advice worked out from one finished run.
struct Recommendation {
    struct Point: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let text: String
        var isEstimate = false
    }

    let main: ServerResult
    /// Same protocol, different provider. When the winner is the current DNS: the fastest alternative instead.
    let backup: ServerResult?
    /// The winner is the DNS the Mac already uses: the Current System DNS row, or a server at the same address.
    let keepCurrent: Bool
    /// The fastest encrypted server, offered when plain DNS is intercepted.
    let encryptedAlternative: ServerResult?
    let points: [Point]

    init?(run: BenchmarkRun, ranked: [ServerResult], metric: RankingMetric, tied: [ServerResult]) {
        guard let winner = ranked.first(where: { $0.successes > 0 }) else { return nil }
        main = winner
        keepCurrent = run.isCurrentDNS(winner)
        backup = keepCurrent
            ? ranked.first { $0.successes > 0 && !run.isCurrentDNS($0) }
            : run.backup(for: winner, metric: metric)
        let intercepted = run.interceptionDetected == true && winner.proto == .udp
        encryptedAlternative = intercepted ? ranked.first { $0.proto.isEncrypted && $0.successes > 0 } : nil

        var points: [Point] = []
        if run.status == .cancelled {
            points.append(Point(id: "stopped", icon: "pause.circle.fill", tint: .orange,
                                text: "This test was stopped early, so treat these suggestions as a rough guide."))
        }
        if keepCurrent {
            points.append(Point(id: "keep", icon: "checkmark.seal.fill", tint: .green,
                                text: "**Keep your current DNS.** It answered fastest in this test, so there's nothing to change."))
        } else if let backup {
            let why = winner.proto.isEncrypted
                ? "If \(Self.md(winner.name)) ever has problems, **\(Self.md(backup.name))** is the next best encrypted option from another provider."
                : "Use **\(Self.md(backup.name))** (\(backup.address)) as the backup: it's from a different provider, so one outage won't stop your lookups."
            points.append(Point(id: "backup", icon: "square.stack.3d.up.fill", tint: .blue, text: why))
        }
        if !tied.isEmpty {
            let names = Self.md(TieText.names([winner] + tied))
            let advice = tied.allSatisfy { $0.providerKey == winner.providerKey }
                ? "They're from the same provider, so it doesn't matter which address you use as the main one."
                : "Choose between them on privacy policy or filtering (such as malware or ad blocking) rather than speed, or re-test them with more rounds."
            points.append(Point(id: "tie", icon: "equal.circle.fill", tint: .indigo,
                                text: "**\(names) are statistically tied**: the differences are within measurement noise. \(advice)"))
        }
        points += Self.destinationPoints(run: run, ranked: ranked, winner: winner, keepCurrent: keepCurrent, metric: metric, tied: tied)
        if winner.proto == .dot {
            points.append(Point(id: "dot", icon: "lock.fill", tint: .teal,
                                text: "**\(Self.md(winner.name)) is encrypted DNS (DNS-over-TLS).** macOS network settings only take plain DNS addresses and browsers only offer DoH, so install it as an encrypted DNS profile for the whole Mac."))
        } else if winner.proto == .doh {
            points.append(Point(id: "doh", icon: "lock.fill", tint: .purple,
                                text: "**\(Self.md(winner.name)) is encrypted DNS (DNS-over-HTTPS).** macOS network settings only take IP addresses, so turn it on in your browser's *Secure DNS* setting, or install it as an encrypted DNS profile for the whole Mac."))
        }
        for server in [winner, backup].compactMap({ $0 }) where server.successRate < 0.99 && server.attempts > 0 {
            let advice = server.id == winner.id
                ? "Each failed lookup can stall a page for seconds. Keep a backup set and test again later to see whether it was a blip."
                : "A backup is only used when the main server fails, but a more reliable one would be safer."
            points.append(Point(id: "reliability-\(server.id)", icon: "exclamationmark.triangle.fill", tint: .orange,
                                text: "**\(Self.md(server.name)) answered only \(Format.percent(server.successRate)) of lookups.** \(advice)"))
        }
        if intercepted {
            let alternative = encryptedAlternative.map {
                "Encrypted DNS gets around it: **\(Self.md($0.name))** was the fastest encrypted server here at \(Format.ms($0.value(for: metric)))."
            } ?? "Encrypted DNS gets around it: switch on the DoT and DoH servers and test again to find the fastest one."
            points.append(Point(id: "intercepted", icon: "exclamationmark.shield.fill", tint: .orange,
                                text: "**Plain DNS is intercepted on this network**, so the UDP times mostly measure your router or ISP, and switching servers may change nothing. \(alternative)"))
        }
        if let system = run.systemResult, tied.contains(where: { $0.id == system.id }) {
            points.append(Point(id: "saving", icon: "gauge.with.dots.needle.33percent", tint: .secondary,
                                text: "Your current DNS is statistically tied with \(Self.md(winner.name)), so switching wouldn't make a noticeable speed difference."))
        } else if !metric.needsConnections, let saving = Self.saving(run: run, main: winner, metric: metric, intercepted: intercepted) {
            points.append(saving)
        }
        self.points = points
    }

    /// Once the test's destinations are checked: whether the winner sends you to near servers, and what it saves per new
    /// website against your current DNS once the distance is counted too.
    private static func destinationPoints(run: BenchmarkRun, ranked: [ServerResult], winner: ServerResult, keepCurrent: Bool,
                                          metric: RankingMetric, tied: [ServerResult]) -> [Point] {
        let destinations = run.destinations
        guard destinations.isChecked, let mine = destinations.summaries[winner.id], mine.websites > 0 else { return [] }
        var points: [Point] = []
        if destinations.sendsFartherThanOthers(winner.id), let nearest = destinations.nearestOnAverage(among: ranked),
           let theirs = destinations.summaries[nearest.id] {
            points.append(Point(id: "destinations", icon: "location.north.line.fill", tint: .orange,
                                text: "**\(md(winner.name)) sends you to farther servers than the others:** farther on \(mine.farther) of \(mine.websites) websites, about \(Format.ms(mine.averageExtra - theirs.averageExtra)) more per connection than **\(md(nearest.name))**, whose picks are nearest."))
        } else {
            points.append(Point(id: "destinations", icon: "location.north.line.fill", tint: .teal,
                                text: "**\(md(winner.name)) also sends you to near servers:** the nearest on \(mine.nearest) of \(mine.websites) websites."))
        }

        // When your current DNS is tied with the winner, the advice already says switching makes no real difference.
        guard metric.needsConnections, !keepCurrent, let system = run.systemResult, !tied.contains(where: { $0.id == system.id }), let current = destinations.summaries[system.id], system.successes > 0 else { return points }
        // The lookup part the connection-based ranking uses (see `ServerResult.value(for:)`).
        let basis = RankingMetric.score
        let lookup = system.value(for: basis) - winner.value(for: basis)
        let distance = DestinationReport.tripsPerNewWebsite * (current.averageExtra - mine.averageExtra)
        guard lookup.isFinite, distance.isFinite else { return points }
        func part(_ value: Double, _ what: String) -> String {
            abs(value) < 0.5 ? "about the same \(what)" : "\(Format.ms(abs(value))) \(value > 0 ? "saved" : "lost") \(what)"
        }
        let total = lookup + distance
        let headline = abs(total) < 1
            ? "**Per new website, about the same as your current DNS**"
            : "**Per new website, about \(Format.ms(abs(total))) \(total > 0 ? "faster" : "slower") than your current DNS**"
        points.append(Point(id: "per-website", icon: "stopwatch", tint: total >= 0 ? .green : .orange,
                            text: "\(headline): \(part(lookup, "on the lookup")) and \(part(distance, "on the way to the server")).",
                            isEstimate: true))
        return points
    }

    /// Server names go into Markdown, so characters that would start formatting are escaped.
    private static func md(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "*_`[]\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// "About N ms faster per lookup" against the current system DNS, clearly an estimate.
    private static func saving(run: BenchmarkRun, main: ServerResult, metric: RankingMetric, intercepted: Bool) -> Point? {
        guard !run.isCurrentDNS(main), !intercepted else { return nil }
        guard let system = run.systemResult else {
            return Point(id: "saving", icon: "gauge.with.dots.needle.67percent", tint: .secondary,
                         text: "Include **Current System DNS** in your next test to see how much faster this would be than what you use now.")
        }
        guard system.successes > 0 else { return nil }
        // Typical-lookup metrics compare directly; for best-case or worst-case rankings, compare averages.
        let basis: RankingMetric = [.score, .average, .median].contains(metric) ? metric : .average
        let difference = system.value(for: basis) - main.value(for: basis)
        guard difference.isFinite, difference > 0 else { return nil }
        let text: String
        if difference < 1 {
            text = "About the same speed as your current DNS (\(system.address)): less than 1 ms per lookup."
        } else {
            let perLookup = difference < 10 ? String(format: "%.1f", difference) : "\(Int(difference.rounded()))"
            text = "About \(perLookup) ms faster per lookup than your current DNS (\(system.address)). Opening a new website typically needs 10–20 lookups, so roughly \(range(difference * 10, difference * 20)) quicker on first visits."
        }
        return Point(id: "saving", icon: "gauge.with.dots.needle.67percent", tint: .green, text: text, isEstimate: true)
    }

    /// Rounded so the estimate doesn't look more precise than it is: 194 → 190 ms, 2,340 → 2.3 s.
    private static func range(_ low: Double, _ high: Double) -> String {
        func seconds(_ value: Double) -> String { String(format: "%.1f", value / 1000) }
        func ms(_ value: Double) -> Int { value < 100 ? Int(value.rounded()) : Int((value / 10).rounded()) * 10 }
        if low >= 1000 { return "\(seconds(low))–\(seconds(high)) s" }
        if high >= 1000 { return "\(ms(low)) ms – \(seconds(high)) s" }
        return "\(ms(low))–\(ms(high)) ms"
    }
}

/// "What you should do": the advice above as a compact card, with buttons to act on it.
struct RecommendationPanel: View {
    let run: BenchmarkRun
    let ranked: [ServerResult]
    let metric: RankingMetric
    /// Servers statistically tied with the winner.
    let tied: [ServerResult]

    @EnvironmentObject private var store: AppStore
    @ObservedObject private var actions = DNSActionCenter.shared
    @Environment(\.accent) private var accent

    var body: some View {
        if let advice = Recommendation(run: run, ranked: ranked, metric: metric, tied: tied) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "lightbulb.max.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.yellow.gradient))
                    Text("What you should do").font(.headline)
                    Spacer()
                }

                HStack(alignment: .top, spacing: 12) {
                    PickTile(role: advice.keepCurrent ? "KEEP USING" : "MAIN DNS", result: advice.main, metric: metric, isMain: true)
                    if let backup = advice.backup {
                        PickTile(role: advice.keepCurrent ? "NEXT BEST" : "BACKUP DNS", result: backup, metric: metric, isMain: false)
                    } else {
                        Text("No backup: no other provider with the same kind of DNS answered in this test.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                }

                if !advice.points.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(advice.points) { point in
                            AdviceRow(point: point)
                        }
                    }
                }

                buttons(advice)
            }
            .card(padding: 18)
        }
    }

    @ViewBuilder
    private func buttons(_ advice: Recommendation) -> some View {
        let main = advice.main
        let encryptedOff = store.servers.contains { $0.proto.isEncrypted && !$0.isEnabled }
        HStack(spacing: 10) {
            if main.canBeSystemDNS, !advice.keepCurrent {
                Button { actions.proposeSwitch(to: main, in: run, metric: metric) } label: {
                    Label("Use \(main.name)…", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(actions.isWorking)
            } else if main.proto.isEncrypted {
                Button { actions.saveProfile(for: main) } label: {
                    Label("Install as Encrypted DNS Profile…", systemImage: "lock.shield.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            if let encrypted = advice.encryptedAlternative {
                Button { actions.saveProfile(for: encrypted) } label: {
                    Label("Install \(encrypted.name) Profile…", systemImage: "lock.shield")
                }
            } else if run.interceptionDetected == true, main.proto == .udp, encryptedOff {
                Button("Switch On Encrypted Servers") { store.enableEncryptedServers() }
            }
            if !tied.isEmpty {
                RetestButton(run: run, contenders: [main] + tied)
            }
            if actions.canRestore {
                Button { Task { await actions.proposeRestore() } } label: {
                    Label("Restore Previous DNS", systemImage: "arrow.uturn.backward")
                }
                .disabled(actions.isWorking)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }
}

private struct PickTile: View {
    let role: String
    let result: ServerResult
    let metric: RankingMetric
    let isMain: Bool

    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            ServerAvatar(name: result.avatarName, color: result.color, isSystem: result.isSystem, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(role)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(isMain ? accent : .secondary)
                HStack(spacing: 6) {
                    Text(result.name).font(.headline).lineLimit(1)
                    ProtocolBadge(proto: result.proto)
                }
                Text("\(result.shortAddress) · \(Format.ms(result.value(for: metric))) \(metric.shortTitle) · \(Format.percent(result.successRate)) answered")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isMain ? accent.opacity(0.08) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isMain ? accent.opacity(0.3) : Color.primary.opacity(0.08)))
    }
}

private struct AdviceRow: View {
    let point: Recommendation.Point

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: point.icon)
                .foregroundStyle(point.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                if point.isEstimate {
                    TagLabel(text: "ESTIMATE", color: .green)
                }
                Text(.init(point.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }
}
