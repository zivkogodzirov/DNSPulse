import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TestingSettings()
                .tabItem { Label("Testing", systemImage: "speedometer") }
            DataSettings()
                .tabItem { Label("Data", systemImage: "externaldrive") }
            NetworksForm()
                .tabItem { Label("Networks", systemImage: "wifi") }
            ScheduleSettings()
                .tabItem { Label("Schedule", systemImage: "clock.badge.checkmark") }
        }
        .frame(width: 600, height: 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("Appearance") {
                HStack(spacing: 18) {
                    Spacer()
                    ForEach(AppTheme.allCases) { theme in
                        ThemeCard(theme: theme, isSelected: store.settings.theme == theme) {
                            store.settings.theme = theme
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 6)

                LabeledContent("Accent colour") {
                    HStack(spacing: 8) {
                        ForEach(AccentChoice.allCases) { choice in
                            Button {
                                store.settings.accent = choice
                            } label: {
                                Circle()
                                    .fill(choice.color.gradient)
                                    .frame(width: 20, height: 20)
                                    .overlay {
                                        if store.settings.accent == choice {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9, weight: .heavy))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(choice.title)
                        }
                    }
                }
            }

            Section("When a test finishes") {
                Toggle("Play a sound", isOn: $store.settings.playSound)
                Text("The Dock icon also bounces if DNS Pulse is in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Check where each DNS sends you", isOn: $store.settings.checkDestinations)
                Text("After Real-world and Cached tests, connects to the server each DNS pointed to for every website, to see which DNS sends you to nearer servers. Adds about a minute. You can also run it from a test's results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Results") {
                Picker("Rank servers by", selection: $store.settings.rankingMetric) {
                    ForEach(RankingMetric.allCases) { Text($0.title).tag($0) }
                }
                Text(store.settings.rankingMetric.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ThemePreview(theme: theme)
                    .frame(width: 124, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isSelected ? accent : Color.primary.opacity(0.15), lineWidth: isSelected ? 3 : 1)
                    )
                Label(theme.title, systemImage: theme.icon)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ThemePreview: View {
    let theme: AppTheme

    var body: some View {
        switch theme {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask(
                        GeometryReader { geometry in
                            Path { path in
                                path.move(to: CGPoint(x: geometry.size.width, y: 0))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                                path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                                path.closeSubpath()
                            }
                        }
                    )
            }
        }
    }
}

private struct MiniWindow: View {
    let dark: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        let background = dark ? Color(white: 0.17) : Color(white: 0.96)
        let sidebar = dark ? Color(white: 0.23) : Color(white: 0.89)
        let line = dark ? Color(white: 0.38) : Color(white: 0.78)
        let card = dark ? Color(white: 0.12) : Color.white
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    Circle().fill(Color.red.opacity(0.85)).frame(width: 5, height: 5)
                    Circle().fill(Color.yellow.opacity(0.85)).frame(width: 5, height: 5)
                    Circle().fill(Color.green.opacity(0.85)).frame(width: 5, height: 5)
                }
                .padding(.bottom, 4)
                Capsule().fill(accent).frame(width: 24, height: 4)
                Capsule().fill(line).frame(width: 20, height: 4)
                Capsule().fill(line).frame(width: 22, height: 4)
                Spacer()
            }
            .padding(7)
            .frame(width: 40)
            .frame(maxHeight: .infinity)
            .background(sidebar)

            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(card).frame(height: 22)
                    .overlay(alignment: .leading) {
                        Capsule().fill(accent.opacity(0.85)).frame(width: 34, height: 5).padding(.leading, 6)
                    }
                RoundedRectangle(cornerRadius: 3).fill(card)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(Color.green.opacity(0.8)).frame(width: 46, height: 4)
                            Capsule().fill(Color.orange.opacity(0.8)).frame(width: 34, height: 4)
                            Capsule().fill(Color.red.opacity(0.7)).frame(width: 24, height: 4)
                        }
                        .padding(6)
                    }
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
        }
    }
}

// MARK: - Testing

private struct TestingSettings: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section {
                Stepper(value: $store.settings.rounds, in: 1...100) {
                    LabeledContent("Rounds per test", value: "\(store.settings.rounds)")
                }
                Picker("Websites per test", selection: $store.settings.websiteLimit) {
                    Text("All enabled").tag(0)
                    ForEach([10, 20, 25, 50, 75], id: \.self) { Text("First \($0)").tag($0) }
                }
                Toggle("Shuffle website order every round", isOn: $store.settings.shuffle)
            } header: {
                Text("How much to test")
            } footer: {
                Text("Each round looks up every website on every server once. More rounds = a more reliable average.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("What to measure") {
                Picker("Test mode", selection: $store.settings.mode) {
                    ForEach(TestMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
                Text(store.settings.mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Record type", selection: $store.settings.recordType) {
                    ForEach(DNSRecordType.allCases) { Text("\($0.rawValue) — \($0.summary)").tag($0) }
                }
            }

            Section("Timing") {
                VStack(alignment: .leading) {
                    LabeledContent("Timeout", value: "\(store.settings.timeoutMs) ms")
                    Slider(value: Binding(
                        get: { Double(store.settings.timeoutMs) },
                        set: { store.settings.timeoutMs = Int($0) }
                    ), in: 250...5000, step: 250)
                }
                Stepper(value: $store.settings.parallelism, in: 1...16) {
                    LabeledContent("Websites looked up at once", value: "\(store.settings.parallelism)")
                }
                Stepper(value: $store.settings.delayMs, in: 0...2000, step: 25) {
                    LabeledContent("Pause between websites", value: store.settings.delayMs == 0 ? "None" : "\(store.settings.delayMs) ms")
                }
                Text(pauseHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Testing Defaults") { store.settings.resetTesting() }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The pause is shared by every website in flight, so it sets the pace of the whole test.
    private var pauseHelp: String {
        let pause = store.settings.delayMs
        let base = "Each website is looked up on every server at once. The pause is the time before the next website starts, counted across all websites being looked up, so lookups don't leave in bursts. Some routers and ISPs drop part of a burst of plain DNS, which shows up as timeouts; 50–100 ms is usually enough to avoid that."
        guard pause > 0 else { return base }
        let jobs = store.settings.rounds * max(1, store.testDomains.count)
        let minimum = Double(jobs) * Double(pause) / 1000
        return base + " With \(pause) ms, a test of \(jobs) website lookups takes at least \(Format.duration(minimum))."
    }
}

// MARK: - Data

private struct DataSettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirm: Confirm?

    private var savedSummary: String {
        let checks = store.history.filter { $0.trigger != nil }.count
        let tests = store.history.count - checks
        let summary = "\(tests) test\(tests == 1 ? "" : "s")"
        return checks == 0 ? summary : "\(summary) + \(checks) automatic check\(checks == 1 ? "" : "s")"
    }

    enum Confirm: String, Identifiable {
        case history, servers, websites, everything
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: $store.settings.historyLimit, in: 5...500, step: 5) {
                    LabeledContent("Keep the last", value: "\(store.settings.historyLimit) tests")
                }
                LabeledContent("Saved now", value: savedSummary)
                Button("Clear History…") { confirm = .history }
                    .disabled(store.history.isEmpty)
            } header: {
                Text("History")
            } footer: {
                Text("Automatic checks are kept separately, up to the same number, so they never push out tests you ran.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Lists") {
                LabeledContent("DNS servers", value: "\(store.servers.count) (\(store.enabledServers.count) on)")
                LabeledContent("Websites", value: "\(store.websites.count) (\(store.enabledWebsites.count) on)")
                HStack {
                    Button("Restore Default Servers…") { confirm = .servers }
                    Button("Restore Default Websites…") { confirm = .websites }
                }
            }

            Section("Storage") {
                LabeledContent("Folder") {
                    Text(AppStore.folder.path(percentEncoded: false))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                HStack {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: AppStore.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([AppStore.folder])
                    }
                    Spacer()
                    Button("Reset Everything…", role: .destructive) { confirm = .everything }
                }
            }

            Section("Command line") {
                Text("Run a test from Terminal with your saved servers and websites:")
                    .font(.callout)
                Text("\"\(Bundle.main.executablePath ?? "DNS Pulse.app/Contents/MacOS/DNSPulse")\" --cli --rounds 3")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(title, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { item in
            Button(buttonTitle(item), role: .destructive) { perform(item) }
        }
    }

    private var title: String {
        switch confirm {
        case .history: "Delete all saved tests?"
        case .servers: "Restore the default DNS servers?"
        case .websites: "Restore the default top 100 websites?"
        case .everything: "Reset all settings, lists and history?"
        case nil: ""
        }
    }

    private func buttonTitle(_ item: Confirm) -> String {
        switch item {
        case .history: "Delete All"
        case .servers, .websites: "Restore Defaults"
        case .everything: "Reset Everything"
        }
    }

    private func perform(_ item: Confirm) {
        switch item {
        case .history:
            store.history.removeAll()
        case .servers:
            store.resetServers()
        case .websites:
            store.resetWebsites()
        case .everything:
            store.history.removeAll()
            store.resetServers()
            store.resetWebsites()
            store.settings = AppSettings()
        }
    }
}
