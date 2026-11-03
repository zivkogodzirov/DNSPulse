import Combine
import Foundation
import SystemConfiguration

/// Known networks (networks.json) and the one the Mac is on right now.
@MainActor
final class NetworkStore: ObservableObject {
    static let file = "networks.json"

    @Published private(set) var networks: [NetworkProfile]
    /// Fingerprint of the current network; nil while offline or before the first check finishes.
    @Published private(set) var currentID: String?
    @Published private(set) var identity: NetworkIdentity?
    @Published private(set) var hasChecked = false

    /// Sends the new network when the Mac moves from one network to another while DNS Pulse is open.
    /// Not sent for the first network found at launch.
    let switched = PassthroughSubject<NetworkProfile, Never>()

    private weak var store: AppStore?
    private var lastKnownID: String?
    private var retriedFingerprint: String?
    private var dynamicStore: SCDynamicStore?
    private var pendingRefresh: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(monitor: Bool = true) {
        networks = AppStore.storedValue([NetworkProfile].self, file: Self.file) ?? []
        $networks
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { value in AppStore.write(value, file: Self.file) }
            .store(in: &subscriptions)
        if monitor {
            startMonitoring()
            refresh(after: 0)
        }
    }

    var current: NetworkProfile? { currentID.flatMap(profile) }

    /// The network with this fingerprint, or one it had before (see `apply`).
    func profile(_ id: String) -> NetworkProfile? {
        index(of: id).map { networks[$0] }
    }

    private func index(of id: String) -> Int? {
        networks.firstIndex { $0.id == id } ?? networks.firstIndex { $0.aliases.contains(id) }
    }

    /// The name shown for a saved test: the network's current name, the name it had then, or "Unknown network".
    func name(for run: BenchmarkRun) -> String {
        name(forID: run.networkID, fallback: run.networkName)
    }

    func name(forID id: String?, fallback: String? = nil) -> String {
        guard let id else { return BenchmarkRun.unknownNetworkName }
        return profile(id)?.name ?? fallback ?? BenchmarkRun.unknownNetworkName
    }

    /// Tags runs started by the engine with the current network, and keeps saved tests with their network
    /// when its fingerprint changes.
    func attach(_ engine: BenchmarkEngine, store: AppStore) {
        engine.networkProvider = { [weak self] in self?.current }
        self.store = store
        store.resolveNetworkID = { [weak self] id in self?.profile(id)?.id }
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: id) else { return }
        networks[index].name = trimmed
        networks[index].hasCustomName = true
    }

    /// Removes a network from the list. Its saved tests stay in History.
    func forget(_ id: String) {
        guard let index = index(of: id), networks[index].id != currentID else { return }
        networks.remove(at: index)
    }

    func dismissPrompt(for id: String) {
        guard let index = index(of: id) else { return }
        networks[index].promptDismissed = true
    }

    // MARK: Detection

    /// Re-reads the network after `delay` seconds, coalescing bursts of change notifications.
    func refresh(after delay: Double = 2) {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            let identity = await Task.detached(priority: .utility) { NetworkIdentity.current() }.value
            guard !Task.isCancelled else { return }
            self?.apply(identity)
        }
    }

    func apply(_ identity: NetworkIdentity?) {
        hasChecked = true
        self.identity = identity
        guard let identity else {
            currentID = nil
            return
        }

        // Right after joining, the router's hardware address may not be known yet; reuse a network seen with
        // the same router and subnet rather than creating a duplicate.
        var id = identity.fingerprint
        if identity.isAddressBased, !networks.contains(where: { $0.id == id }),
           let match = networks
               .filter({ $0.kind == identity.kind && $0.router == identity.router && $0.subnet == identity.subnet })
               .max(by: { $0.lastSeen < $1.lastSeen }) {
            id = match.id
        }
        // And once the hardware address is known, upgrade a network that was first saved without it. The old
        // fingerprint is kept as an alias, since tests in progress and open sheets may still refer to it.
        if !identity.isAddressBased, !networks.contains(where: { $0.id == id }),
           let addressID = NetworkIdentity.fingerprint(kind: identity.kind, routerMAC: nil, router: identity.router, subnet: identity.subnet),
           let index = networks.firstIndex(where: { $0.id == addressID }) {
            networks[index].id = id
            networks[index].aliases.append(addressID)
            if lastKnownID == addressID { lastKnownID = id }
            store?.updateNetworkIDs()
        }

        let now = Date()
        if let index = networks.firstIndex(where: { $0.id == id }) {
            networks[index].lastSeen = now
            networks[index].router = identity.router ?? networks[index].router
            networks[index].subnet = identity.subnet ?? networks[index].subnet
            if !networks[index].hasCustomName, let ssid = identity.ssid {
                networks[index].name = ssid
            }
        } else {
            var profile = NetworkProfile(identity: identity, date: now)
            profile.id = id
            networks.append(profile)
        }

        if currentID != id { currentID = id }
        if let previous = lastKnownID, previous != id, let profile = current {
            switched.send(profile)
        }
        lastKnownID = id

        // configd fills in the router's hardware address a moment after joining; look again once, shortly.
        if identity.isAddressBased, retriedFingerprint != identity.fingerprint {
            retriedFingerprint = identity.fingerprint
            refresh(after: 8)
        }
    }

    private func startMonitoring() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let store = Unmanaged<NetworkStore>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { store.refresh() }
        }
        guard let dynamicStore = SCDynamicStoreCreate(nil, "DNSPulse.networks" as CFString, callback, &context) else { return }
        let keys = ["State:/Network/Global/IPv4"] as CFArray
        let patterns = ["State:/Network/Service/.*/IPv4", "State:/Network/Interface/.*/AirPort"] as CFArray
        SCDynamicStoreSetNotificationKeys(dynamicStore, keys, patterns)
        SCDynamicStoreSetDispatchQueue(dynamicStore, .main)
        self.dynamicStore = dynamicStore
    }
}
