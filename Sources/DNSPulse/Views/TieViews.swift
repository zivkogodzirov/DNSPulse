import SwiftUI

enum TieText {
    /// "Quad9", "Google Public DNS and Quad9", or "Google Public DNS, Quad9 and 3 others".
    static func names(_ results: [ServerResult]) -> String {
        let names = results.map(\.name)
        guard names.count > 3 else { return ListFormatter.localizedString(byJoining: names) }
        return "\(names[0]), \(names[1]) and \(names.count - 2) others"
    }
}

/// Starts a new test of only some servers, such as the winner and the servers tied with it, under the same
/// conditions with more rounds.
struct RetestButton: View {
    let run: BenchmarkRun
    /// The servers to test again, most important first: the winner, then the servers tied with it.
    let contenders: [ServerResult]
    /// The most servers to test again.
    var limit = 3
    var title = "Re-test Top"

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: BenchmarkEngine
    @Environment(\.navigator) private var navigator

    var body: some View {
        let ids = serverIDs
        Button {
            engine.start(store: store, overrides: run.retestOverrides, onlyServers: ids)
            navigator?.show(.benchmark)
        } label: {
            Label("\(title) \(ids.count)", systemImage: "arrow.clockwise")
        }
        .disabled(engine.isRunning || ids.count < 2)
        .help(help(serverCount: ids.count))
    }

    private func help(serverCount: Int) -> String {
        let servers = serverCount == 1 ? "this server" : "these \(serverCount) servers"
        let websites = run.domains.count == 1 ? "website" : "\(run.domains.count) websites"
        return "Tests only \(servers) again with \(run.retestRounds) rounds, using this test's \(websites) and settings, so a real difference can show. Your own settings stay as they are."
    }

    /// The first few contenders that are still in the server list.
    private var serverIDs: Set<UUID> {
        var ids: [UUID] = []
        for result in contenders where ids.count < limit {
            let server = store.servers.first { $0.id == result.id } ?? store.servers.first { $0.matchKey == result.matchKey }
            if let server, !ids.contains(server.id) { ids.append(server.id) }
        }
        return Set(ids)
    }
}

/// A small secondary button on the coloured winner banner.
struct BannerChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.32 : 0.2)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(Capsule())
    }
}
