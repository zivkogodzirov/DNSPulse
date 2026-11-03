import AppKit
import SwiftUI

/// Settings › Schedule: automatic checks and problem alerts.
struct ScheduleSettings: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: BenchmarkEngine
    @EnvironmentObject private var scheduler: Scheduler
    @State private var permission: Notifier.Permission?

    var body: some View {
        let schedule = store.settings.schedule
        let isChecking = engine.isRunning && engine.run?.trigger != nil

        Form {
            Section {
                Picker("Run a quick check", selection: $store.settings.schedule) {
                    ForEach(CheckSchedule.allCases) { Text($0.title).tag($0) }
                }
                if schedule != .off {
                    LabeledContent("Next check") {
                        if isChecking {
                            Text("Checking now…")
                        } else if schedule == .networkChange {
                            Text("When your Mac joins a different network")
                        } else if let next = scheduler.nextCheck {
                            Text(next <= Date() ? "Any moment now" : Format.date(next))
                        }
                    }
                }
                if let last = store.history.first(where: { $0.trigger != nil }) {
                    LabeledContent("Last check", value: Format.date(last.date))
                }
                if let skip = scheduler.lastSkip {
                    Label("Skipped the check at \(skip.date.formatted(date: .omitted, time: .shortened)) because \(skip.reason).", systemImage: "forward.end.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Check Now") { scheduler.runCheck(.scheduled) }
                        .disabled(engine.isRunning)
                        .help("Run the quick check once now")
                }
            } header: {
                Text("Schedule")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A check is a light test: your switched-on servers, the first 20 websites, 1 round, real-world mode, A records. It's saved to History with an AUTO tag without pushing out tests you ran, never interrupts a test you started, and doesn't change your settings.")
                    Label("Checks only run while DNS Pulse is open. With a schedule on, closing the window keeps DNS Pulse running in the Dock — quit it to stop checking.", systemImage: "dock.rectangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Alerts") {
                Toggle("Notify me when my DNS has a problem", isOn: notifyBinding)
                VStack(alignment: .leading, spacing: 4) {
                    Text("After each check, you'll get a notification if your current DNS:")
                    Text("• is 50% or more slower than usual on that network (the median of its last 5 checks)")
                    Text("• fails 5% or more of its lookups (and at least 2)")
                    Text("• has a different address than at the last check on that network")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if store.settings.notifyOnProblems {
                    alertHints(schedule: schedule)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermission() }
        }
    }

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { store.settings.notifyOnProblems },
            set: { isOn in
                store.settings.notifyOnProblems = isOn
                // Permission is only asked for here, when the user turns alerts on.
                if isOn { Task { permission = await Notifier.requestPermission() } }
            }
        )
    }

    @ViewBuilder
    private func alertHints(schedule: CheckSchedule) -> some View {
        switch permission {
        case .denied:
            HStack {
                hint("Notifications from DNS Pulse are turned off in System Settings.", icon: "bell.slash.fill", color: .orange)
                Spacer()
                Button("Open Notification Settings…") { Notifier.openSystemSettings() }
            }
        case .notDetermined:
            HStack {
                hint("DNS Pulse hasn't been allowed to show notifications yet.", icon: "bell.badge.fill", color: .orange)
                Spacer()
                Button("Allow Notifications") { Task { permission = await Notifier.requestPermission() } }
            }
        case .unavailable:
            hint("Notifications only work in the DNS Pulse app. Build it with build_app.sh and open DNS Pulse.app.", icon: "bell.slash.fill", color: .orange)
        default:
            EmptyView()
        }
        if schedule == .off {
            hint("Alerts come from scheduled checks. Choose a schedule above to get them.", icon: "info.circle.fill", color: .secondary)
        }
        if !store.enabledServers.contains(where: \.isSystem) {
            hint("Alerts watch the Current System DNS server. Switch it on in DNS Servers.", icon: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private func hint(_ text: String, icon: String, color: Color) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshPermission() async {
        permission = store.settings.notifyOnProblems ? await Notifier.permission() : nil
    }
}
