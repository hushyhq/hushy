import Foundation
import MurmurCore
import Network

/// Reports the network path as `NetworkConditions` on the main actor: reachable at all,
/// expensive (cellular / Personal Hotspot) and constrained (Low Data Mode). Read-only; it never
/// sends anything.
@MainActor
final class NetworkPathMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.hushy.network-path", qos: .utility)
    private var started = false

    func start(_ onChange: @escaping @MainActor (NetworkConditions) -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let conditions = NetworkConditions(
                isReachable: path.status == .satisfied, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            Task { @MainActor in onChange(conditions) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
