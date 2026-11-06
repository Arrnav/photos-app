import Foundation
import Network

/// A simplified view of the current network path, used to re-probe servers and
/// (later) to apply the Wi-Fi/cellular backup settings.
public struct NetworkPath: Sendable, Equatable {
    public var isSatisfied: Bool
    public var usesWiFi: Bool
    public var usesCellular: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool

    init(_ path: NWPath) {
        isSatisfied = path.status == .satisfied
        usesWiFi = path.usesInterfaceType(.wifi)
        usesCellular = path.usesInterfaceType(.cellular)
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
    }
}

/// Wraps `NWPathMonitor` as an async sequence of distinct path changes.
public enum NetworkPathObserver {
    public static func changes() -> AsyncStream<NetworkPath> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.ethwood.photos.path-monitor")
            let last = LastValue()
            monitor.pathUpdateHandler = { path in
                let simplified = NetworkPath(path)
                if last.replace(with: simplified) {
                    continuation.yield(simplified)
                }
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }

    /// Only touched on the monitor's serial queue.
    private final class LastValue: @unchecked Sendable {
        private var value: NetworkPath?

        func replace(with newValue: NetworkPath) -> Bool {
            defer { value = newValue }
            return value != newValue
        }
    }
}
