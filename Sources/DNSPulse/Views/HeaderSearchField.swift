import AppKit
import SwiftUI

/// A compact search field for a page's header bar.
/// Pages stay alive side by side, and only one of them could own the toolbar's search field.
/// When the header runs out of room it shrinks to a button that opens the field in a popover,
/// as a toolbar search field does.
struct HeaderSearchField: View {
    let prompt: String
    @Binding var text: String

    @State private var showsPopover = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            SearchFieldBox(prompt: prompt, text: $text)
                .frame(minWidth: 120, idealWidth: 120, maxWidth: 180)
            Button {
                showsPopover = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(text.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .help(text.isEmpty ? prompt : "Searching for “\(text)”")
            .accessibilityLabel(prompt)
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                SearchFieldBox(prompt: prompt, text: $text, focusesOnAppear: true)
                    .frame(width: 220)
                    .padding(10)
            }
        }
    }
}

private struct SearchFieldBox: View {
    let prompt: String
    @Binding var text: String
    var focusesOnAppear = false

    @FocusState private var isFocused: Bool
    @Environment(\.isActiveSection) private var isActiveSection

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { text = "" }
                // A hidden page stays alive, so keep its field out of the Tab order.
                .disabled(!isActiveSection)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear the search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                .padding(-1.5)
                .opacity(isFocused ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { if focusesOnAppear { isFocused = true } }
    }
}
