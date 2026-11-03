import AppKit
import SwiftUI

@main
enum DNSPulseMain {
    static func main() {
        if CommandLine.arguments.contains("--cli") {
            Task {
                let status = await CommandLineRunner.run(CommandLine.arguments)
                exit(status)
            }
            dispatchMain()
        } else {
            DNSPulseApp.main()
        }
    }
}

struct DNSPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Kept in `@State`, not `@StateObject`, so the app itself doesn't observe them: every change (several a second
    // during a test) would otherwise re-render the whole window, including the sections kept alive behind the one
    // on screen. The views that show their values observe them instead.
    @State private var store = AppStore()
    @State private var engine = BenchmarkEngine()
    @State private var networks = NetworkStore()
    @State private var scheduler = Scheduler()

    var body: some Scene {
        Window("DNS Pulse", id: "main") {
            ContentView(engine: engine)
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(networks)
                .environmentObject(scheduler)
                .modifier(AppAppearance(store: store))
                .frame(minWidth: 980, minHeight: 640)
                .task { networks.attach(engine, store: store) }
                .task {
                    scheduler.attach(store: store, engine: engine, networks: networks)
                    appDelegate.scheduler = scheduler
                }
                .capturesOpenMainWindow()
        }
        .defaultSize(width: 1220, height: 820)
        .commands { AppCommands(store: store, engine: engine) }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(networks)
                .environmentObject(scheduler)
                .modifier(AppAppearance(store: store))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var scheduler: Scheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        BrowserHistory.removeLeftoverCopies()
    }

    /// A history scan still running when the app quits never gets to delete its copy.
    func applicationWillTerminate(_ notification: Notification) {
        BrowserHistory.removeLeftoverCopies()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Scheduled checks keep running from the Dock after the window is closed.
        !(scheduler?.keepsAppRunning ?? false)
    }

    /// Clicking the Dock icon after the window was closed brings it back (SwiftUI doesn't reopen a `Window` scene).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }
}

/// Applies the chosen accent colour and theme. It follows only those two settings, so other changes to the store
/// don't re-apply the window's environment.
private struct AppAppearance: ViewModifier {
    let store: AppStore
    @State private var accent: AccentChoice

    init(store: AppStore) {
        self.store = store
        _accent = State(initialValue: store.settings.accent)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.accent, accent.color)
            .tint(accent.color)
            .onReceive(store.$settings.map(\.accent).removeDuplicates()) { accent = $0 }
            .onReceive(store.$settings.map(\.theme).removeDuplicates()) { Appearance.apply($0) }
    }
}

enum Appearance {
    @MainActor
    static func apply(_ theme: AppTheme) {
        let appearance: NSAppearance? = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        // Setting the same appearance again still re-renders every window, and each window's AppAppearance
        // replays the current theme whenever SwiftUI re-subscribes it.
        guard NSApp.appearance?.name != appearance?.name else { return }
        NSApp.appearance = appearance
    }
}

struct AppCommands: Commands {
    @ObservedObject var store: AppStore
    @ObservedObject var engine: BenchmarkEngine

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Benchmark") {
            Button("Start Test") { engine.start(store: store) }
                .keyboardShortcut("r")
                .disabled(engine.isRunning)
            Button("Stop Test") { engine.stop() }
                .keyboardShortcut(".")
                .disabled(!engine.isRunning)
            Divider()
            Picker("Rounds", selection: $store.settings.rounds) {
                ForEach([1, 2, 3, 5, 10, 20], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Test Mode", selection: $store.settings.mode) {
                ForEach(TestMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Record Type", selection: $store.settings.recordType) {
                ForEach(DNSRecordType.allCases) { Text($0.rawValue).tag($0) }
            }
        }

        CommandGroup(after: .sidebar) {
            Picker("Appearance", selection: $store.settings.theme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }
            Divider()
        }
    }
}
