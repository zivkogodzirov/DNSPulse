import SwiftUI

/// Switches sidebar sections from inside a page.
/// Pages hold this stable reference instead of a binding to the selection, so clicking another section
/// doesn't make every page re-render (a binding counts as changed whenever the selection does).
@MainActor
final class SectionNavigator {
    fileprivate(set) var handler: (SidebarItem) -> Void = { _ in }

    func show(_ item: SidebarItem) { handler(item) }

    /// Called once by ContentView, which owns the selection.
    func connect(_ handler: @escaping (SidebarItem) -> Void) { self.handler = handler }
}

private struct SectionNavigatorKey: EnvironmentKey {
    static let defaultValue: SectionNavigator? = nil
}

/// Whether a kept-alive page is the section on screen. Each page keeps one object for its lifetime, so a switch flips
/// this flag and updates only the views that read it. Changing an environment value instead re-renders and re-measures
/// both pages involved, down to every split-view pane and list row.
@Observable
final class SectionActivity {
    var isActive: Bool

    init(isActive: Bool) { self.isActive = isActive }
}

private struct SectionActivityKey: EnvironmentKey {
    static let defaultValue: SectionActivity? = nil
}

extension EnvironmentValues {
    /// The app's navigator; nil only in previews or views shown outside the main window.
    var navigator: SectionNavigator? {
        get { self[SectionNavigatorKey.self] }
        set { self[SectionNavigatorKey.self] = newValue }
    }

    /// False while a page is kept alive but hidden behind another sidebar section.
    /// Pages use it to show their toolbar items and window title only while they're on screen.
    /// It reads a `SectionActivity`, so a switch updates only the views that read it, through Observation.
    var isActiveSection: Bool {
        self[SectionActivityKey.self]?.isActive ?? true
    }

    /// Set once per page by ContentView; pages read `isActiveSection`.
    var sectionActivity: SectionActivity? {
        get { self[SectionActivityKey.self] }
        set { self[SectionActivityKey.self] = newValue }
    }
}
