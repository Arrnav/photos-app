import Core
import Foundation
import Testing
import CloudCore

/// Answers pings from a fixed table; records which servers were tried.
final class FakeProber: ServerProber, @unchecked Sendable {
    private let lock = NSLock()
    private let reachable: Set<String>
    private let delay: Duration
    private(set) var attempts: [(host: String, timeout: Duration)] = []

    init(reachable: Set<String>, delay: Duration = .zero) {
        self.reachable = reachable
        self.delay = delay
    }

    func ping(_ server: URL, timeout: Duration) async -> Result<Void, CloudError> {
        let host = server.host() ?? ""
        lock.withLock { attempts.append((host, timeout)) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return reachable.contains(host)
            ? .success(())
            : .failure(CloudError(kind: .transport, message: "the server did not answer in time."))
    }

    var hostsTried: [String] { lock.withLock { attempts.map(\.host) } }
}

private let addresses = ServerAddresses(local: URL(string: "http://192.168.1.10:2283"), remote: URL(string: "http://100.64.0.10:2283"))

@Suite struct ServerSelectorTests {
    @Test func prefersLocalWhenItAnswers() async {
        let prober = FakeProber(reachable: ["192.168.1.10", "100.64.0.10"])
        let selector = ServerSelector(prober: prober) { addresses }
        let status = await selector.resolve()
        #expect(status == .connected(ActiveServer(route: .local, url: addresses.local!)))
        #expect(prober.hostsTried == ["192.168.1.10"])
    }

    @Test func fallsBackToRemoteWhenLocalFails() async {
        let prober = FakeProber(reachable: ["100.64.0.10"])
        let selector = ServerSelector(prober: prober) { addresses }
        let status = await selector.resolve()
        #expect(status == .connected(ActiveServer(route: .remote, url: addresses.remote!)))
        #expect(prober.hostsTried == ["192.168.1.10", "100.64.0.10"])
    }

    @Test func usesShortTimeoutForLocalProbe() async {
        let prober = FakeProber(reachable: [])
        let selector = ServerSelector(prober: prober, localTimeout: .milliseconds(1500), remoteTimeout: .seconds(6)) { addresses }
        _ = await selector.resolve()
        #expect(prober.attempts.map(\.timeout) == [.milliseconds(1500), .seconds(6)])
    }

    @Test func reportsEachFailureReadably() async {
        let selector = ServerSelector(prober: FakeProber(reachable: [])) { addresses }
        let status = await selector.resolve()
        #expect(status == .unreachable([
            "Local (192.168.1.10): the server did not answer in time.",
            "Remote (100.64.0.10): the server did not answer in time.",
        ]))
    }

    @Test func remoteOnlyConfiguration() async {
        let prober = FakeProber(reachable: ["100.64.0.10"])
        let selector = ServerSelector(prober: prober) { ServerAddresses(local: nil, remote: addresses.remote) }
        #expect(await selector.resolve().activeServer?.route == .remote)
        #expect(prober.hostsTried == ["100.64.0.10"])
    }

    @Test func noAddressesConfigured() async {
        let selector = ServerSelector(prober: FakeProber(reachable: [])) { ServerAddresses(local: nil, remote: nil) }
        #expect(await selector.resolve() == .unreachable(["No server address is configured."]))
    }

    @Test func concurrentResolvesShareOneProbe() async {
        let prober = FakeProber(reachable: ["192.168.1.10"], delay: .milliseconds(50))
        let selector = ServerSelector(prober: prober) { addresses }
        async let first = selector.resolve()
        async let second = selector.resolve()
        let results = await [first, second]
        #expect(results[0] == results[1])
        #expect(prober.hostsTried == ["192.168.1.10"])
    }

    @Test func switchesWhenNetworkChanges() async {
        // Home Wi-Fi first, then away: the re-probe must move to the remote address.
        final class Toggle: @unchecked Sendable { var atHome = true }
        let toggle = Toggle()
        struct NetworkDependentProber: ServerProber {
            let toggle: Toggle
            func ping(_ server: URL, timeout: Duration) async -> Result<Void, CloudError> {
                let local = server.host() == "192.168.1.10"
                return local == toggle.atHome || !local ? .success(()) : .failure(CloudError(kind: .transport, message: "unreachable"))
            }
        }
        let selector = ServerSelector(prober: NetworkDependentProber(toggle: toggle)) { addresses }
        #expect(await selector.resolve().activeServer?.route == .local)
        toggle.atHome = false
        #expect(await selector.resolve().activeServer?.route == .remote)
    }

    @Test func publishesStatusUpdates() async {
        let selector = ServerSelector(prober: FakeProber(reachable: ["192.168.1.10"])) { addresses }
        let updates = await selector.updates()
        _ = await selector.resolve()
        var seen: [ConnectionStatus] = []
        for await status in updates {
            seen.append(status)
            if case .connected = status { break }
        }
        #expect(seen.last?.activeServer?.route == .local)
    }
}

