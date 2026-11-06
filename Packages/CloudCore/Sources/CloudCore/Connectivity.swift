import Core
import Foundation

public enum ServerRoute: String, Sendable, Hashable {
    case local
    case remote
}

public struct ActiveServer: Sendable, Hashable {
    public let route: ServerRoute
    public let url: URL

    public init(route: ServerRoute, url: URL) {
        self.route = route
        self.url = url
    }
}

public enum ConnectionStatus: Sendable, Equatable {
    case unknown
    case checking
    case connected(ActiveServer)
    /// Neither address answered. Each entry describes one address, e.g. "Local (192.168.1.10): timed out".
    case unreachable([String])

    public var activeServer: ActiveServer? {
        if case .connected(let server) = self { server } else { nil }
    }
}

/// Checks whether an address is a Cloud server that answers (each provider has its own ping).
public protocol ServerProber: Sendable {
    func ping(_ server: URL, timeout: Duration) async -> Result<Void, CloudError>
}

/// Chooses between the local and remote address: the local one is used if it
/// answers `/server/ping` within a short timeout, otherwise the remote one.
/// Concurrent `resolve()` calls share one probe.
public actor ServerSelector {
    public typealias AddressSource = @Sendable () async -> ServerAddresses

    public private(set) var status: ConnectionStatus = .unknown

    private let prober: any ServerProber
    private let addresses: AddressSource
    private let localTimeout: Duration
    private let remoteTimeout: Duration
    private var inFlight: Task<ConnectionStatus, Never>?
    private var continuations: [UUID: AsyncStream<ConnectionStatus>.Continuation] = [:]

    public init(
        prober: any ServerProber,
        localTimeout: Duration = .milliseconds(1500),
        remoteTimeout: Duration = .seconds(6),
        addresses: @escaping AddressSource
    ) {
        self.prober = prober
        self.addresses = addresses
        self.localTimeout = localTimeout
        self.remoteTimeout = remoteTimeout
    }

    public var activeServer: ActiveServer? { status.activeServer }

    /// Emits the current status immediately, then every change.
    public func updates() -> AsyncStream<ConnectionStatus> {
        let (stream, continuation) = AsyncStream<ConnectionStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    @discardableResult
    public func resolve() async -> ConnectionStatus {
        if let inFlight { return await inFlight.value }
        let task = Task { await probe() }
        inFlight = task
        if status.activeServer == nil { publish(.checking) }
        let result = await task.value
        inFlight = nil
        publish(result)
        return result
    }

    private func probe() async -> ConnectionStatus {
        let addresses = await addresses()
        var failures: [String] = []

        let candidates: [(ServerRoute, URL, Duration)] = [
            addresses.local.map { (.local, $0, localTimeout) },
            addresses.remote.map { (.remote, $0, remoteTimeout) },
        ].compactMap { $0 }

        guard !candidates.isEmpty else {
            return .unreachable(["No server address is configured."])
        }

        for (route, url, timeout) in candidates {
            switch await prober.ping(url, timeout: timeout) {
            case .success:
                Log.networking.info("Using \(route.rawValue, privacy: .public) server \(url.absoluteString, privacy: .public)")
                return .connected(ActiveServer(route: route, url: url))
            case .failure(let error):
                let label = route == .local ? "Local" : "Remote"
                let entry = "\(label) (\(url.host() ?? url.absoluteString)): \(error.message)"
                Log.networking.notice("\(entry, privacy: .public)")
                failures.append(entry)
            }
        }
        return .unreachable(failures)
    }

    private func publish(_ newStatus: ConnectionStatus) {
        guard newStatus != status else { return }
        status = newStatus
        for continuation in continuations.values { continuation.yield(newStatus) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

extension Duration {
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
