import AppKit
import Observation
import SwiftUI

// Building blocks for the per-website heat grid (DomainMatrixView).
// Every server column always fits the available width; when even the thinnest columns can't fit,
// the columns are paged with a visible pager instead of a hidden horizontal scroll.

// MARK: - Options

enum ValueMode: String, CaseIterable, Identifiable {
    case milliseconds, delta, hidden

    var id: Self { self }

    var title: String {
        switch self {
        case .milliseconds: "Milliseconds"
        case .delta: "Difference from Fastest"
        case .hidden: "Hidden"
        }
    }
}

enum MatrixOrder: String, CaseIterable, Identifiable {
    case slowest = "Slowest first"
    case fastest = "Fastest first"
    case spread = "Biggest difference"
    case name = "A–Z"
    case list = "List order"

    var id: Self { self }
}

struct ServerSort: Equatable {
    let id: UUID
    var ascending: Bool
}

struct DrillTarget: Equatable {
    let row: Int
    let column: Int?
}

enum ColumnPreset: String, CaseIterable, Identifiable {
    case all, top10, top20, answered

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All servers"
        case .top10: "Top 10"
        case .top20: "Top 20"
        case .answered: "Answered only"
        }
    }

    /// Never returns an empty list: falls back to every server.
    func apply(_ ranked: [ServerResult], hidden: Set<UUID>) -> [ServerResult] {
        let visible = ranked.filter { !hidden.contains($0.id) }
        let answered = visible.filter { $0.successes > 0 }
        let list: [ServerResult]
        switch self {
        case .all: list = visible
        case .top10: list = Array(answered.prefix(10))
        case .top20: list = Array(answered.prefix(20))
        case .answered: list = answered
        }
        return list.isEmpty ? ranked : list
    }
}

// MARK: - Layout

enum GridDensity: Hashable {
    case comfortable, compact, dense

    var showsNumbers: Bool { self != .dense }
}

/// Pure width maths: how wide each part of the grid is for a given available width.
struct GridLayout: Hashable {
    static let inset: CGFloat = 12
    static let gutter: CGFloat = 8
    static let minColumn: CGFloat = 14
    static let maxColumn: CGFloat = 104
    static let inspectorHeight: CGFloat = 30
    static let labelCap: CGFloat = 88
    static let angle: Double = 55

    private(set) var narrow = false
    private(set) var nameWidth: CGFloat = 0
    private(set) var bestWidth: CGFloat = 0
    private(set) var avgWidth: CGFloat = 0
    private(set) var columnWidth: CGFloat = 0
    private(set) var visibleColumns = 0
    private(set) var totalColumns = 0
    private(set) var density: GridDensity = .comfortable
    private(set) var labelHeight: CGFloat = 0

    /// `available` is the width of the whole websites view (never the card itself, which depends on this).
    init(available: CGFloat, labels: [String]) {
        let count = max(labels.count, 1)
        let inner = max(0, available - 2 * Self.inset)
        narrow = inner < 760
        bestWidth = narrow ? 24 : 76
        avgWidth = narrow ? 46 : 52
        nameWidth = (narrow ? (inner * 0.20).clamped(112, 150) : (inner * 0.17).clamped(140, 210)).rounded()
        let area = max(0, inner - nameWidth - 2 * Self.gutter - bestWidth - avgWidth)
        func fit(_ columns: Int, gap: CGFloat) -> CGFloat { ((area + gap) / CGFloat(columns) - gap).rounded(.down) }

        totalColumns = labels.count
        var column = fit(count, gap: 2)
        if column < 28 { column = min(fit(count, gap: 1), 27) } // the dense tier uses 1 pt gaps
        if column >= Self.minColumn {
            visibleColumns = labels.count
            if column > Self.maxColumn {
                // Few servers: cap the columns, give the spare room to website names, and let the card hug its content.
                let used = CGFloat(count) * (Self.maxColumn + 2) - 2
                nameWidth = min(nameWidth + (area - used), 280)
                column = Self.maxColumn
            }
        } else {
            visibleColumns = max(1, Int((area + 1) / (Self.minColumn + 1)))
            column = min(fit(visibleColumns, gap: 1), 27)
        }
        columnWidth = column
        density = column >= 60 ? .comfortable : (column >= 28 ? .compact : .dense)
        labelHeight = density == .comfortable ? 28 : Self.angledHeight(labels)
    }

    var gap: CGFloat { density == .dense ? 1 : 2 }
    var pitchX: CGFloat { columnWidth + gap }
    var rowHeight: CGFloat {
        switch density {
        case .comfortable: 26
        case .compact: 24
        case .dense: 20
        }
    }
    var cellsWidth: CGFloat { max(0, CGFloat(visibleColumns) * pitchX - gap) }
    var cardWidth: CGFloat { 2 * Self.inset + nameWidth + Self.gutter + cellsWidth + Self.gutter + bestWidth + avgWidth }
    var overflows: Bool { visibleColumns < totalColumns }
    var avatarSize: CGFloat { (columnWidth - 4).clamped(10, 20) }
    var columnHeaderHeight: CGFloat { labelHeight + 3 + avatarSize + 6 }

    /// x of visible column `index` inside a row (rows are padded by `inset`).
    func cellX(_ index: Int) -> CGFloat { Self.inset + nameWidth + Self.gutter + CGFloat(index) * pitchX }

    static func angledHeight(_ labels: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return (min(widest + 4, labelCap) * sin(angle * .pi / 180)).rounded(.up) + 8
    }
}

// MARK: - Model

/// Flat, row-major copy of the run's per-website results for the shown servers.
/// `.nan` = not tested yet, `.infinity` = never answered.
struct GridModel {
    let servers: [ServerResult]
    let labels: [String]
    let domains: [String]
    let values: [Double]
    let partial: [Bool]
    let rowBest: [Double]
    let rowBestCol: [Int?]
    let rowWorst: [Double]
    let rowWorstCol: [Int?]
    let rowMean: [Double]
    /// Filtered and sorted indices into `domains`.
    let rowOrder: [Int]
    /// Column statistics over the filtered rows.
    let colMean: [Double]
    let colWins: [Int]
    let colNoAnswer: [Int]
    let scale: HeatScale
    let version: Int
    /// Lookup times, connection times to the servers the answers pointed to, or both together.
    let source: GridSource
    /// The connection times behind the values, when they use them.
    let destinations: DestinationReport?

    var n: Int { servers.count }
    func value(_ row: Int, _ column: Int) -> Double { values[row * n + column] }

    /// Smallest column average, and which column has it.
    var bestColumn: (index: Int, mean: Double)? {
        colMean.enumerated().filter { $0.element.isFinite }.min { $0.element < $1.element }.map { ($0.offset, $0.element) }
    }

    init(run: BenchmarkRun, servers: [ServerResult], colour: HeatColourMode, search: String,
         categories: [String: WebsiteCategory], order: MatrixOrder, serverSort: ServerSort?, source: GridSource = .lookup) {
        let n = servers.count
        let destinations = source.usesConnections ? run.destinations : nil
        let domains = run.domains
        let rows = domains.count
        var values = [Double](repeating: .nan, count: rows * n)
        var partial = [Bool](repeating: false, count: rows * n)
        var best = [Double](repeating: .infinity, count: rows)
        var bestCol = [Int?](repeating: nil, count: rows)
        var worst = [Double](repeating: -.infinity, count: rows)
        var worstCol = [Int?](repeating: nil, count: rows)
        var mean = [Double](repeating: .infinity, count: rows)

        for (r, domain) in domains.enumerated() {
            var sum = 0.0
            var count = 0
            for (c, server) in servers.enumerated() {
                let index = r * n + c
                let average: Double
                if let destinations {
                    guard let time = destinations.time(server.id, domain) else { continue }
                    guard time.isFinite else {
                        values[index] = .infinity
                        continue
                    }
                    if source == .combined {
                        guard let stat = server.domainStats[domain], stat.attempts > 0 else { continue }
                        partial[index] = stat.failures > 0
                        guard let lookup = stat.mean else {
                            values[index] = .infinity
                            continue
                        }
                        average = lookup + DestinationReport.tripsPerNewWebsite * time
                    } else {
                        average = time
                    }
                } else {
                    guard let stat = server.domainStats[domain], stat.attempts > 0 else { continue }
                    partial[index] = stat.failures > 0
                    guard let mean = stat.mean else {
                        values[index] = .infinity
                        continue
                    }
                    average = mean
                }
                values[index] = average
                sum += average
                count += 1
                if average < best[r] { best[r] = average; bestCol[r] = c }
                if average > worst[r] { worst[r] = average; worstCol[r] = c }
            }
            if count > 0 { mean[r] = sum / Double(count) }
        }

        // Filter by domain or category name.
        let query = search.trimmingCharacters(in: .whitespaces)
        var order_ = Array(domains.indices)
        if !query.isEmpty {
            order_ = order_.filter {
                domains[$0].localizedCaseInsensitiveContains(query)
                    || (categories[domains[$0]]?.title.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        // Sort. Missing values always go last; ties keep list order.
        func key(_ value: Double, ascending: Bool) -> Double {
            value.isFinite ? (ascending ? value : -value) : .greatestFiniteMagnitude
        }
        func stableSort(_ by: (Int) -> Double) {
            order_ = order_.enumerated()
                .sorted { a, b in
                    let ka = by(a.element), kb = by(b.element)
                    return ka != kb ? ka < kb : a.offset < b.offset
                }
                .map(\.element)
        }
        if let sort = serverSort, let c = servers.firstIndex(where: { $0.id == sort.id }) {
            stableSort { key(values[$0 * n + c], ascending: sort.ascending) }
        } else {
            switch order {
            case .slowest: stableSort { key(mean[$0], ascending: false) }
            case .fastest: stableSort { key(mean[$0], ascending: true) }
            case .spread: stableSort { r in best[r].isFinite && worst[r] > best[r] ? -(worst[r] / best[r]) : .greatestFiniteMagnitude }
            case .name: order_.sort { domains[$0].localizedStandardCompare(domains[$1]) == .orderedAscending }
            case .list: break
            }
        }

        var columnSum = [Double](repeating: 0, count: n)
        var columnCount = [Int](repeating: 0, count: n)
        var wins = [Int](repeating: 0, count: n)
        var none = [Int](repeating: 0, count: n)
        for r in order_ {
            if let c = bestCol[r] { wins[c] += 1 }
            for c in 0..<n {
                let value = values[r * n + c]
                if value.isFinite {
                    columnSum[c] += value
                    columnCount[c] += 1
                } else if value.isInfinite {
                    none[c] += 1
                }
            }
        }
        colMean = (0..<n).map { columnCount[$0] > 0 ? columnSum[$0] / Double(columnCount[$0]) : (none[$0] > 0 ? .infinity : .nan) }
        colWins = wins
        colNoAnswer = none

        let nameCount = Dictionary(servers.map { ($0.name, 1) }, uniquingKeysWith: +)
        labels = servers.map { nameCount[$0.name, default: 0] > 1 ? "\($0.name) · \($0.shortAddress)" : $0.name }
        // Colour range comes from every row, so filtering never recolours the grid.
        scale = HeatScale(mode: colour, sortedFinite: values.filter(\.isFinite).sorted())
        var hasher = Hasher()
        hasher.combine(run.id)
        hasher.combine(run.totalLookups)
        hasher.combine(servers.map(\.id))
        hasher.combine(colour)
        hasher.combine(source)
        hasher.combine(run.destinationCheck?.date)
        version = hasher.finalize()
        self.source = source
        self.destinations = destinations

        self.servers = servers
        self.domains = domains
        self.values = values
        self.partial = partial
        rowBest = best
        rowBestCol = bestCol
        rowWorst = worst
        rowWorstCol = worstCol
        rowMean = mean
        rowOrder = order_
    }

    func answeredCount(row r: Int) -> Int {
        (0..<n).filter { value(r, $0).isFinite }.count
    }

    func spokenSummary(row r: Int) -> String {
        var parts = [domains[r]]
        if let c = rowBestCol[r] { parts.append("Fastest \(servers[c].name), \(Int(rowBest[r].rounded())) milliseconds") }
        if rowMean[r].isFinite { parts.append("Average \(Int(rowMean[r].rounded())) milliseconds") }
        if let c = rowWorstCol[r], c != rowBestCol[r] { parts.append("Slowest \(servers[c].name), \(Int(rowWorst[r].rounded())) milliseconds") }
        let none = (0..<n).filter { value(r, $0).isInfinite }.count
        if none > 0 { parts.append("\(none) server\(none == 1 ? "" : "s") did not answer") }
        return parts.joined(separator: ". ")
    }

    /// Tab-separated header and row, ready to paste into a spreadsheet.
    func tsv(row r: Int) -> String {
        let header = (["Website"] + servers.map(\.name)).joined(separator: "\t")
        let cells = (0..<n).map { c -> String in
            let value = value(r, c)
            return value.isFinite ? String(format: "%.2f", value) : (value.isInfinite ? "no answer" : "")
        }
        return header + "\n" + ([domains[r]] + cells).joined(separator: "\t")
    }
}

// MARK: - Hover

/// What the mouse is over. Only the crosshair overlays and the inspector read it, so hovering never redraws the grid.
@Observable
final class GridPointer {
    enum Part: Equatable { case name, cells, header }

    struct Target: Equatable {
        var row: Int?
        var column: Int?
        var part: Part
    }

    private(set) var target: Target?

    func set(_ newTarget: Target) {
        if newTarget != target { target = newTarget }
    }

    /// Leaving one row can be reported after entering the next, so only clear a matching target.
    func clear(row: Int?, part: Part) {
        if let target, target.row == row, target.part == part { self.target = nil }
    }
}

// MARK: - Cells

/// One Canvas per row. Equatable on a precomputed key (values contain NaN, and NaN != NaN).
struct HeatRow: View, Equatable {
    let key: Int
    let values: [Double]
    let partial: [Bool]
    /// Index of the row's fastest server inside this window, if it's visible.
    let bestIndex: Int?
    let rowBest: Double
    let scale: HeatScale
    let layout: GridLayout
    let valueMode: ValueMode
    let markBest: Bool
    let dark: Bool

    static func == (a: Self, b: Self) -> Bool { a.key == b.key }

    var body: some View {
        Canvas { context, _ in
            let fills = HeatPalette.fills(dark: dark)
            let inks = HeatPalette.inks(dark: dark)
            let size: CGFloat = layout.density == .comfortable ? 11 : 10
            let regular = Font.system(size: size, weight: dark ? .semibold : .medium).monospacedDigit()
            let bold = Font.system(size: size, weight: .bold).monospacedDigit()
            let radius = min(4, layout.columnWidth / 5)
            var cache: [String: GraphicsContext.ResolvedText] = [:]

            for index in values.indices {
                let value = values[index]
                let rect = CGRect(x: CGFloat(index) * layout.pitchX, y: layout.gap / 2,
                                  width: layout.columnWidth, height: layout.rowHeight - layout.gap)
                let cell = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)

                if value.isNaN {
                    context.fill(cell, with: .color(.primary.opacity(0.04)))
                    continue
                }
                if value.isInfinite {
                    context.fill(cell, with: .color(.red.opacity(dark ? 0.22 : 0.14)))
                    let s = min(3.5, rect.height / 4)
                    var cross = Path()
                    cross.move(to: CGPoint(x: rect.midX - s, y: rect.midY - s))
                    cross.addLine(to: CGPoint(x: rect.midX + s, y: rect.midY + s))
                    cross.move(to: CGPoint(x: rect.midX + s, y: rect.midY - s))
                    cross.addLine(to: CGPoint(x: rect.midX - s, y: rect.midY + s))
                    context.stroke(cross, with: .color(.red), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    continue
                }

                let bucket = scale.bucket(value, rowBest: rowBest)
                context.fill(cell, with: .color(fills[bucket]))
                let isBest = index == bestIndex
                if markBest, isBest {
                    let inner = Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: max(0, radius - 0.75), style: .continuous)
                    context.stroke(inner, with: .color(.primary.opacity(0.6)), lineWidth: 1.5)
                }
                if partial[index] {
                    var corner = Path()
                    corner.move(to: CGPoint(x: rect.maxX - 6, y: rect.minY))
                    corner.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    corner.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 6))
                    corner.closeSubpath()
                    context.fill(corner, with: .color(.orange))
                    // Outline in the cell's text colour so the marker stays visible on orange-ish fills.
                    context.stroke(corner, with: .color(inks[bucket].opacity(0.75)), lineWidth: 0.75)
                }

                guard layout.density.showsNumbers, valueMode != .hidden else { continue }
                let label = (valueMode == .delta && !isBest && rowBest.isFinite) ? "+" + Format.msValue(value - rowBest) : Format.msValue(value)
                let cacheKey = (isBest ? "b" : "r") + label
                var text = cache[cacheKey] ?? context.resolve(Text(label).font(isBest ? bold : regular))
                cache[cacheKey] = text
                // Never draw clipped digits; the inspector shows the exact value instead.
                guard text.measure(in: rect.size).width <= rect.width - 4 else { continue }
                text.shading = .color(inks[bucket])
                context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
        .frame(width: layout.cellsWidth, height: layout.rowHeight)
        .accessibilityHidden(true)
    }
}

/// Row and column highlight for one row. The only part of a row that observes the pointer.
struct RowCrosshair: View {
    let pointer: GridPointer
    let row: Int
    let layout: GridLayout
    let first: Int
    @Environment(\.accent) private var accent

    var body: some View {
        let target = pointer.target
        let inRow = target?.row == row
        ZStack(alignment: .topLeading) {
            if inRow { Rectangle().fill(accent.opacity(0.07)) }
            if let column = target?.column, column >= first, column < first + layout.visibleColumns {
                let x = layout.cellX(column - first)
                Rectangle()
                    .fill(accent.opacity(0.10))
                    .frame(width: layout.pitchX, height: layout.rowHeight)
                    .offset(x: x - layout.gap / 2)
                if inRow, target?.part == .cells {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary, lineWidth: 2)
                        .frame(width: layout.columnWidth + 2, height: layout.rowHeight - layout.gap + 2)
                        .offset(x: x - 1, y: layout.gap / 2 - 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Column highlight in the header strip.
struct HeaderBand: View {
    let pointer: GridPointer
    let layout: GridLayout
    let first: Int
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let column = pointer.target?.column, column >= first, column < first + layout.visibleColumns {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accent.opacity(0.10))
                    .frame(width: layout.pitchX)
                    .offset(x: CGFloat(column - first) * layout.pitchX - layout.gap / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

struct NameCell: View {
    let domain: String
    let category: WebsiteCategory?
    let dense: Bool
    let rowHeight: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(category?.color ?? Color.secondary.opacity(0.3))
                .frame(width: 3, height: max(8, rowHeight - 10))
            Text(domain)
                .font(.system(size: dense ? 11 : 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct BestCell: View {
    let server: ServerResult?
    let value: Double
    let narrow: Bool

    var body: some View {
        if let server, value.isFinite {
            HStack(spacing: 4) {
                ServerAvatar(name: server.avatarName, color: server.color, isSystem: server.isSystem, size: 14)
                if !narrow {
                    Text(Format.msValue(value))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            .help("Fastest: \(server.name) · \(Format.ms(value))")
        } else {
            Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Header

/// Spreadsheet-style label at −55°. Rotation doesn't affect layout, so the header reserves `labelHeight`
/// and the label's own frame is 0×0 (it never takes clicks).
struct AngledLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize()
            .frame(maxWidth: GridLayout.labelCap, alignment: .leading)
            .frame(width: 0, height: 0, alignment: .leading)
            .offset(x: 0)
            .rotationEffect(.degrees(-GridLayout.angle), anchor: .center)
            .accessibilityHidden(true)
    }
}

struct ColumnHeaderCell: View {
    let server: ServerResult
    let label: String
    let layout: GridLayout
    let sort: ServerSort?

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                Color.clear
                if layout.density == .comfortable {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(width: layout.columnWidth - 4)
                } else {
                    AngledLabel(text: label)
                        .padding(.bottom, 2)
                }
            }
            .frame(width: layout.columnWidth, height: layout.labelHeight)
            ServerAvatar(name: server.avatarName, color: server.color, isSystem: server.isSystem, size: layout.avatarSize)
                .overlay(alignment: .bottomTrailing) {
                    if let sort, sort.id == server.id {
                        Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(.tint)
                            .offset(x: 4, y: 3)
                    }
                }
        }
        .frame(width: layout.columnWidth, height: layout.columnHeaderHeight - 6, alignment: .bottom)
        .contentShape(Rectangle())
    }
}

/// The exact numbers for whatever the mouse is over.
struct InspectorText: View {
    let model: GridModel
    let pointer: GridPointer
    let rounds: Int
    let categories: [String: WebsiteCategory]

    var body: some View {
        Group {
            if let target = pointer.target {
                content(for: target)
            } else {
                idle
            }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
    }

    private var idle: some View {
        Label("\(model.rowOrder.count) website\(model.rowOrder.count == 1 ? "" : "s") × \(model.n) server\(model.n == 1 ? "" : "s") · hover a cell for exact times · click a website to see every server", systemImage: "cursorarrow.rays")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func content(for target: GridPointer.Target) -> some View {
        switch target.part {
        case .cells:
            if let r = target.row, let c = target.column, r < model.domains.count, c < model.n { cell(r, c) } else { idle }
        case .name:
            if let r = target.row, r < model.domains.count { website(r) } else { idle }
        case .header:
            if let c = target.column, c < model.n { column(c) } else { idle }
        }
    }

    private func cell(_ r: Int, _ c: Int) -> some View {
        let server = model.servers[c]
        let domain = model.domains[r]
        let value = model.value(r, c)
        let stat = server.domainStats[domain]
        var long = "", medium = "", short = ""
        if model.source == .combined, value.isFinite {
            let connection = model.destinations?.time(server.id, domain) ?? .nan
            let lookup = value - DestinationReport.tripsPerNewWebsite * connection
            let rank = 1 + (0..<model.n).filter { model.value(r, $0).isFinite && model.value(r, $0) < value }.count
            let best = model.rowBest[r]
            let bestName = model.rowBestCol[r].map { model.servers[$0].name } ?? "best"
            let versus = rank == 1 ? "soonest" : "+\(Format.ms(value - best)) vs \(bestName)"
            long = "\(server.name) › \(domain) · lookup \(Format.ms(lookup)) + 3 × connection \(Format.ms(connection)) = \(Format.ms(value)) · \(versus)"
            medium = "\(server.name) › \(domain) · \(Format.ms(value)) · \(rank == 1 ? "soonest" : "+\(Format.ms(value - best))")"
            short = "\(server.name) › \(domain) · \(Format.ms(value))"
        } else if model.source.usesConnections {
            let addresses = server.destinations?[domain]?.joined(separator: ", ") ?? "no address"
            if value.isNaN {
                long = "\(server.name) › \(domain) · no server address from this DNS"
                medium = long
                short = "\(server.name) › \(domain) · no address"
            } else if value.isInfinite {
                long = "\(server.name) › \(domain) · couldn't connect to \(addresses)"
                medium = "\(server.name) › \(domain) · couldn't connect"
                short = medium
            } else {
                let rank = 1 + (0..<model.n).filter { model.value(r, $0).isFinite && model.value(r, $0) < value }.count
                let best = model.rowBest[r]
                let bestName = model.rowBestCol[r].map { model.servers[$0].name } ?? "nearest"
                let versus = rank == 1 ? "nearest" : "+\(Format.ms(value - best)) vs \(bestName)"
                long = "\(server.name) › \(domain) · server \(addresses) · connects in \(Format.ms(value)) · \(versus)"
                medium = "\(server.name) › \(domain) · \(Format.ms(value)) · \(rank == 1 ? "nearest" : "+\(Format.ms(value - best))")"
                short = "\(server.name) › \(domain) · \(Format.ms(value))"
            }
        } else if value.isNaN {
            long = "\(server.name) › \(domain) · \(server.leftOut?[domain] == nil ? "not tested yet" : "left out: refuses made-up names here, but answers the real website")"
            medium = "\(server.name) › \(domain) · \(server.leftOut?[domain] == nil ? "not tested yet" : "left out")"
            short = medium
        } else if value.isInfinite {
            long = "\(server.name) › \(domain) · no answer (\(stat?.failures ?? 0) of \(stat?.attempts ?? 0) lookups failed)"
            medium = "\(server.name) › \(domain) · no answer"
            short = medium
        } else {
            let answered = model.answeredCount(row: r)
            let rank = 1 + (0..<model.n).filter { model.value(r, $0).isFinite && model.value(r, $0) < value }.count
            let best = model.rowBest[r]
            let bestName = model.rowBestCol[r].map { model.servers[$0].name } ?? "fastest"
            let versus = rank == 1 ? "fastest" : "+\(Format.ms(value - best)) vs \(bestName)"
            let failures = (stat?.failures ?? 0) > 0 ? " · \(stat!.failures) of \(stat!.attempts) lookups failed" : ""
            long = "\(server.name) · \(server.shortAddress) · \(server.proto.shortTitle) › \(domain)   \(Format.ms(value)) · \(Self.ordinal(rank)) of \(answered) · \(versus) · site avg \(Format.ms(model.rowMean[r]))\(failures)"
            medium = "\(server.name) › \(domain) · \(Format.ms(value)) · \(Self.ordinal(rank)) of \(answered) · \(rank == 1 ? "fastest" : "+\(Format.ms(value - best)) vs fastest")"
            short = "\(server.name) › \(domain) · \(Format.ms(value))"
        }
        return HStack(spacing: 6) {
            ServerAvatar(name: server.avatarName, color: server.color, isSystem: server.isSystem, size: 14)
            ViewThatFits(in: .horizontal) {
                Text(long)
                Text(medium)
                Text(short)
            }
        }
    }

    private func website(_ r: Int) -> some View {
        let domain = model.domains[r]
        var long = domain, short = domain
        if let b = model.rowBestCol[r], let w = model.rowWorstCol[r] {
            let ratio = model.rowBest[r] > 0 ? model.rowWorst[r] / model.rowBest[r] : 1
            let category = categories[domain].map { " · \($0.title)" } ?? ""
            let (low, high, done) = switch model.source {
            case .lookup: ("fastest", "slowest", "answered")
            case .connection: ("nearest", "farthest", "connected")
            case .combined: ("soonest", "latest", "measured")
            }
            long = "\(domain)\(category) · \(low) \(model.servers[b].name) \(Format.ms(model.rowBest[r])) · \(high) \(model.servers[w].name) \(Format.ms(model.rowWorst[r])) (\(String(format: "%.1f", ratio))×) · avg \(Format.ms(model.rowMean[r])) · \(model.answeredCount(row: r)) of \(model.n) \(done)"
            short = "\(domain) · \(Format.msValue(model.rowBest[r]))–\(Format.msValue(model.rowWorst[r])) ms"
        }
        return ViewThatFits(in: .horizontal) {
            Label(long, systemImage: "globe")
            Label(short, systemImage: "globe")
        }
    }

    private func column(_ c: Int) -> some View {
        let server = model.servers[c]
        let mean = model.colMean[c]
        let sites = model.rowOrder.count
        let isConnection = model.source.usesConnections
        let long = "\(server.name) · \(server.shortAddress) · avg \(isConnection ? "connection " : "")\(Format.ms(mean)) over \(sites) website\(sites == 1 ? "" : "s") · \(isConnection ? "nearest" : "fastest") on \(model.colWins[c]) · \(isConnection ? "couldn't connect" : "no answer") on \(model.colNoAnswer[c])"
        let short = "\(server.name) · avg \(Format.ms(mean)) · \(isConnection ? "nearest" : "fastest") on \(model.colWins[c])"
        return HStack(spacing: 6) {
            ServerAvatar(name: server.avatarName, color: server.color, isSystem: server.isSystem, size: 14)
            ViewThatFits(in: .horizontal) {
                Text(long)
                Text(short)
            }
        }
    }

    static func ordinal(_ number: Int) -> String {
        let suffix: String
        switch (number % 10, number % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(number)\(suffix)"
    }
}

/// Shown instead of a horizontal scroll bar when not every server fits.
struct ColumnPager: View {
    let first: Int
    let visible: Int
    let total: Int
    let colours: [Color]
    let onChange: (Int) -> Void
    /// nil hides the shortcut (e.g. during a live test, when columns ignore presets).
    let onTop20: (() -> Void)?

    var body: some View {
        let maxFirst = max(0, total - visible)
        HStack(spacing: 6) {
            Button { onChange(max(0, first - visible)) } label: { Image(systemName: "chevron.left") }
                .disabled(first == 0)
                .help("Previous servers")
            Text("Servers \(first + 1)–\(min(first + visible, total)) of \(total)")
                .font(.caption.monospacedDigit())
            Button { onChange(min(maxFirst, first + visible)) } label: { Image(systemName: "chevron.right") }
                .disabled(first >= maxFirst)
                .help("Next servers")
            Canvas { context, size in
                let tick = size.width / CGFloat(max(total, 1))
                for (index, colour) in colours.enumerated() {
                    context.fill(Path(CGRect(x: CGFloat(index) * tick, y: 0, width: max(1, tick - 1), height: size.height)), with: .color(colour))
                }
                let frame = CGRect(x: CGFloat(first) * tick - 1, y: -1, width: CGFloat(visible) * tick + 1, height: size.height + 2)
                context.stroke(Path(roundedRect: frame, cornerRadius: 2), with: .color(.accentColor), lineWidth: 1.5)
            }
            .frame(width: CGFloat(min(total, 60)) * 3, height: 8)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                let tick = CGFloat(min(total, 60)) * 3 / CGFloat(max(total, 1))
                onChange((Int(point.x / tick) - visible / 2).clamped(0, maxFirst))
            }
            .help("Click to jump to those servers")
            if let onTop20 {
                Button("Top 20", action: onTop20)
                    .help("Show only the 20 fastest servers")
            }
        }
        .buttonStyle(.borderless)
    }
}

struct HeatLegendView: View {
    let scale: HeatScale
    let dark: Bool

    var body: some View {
        let fills = HeatPalette.fills(dark: dark)
        let labels = scale.legend
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 1) {
                ForEach(0..<HeatScale.steps, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2).fill(fills[index]).frame(width: 19, height: 9)
                }
            }
            HStack(spacing: 0) {
                Text(labels.0)
                Spacer(minLength: 4)
                Text(labels.1)
                Spacer(minLength: 4)
                Text(labels.2)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 159)
        }
        .help(scale.mode == .time ? "Colour shows response time on a log scale." : "Colour shows how many times slower than the website's fastest server.")
    }
}

// MARK: - Drill-down

/// Every server's time for one website, fastest first.
struct WebsiteDrillDown: View {
    let model: GridModel
    let row: Int
    let highlight: Int?
    let category: WebsiteCategory?
    let rounds: Int
    let siteEnabled: Bool?
    let onSwitchOff: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        let domain = model.domains[row]
        let entries = (0..<model.n).map { ($0, model.value(row, $0)) }.sorted { a, b in
            func rank(_ value: Double) -> Double { value.isFinite ? value : (value.isInfinite ? .greatestFiniteMagnitude : .infinity) }
            return rank(a.1) < rank(b.1)
        }
        let best = model.rowBest[row]
        let worst = model.rowWorst[row]

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let category { CategoryIcon(category: category, size: 20) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(domain).font(.headline)
                    Text(model.source == .combined
                         ? "\(model.n) server\(model.n == 1 ? "" : "s") · lookup time plus three trips to the server each one pointed to"
                         : model.source == .connection
                         ? "\(model.n) server\(model.n == 1 ? "" : "s") · time to connect to the server each one pointed to"
                         : "\(model.n) server\(model.n == 1 ? "" : "s") · \(rounds) lookup\(rounds == 1 ? "" : "s") each")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.0) { position, entry in
                        let server = model.servers[entry.0]
                        let value = entry.1
                        let stat = server.domainStats[domain]
                        HStack(spacing: 8) {
                            Text("\(position + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            ServerAvatar(name: server.avatarName, color: server.color, isSystem: server.isSystem, size: 16)
                            Text(server.name).lineLimit(1)
                            Spacer(minLength: 6)
                            if value.isFinite {
                                LatencyBar(fraction: Heat.barFraction(for: value, low: best, high: worst),
                                           color: Heat.logColor(for: value, low: best, high: worst))
                                    .frame(width: 70)
                                Text(Format.ms(value))
                                    .font(.callout.monospacedDigit())
                                    .frame(width: 64, alignment: .trailing)
                            } else {
                                Text(model.source.usesConnections
                                     ? (value.isInfinite ? "Couldn't connect" : "No address")
                                     : (value.isInfinite ? "No answer" : server.leftOut?[domain] == nil ? "Not tested" : "Left out"))
                                    .font(.callout)
                                    .foregroundStyle(value.isInfinite ? Color.red : .secondary)
                            }
                            if model.source != .connection, let stat, stat.failures > 0, value.isFinite {
                                Text("\(stat.failures) failed").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 5).fill(entry.0 == highlight ? accent.opacity(0.14) : .clear))
                    }
                }
            }
            .frame(height: min(440, CGFloat(entries.count) * 26))
            Divider()
            HStack {
                Button("Copy Times") { Exporter.copy(model.tsv(row: row)) }
                Spacer()
                Button("Switch Off This Website for Next Tests", action: onSwitchOff)
                    .disabled(siteEnabled != true)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 380)
    }
}
