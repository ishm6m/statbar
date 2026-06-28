import Foundation
import Network

/// Observes network reachability. Drives the "Offline — displaying
/// last known data" banner and lets the refresh loop skip doomed requests.
///
/// `NWPathMonitor` reports the path on a background queue; we hop to the main
/// actor so `isOnline` (an `@Published`/observable flag) only mutates there and
/// SwiftUI observers update safely. Recovery is automatic: when the path goes
/// `.satisfied` again the monitor fires, `isOnline` flips true, and the menu
/// bar / refresh loop resume.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.getstatbar.StatBar.network-monitor")

    /// Fired when connectivity is regained, so the app can trigger an immediate
    /// refresh instead of waiting for the next scheduled tick.
    var onReconnect: (() -> Void)?

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.apply(online: online)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private func apply(online: Bool) {
        let wasOnline = isOnline
        guard online != wasOnline else { return }
        isOnline = online
        if online {
            Log.network.info("Connectivity restored")
            onReconnect?()
        } else {
            Log.network.notice("Network unavailable — serving last known data")
        }
    }
}
