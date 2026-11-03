import AppKit
import SwiftUI

/// A column of a `LiteTable`.
struct LiteColumn<Row> {
    enum Width {
        case fixed(CGFloat)
        /// Shares the table's spare width equally with the other flexible columns, like a resizable table column.
        case flexible(min: CGFloat, ideal: CGFloat)
    }

    let title: String
    let width: Width
    let alignment: Alignment
    let comparator: KeyPathComparator<Row>?
    let cell: (Row) -> AnyView

    init<Content: View>(_ title: String, width: Width, alignment: Alignment = .leading,
                        @ViewBuilder content: @escaping (Row) -> Content) {
        self.title = title
        self.width = width
        self.alignment = alignment
        comparator = nil
        cell = { AnyView(content($0)) }
    }

    init<Value: Comparable, Content: View>(_ title: String, value: KeyPath<Row, Value>, width: Width, alignment: Alignment = .leading,
                                           @ViewBuilder content: @escaping (Row) -> Content) {
        self.title = title
        self.width = width
        self.alignment = alignment
        comparator = KeyPathComparator(value)
        cell = { AnyView(content($0)) }
    }

    /// Text sorts the way Finder does ("Server 2" before "Server 10"), as in a SwiftUI `Table`.
    init<Content: View>(_ title: String, value: KeyPath<Row, String>, width: Width, alignment: Alignment = .leading,
                        @ViewBuilder content: @escaping (Row) -> Content) {
        self.title = title
        self.width = width
        self.alignment = alignment
        comparator = KeyPathComparator(value, comparator: .localizedStandard)
        cell = { AnyView(content($0)) }
    }
}

@resultBuilder
enum LiteColumnBuilder<Row> {
    static func buildExpression(_ column: LiteColumn<Row>) -> [LiteColumn<Row>] { [column] }
    static func buildBlock(_ columns: [LiteColumn<Row>]...) -> [LiteColumn<Row>] { columns.flatMap { $0 } }
    static func buildOptional(_ columns: [LiteColumn<Row>]?) -> [LiteColumn<Row>] { columns ?? [] }
    static func buildEither(first columns: [LiteColumn<Row>]) -> [LiteColumn<Row>] { columns }
    static func buildEither(second columns: [LiteColumn<Row>]) -> [LiteColumn<Row>] { columns }
}

/// A lightweight table made only of SwiftUI views, for lists of up to a few thousand rows.
///
/// SwiftUI's `Table` hosts every cell in its own view inside an NSTableView, and moving that table in or out of
/// a window costs a few hundred milliseconds, which made switching sidebar sections slow. This keeps the parts
/// of `Table` the app uses: sortable headers, Mac-style selection and keyboard control, a context menu that acts
/// on the selection, and a double-click action. Only the rows on screen are built.
struct LiteTable<Row: Identifiable>: View {
    private let rows: [Row]
    @Binding private var selection: Set<Row.ID>
    @Binding private var sortOrder: [KeyPathComparator<Row>]
    private let rowHeight: CGFloat
    private let columns: [LiteColumn<Row>]
    private var menu: ((Set<Row.ID>) -> AnyView)?
    private var primaryAction: ((Set<Row.ID>) -> Void)?
    private var primaryActionName = "Open"
    private var rowLabel: ((Row) -> String)?
    private var emptyContent: AnyView?

    @FocusState private var isFocused: Bool
    @Environment(\.controlActiveState) private var activeState
    @State private var selector = LiteTableSelector<Row>()
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    private static var headerHeight: CGFloat { 28 }
    private static var inset: CGFloat { 10 }
    private static var cellPadding: CGFloat { 8 }
    private static var spacing: CGFloat { 16 }
    private static var listSpace: String { "LiteTable.rows" }

    init(_ rows: [Row], selection: Binding<Set<Row.ID>>, sortOrder: Binding<[KeyPathComparator<Row>]>, rowHeight: CGFloat,
         @LiteColumnBuilder<Row> columns: () -> [LiteColumn<Row>]) {
        self.rows = rows
        _selection = selection
        _sortOrder = sortOrder
        self.rowHeight = rowHeight
        self.columns = columns()
    }

    /// Like `Table.contextMenu(forSelectionType:menu:primaryAction:)`: a right-clicked row inside the selection acts on
    /// the whole selection, any other row only on itself. The primary action runs on double-click.
    func rowContextMenu<Menu: View>(primaryActionName: String = "Open", @ViewBuilder menu: @escaping (Set<Row.ID>) -> Menu,
                                    primaryAction: ((Set<Row.ID>) -> Void)? = nil) -> Self {
        var table = self
        table.menu = { AnyView(menu($0)) }
        table.primaryAction = primaryAction
        table.primaryActionName = primaryActionName
        return table
    }

    /// What VoiceOver reads for a row.
    func rowAccessibilityLabel(_ label: @escaping (Row) -> String) -> Self {
        var table = self
        table.rowLabel = label
        return table
    }

    /// Shown in place of the rows when there are none.
    func emptyState<Content: View>(@ViewBuilder _ content: () -> Content) -> Self {
        var table = self
        table.emptyContent = AnyView(content())
        return table
    }

    var body: some View {
        let _ = selector.update(rows: rows, selection: $selection)
        ScrollViewReader { scroller in
            GeometryReader { geometry in
                let layout = layout(for: geometry.size)
                // Scrolls sideways, header and all, only when the columns can't shrink enough to fit (like NSTableView).
                ScrollView(layout.scrollsSideways ? .horizontal : []) {
                    VStack(spacing: 0) {
                        header(widths: layout.widths)
                        Divider()
                        ScrollView(.vertical) {
                            rowStack(widths: layout.widths)
                                .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .named(Self.listSpace)).minY } action: { [selector] in
                                    selector.scrollOffset = $0
                                }
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, minHeight: layout.listHeight, alignment: .topLeading)
                                .background {
                                    // Clicking below or beside the rows clears the selection.
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture { selector.clear() }
                                }
                        }
                        .coordinateSpace(.named(Self.listSpace))
                        .frame(height: layout.listHeight)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [selector] in selector.pageHeight = $0 }
                    }
                    .frame(width: layout.width, alignment: .topLeading)
                }
                .overlay {
                    if rows.isEmpty, let emptyContent { emptyContent }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .modifier(FocusableWhileActive())
            .focused($isFocused)
            .focusEffectDisabled()
            // These handlers can outlive the body that made them, so they go through `selector`, which always
            // has the current rows and selection.
            .onKeyPress(keys: [.upArrow, .downArrow, .home, .end, .pageUp, .pageDown]) { [selector] press in
                handleKey(press, selector: selector, scroller: scroller)
            }
            .onKeyPress(.escape) { [selector] in
                selector.clear()
                return .handled
            }
            .onKeyPress(.return) { [selector, primaryAction] in
                guard let primaryAction, !selector.selection.isEmpty else { return .ignored }
                primaryAction(selector.selection)
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "aA"), phases: .down) { [selector] press in
                guard press.modifiers.contains(.command), !press.modifiers.contains(.option), !press.modifiers.contains(.control) else {
                    return .ignored
                }
                selector.selectAll()
                return .handled
            }
            .onCommand(#selector(NSText.selectAll(_:))) { [selector] in selector.selectAll() }
            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                scrollerStyle = NSScroller.preferredScrollerStyle
            }
        }
    }

    // MARK: Layout

    private struct Layout {
        var widths: [CGFloat]
        var width: CGFloat
        var listHeight: CGFloat
        var scrollsSideways: Bool
    }

    private func layout(for size: CGSize) -> Layout {
        // Always-visible scroll bars ("Show scroll bars: Always", or a mouse attached) take room from the rows.
        let scroller = scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        var listHeight = max(0, size.height - Self.headerHeight - 1)
        let verticalScroller = CGFloat(rows.count) * rowHeight + 12 > listHeight ? scroller : 0
        let widths = columnWidths(for: size.width - verticalScroller)
        let tableWidth = widths.reduce(0, +) + Self.spacing * CGFloat(max(widths.count - 1, 0)) + 2 * (Self.inset + Self.cellPadding)
        let scrollsSideways = tableWidth + verticalScroller > size.width + 0.5
        if scrollsSideways { listHeight = max(0, listHeight - scroller) }
        return Layout(widths: widths, width: max(size.width, tableWidth + verticalScroller), listHeight: listHeight, scrollsSideways: scrollsSideways)
    }

    private func columnWidths(for width: CGFloat) -> [CGFloat] {
        let available = width - 2 * (Self.inset + Self.cellPadding) - Self.spacing * CGFloat(max(columns.count - 1, 0))
        var widths: [CGFloat] = []
        var flexible: [Int] = []
        var minimum: CGFloat = 0
        var ideal: CGFloat = 0
        for (index, column) in columns.enumerated() {
            switch column.width {
            case .fixed(let value):
                widths.append(value)
                minimum += value
                ideal += value
            case .flexible(let low, let preferred):
                widths.append(preferred)
                flexible.append(index)
                minimum += low
                ideal += preferred
            }
        }
        guard !flexible.isEmpty else { return widths }
        if available >= ideal {
            let extra = (available - ideal) / CGFloat(flexible.count)
            for index in flexible { widths[index] += extra }
        } else {
            // Shrink each flexible column towards its minimum in proportion to how much it can give.
            let slack = ideal - minimum
            let fraction = slack > 0 ? min(1, (ideal - max(available, minimum)) / slack) : 0
            for index in flexible {
                if case .flexible(let low, let preferred) = columns[index].width {
                    widths[index] = preferred - (preferred - low) * fraction
                }
            }
        }
        return widths
    }

    private func header(widths: [CGFloat]) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(columns.indices, id: \.self) { index in
                headerCell(columns[index])
                    .frame(width: widths[index], alignment: columns[index].alignment)
                    .overlay(alignment: .trailing) {
                        if index < columns.count - 1 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(width: 1, height: 14)
                                .offset(x: Self.spacing / 2)
                        }
                    }
            }
        }
        .padding(.horizontal, Self.inset + Self.cellPadding)
        .frame(maxWidth: .infinity, minHeight: Self.headerHeight, maxHeight: Self.headerHeight, alignment: .leading)
    }

    @ViewBuilder
    private func headerCell(_ column: LiteColumn<Row>) -> some View {
        let title = Text(column.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        if let comparator = column.comparator {
            let order = sortOrder.first.flatMap { $0.keyPath == comparator.keyPath ? $0.order : nil }
            Button {
                sort(by: comparator)
            } label: {
                HStack(spacing: 4) {
                    title
                    Spacer(minLength: 0)
                    if let order {
                        Image(systemName: order == .forward ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(column.title)
            .accessibilityValue(order == nil ? "" : order == .forward ? "Sorted ascending" : "Sorted descending")
            .accessibilityHint("Sorts the list by this column")
            .accessibilityAddTraits(.isHeader)
        } else {
            title.accessibilityAddTraits(.isHeader)
        }
    }

    private func rowStack(widths: [CGFloat]) -> some View {
        let emphasized = isFocused && activeState == .key
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let isSelected = selection.contains(row.id)
                LiteTableRow(
                    row: row,
                    columns: columns,
                    widths: widths,
                    height: rowHeight,
                    isStriped: index % 2 == 1,
                    isSelected: isSelected,
                    // Neighbouring selected rows join into one highlight, as in an NSTableView.
                    joinsAbove: isSelected && index > 0 && selection.contains(rows[index - 1].id),
                    joinsBelow: isSelected && index < rows.count - 1 && selection.contains(rows[index + 1].id),
                    isEmphasized: emphasized,
                    inset: Self.inset,
                    cellPadding: Self.cellPadding,
                    spacing: Self.spacing,
                    label: rowLabel?(row),
                    menuTargets: isSelected ? selection : [row.id],
                    menu: menu,
                    primaryActionName: primaryAction == nil ? nil : primaryActionName,
                    onClick: { click(row.id) },
                    onSelect: { selector.select(row.id) },
                    onPrimaryAction: { primaryAction?(selector.targets(for: row.id)) }
                )
                .id(row.id)
            }
        }
    }

    // MARK: Selection

    private func sort(by comparator: KeyPathComparator<Row>) {
        if var first = sortOrder.first, first.keyPath == comparator.keyPath {
            first.order = first.order == .forward ? .reverse : .forward
            sortOrder[0] = first
        } else {
            sortOrder = [comparator] + sortOrder.filter { $0.keyPath != comparator.keyPath }
        }
    }

    private func click(_ id: Row.ID) {
        // No `isFocused = true` here: the click has already focused the table, and setting it again drops the focus.
        let event = NSApp.currentEvent.flatMap { [.leftMouseDown, .leftMouseUp].contains($0.type) ? $0 : nil }
        let modifiers = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if modifiers.contains(.shift) {
            selector.extend(to: id)
        } else if modifiers.contains(.command) {
            selector.toggle(id)
        } else {
            selector.select(id)
            // Reading the click count keeps single clicks immediate; a second tap gesture would delay them.
            if (event?.clickCount ?? 1) >= 2 { primaryAction?(selector.targets(for: id)) }
        }
    }

    private func handleKey(_ press: KeyPress, selector: LiteTableSelector<Row>, scroller: ScrollViewProxy) -> KeyPress.Result {
        let rows = selector.rows
        guard let first = rows.first, let last = rows.last else { return .ignored }
        switch press.key {
        case .home:
            scroller.scrollTo(first.id, anchor: .top)
        case .end:
            scroller.scrollTo(last.id, anchor: .bottom)
        case .pageUp, .pageDown:
            // Scrolls a page and leaves the selection alone, as NSTableView does.
            let perPage = max(1, Int(selector.pageHeight / rowHeight) - 1)
            let top = Int(max(0, selector.scrollOffset) / rowHeight)
            let target = press.key == .pageDown ? min(top + perPage, rows.count - 1) : max(top - perPage, 0)
            scroller.scrollTo(rows[target].id, anchor: .top)
            // Where that scroll lands (the rows sit 6 pt down), so a press queued before the next layout pages on from it.
            selector.scrollOffset = min(CGFloat(target) * rowHeight, CGFloat(rows.count) * rowHeight + 6 - selector.pageHeight)
        default:
            let id = selector.move(down: press.key == .downArrow, extending: press.modifiers.contains(.shift))
            scroller.scrollTo(id)
        }
        return .handled
    }
}

/// Mac table selection: click, ⌘-click, ⇧-click and the arrow keys.
/// A reference type so handlers SwiftUI keeps from an earlier body still act on the current rows and selection,
/// and so the anchor and cursor, which never change what's drawn, don't cause re-renders.
private final class LiteTableSelector<Row: Identifiable> {
    private(set) var rows: [Row] = []
    private var selectionBinding: Binding<Set<Row.ID>> = .constant([])
    /// Where ⇧-click and ⇧-arrow ranges start.
    private var anchor: Row.ID?
    /// The row the arrow keys move from.
    private var cursor: Row.ID?
    /// What was selected before the current ⇧ range, so ⌘-clicked rows survive extending it.
    private var rangeBase: Set<Row.ID> = []
    /// The selection as this selector last set it. Anything else means the page changed it (Clear Selection,
    /// a quick select, a delete), and the anchor and range above no longer describe it.
    private var lastSet: Set<Row.ID>?
    /// The rows' scroll position and visible height, for Page Up and Page Down.
    var scrollOffset: CGFloat = 0
    var pageHeight: CGFloat = 0

    private(set) var selection: Set<Row.ID> {
        get { selectionBinding.wrappedValue }
        set {
            selectionBinding.wrappedValue = newValue
            lastSet = newValue
        }
    }

    func update(rows: [Row], selection: Binding<Set<Row.ID>>) {
        self.rows = rows
        selectionBinding = selection
    }

    /// What the primary action and context menu act on for a row: the selection if the row is part of it.
    func targets(for id: Row.ID) -> Set<Row.ID> {
        selection.contains(id) ? selection : [id]
    }

    func select(_ id: Row.ID) {
        selection = [id]
        anchor = id
        cursor = id
        rangeBase = []
    }

    func toggle(_ id: Row.ID) {
        forgetRangeIfChangedElsewhere()
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        anchor = id
        cursor = id
        rangeBase = selection
    }

    func extend(to id: Row.ID) {
        forgetRangeIfChangedElsewhere()
        guard let anchor, rows.contains(where: { $0.id == anchor }) else { return select(id) }
        selection = rangeBase.union(range(from: anchor, to: id))
        cursor = id
    }

    func selectAll() {
        selection = Set(rows.map(\.id))
        rangeBase = []
    }

    func clear() {
        selection.removeAll()
        rangeBase = []
    }

    /// Moves the selection one row up or down (⇧ extends it) and returns the row to scroll to.
    func move(down: Bool, extending: Bool) -> Row.ID {
        forgetRangeIfChangedElsewhere(keepingRun: true)
        let ids = rows.map(\.id)
        let selected = selection
        let current: Int? = {
            if let cursor, selected.contains(cursor), let index = ids.firstIndex(of: cursor) { return index }
            let indices = ids.indices.filter { selected.contains(ids[$0]) }
            return down ? indices.last : indices.first
        }()
        let target = current.map { min(max($0 + (down ? 1 : -1), 0), ids.count - 1) } ?? (down ? 0 : ids.count - 1)
        let id = ids[target]
        if extending, let current {
            if anchor == nil || !selected.contains(anchor!) { anchor = ids[current] }
            extend(to: id)
        } else {
            select(id)
        }
        return id
    }

    /// After the page changed the selection, a ⇧ range builds on what's selected now, never on rows it deselected.
    /// As in NSTableView, a ⇧-click starts from the last selected row if the anchor was deselected, and resizes the
    /// selected run around the anchor while keeping the page's other picks. ⇧-arrows (`keepingRun`) keep them all and,
    /// with the anchor gone, grow from the end they move toward (see `move`), so they never fill the gaps between picks.
    private func forgetRangeIfChangedElsewhere(keepingRun: Bool = false) {
        let current = selection
        guard current != lastSet else { return }
        lastSet = current
        rangeBase = current
        if anchor.map({ !current.contains($0) }) ?? true {
            anchor = keepingRun ? nil : rows.last { current.contains($0.id) }?.id
            cursor = nil
        }
        guard !keepingRun, let anchor, let index = rows.firstIndex(where: { $0.id == anchor }) else { return }
        var low = index, high = index
        while low > 0, current.contains(rows[low - 1].id) { low -= 1 }
        while high < rows.count - 1, current.contains(rows[high + 1].id) { high += 1 }
        rangeBase.subtract(rows[low...high].map(\.id))
    }

    private func range(from start: Row.ID, to end: Row.ID) -> Set<Row.ID> {
        guard let from = rows.firstIndex(where: { $0.id == start }),
              let to = rows.firstIndex(where: { $0.id == end }) else { return [end] }
        return Set(rows[min(from, to)...max(from, to)].map(\.id))
    }
}

/// A page kept alive behind another sidebar section must not keep the keyboard.
/// Only this modifier reads `isActiveSection`, so switching sections doesn't re-render the table.
private struct FocusableWhileActive: ViewModifier {
    @Environment(\.isActiveSection) private var isActiveSection

    func body(content: Content) -> some View {
        content.focusable(isActiveSection)
    }
}

private struct LiteTableRow<Row: Identifiable>: View {
    let row: Row
    let columns: [LiteColumn<Row>]
    let widths: [CGFloat]
    let height: CGFloat
    let isStriped: Bool
    let isSelected: Bool
    let joinsAbove: Bool
    let joinsBelow: Bool
    let isEmphasized: Bool
    let inset: CGFloat
    let cellPadding: CGFloat
    let spacing: CGFloat
    let label: String?
    let menuTargets: Set<Row.ID>
    let menu: ((Set<Row.ID>) -> AnyView)?
    let primaryActionName: String?
    let onClick: () -> Void
    let onSelect: () -> Void
    let onPrimaryAction: () -> Void

    @State private var isHovered = false

    private static var stripe: Color { Color(nsColor: NSColor.alternatingContentBackgroundColors[1]) }

    var body: some View {
        let emphasized = isSelected && isEmphasized
        HStack(spacing: spacing) {
            ForEach(columns.indices, id: \.self) { index in
                columns[index].cell(row)
                    .frame(width: widths[index], alignment: columns[index].alignment)
            }
        }
        .padding(.horizontal, cellPadding)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .environment(\.backgroundProminence, emphasized ? .increased : .standard)
        .background(background, in: UnevenRoundedRectangle(
            topLeadingRadius: joinsAbove ? 0 : 5, bottomLeadingRadius: joinsBelow ? 0 : 5,
            bottomTrailingRadius: joinsBelow ? 0 : 5, topTrailingRadius: joinsAbove ? 0 : 5, style: .continuous))
        .padding(.horizontal, inset)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .onHover { isHovered = $0 }
        .contextMenu {
            if let menu { menu(menuTargets) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label.map { Text($0) } ?? Text(""))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(.default, onSelect)
        .accessibilityActions {
            if let primaryActionName { Button(primaryActionName, action: onPrimaryAction) }
        }
    }

    private var background: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color(nsColor: isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor))
        }
        if isHovered { return AnyShapeStyle(Color.primary.opacity(0.06)) }
        return isStriped ? AnyShapeStyle(Self.stripe) : AnyShapeStyle(Color.clear)
    }
}
