import SwiftUI

// MARK: - Statistics table

struct StatisticsTable: View {
    let ranked: [ServerResult]
    @State private var sortOrder = [KeyPathComparator(\Row.rank)]

    struct Row: Identifiable {
        let id: UUID
        let rank: Int
        let name: String
        let address: String
        let color: Color
        let score: Double
        let mean: Double
        /// 95% margin of error of the mean.
        let margin: Double
        let median: Double
        let minimum: Double
        let p95: Double
        let maximum: Double
        let jitter: Double
        let success: Double
        let failures: Int
    }

    var body: some View {
        let rows = ranked.enumerated().map { index, result in
            let stats = result.stats
            return Row(
                id: result.id, rank: index + 1, name: result.name, address: result.address, color: result.color,
                score: result.score, mean: stats.mean, margin: stats.marginOfError, median: stats.median, minimum: stats.minimum,
                p95: stats.p95, maximum: stats.maximum, jitter: stats.stdDev,
                success: result.successRate, failures: result.failures
            )
        }
        .sorted(using: sortOrder)

        VStack(alignment: .leading, spacing: 8) {
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("#", value: \.rank) { row in
                    Text("\(row.rank)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(26)
                TableColumn("Server", value: \.name) { row in
                    HStack(spacing: 8) {
                        Circle().fill(row.color).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).fontWeight(.medium)
                            Text(row.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 150, ideal: 180)
                TableColumn("Score", value: \.score) { row in
                    Text(Format.ms(row.score)).fontWeight(.semibold).monospacedDigit()
                }
                .width(min: 56, ideal: 68, max: 100)
                TableColumn("Average", value: \.mean) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Format.ms(row.mean)).monospacedDigit()
                        if row.mean.isFinite, row.margin.isFinite {
                            Text("± \(Format.ms(row.margin))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 58, ideal: 68, max: 100)
                TableColumn("Median", value: \.median) { Text(Format.ms($0.median)).monospacedDigit() }
                .width(min: 52, ideal: 62, max: 100)
                TableColumn("Fastest", value: \.minimum) { Text(Format.ms($0.minimum)).monospacedDigit() }
                .width(min: 52, ideal: 62, max: 100)
                TableColumn("95th %", value: \.p95) { Text(Format.ms($0.p95)).monospacedDigit() }
                .width(min: 52, ideal: 62, max: 100)
                TableColumn("Slowest", value: \.maximum) { Text(Format.ms($0.maximum)).monospacedDigit() }
                .width(min: 52, ideal: 62, max: 100)
                TableColumn("Jitter", value: \.jitter) { Text(Format.ms($0.jitter)).monospacedDigit() }
                .width(min: 52, ideal: 62, max: 100)
                TableColumn("Answered", value: \.success) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Format.percent(row.success)).monospacedDigit()
                        if row.failures > 0 {
                            Text("\(row.failures) failed").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .width(min: 66, ideal: 84)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollDisabled(true)
            .frame(height: CGFloat(rows.count) * 40 + 34)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))

            Text("Click a column header to sort. **Score** is the average with every failed lookup counted as a full timeout. **Jitter** is the standard deviation — lower means steadier. **±** under the average is its 95% margin of error.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Per-website heat grid

/// Every website × every server, always fitted to the available width (see HeatGrid.swift).
struct DomainMatrixView: View {
    let run: BenchmarkRun
    /// Ranked, same order as the leaderboard.
    let servers: [ServerResult]
    var isLive = false
    var allowsRetest = false

    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.contentWidthLimit) private var widthLimit
    @AppStorage("websites.colour") private var colour: HeatColourMode = .time
    @AppStorage("websites.values") private var valueMode: ValueMode = .milliseconds
    @AppStorage("websites.markBest") private var markBest = true
    @AppStorage("websites.columns") private var preset: ColumnPreset = .all
    @AppStorage("websites.source") private var source: GridSource = .lookup
    @State private var search = ""
    @State private var order: MatrixOrder = .slowest
    @State private var serverSort: ServerSort?
    @State private var hidden: Set<UUID> = []
    @State private var firstColumn = 0
    @State private var drill: DrillTarget?
    @State private var pendingSwitchOff: PendingSwitchOff?
    @State private var width: CGFloat = 0
    /// Passed down to the overlays; never read in this body, so hovering doesn't rebuild the grid.
    @State private var pointer = GridPointer()

    var body: some View {
        let columns: [ServerResult] = isLive
            ? servers.sorted { runIndex($0) < runIndex($1) }
            : preset.apply(servers, hidden: hidden)
        let sites = Dictionary(store.websites.map { ($0.domain, $0) }, uniquingKeysWith: { first, _ in first })
        let categories = sites.mapValues(\.category)
        // A per-server sort only applies while that server's column is shown (presets and hiding can remove it).
        let activeSort = isLive ? nil : serverSort.flatMap { sort in columns.contains { $0.id == sort.id } ? sort : nil }
        let model = GridModel(run: run, servers: columns, colour: colour, search: search, categories: categories,
                              order: isLive ? .list : order, serverSort: activeSort, source: shownSource)
        let available = widthLimit > 0 ? min(width, widthLimit) : width
        let layout = GridLayout(available: available, labels: model.labels)
        let first = min(firstColumn, max(0, columns.count - layout.visibleColumns))
        let dark = scheme == .dark
        let ranked = run.domains.indices.filter { model.rowMean[$0].isFinite }.sorted { model.rowMean[$0] < model.rowMean[$1] }

        // Measure the width offered by the parent with a zero-height probe. Measuring the content itself would
        // feed back: a wide grid would keep the view wide after the window shrinks.
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width.rounded(.down)
                } action: { newWidth in
                    if abs(newWidth - width) >= 1 { width = newWidth }
                }
            VStack(alignment: .leading, spacing: 14) {
                if ranked.count >= 6, !isLive {
                    let verb = switch model.source {
                    case .lookup: "resolve"
                    case .connection: "connect to"
                    case .combined: "start loading"
                    }
                    HStack(alignment: .top, spacing: 12) {
                        DomainHighlights(title: "Quickest to \(verb)", icon: "hare.fill", tint: .green,
                                         rows: ranked.prefix(5).map { (model.domains[$0], model.rowMean[$0]) })
                        DomainHighlights(title: "Slowest to \(verb)", icon: "tortoise.fill", tint: .red,
                                         rows: ranked.suffix(5).reversed().map { (model.domains[$0], model.rowMean[$0]) })
                    }
                }

                toolbar(model: model, shown: columns.count, dark: dark, available: available)

                if available > 0, !columns.isEmpty, !run.domains.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(model.rowOrder.enumerated()), id: \.element) { position, r in
                                let site = sites[model.domains[r]]
                                MatrixRow(r: r, zebra: !position.isMultiple(of: 2), model: model, layout: layout, first: first,
                                          category: site?.category, pointer: pointer,
                                          heatKey: rowKey(model, r, layout, first, dark), valueMode: valueMode,
                                          markBest: markBest, dark: dark, rounds: run.rounds,
                                          siteID: site?.id, siteEnabled: site?.isEnabled,
                                          canShowAll: !isLive && (preset != .all || !hidden.isEmpty),
                                          onShowAll: showAllServers,
                                          onSwitchOffSite: { id in store.setWebsites([id], enabled: false) },
                                          drill: $drill)
                            }
                            if model.rowOrder.isEmpty {
                                HStack {
                                    Text("No websites match “\(search)”").foregroundStyle(.secondary)
                                    Button("Clear Filter") { search = "" }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        } header: {
                            header(model: model, layout: layout, first: first, dark: dark)
                        }
                    }
                    .padding(.bottom, 6)
                    .frame(width: layout.cardWidth, alignment: .leading)
                    .animation(.snappy, value: isLive)
                    .background {
                        // Shadow on the shape only: a whole-view shadow would rasterise the tall grid.
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                            .allowsHitTesting(false)
                    }
                } else if available > 0 {
                    ContentUnavailableView("No website results yet", systemImage: "globe",
                                           description: Text("Start a test to see how fast each server resolves each website."))
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .card()
                }

                if !isLive {
                    RetestFailuresBar(run: run, allowsRetest: allowsRetest)
                }

                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // minWidth 0: the fixed-width grid must never set a minimum width for the window. If it did, shrinking the
        // window would collapse the sidebar and clip the page instead of re-fitting the columns.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Switch off \(pendingSwitchOff?.name ?? "this server")?",
                            isPresented: Binding(get: { pendingSwitchOff != nil }, set: { if !$0 { pendingSwitchOff = nil } }),
                            presenting: pendingSwitchOff) { server in
            Button("Switch Off") { store.setServers([server.storeID], enabled: false) }
        } message: { server in
            Text("\(server.name) will be skipped in future tests. You can switch it back on in DNS Servers.")
        }

    }

    /// Connection times once the test's destinations have been checked; lookup times otherwise.
    private var shownSource: GridSource {
        !isLive && run.destinationCheck != nil ? source : .lookup
    }

    // MARK: Toolbar

    @ViewBuilder
    private func toolbar(model: GridModel, shown: Int, dark: Bool, available: CGFloat) -> some View {
        let sourcePicker = Picker("Show", selection: $source) {
            ForEach(GridSource.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Lookup time: how fast each DNS answered. Connection time: how long it takes to connect to the server each DNS pointed to, which shows whether it sends you to a near or far copy of the website. Lookup + connection: the two together, as a new visit uses them: one lookup, then three trips to the server.")
        let showsSourcePicker = !isLive && run.destinationCheck != nil

        let filter = HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter websites or categories", text: $search)
                .textFieldStyle(.plain)
                .editableWhileSectionActive()
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .frame(minWidth: 150, maxWidth: 240)

        let sortControls = HStack(spacing: 8) {
            Picker("Sort", selection: Binding(get: { order }, set: { order = $0; serverSort = nil })) {
                ForEach(MatrixOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            .disabled(isLive)
            if let sort = serverSort, let server = model.servers.first(where: { $0.id == sort.id }), !isLive {
                Button { serverSort = nil } label: {
                    Label("\(server.name) \(sort.ascending ? "↑" : "↓")", systemImage: "xmark")
                }
                .buttonStyle(ChipButtonStyle(isSelected: true))
                .help("Sorted by this server. Click to clear.")
            }
            if isLive {
                Label("Order updates when the test finishes", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }

        let serversMenu = Menu {
            Picker("Columns", selection: $preset) {
                ForEach(ColumnPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            if !hidden.isEmpty {
                Divider()
                Button("Show \(hidden.count) Hidden Server\(hidden.count == 1 ? "" : "s")") { hidden.removeAll() }
            }
        } label: {
            Label("\(shown) of \(servers.count) server\(servers.count == 1 ? "" : "s")", systemImage: "server.rack")
        }
        .fixedSize()
        .disabled(isLive)

        let colourPicker = Picker("Colour", selection: $colour) {
            ForEach(HeatColourMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Time: log scale of milliseconds. vs Fastest: how much slower than that website's fastest server.")

        let display = Menu {
            Picker("Numbers", selection: $valueMode) {
                ForEach(ValueMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Outline Fastest per Website", isOn: $markBest)
        } label: {
            Label("Display", systemImage: "slider.horizontal.3")
        }
        .fixedSize()

        let legend = HeatLegendView(scale: model.scale, dark: dark)

        // Pick the widest arrangement that really fits, instead of guessing a breakpoint.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                if showsSourcePicker { sourcePicker }
                filter
                sortControls
                serversMenu
                colourPicker
                display
                Spacer(minLength: 12)
                legend
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if showsSourcePicker { sourcePicker }
                    filter
                    sortControls
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    serversMenu
                    colourPicker
                    display
                    Spacer(minLength: 12)
                    legend
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if showsSourcePicker { sourcePicker }
                HStack(spacing: 10) {
                    filter
                    sortControls
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    serversMenu
                    colourPicker
                    display
                }
                legend
            }
        }
        .frame(maxWidth: max(available, 1), alignment: .leading)
    }

    // MARK: Sticky header

    private func header(model: GridModel, layout: GridLayout, first: Int, dark: Bool) -> some View {
        let lo = first
        let hi = min(first + layout.visibleColumns, model.n)
        let bestColumn = model.bestColumn
        let finiteMeans = model.colMean.filter(\.isFinite)
        let overall = finiteMeans.isEmpty ? Double.infinity : finiteMeans.reduce(0, +) / Double(finiteMeans.count)

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                InspectorText(model: model, pointer: pointer, rounds: run.rounds,
                              categories: Dictionary(store.websites.map { ($0.domain, $0.category) }, uniquingKeysWith: { first, _ in first }))
                Spacer(minLength: 8)
                if layout.overflows {
                    ColumnPager(first: first, visible: layout.visibleColumns, total: model.n,
                                colours: model.colMean.map { mean in
                                    mean.isFinite ? HeatPalette.fills(dark: dark)[model.scale.bucket(mean, rowBest: bestColumn?.mean ?? mean)] : Color.red.opacity(0.3)
                                },
                                onChange: { firstColumn = $0 },
                                onTop20: isLive ? nil : { preset = .top20; firstColumn = 0 })
                }
            }
            .frame(height: GridLayout.inspectorHeight)
            .padding(.horizontal, GridLayout.inset)

            Divider()

            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("WEBSITE")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text(model.rowOrder.count == model.domains.count ? "\(model.domains.count)" : "\(model.rowOrder.count) of \(model.domains.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .frame(width: layout.nameWidth, alignment: .bottomLeading)
                .padding(.bottom, 4)
                Color.clear.frame(width: GridLayout.gutter, height: 1)
                HStack(alignment: .bottom, spacing: layout.gap) {
                    ForEach(lo..<hi, id: \.self) { c in
                        headerButton(model: model, column: c, layout: layout)
                    }
                }
                .frame(width: layout.cellsWidth, alignment: .leading)
                .background(alignment: .topLeading) { HeaderBand(pointer: pointer, layout: layout, first: first) }
                Color.clear.frame(width: GridLayout.gutter, height: 1)
                Group {
                    if layout.narrow {
                        Color.clear
                    } else {
                        Text("Fastest")
                    }
                }
                .frame(width: layout.bestWidth, alignment: .leading)
                Text("Avg")
                    .frame(width: layout.avgWidth, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(height: layout.columnHeaderHeight, alignment: .bottom)
            .padding(.horizontal, GridLayout.inset)
            .padding(.bottom, 2)

            HStack(spacing: 0) {
                Text("Average")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: layout.nameWidth, alignment: .leading)
                    .help("Each server's average over the websites shown")
                Color.clear.frame(width: GridLayout.gutter, height: 1)
                HeatRow(key: averageKey(model, layout, first, dark),
                        values: Array(model.colMean[lo..<hi]),
                        partial: (lo..<hi).map { model.colNoAnswer[$0] > 0 },
                        bestIndex: bestColumn.flatMap { (lo..<hi).contains($0.index) ? $0.index - lo : nil },
                        rowBest: bestColumn?.mean ?? .infinity,
                        scale: model.scale, layout: layout, valueMode: valueMode, markBest: markBest, dark: dark)
                    .equatable()
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case .active(let point) = phase {
                            pointer.set(.init(row: nil, column: lo + min(max(Int(point.x / layout.pitchX), 0), max(hi - lo - 1, 0)), part: .header))
                        } else {
                            pointer.clear(row: nil, part: .header)
                        }
                    }
                Color.clear.frame(width: GridLayout.gutter, height: 1)
                BestCell(server: bestColumn.map { model.servers[$0.index] }, value: bestColumn?.mean ?? .infinity, narrow: layout.narrow)
                    .frame(width: layout.bestWidth, alignment: .leading)
                Text(Format.msValue(overall))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(width: layout.avgWidth, alignment: .trailing)
            }
            .frame(height: layout.rowHeight)
            .padding(.horizontal, GridLayout.inset)
            .background(Color.accentColor.opacity(0.04))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bestColumn.map { "Average per server. Fastest on average: \(model.servers[$0.index].name), \(Int($0.mean.rounded())) milliseconds." } ?? "Average per server")

            Divider()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous))
    }

    private func headerButton(model: GridModel, column c: Int, layout: GridLayout) -> some View {
        let server = model.servers[c]
        let inStore = store.servers.first { $0.id == server.id } ?? store.servers.first { $0.matchKey == server.matchKey }
        return Button {
            guard !isLive else { return }
            cycleSort(server)
        } label: {
            ColumnHeaderCell(server: server, label: model.labels[c], layout: layout,
                             sort: isLive ? nil : serverSort.flatMap { $0.id == server.id ? $0 : nil })
        }
        .buttonStyle(.plain)
        .help("\(server.name) · \(server.address) · avg \(Format.ms(model.colMean[c])) · fastest on \(model.colWins[c]) website\(model.colWins[c] == 1 ? "" : "s"). Click to sort.")
        .onContinuousHover { phase in
            if case .active = phase {
                pointer.set(.init(row: nil, column: c, part: .header))
            } else {
                pointer.clear(row: nil, part: .header)
            }
        }
        .contextMenu {
            Button("Sort Websites by \(server.name): Fastest First") { serverSort = ServerSort(id: server.id, ascending: true) }
                .disabled(isLive)
            Button("Sort Websites by \(server.name): Slowest First") { serverSort = ServerSort(id: server.id, ascending: false) }
                .disabled(isLive)
            Button("Hide \(server.name)") { hidden.insert(server.id) }
                .disabled(isLive)
            Button("Copy Address") { Exporter.copy(server.address) }
            Divider()
            Button("Switch Off \(server.name) for Next Tests…") {
                if let inStore { pendingSwitchOff = PendingSwitchOff(name: server.name, storeID: inStore.id) }
            }
                .disabled(server.isSystem || inStore == nil || inStore?.isEnabled == false)
        }
        .accessibilityLabel("Sort by \(server.name)")
    }

    private func cycleSort(_ server: ServerResult) {
        if let sort = serverSort, sort.id == server.id {
            serverSort = sort.ascending ? ServerSort(id: server.id, ascending: false) : nil
        } else {
            serverSort = ServerSort(id: server.id, ascending: true)
        }
    }

    private func showAllServers() {
        preset = .all
        hidden.removeAll()
    }

    private var footnote: String {
        if shownSource == .combined {
            let base = colour == .time
                ? "Each website's average lookup time plus three times the time to connect to the server that DNS pointed to: about how soon a new visit to the website can start loading (one lookup, then connecting, securing the connection and asking for the page)."
                : "Colour shows how much later each DNS gets the website started than the soonest one."
            let numbers = valueMode == .delta ? " “+N” = milliseconds later than the soonest." : ""
            let outline = markBest ? " · outlined = soonest for that website" : ""
            return base + numbers + " ✕ couldn't connect or never answered · empty = no address from that DNS · orange corner = some lookups failed" + outline + " · hover a cell to see the lookup and connection parts."
        }
        if shownSource == .connection {
            let base = colour == .time
                ? "Time to connect to the server each DNS pointed to for each website (best of 3 tries; the average when a DNS gave several). Nearer servers connect sooner, and every new connection pays that distance about three times."
                : "Colour shows how much slower each connection was than to the nearest server any DNS found for that website."
            let numbers = valueMode == .delta ? " “+N” = milliseconds slower than the nearest." : ""
            let outline = markBest ? " · outlined = nearest for that website" : ""
            let checked = run.destinationCheck.map { " Checked \(Format.date($0.date))." } ?? ""
            return base + numbers + " ✕ couldn't connect · empty = no address from that DNS" + outline + " · click a website for every server's time." + checked
        }
        let base = colour == .time
            ? "Average milliseconds per website over \(run.rounds) round\(run.rounds == 1 ? "" : "s"). Colours use a log scale, so 20 ms and 40 ms stay distinguishable next to 500 ms sites."
            : "Colour shows how much slower each server was than that website's fastest server (2× = twice as long)."
        let numbers = valueMode == .delta ? " “+N” = milliseconds slower than the website's fastest server." : ""
        let outline = markBest ? " · outlined = fastest for that website" : ""
        let leftOut = run.leftOutLookups > 0 ? " · empty = left out, as that server refuses made-up names under that website but answers the real one" : ""
        return base + numbers + " ✕ never answered · orange corner = some lookups failed" + leftOut + outline + " · click a website for every server's time."
    }

    private func runIndex(_ server: ServerResult) -> Int {
        run.results.firstIndex { $0.id == server.id } ?? .max
    }

    private func rowKey(_ model: GridModel, _ r: Int, _ layout: GridLayout, _ first: Int, _ dark: Bool) -> Int {
        let lo = first
        let hi = min(first + layout.visibleColumns, model.n)
        var hasher = optionsHasher(layout, model.scale, first, dark)
        for c in lo..<hi {
            hasher.combine(model.value(r, c).bitPattern)
            hasher.combine(model.partial[r * model.n + c])
        }
        hasher.combine(model.rowBest[r].bitPattern)
        hasher.combine(model.rowBestCol[r])
        return hasher.finalize()
    }

    /// The average row averages only the websites shown, so it changes with the filter.
    private func averageKey(_ model: GridModel, _ layout: GridLayout, _ first: Int, _ dark: Bool) -> Int {
        let lo = first
        let hi = min(first + layout.visibleColumns, model.n)
        var hasher = optionsHasher(layout, model.scale, first, dark)
        hasher.combine("average")
        for c in lo..<hi {
            hasher.combine(model.colMean[c].bitPattern)
            hasher.combine(model.colNoAnswer[c])
        }
        hasher.combine(model.bestColumn?.index)
        return hasher.finalize()
    }

    /// Everything besides the values that changes how a row is drawn. Values are hashed by bit pattern
    /// because NaN (not tested yet) never equals itself.
    private func optionsHasher(_ layout: GridLayout, _ scale: HeatScale, _ first: Int, _ dark: Bool) -> Hasher {
        var hasher = Hasher()
        hasher.combine(first)
        hasher.combine(layout)
        hasher.combine(scale)
        hasher.combine(valueMode)
        hasher.combine(markBest)
        hasher.combine(dark)
        return hasher
    }
}

/// The saved server to switch off, resolved when the menu item is chosen (the run's result may refer to an older id).
private struct PendingSwitchOff {
    let name: String
    let storeID: UUID
}

/// One website row: name, the heat cells, the fastest server and the average.
private struct MatrixRow: View {
    let r: Int
    let zebra: Bool
    let model: GridModel
    let layout: GridLayout
    let first: Int
    let category: WebsiteCategory?
    let pointer: GridPointer
    let heatKey: Int
    let valueMode: ValueMode
    let markBest: Bool
    let dark: Bool
    let rounds: Int
    let siteID: UUID?
    let siteEnabled: Bool?
    let canShowAll: Bool
    let onShowAll: () -> Void
    let onSwitchOffSite: (UUID) -> Void
    @Binding var drill: DrillTarget?

    var body: some View {
        let n = model.n
        let lo = first
        let hi = min(first + layout.visibleColumns, n)
        let base = r * n
        let count = max(hi - lo, 1)

        HStack(spacing: 0) {
            NameCell(domain: model.domains[r], category: category, dense: layout.density == .dense, rowHeight: layout.rowHeight)
                .frame(width: layout.nameWidth, height: layout.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { drill = DrillTarget(row: r, column: nil) }
                .onContinuousHover { phase in
                    if case .active = phase {
                        pointer.set(.init(row: r, column: nil, part: .name))
                    } else {
                        pointer.clear(row: r, part: .name)
                    }
                }
                .popover(isPresented: drillBinding, arrowEdge: .trailing) {
                    WebsiteDrillDown(model: model, row: r, highlight: drill?.column, category: category, rounds: rounds,
                                     siteEnabled: siteEnabled) {
                        if let siteID { onSwitchOffSite(siteID) }
                        drill = nil
                    }
                }
            Color.clear.frame(width: GridLayout.gutter, height: 1)
            HeatRow(key: heatKey,
                    values: Array(model.values[(base + lo)..<(base + hi)]),
                    partial: Array(model.partial[(base + lo)..<(base + hi)]),
                    bestIndex: model.rowBestCol[r].flatMap { (lo..<hi).contains($0) ? $0 - lo : nil },
                    rowBest: model.rowBest[r], scale: model.scale, layout: layout,
                    valueMode: valueMode, markBest: markBest, dark: dark)
                .equatable()
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let point) = phase {
                        pointer.set(.init(row: r, column: lo + min(max(Int(point.x / layout.pitchX), 0), count - 1), part: .cells))
                    } else {
                        pointer.clear(row: r, part: .cells)
                    }
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    drill = DrillTarget(row: r, column: lo + min(max(Int(point.x / layout.pitchX), 0), count - 1))
                }
            Color.clear.frame(width: GridLayout.gutter, height: 1)
            BestCell(server: model.rowBestCol[r].map { model.servers[$0] }, value: model.rowBest[r], narrow: layout.narrow)
                .frame(width: layout.bestWidth, alignment: .leading)
            Text(Format.msValue(model.rowMean[r]))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: layout.avgWidth, alignment: .trailing)
        }
        .padding(.horizontal, GridLayout.inset)
        .frame(height: layout.rowHeight)
        .background(zebra ? Color.primary.opacity(0.025) : .clear)
        .overlay(alignment: .topLeading) {
            RowCrosshair(pointer: pointer, row: r, layout: layout, first: first)
        }
        .contextMenu {
            Button("Show Every Server's Time…") { drill = DrillTarget(row: r, column: nil) }
            Button("Copy Website") { Exporter.copy(model.domains[r]) }
            Button("Copy Row") { Exporter.copy(model.tsv(row: r)) }
            if canShowAll {
                Button("Show All Servers", action: onShowAll)
            }
            Divider()
            Button("Switch Off This Website for Next Tests") {
                if let siteID { onSwitchOffSite(siteID) }
            }
            .disabled(siteID == nil || siteEnabled != true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.spokenSummary(row: r))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { drill = DrillTarget(row: r, column: nil) }
    }

    private var drillBinding: Binding<Bool> {
        Binding(
            get: { drill?.row == r },
            set: { isPresented in
                if !isPresented, drill?.row == r { drill = nil }
            }
        )
    }
}

private struct DomainHighlights: View {
    let title: String
    let icon: String
    let tint: Color
    let rows: [(String, Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(rows, id: \.0) { domain, value in
                HStack {
                    Text(domain).lineLimit(1)
                    Spacer()
                    Text(Format.ms(value)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}
