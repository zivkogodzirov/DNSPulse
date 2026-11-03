import AppKit
import SwiftUI

/// Ranks the sites in your browsers' history so you can test the ones you actually visit.
struct ImportHistorySheet: View {
    /// The folder that holds `Library`; only tests point it elsewhere.
    var home = FileManager.default.homeDirectoryForCurrentUser
    /// Called with the number of websites added.
    let onAdd: (Int) -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var reports: [BrowserHistoryReport] = []
    @State private var isScanning = true
    @State private var excluded = Set<BrowserKind>()
    @State private var selected = Set<String>()
    @State private var scanCount = 0

    static let previewLimit = 100
    static let preselectCount = 25
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    /// Domains already in the website list, without "www." so they match the history's site names.
    private var existing: Set<String> {
        Set(store.websites.map { $0.domain.hasPrefix("www.") ? String($0.domain.dropFirst(4)) : $0.domain })
    }

    private var candidates: [SiteVisits] {
        let used = reports.filter { $0.status == .ok && !excluded.contains($0.browser) }
        return Array(BrowserHistory.combine(used).prefix(Self.previewLimit))
    }

    /// Ticked sites that aren't in the list yet, most visited first.
    private var toAdd: [String] {
        let existing = existing
        return candidates.map(\.domain).filter { selected.contains($0) && !existing.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isScanning {
                ProgressView("Reading browser history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                browsers
                Divider()
                sites
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 700)
        .task(id: scanCount) { await scan() }
        .onChange(of: excluded) { _, _ in preselect() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CategoryIcon(category: .personal, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Import From Browser History").font(.title3.weight(.bold))
                Text("Test the websites you actually visit. DNS Pulse ranks the sites in your browsers’ history from the last \(BrowserHistory.days) days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: Browsers

    private var browsers: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Browsers on this Mac")
            VStack(spacing: 0) {
                ForEach(reports) { report in
                    BrowserStatusRow(report: report, isIncluded: includeBinding(report.browser)) {
                        scanCount += 1
                    }
                    if report.id != reports.last?.id { Divider().padding(.leading, 40) }
                }
            }
            .card(padding: 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func includeBinding(_ browser: BrowserKind) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(browser) },
            set: { isOn in
                if isOn { excluded.remove(browser) } else { excluded.insert(browser) }
            }
        )
    }

    // MARK: Sites

    private var sites: some View {
        let list = candidates
        let existing = existing
        let most = list.first?.visits ?? 1
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                sectionTitle(list.isEmpty ? "Your most visited sites" : "Your \(list.count) most visited site\(list.count == 1 ? "" : "s")")
                Spacer()
                Menu("Select") {
                    ForEach([10, 25, 50], id: \.self) { count in
                        Button("Top \(count)") { selectTop(count) }
                    }
                    Button("All") { selectTop(Self.previewLimit) }
                    Divider()
                    Button("None") { selected.removeAll() }
                }
                .fixedSize()
                .disabled(list.isEmpty)
                .help("Tick the most visited sites that aren’t in your list yet")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            if list.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, site in
                            SiteRow(rank: index + 1, site: site, fraction: Double(site.visits) / Double(max(most, 1)),
                                    isListed: existing.contains(site.domain), isSelected: selectionBinding(site.domain))
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        let needsAccess = reports.contains { $0.status == .needsFullDiskAccess }
        let anyRead = reports.contains { $0.status == .ok }
        return VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(anyRead ? "No browsers selected" : "No websites found").font(.headline)
            Text(anyRead ? "Tick a browser above to see its most visited sites."
                 : needsAccess ? "Safari needs Full Disk Access before DNS Pulse can read its history."
                    + (reports.count > 1 ? " Your other browsers had no visits in the last \(BrowserHistory.days) days." : "")
                 : "Your browsers have no visits in the last \(BrowserHistory.days) days that DNS Pulse can test.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectionBinding(_ domain: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(domain) },
            set: { isOn in
                if isOn { selected.insert(domain) } else { selected.remove(domain) }
            }
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    // MARK: Footer

    private var footer: some View {
        let count = toAdd.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Your history is read only on this Mac, from a temporary copy that’s deleted straight away. Nothing leaves your Mac, and only the site names you tick are saved to your list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Label("Added as “\(WebsiteCategory.personal.title)”", systemImage: WebsiteCategory.personal.icon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(count) Website\(count == 1 ? "" : "s")") {
                    let result = store.addDomains(toAdd, category: .personal)
                    onAdd(result.added)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            }
        }
        .padding(16)
    }

    // MARK: Actions

    private func scan() async {
        isScanning = reports.isEmpty
        let home = home
        let result = await Task.detached(priority: .userInitiated) { BrowserHistory.scan(home: home) }.value
        guard !Task.isCancelled else { return }
        reports = result
        isScanning = false
        preselect()
    }

    /// Ticks the most visited sites that aren't in the list yet.
    private func preselect() {
        selectTop(Self.preselectCount)
    }

    private func selectTop(_ count: Int) {
        let existing = existing
        selected = Set(candidates.filter { !existing.contains($0.domain) }.prefix(count).map(\.domain))
    }
}

// MARK: - Rows

private struct BrowserStatusRow: View {
    let report: BrowserHistoryReport
    @Binding var isIncluded: Bool
    let onCheckAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("Include \(report.browser.title)", isOn: $isIncluded)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(report.status != .ok)
                    .opacity(report.status == .ok ? 1 : 0)
                Image(systemName: report.browser.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(report.browser.title).fontWeight(.medium)
                Spacer()
                status
            }
            if report.status == .needsFullDiskAccess {
                HStack(spacing: 10) {
                    Text("Safari keeps its history in a protected folder. Allow DNS Pulse under Privacy & Security › Full Disk Access, then check again (you may need to reopen DNS Pulse).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Open Settings…") {
                        if let url = ImportHistorySheet.fullDiskAccessURL { NSWorkspace.shared.open(url) }
                    }
                    .help("Open System Settings › Privacy & Security › Full Disk Access")
                    Button("Check Again", action: onCheckAgain)
                }
                .padding(.leading, 56)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var status: some View {
        switch report.status {
        case .ok:
            let visits = report.totalVisits
            Label("\(visits.formatted()) visit\(visits == 1 ? "" : "s") · \(report.sites.count) site\(report.sites.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .noHistory:
            Text("No history found").font(.callout).foregroundStyle(.secondary)
        case .needsFullDiskAccess:
            Label("Needs Full Disk Access", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        case .unreadable(let reason):
            Label("Couldn’t read history", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .help(reason)
        }
    }
}

private struct SiteRow: View {
    let rank: Int
    let site: SiteVisits
    let fraction: Double
    let isListed: Bool
    @Binding var isSelected: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Add \(site.domain)", isOn: isListed ? .constant(false) : $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isListed)
            Text("\(rank)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            Text(site.domain)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            if isListed {
                TagLabel(text: "ALREADY IN YOUR LIST")
            }
            Spacer(minLength: 8)
            Text("\(site.visits.formatted()) visit\(site.visits == 1 ? "" : "s")")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            LatencyBar(fraction: fraction, color: accent)
                .frame(width: 70)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .opacity(isListed ? 0.6 : 1)
        .background(isSelected && !isListed ? accent.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if !isListed { isSelected.toggle() } }
        .help(site.lastVisit.map { "Last visited \(Format.date($0))" } ?? "")
    }
}
