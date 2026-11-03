import AppKit
import SwiftUI

/// Brings the main window back from AppKit code: Dock clicks and notification clicks.
@MainActor
enum MainWindow {
    static let id = "main"
    /// Captured from the main window's environment; it keeps working after that window has closed.
    static var openAction: OpenWindowAction?

    static func show() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { isMain($0) && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openAction {
            openAction(id: id)
        } else {
            NSApp.windows.first(where: isMain)?.makeKeyAndOrderFront(nil)
        }
    }

    /// SwiftUI names the window after the scene id ("main", "main-AppWindow-1", …).
    static func isMain(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue else { return false }
        return identifier == id || identifier.hasPrefix("\(id)-")
    }
}

extension View {
    /// Lets `MainWindow.show()` reopen the main window after it was closed.
    func capturesOpenMainWindow() -> some View {
        modifier(OpenWindowCapture())
    }
}

private struct OpenWindowCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { MainWindow.openAction = openWindow }
    }
}
