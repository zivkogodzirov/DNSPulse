import SwiftUI

extension View {
    /// The window title and toolbar items of a page that stays alive behind other sidebar sections.
    /// They're only shown while the page is on screen. Only this modifier reads `isActiveSection`, so switching
    /// sections doesn't re-render the page itself.
    func sectionChrome<Items: ToolbarContent>(title: String, @ToolbarContentBuilder items: @escaping () -> Items) -> some View {
        modifier(SectionChrome(title: title, items: items))
    }
}

private struct SectionChrome<Items: ToolbarContent>: ViewModifier {
    let title: String
    let items: () -> Items

    @Environment(\.isActiveSection) private var isActiveSection

    func body(content: Content) -> some View {
        content
            // A hidden page must not set the title at all: with pages stacked, the first title wins, even an empty one.
            // Setting it from a background keeps the page itself out of the `if`, so its state survives switching.
            .background {
                if isActiveSection { Color.clear.navigationTitle(title) }
            }
            .toolbar {
                if isActiveSection { items() }
            }
    }
}
