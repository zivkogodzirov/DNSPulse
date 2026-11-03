import SwiftUI

/// Names the DNS resolver the Mac really ends up using, which can differ from the address in its network settings.
struct ActiveResolverLabel: View {
    @EnvironmentObject private var networks: NetworkStore
    @StateObject private var monitor = ActiveResolverMonitor()
    @State private var showDetails = false

    var body: some View {
        Button { showDetails.toggle() } label: {
            Label(title, systemImage: "person.text.rectangle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Which DNS resolver really answers for this Mac. Click for details.")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            ActiveResolverDetails(monitor: monitor)
        }
        .task(id: networks.currentID) { await monitor.refresh() }
    }

    private var title: String {
        switch monitor.state {
        case .checking:
            return "Finding your Mac’s DNS resolver…"
        case .unavailable:
            return "Your Mac’s DNS resolver: couldn’t be found"
        case .found(let resolvers):
            let first = resolvers[0]
            let others = Set(resolvers.map(\.name)).subtracting([first.name]).count
            return "Your Mac’s DNS resolver: \(first.name)"
                + (first.location.map { " · \($0)" } ?? "")
                + (others > 0 ? " +\(others) more" : "")
        }
    }
}

private struct ActiveResolverDetails: View {
    @ObservedObject var monitor: ActiveResolverMonitor
    @EnvironmentObject private var engine: BenchmarkEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Mac’s DNS resolver").font(.headline)

            switch monitor.state {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            case .unavailable:
                Text("No answer came back. Check your connection, or dnscheck.tools may be down.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .found(let resolvers):
                ForEach(resolvers) { resolver in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resolver.name).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                        if let organisation = resolver.organisation, organisation != resolver.name {
                            Text(organisation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Text([resolver.address, resolver.location].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Divider()

            if let configured = SystemDNS.servers().first {
                explanation("Your Mac is set to \(configured). That’s only who it asks first: these are the resolvers that then look names up on the internet.")
            }
            if engine.interception == .intercepted {
                explanation("Your network intercepts plain DNS, so changing the DNS address on your Mac or router won’t change this. Encrypted DNS will.")
            }
            explanation("This is the Mac’s own DNS, which most apps use. Chrome’s Secure DNS setting skips it, so dnscheck.tools can show a different resolver in Chrome.")
            explanation("How it’s known: DNS Pulse looks up a one-off made-up name under dnscheck.tools. Only that site’s name server can answer, and it sees which resolver asked, then who owns that address.")

            Button("Check Again") { Task { await monitor.refresh() } }
                .disabled(monitor.state == .checking)
        }
        .padding(18)
        .frame(width: 380)
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
