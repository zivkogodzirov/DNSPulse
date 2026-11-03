import SwiftUI

/// Shared state behind the buttons that act on a result: switching the Mac's DNS, putting it back,
/// and saving encrypted DNS profiles.
/// One instance, so every results page sees the same saved "previous" setting and progress.
@MainActor
final class DNSActionCenter: ObservableObject {
    static let shared = DNSActionCenter()

    struct SwitchPlan: Identifiable {
        let id = UUID()
        let main: ServerResult
        let backup: ServerResult?
        let interceptionDetected: Bool

        var servers: [String] { [main.address] + (backup.map { [$0.address] } ?? []) }
    }

    struct RestorePlan: Identifiable {
        let id = UUID()
        let service: String
        let servers: [String]
        /// The service macOS routes through, so the system DNS shows the result.
        let isPrimary: Bool

        var isAutomatic: Bool { servers == [DNSSwitcher.automatic] }
        var summary: String { isAutomatic ? "automatic DNS (from your router)" : ListFormatter.localizedString(byJoining: servers) }
    }

    struct ProfileGuide: Identifiable {
        let id = UUID()
        let serverName: String
        let proto: DNSProtocol
        let file: URL
    }

    struct Message: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    enum Phase: Equatable {
        case idle, waitingForPassword, checking
    }

    @Published var plan: SwitchPlan?
    @Published var restorePlan: RestorePlan?
    @Published var message: Message?
    @Published var profileGuide: ProfileGuide?
    @Published private(set) var phase: Phase = .idle
    /// Set when the password prompt was cancelled, so the sheet can say nothing changed.
    @Published var wasCancelled = false
    @Published private(set) var previous: [String: [String]] = DNSSwitcher.savedPrevious

    var isWorking: Bool { phase != .idle }
    var canRestore: Bool { !previous.isEmpty }

    func proposeSwitch(to result: ServerResult, in run: BenchmarkRun, metric: RankingMetric) {
        guard result.canBeSystemDNS, !isWorking else { return }
        wasCancelled = false
        plan = SwitchPlan(main: result, backup: run.backup(for: result, metric: metric),
                          interceptionDetected: run.interceptionDetected == true)
    }

    /// Saves a DoT or DoH result as a .mobileconfig, then explains how to approve it. Never opens or installs it.
    func saveProfile(for result: ServerResult) {
        guard result.proto.isEncrypted else { return }
        do {
            guard let file = try DNSProfile.save(for: result) else { return }
            profileGuide = ProfileGuide(serverName: result.name, proto: result.proto, file: file)
        } catch {
            message = Message(title: "The profile wasn't saved", text: error.localizedDescription)
        }
    }

    /// Picks the setting to put back: the active service's if one was saved, otherwise the only (or first) saved one.
    /// Settings that can never be put back (the service was removed or renamed, or its servers can't be set)
    /// are forgotten first, so they don't keep failing or hide the others.
    func proposeRestore() async {
        previous = DNSSwitcher.savedPrevious
        guard !previous.isEmpty, !isWorking else { return }
        let (primary, services) = await Task.detached(priority: .userInitiated) {
            (DNSSwitcher.primaryServiceName(), DNSSwitcher.serviceNames())
        }.value
        let gone = DNSSwitcher.savedPrevious.filter { name, servers in
            services?.contains(name) == false || DNSSwitcher.command(service: name, servers: servers) == nil
        }.keys.sorted()
        gone.forEach(DNSSwitcher.forgetPrevious)
        let saved = DNSSwitcher.savedPrevious
        previous = saved
        let name = primary.flatMap { saved[$0] == nil ? nil : $0 } ?? saved.keys.sorted().first
        if let name, let servers = saved[name] {
            restorePlan = RestorePlan(service: name, servers: servers, isPrimary: name == primary)
        } else if !gone.isEmpty {
            let names = ListFormatter.localizedString(byJoining: gone)
            message = Message(title: "Nothing to restore", text: gone.count == 1
                ? "DNS Pulse can't put back the setting it saved for \(names): that network service no longer exists on this Mac, or its saved servers can't be set again. The saved setting has been removed."
                : "DNS Pulse can't put back the settings it saved for \(names): those network services no longer exist on this Mac, or their saved servers can't be set again. The saved settings have been removed.")
        }
    }

    func perform(_ plan: SwitchPlan, on service: DNSSwitcher.Service) async {
        guard !isWorking else { return }
        wasCancelled = false
        phase = .waitingForPassword
        // Let the sheet draw its progress state; the password prompt then holds the main thread until answered.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let outcome = DNSSwitcher.apply(plan.servers, to: service.name)
        if case .changed = outcome { DNSSwitcher.rememberSwitch(of: service, to: plan.servers) }
        previous = DNSSwitcher.savedPrevious
        switch outcome {
        case .cancelled:
            phase = .idle
            wasCancelled = true
        case .failed(let reason):
            phase = .idle
            self.plan = nil
            message = Message(title: "DNS wasn't changed", text: "macOS reported: \(reason)")
        case .changed:
            phase = .checking
            let check = await DNSSwitcher.check(after: plan.servers)
            phase = .idle
            self.plan = nil
            message = Self.switchedMessage(plan, service: service.name, check: check)
        }
    }

    func restore(_ plan: RestorePlan) async {
        guard !isWorking else { return }
        phase = .waitingForPassword
        try? await Task.sleep(nanoseconds: 150_000_000)
        let outcome = DNSSwitcher.apply(plan.servers, to: plan.service)
        switch outcome {
        case .cancelled:
            phase = .idle
        case .failed(let reason):
            phase = .idle
            message = Message(title: "DNS wasn't restored", text: "macOS reported: \(reason)")
        case .changed:
            DNSSwitcher.forgetPrevious(for: plan.service)
            // The system DNS belongs to the primary service, so it says nothing about any other one.
            var now = ""
            if plan.isPrimary {
                phase = .checking
                let check = await DNSSwitcher.check(after: plan.servers)
                now = check.systemServers.isEmpty ? "" : " (\(ListFormatter.localizedString(byJoining: check.systemServers)) right now)"
            }
            phase = .idle
            message = Message(title: "DNS restored", text: plan.isAutomatic
                ? "\(plan.service) is back to automatic DNS from your router\(now)."
                : "\(plan.service) is back to \(plan.summary).")
        }
        previous = DNSSwitcher.savedPrevious
    }

    private static func switchedMessage(_ plan: SwitchPlan, service: String, check: DNSSwitcher.Check) -> Message {
        var lines: [String] = []
        if let backup = plan.backup {
            lines.append("\(service) now uses \(plan.main.address) (\(plan.main.name)) with \(backup.address) (\(backup.name)) as a backup.")
        } else {
            lines.append("\(service) now uses \(plan.main.address) (\(plan.main.name)).")
        }
        if check.systemServers.first != plan.main.address {
            let reported = check.systemServers.isEmpty ? "no DNS servers" : ListFormatter.localizedString(byJoining: check.systemServers)
            lines.append("macOS accepted the change but still reports \(reported). It can take a few seconds to apply.")
        }
        if let probe = check.probe, let address = check.probed {
            if probe.status.isSuccess {
                lines.append("A test lookup through \(address) was answered in \(Format.ms(probe.latencyMs)).")
            } else {
                let reason = probe.status == .timeout ? "got no answer" : "failed (\(probe.detail ?? "error"))"
                lines.append("A test lookup through \(address) \(reason). If websites stop loading, use Restore Previous DNS.")
            }
        }
        if plan.interceptionDetected {
            lines.append("Your network intercepts plain DNS, so your router or ISP may still be answering instead.")
        }
        return Message(title: "Your Mac now uses \(plan.main.name)", text: lines.joined(separator: "\n\n"))
    }
}

// MARK: - Presenting

extension View {
    /// Attaches the sheets and alerts the DNS action buttons need. Add once per results page.
    func dnsActionSheets() -> some View {
        modifier(DNSActionsPresenter())
    }
}

private struct DNSActionsPresenter: ViewModifier {
    @ObservedObject private var center = DNSActionCenter.shared
    /// Benchmark and History both stay alive with a results page; only the one on screen presents.
    @Environment(\.isActiveSection) private var isActiveSection

    func body(content: Content) -> some View {
        content
            .sheet(item: isActiveSection ? $center.plan : .constant(nil)) { plan in
                UseDNSSheet(plan: plan, center: center)
            }
            .sheet(item: isActiveSection ? $center.profileGuide : .constant(nil)) { guide in
                ProfileGuideSheet(guide: guide)
            }
            .confirmationDialog(
                "Restore the DNS settings for \(center.restorePlan?.service ?? "this network")?",
                isPresented: Binding(get: { isActiveSection && center.restorePlan != nil }, set: { if !$0 { center.restorePlan = nil } }),
                titleVisibility: .visible,
                presenting: center.restorePlan
            ) { plan in
                Button("Restore") { Task { await center.restore(plan) } }
            } message: { plan in
                Text("\(plan.service) will go back to \(plan.summary), the setting it had before DNS Pulse changed it. You'll be asked for your Mac password.")
            }
            .alert(
                center.message?.title ?? "",
                isPresented: Binding(get: { isActiveSection && center.message != nil }, set: { if !$0 { center.message = nil } }),
                presenting: center.message
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message.text)
            }
    }
}

// MARK: - Confirmation sheet

private struct UseDNSSheet: View {
    let plan: DNSActionCenter.SwitchPlan
    @ObservedObject var center: DNSActionCenter

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var service: DNSSwitcher.Service?
    @State private var isLoading = true

    private var alreadyInUse: Bool { service?.servers == plan.servers }
    private var canBeRestored: Bool { service?.canBeRestored ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking up your network connection…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                } else if let service {
                    change(service)
                    notes(service)
                } else {
                    Label("DNS Pulse couldn't find an active network connection. Check that you're online and try again.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
                }
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 560)
        .interactiveDismissDisabled(center.isWorking)
        .task {
            service = await Task.detached(priority: .userInitiated) { DNSSwitcher.primaryService() }.value
            isLoading = false
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(accent.gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text("Use \(plan.main.name) for DNS?").font(.title3.weight(.bold))
                Text("Changes the DNS servers of your Mac's active network connection. Every app uses them straight away.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private func change(_ service: DNSSwitcher.Service) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Network service: ") + Text(service.name).fontWeight(.semibold)
            } icon: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .font(.callout)

            HStack(alignment: .center, spacing: 12) {
                SettingBox(title: "Now") {
                    if service.isAutomatic {
                        Text("Automatic").fontWeight(.semibold)
                        let detected = SystemDNS.servers()
                        Text(detected.isEmpty ? "From your router" : "\(detected.joined(separator: ", ")) from your router")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        ForEach(service.servers, id: \.self) { Text($0).font(.callout.monospaced()) }
                    }
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
                SettingBox(title: "New", highlighted: true) {
                    ServerLine(result: plan.main, role: "MAIN")
                    if let backup = plan.backup {
                        ServerLine(result: backup, role: "BACKUP")
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if plan.backup == nil {
                Text("No other provider answered in this test, so there's no backup server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("The backup is the fastest server from a different provider, used if the main one doesn't answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func notes(_ service: DNSSwitcher.Service) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if plan.interceptionDetected {
                NoteRow(icon: "exclamationmark.shield.fill", tint: .orange,
                        text: "Plain DNS is intercepted on this network. This change may have no effect until your router or ISP stops intercepting it.")
            }
            if alreadyInUse {
                NoteRow(icon: "checkmark.circle.fill", tint: .green, text: "\(service.name) already uses these servers.")
            } else if let server = service.servers.first(where: { !DNSSwitcher.isSettableAddress($0) }) {
                NoteRow(icon: "exclamationmark.triangle.fill", tint: .orange,
                        text: "DNS Pulse can't change \(service.name), because it couldn't put \(server) back afterwards. Change DNS in System Settings instead.")
            }
            NoteRow(icon: "lock.fill", tint: .secondary,
                    text: "You'll be asked for your Mac password. **Restore Previous DNS** puts the old setting back later.")
            if let command = DNSSwitcher.command(service: service.name, servers: plan.servers) {
                DisclosureGroup("Command DNS Pulse will run") {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
                .font(.caption)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch center.phase {
            case .waitingForPassword:
                ProgressView().controlSize(.small)
                Text("Waiting for your password…").font(.callout).foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking the new servers…").font(.callout).foregroundStyle(.secondary)
            case .idle:
                if center.wasCancelled {
                    Label("Cancelled — nothing was changed.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(center.isWorking)
            Button("Change DNS…") {
                guard let service else { return }
                Task { await center.perform(plan, on: service) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(service == nil || alreadyInUse || !canBeRestored || center.isWorking)
        }
        .padding(16)
    }
}

private struct SettingBox<Content: View>: View {
    let title: String
    var highlighted = false
    @ViewBuilder var content: Content
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(highlighted ? accent.opacity(0.1) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(highlighted ? accent.opacity(0.35) : Color.primary.opacity(0.08)))
    }
}

private struct ServerLine: View {
    let result: ServerResult
    let role: String

    var body: some View {
        HStack(spacing: 8) {
            ServerAvatar(name: result.avatarName, color: result.color, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.address).font(.callout.monospaced().weight(.semibold))
                Text(result.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            TagLabel(text: role, color: role == "MAIN" ? .blue : .secondary)
                .fixedSize()
        }
    }
}

struct NoteRow: View {
    let icon: String
    let tint: Color
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The main call to action on the coloured winner banner: a solid white capsule.
struct BannerPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color(hex: "#3730A3"))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 170, alignment: .leading)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.8 : 0.95)))
            .contentShape(Capsule())
    }
}
