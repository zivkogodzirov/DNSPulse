import SwiftUI
import UniformTypeIdentifiers

struct WebsitesView: View {
    @EnvironmentObject private var store: AppStore

    @State private var selection = Set<Website.ID>()
    @State private var search = ""
    @State private var show: Show = .all
    @State private var category: WebsiteCategory?
    @State private var sortOrder = [KeyPathComparator(\Website.sortRank)]
    @State private var sheet: SheetKind?
    @State private var pendingDelete: Set<Website.ID> = []
    @State private var showDeleteConfirm = false
    @State private var showResetConfirm = false
    @State private var showHistoryImport = false
    @State private var message: String?

    enum Show: String, CaseIterable, Identifiable {
        case all = "All"
        case enabled = "On"
        case disabled = "Off"
        case custom = "Custom"

        var id: String { rawValue }
    }

    enum SheetKind: Identifiable {
        case add
        case edit(Website)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let website): website.id.uuidString
            }
        }
    }

    private var visible: [Website] {
        var list = store.websites.filter { website in
            switch show {
            case .all: true
            case .enabled: website.isEnabled
            case .disabled: !website.isEnabled
            case .custom: website.isCustom
            }
        }
        if let category { list = list.filter { $0.category == category } }
        if !search.isEmpty { list = list.filter { $0.domain.localizedCaseInsensitiveContains(search) } }
        list.sort(using: sortOrder)
        return list
    }

    var body: some View {
        let rows = visible
        VStack(spacing: 0) {
            header
            Divider()
            LiteTable(rows, selection: $selection, sortOrder: $sortOrder, rowHeight: 30) {
                LiteColumn("On", width: .fixed(28)) { website in
                    Toggle("Include in tests", isOn: enabledBinding(website.id))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                LiteColumn("#", value: \.sortRank, width: .fixed(36)) { website in
                    Text(website.rank.map { "\($0)" } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LiteColumn("Website", value: \.domain, width: .flexible(min: 200, ideal: 300)) { website in
                    HStack(spacing: 10) {
                        CategoryIcon(category: website.category, size: 22)
                        Text(website.domain).fontWeight(.medium).lineLimit(1)
                    }
                    .opacity(website.isEnabled ? 1 : 0.5)
                }
                LiteColumn("Category", value: \.category.title, width: .flexible(min: 90, ideal: 130)) { website in
                    Text(website.category.title).foregroundStyle(.secondary).lineLimit(1)
                }
                LiteColumn("Source", value: \.sourceTitle, width: .fixed(80)) { website in
                    TagLabel(text: website.sourceTitle.uppercased(), color: website.isCustom ? .green : .secondary)
                }
            }
            .rowContextMenu(primaryActionName: "Edit") { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                if let id = ids.first { edit(id) }
            }
            .rowAccessibilityLabel { website in
                "\(website.domain), \(website.category.title), \(website.isEnabled ? "switched on" : "switched off")"
            }
            .emptyState {
                if search.isEmpty {
                    ContentUnavailableView("No Websites", systemImage: "globe", description: Text("No websites match this filter."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
            .sectionDeleteCommand { requestDelete(selection) }
        }
        .sectionChrome(title: "Websites") { toolbar }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .add:
                AddWebsitesSheet { domains, category, enabled in
                    let result = store.addDomains(domains, category: category, enabled: enabled)
                    if result.duplicates > 0 {
                        message = "Added \(result.added) website\(result.added == 1 ? "" : "s"). \(result.duplicates) were already in the list."
                    }
                }
            case .edit(let website):
                EditWebsiteSheet(website: website, existing: Set(store.websites.filter { $0.id != website.id }.map(\.domain))) {
                    store.upsert($0)
                }
            }
        }
        .sheet(isPresented: $showHistoryImport) {
            ImportHistorySheet { added in
                // Show what was just added.
                if added > 0 { show = .all; category = .personal; search = "" }
            }
        }
        .confirmationDialog(pendingDelete.count == 1 ? "Delete this website?" : "Delete \(pendingDelete.count) websites?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                store.deleteWebsites(pendingDelete)
                selection.subtract(pendingDelete)
            }
        } message: {
            Text("Tip: switching a website off keeps it in the list for later.")
        }
        .confirmationDialog("Restore the default top 100 websites?", isPresented: $showResetConfirm) {
            Button("Restore Defaults", role: .destructive) {
                store.resetWebsites()
                selection.removeAll()
            }
        } message: {
            Text("Your custom websites and edits will be replaced with the built-in list.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $show) {
                ForEach(Show.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)

            Picker("Category", selection: $category) {
                Text("All categories").tag(WebsiteCategory?.none)
                Divider()
                ForEach(WebsiteCategory.allCases) { Label($0.title, systemImage: $0.icon).tag(WebsiteCategory?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()

            // Hidden when even a collapsed search field leaves no room for it.
            ViewThatFits(in: .horizontal) {
                Text("\(store.enabledWebsites.count) of \(store.websites.count) switched on")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Color.clear.frame(width: 0, height: 0)
            }
            .layoutPriority(2)

            Spacer()

            Menu("Use Top…") {
                ForEach([10, 25, 50, 75, 100], id: \.self) { count in
                    Button("Top \(count)") { store.enableTopWebsites(count) }
                }
            }
            .fixedSize()
            .help("Switch on only the most popular built-in websites. Your own websites are left as they are.")
            Group {
                Button("All On") { store.setWebsites(Set(visible.map(\.id)), enabled: true) }
                Button("All Off") { store.setWebsites(Set(visible.map(\.id)), enabled: false) }
            }
            .fixedSize()
            HeaderSearchField(prompt: "Search websites", text: $search)
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { sheet = .add } label: { Label("Add Websites", systemImage: "plus") }
                .help("Add one or more websites")
            Button { if let id = selection.first { edit(id) } } label: { Label("Edit", systemImage: "pencil") }
                .disabled(selection.count != 1)
                .help("Edit the selected website")
            Button { requestDelete(selection) } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
                .help("Delete the selected websites")
            Menu {
                Button("Import Websites…") { importWebsites() }
                Button("Import From Browser History…") { showHistoryImport = true }
                Button("Export Websites…") {
                    let text = store.websites.map(\.domain).joined(separator: "\n") + "\n"
                    Exporter.save(text, name: "DNS Pulse websites.txt", type: .plainText)
                }
                Divider()
                Button("Restore Default Top 100…") { showResetConfirm = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<Website.ID>) -> some View {
        if ids.count == 1, let id = ids.first {
            Button("Edit…") { edit(id) }
            if let website = store.websites.first(where: { $0.id == id }) {
                Button("Copy Domain") { Exporter.copy(website.domain) }
            }
            Divider()
        }
        if !ids.isEmpty {
            Button("Switch On") { store.setWebsites(ids, enabled: true) }
            Button("Switch Off") { store.setWebsites(ids, enabled: false) }
            Menu("Category") {
                ForEach(WebsiteCategory.allCases) { category in
                    Button(category.title) { store.setWebsites(ids, category: category) }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { requestDelete(ids) }
        }
    }

    private func enabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { store.websites.first { $0.id == id }?.isEnabled ?? false },
            set: { value in
                if let index = store.websites.firstIndex(where: { $0.id == id }) {
                    store.websites[index].isEnabled = value
                }
            }
        )
    }

    private func edit(_ id: UUID) {
        guard let website = store.websites.first(where: { $0.id == id }) else { return }
        sheet = .edit(website)
    }

    private func requestDelete(_ ids: Set<Website.ID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
        showDeleteConfirm = true
    }

    private func importWebsites() {
        guard let data = Exporter.open(types: [.plainText, .commaSeparatedText, .text]),
              let text = String(data: data, encoding: .utf8) else { return }
        let parsed = DomainParser.extract(from: text)
        let limited = Array(parsed.valid.prefix(5000))
        guard !limited.isEmpty else {
            message = "No website addresses were found in that file."
            return
        }
        let result = store.addDomains(limited, category: .other)
        var note = "Imported \(result.added) website\(result.added == 1 ? "" : "s")."
        if result.duplicates > 0 { note += " \(result.duplicates) were already in the list." }
        if parsed.valid.count > limited.count { note += " Only the first 5,000 were used." }
        message = note
    }
}

// MARK: - Sheets

private struct AddWebsitesSheet: View {
    let onAdd: ([String], WebsiteCategory, Bool) -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var category: WebsiteCategory = .other
    @State private var enabled = true

    var body: some View {
        let parsed = DomainParser.extract(from: text)
        let existing = Set(store.websites.map(\.domain))
        let fresh = parsed.valid.filter { !existing.contains($0) }
        let duplicates = parsed.valid.count - fresh.count

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Websites").font(.title3.weight(.bold))
                    Text("Paste one or many — one per line, or separated by commas. Full URLs are fine.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("mybank.com.au\nhttps://www.news.com.au/sport\nexample.org, example.net")
                            .font(.body.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(13)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 190)

            HStack(spacing: 14) {
                Label("\(fresh.count) new", systemImage: "plus.circle.fill").foregroundStyle(.green)
                if duplicates > 0 {
                    Label("\(duplicates) already listed", systemImage: "equal.circle.fill").foregroundStyle(.secondary)
                }
                if !parsed.invalid.isEmpty {
                    Label("\(parsed.invalid.count) not valid", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .help(parsed.invalid.prefix(10).joined(separator: ", "))
                }
            }
            .font(.callout)

            HStack {
                Picker("Category", selection: $category) {
                    ForEach(WebsiteCategory.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                .fixedSize()
                Toggle("Switch on", isOn: $enabled)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(fresh.count) Website\(fresh.count == 1 ? "" : "s")") {
                    onAdd(parsed.valid, category, enabled)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fresh.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

private struct EditWebsiteSheet: View {
    @State var website: Website
    let existing: Set<String>
    let onSave: (Website) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var domainText = ""

    var body: some View {
        let normalized = DomainParser.normalize(domainText)
        let problem: String? = normalized == nil ? "Enter a website address such as example.com"
            : existing.contains(normalized!) ? "That website is already in the list" : nil

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CategoryIcon(category: website.category, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Website").font(.title3.weight(.bold))
                    Text(website.isCustom ? "Added by you" : "Top 100 · rank \(website.rank ?? 0)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Address", text: $domainText, prompt: Text("example.com"))
                    .font(.body.monospaced())
                Picker("Category", selection: $website.category) {
                    ForEach(WebsiteCategory.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                Toggle("Include in tests", isOn: $website.isEnabled)
            }
            .formStyle(.grouped)
            .frame(height: 170)

            HStack {
                if let problem {
                    Label(problem, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let normalized { website.domain = normalized }
                    onSave(website)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { domainText = website.domain }
    }
}
