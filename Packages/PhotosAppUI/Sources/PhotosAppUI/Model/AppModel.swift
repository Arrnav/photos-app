import Core
import Foundation
import GRDB
import Persistence
import Photos
import CloudCore
import MediaCache
import Observation

/// App-wide state: accounts, server addresses and reachability, and the active
/// account's `LibrarySession`. Created once by the app and passed down.
@MainActor
@Observable
public final class AppModel {
    public let accounts: AccountStore
    public let serverSettings: ServerSettings

    public private(set) var connection: ConnectionStatus = .unknown
    public private(set) var session: LibrarySession?
    public private(set) var serverInfo: CloudServerInfo?
    public private(set) var versionWarning: String?
    /// Shown instead of the library when opening the account's database fails.
    public private(set) var sessionError: String?

    /// The Cloud server type (Immich today); everything server-specific goes through it.
    public let provider: any CloudProvider
    private let selector: ServerSelector
    private var prober: any ServerProber { provider.prober }
    private let mediaSession = URLSessionDownloader.makeSession()
    private let originalsSession = URLSessionFileDownloader.makeSession()
    private var started = false
    private var versionCheckedFor: URL?
    private var resolveTask: Task<Void, Never>?

    public init(accounts: AccountStore, serverSettings: ServerSettings, provider: any CloudProvider) {
        self.accounts = accounts
        self.serverSettings = serverSettings
        self.provider = provider
        selector = ServerSelector(prober: provider.prober) { @MainActor in serverSettings.addresses }
    }

    public var isSignedIn: Bool { accounts.activeAccount != nil }

    /// Shown as "Syncing Paused": the server can't be reached, or the last sync failed.
    var isSyncPaused: Bool {
        if case .unreachable = connection { return true }
        if case .failed = session?.syncStatus { return true }
        return false
    }

    public func start() {
        guard !started else { return }
        started = true
        LaunchTiming.mark("start")
        CrashReports.shared.start()
        AppLog.start()
        openSessionForActiveAccount()

        Task { [weak self, selector] in
            for await status in await selector.updates() {
                self?.connectionChanged(status)
            }
        }
        Task { [weak self] in
            // The first value arrives immediately, which triggers the launch probe.
            for await _ in NetworkPathObserver.changes() {
                self?.scheduleResolve(after: .milliseconds(300))
            }
        }
        if ScreenCapture.isEnabled { ScreenCapture.log("app started") }
        // Test snapshots never outlive the test that took them.
        if !ScreenCapture.isEnabled && !ScreensSelfTest.isEnabled && !EditorSelfTest.isEnabled && !OfflineSelfTest.isEnabled { try? FileManager.default.removeItem(at: ScreenCapture.folder) }
        // `-MLSelfTest`: people, smart search and trash retention from the real server.
        if ProcessInfo.processInfo.arguments.contains("-MLSelfTest") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let session = self?.session else { return }
                func say(_ text: String) { FileHandle.standardError.write(Data(("MLTEST " + text + "\n").utf8)) }
                do {
                    let people = try await session.people()
                    say("people \(people.count), named \(people.filter { !$0.name.isEmpty }.count)")
                    if let first = people.first {
                        let items = try await session.personItems(first.id)
                        let face = await session.personFace(first.id)
                        say("first person: \(items.count) photos, face \(face.map { "\(Int($0.size.width))px" } ?? "missing")")
                    }
                } catch { say("people error \(error)") }
                do { say("smart search 'car': \(try await session.smartSearch("car").count) results") } catch { say("smart search error \(error)") }
                await session.refreshTrashRetentionDays()
                say("trash days \(session.trashRetentionDays), trashed items \(await session.trashDates().count)")
                say("done")
            }
        }
        if ScrollSelfTest.isEnabled {
            Task {
                try? await Task.sleep(for: .seconds(6))
                await ScrollSelfTest.run()
            }
        }
        if OfflineSelfTest.isEnabled {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let session = self?.session else { return }
                await OfflineSelfTest.run(session: session)
            }
        }
        if EditorSelfTest.isEnabled {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let session = self?.session else { return }
                await EditorSelfTest.run(session: session)
            }
        }
        if ScreensSelfTest.isEnabled {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let session = self?.session else { return }
                await ScreensSelfTest.run(session: session)
            }
        }
        // `-DeleteSelfTest`: phone copies left behind by Cloud-only deletes, Recover round trip on one
        // trashed Cloud-only item (restored, survives a sync, trashed again), and what Collections loads.
        if ProcessInfo.processInfo.arguments.contains("-DeleteSelfTest") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let session = self?.session else { return }
                func say(_ text: String) { FileHandle.standardError.write(Data(("DELETETEST " + text + "\n").utf8)) }
                let ownerID = session.account.userID
                let orphans = (try? await session.database.reader.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT l.id FROM localAsset l WHERE EXISTS (SELECT 1 FROM remoteAsset r WHERE r.checksum = l.checksum AND r.deletedAt IS NOT NULL)
                        AND NOT EXISTS (SELECT 1 FROM remoteAsset r WHERE r.checksum = l.checksum AND r.deletedAt IS NULL)
                        """)
                }) ?? []
                let inPhotos = PHAsset.fetchAssets(withLocalIdentifiers: orphans, options: nil).count
                say("phone copies whose Cloud copy is in the trash: \(orphans.count), still in the phone's library: \(inPhotos)")
                let candidate = try? await session.database.reader.read { db in
                    try String.fetchOne(db, sql: """
                        SELECT r.id FROM remoteAsset r WHERE r.ownerId = ? AND r.deletedAt IS NOT NULL AND r.visibility = 'timeline'
                        AND NOT EXISTS (SELECT 1 FROM localAsset l WHERE l.checksum = r.checksum) ORDER BY r.deletedAt DESC LIMIT 1
                        """, arguments: [ownerID])
                }
                if let id = candidate.flatMap({ $0 }), let connection = session.connection {
                    do {
                        try await session.restoreFromTrash(assetIDs: [id])
                        session.syncNow()
                        try? await Task.sleep(for: .seconds(8))
                        let inLibrary = session.timeline.items.contains { $0.id == id }
                        let stillRestored = try await session.database.reader.read { db in
                            try Bool.fetchOne(db, sql: "SELECT deletedAt IS NULL FROM remoteAsset WHERE id = ?", arguments: [id]) ?? false
                        }
                        say("recover \(id): restored locally, in Library \(inLibrary), still restored after sync \(stillRestored)")
                        try await connection.moveToTrash(assetIDs: [id])
                        try await session.database.writer.write { db in try RemoteStore.setDeletedAt(.now, ids: [id], in: db) }
                        say("put back in Recently Deleted")
                    } catch { say("recover error \(error)") }
                } else {
                    say("no Cloud-only trashed item to try Recover on")
                }
                let trash = (try? await session.database.reader.read { db in try TimelineQuery.remote(ownerID: ownerID, scope: .trash, in: db) }.count) ?? -1
                say("Recently Deleted items \(trash)")
                do { say("memories \(try await session.memories().count)") } catch { say("memories error \(error)") }
                do { say("people \(try await session.people().count)") } catch { say("people error \(error)") }
                say("done")
            }
        }
        // `-PhoneChangesSelfTest`: a phone-library change (favourite the newest photo, then put it
        // back), the same path Delete uses, which crashed when its block was main-actor isolated.
        if ProcessInfo.processInfo.arguments.contains("-PhoneChangesSelfTest") {
            Task {
                try? await Task.sleep(for: .seconds(5))
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.fetchLimit = 1
                guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else {
                    FileHandle.standardError.write(Data("PHONETEST no photo\n".utf8))
                    return
                }
                let original = asset.isFavorite
                do {
                    try await PhoneLibraryChanges.setFavorite(!original, localIDs: [asset.localIdentifier])
                    try await PhoneLibraryChanges.setFavorite(original, localIDs: [asset.localIdentifier])
                    FileHandle.standardError.write(Data("PHONETEST PASS (favourite toggled and restored)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("PHONETEST error \(error)\n".utf8))
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-ConnectivitySelfTest") {
            Task { await runConnectivitySelfTest() }
        }
        // `-BackupSelfTest`: the upload format against the real server, with no side effects.
        if ProcessInfo.processInfo.arguments.contains("-BackupSelfTest") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let session = self?.session else { return }
                print("BACKUPTEST \(await session.backupSelfTest())")
            }
        }
        // `-VerifyChecksums`: the checksum check (docs/DESIGN.md D5) at launch, printed to the console (devicectl --console).
        if ProcessInfo.processInfo.arguments.contains("-VerifyChecksums") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let session = self?.session else { return }
                await session.phoneLibrary.refresh()
                let counts = await session.phoneCounts()
                print("CHECKSUMS phone=\(counts.total) identified=\(counts.withChecksum) byCloudId=\(counts.fromCloudId) failed=\(counts.failed)")
                let result = await session.phoneLibrary.verifyMatchedChecksums(limit: 200)
                print("CHECKSUMS \(result.summary)")
                for mismatch in result.mismatches { print("CHECKSUMS MISMATCH \(mismatch.localID) expected=\(mismatch.expected) actual=\(mismatch.actual) resources=\(mismatch.resources)") }
                for error in result.errors.prefix(20) { print("CHECKSUMS ERROR \(error)") }
            }
        }
    }

    /// Foreground: re-check which server to use, then sync if due.
    public func sceneBecameActive() {
        guard started else { return }
        session?.setActive(true)
        scheduleResolve(after: .zero)
    }

    public func sceneEnteredBackground() {
        session?.setActive(false)
        scheduleBackgroundTasks()
    }

    public func reconnect() {
        scheduleResolve(after: .zero)
    }

    private func scheduleResolve(after delay: Duration) {
        resolveTask?.cancel()
        resolveTask = Task { [selector] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await selector.resolve()
        }
    }

    private func connectionChanged(_ status: ConnectionStatus) {
        connection = status
        let server = status.activeServer
        session?.serverChanged(server)
        if let server, server.url != versionCheckedFor {
            versionCheckedFor = server.url
            Task { await checkVersion(on: server) }
        }
        if case .connected = status {
            session?.syncIfDue()
        }
    }

    private func checkVersion(on server: ActiveServer) async {
        do {
            let info = try await provider.serverInfo(at: server.url)
            serverInfo = info
            versionWarning = info.warning
            Log.networking.info("\(self.provider.name, privacy: .public) server version \(info.version, privacy: .public)")
        } catch {
            versionCheckedFor = nil
            Log.networking.error("Version check failed: \(CloudError.wrap(error, operation: "Version check").message, privacy: .public)")
        }
    }

    // MARK: Accounts

    /// Signs in against whichever configured address answers first.
    public func signIn(email: String, password: String) async throws {
        let status = await selector.resolve()
        guard let server = status.activeServer else {
            if case .unreachable(let reasons) = status {
                throw CloudError(kind: .transport, message: "Could not reach the server.\n" + reasons.joined(separator: "\n"))
            }
            throw CloudError(kind: .transport, message: "Could not reach the server.")
        }
        let result = try await provider.signIn(at: server.url, email: email.trimmingCharacters(in: .whitespaces), password: password)
        let account = Account(userID: result.userID, email: result.email, name: result.name, isAdmin: result.isAdmin)
        try accounts.signIn(account, token: result.token)
        Log.networking.info("Signed in as \(result.email, privacy: .private) via \(server.route.rawValue, privacy: .public)")
        openSessionForActiveAccount()
    }

    public func switchTo(_ account: Account) {
        guard account != accounts.activeAccount else { return }
        accounts.switchTo(account)
        openSessionForActiveAccount()
    }

    /// Ends the server session, forgets the token and removes local data for the account.
    public func signOut(_ account: Account) async {
        if let token = accounts.token(for: account), let server = connection.activeServer {
            await provider.signOut(at: server.url, token: token)
        }
        if session?.account == account {
            session?.deleteLocalData()
            session = nil
        } else {
            AccountPaths(userID: account.userID).removeAll()
        }
        accounts.signOut(account)
        HiddenVault.forgetPin(userID: account.userID)
        openSessionForActiveAccount()
    }

    private func openSessionForActiveAccount() {
        guard let account = accounts.activeAccount else {
            session?.close()
            session = nil
            return
        }
        let token = accounts.token(for: account)
        // Re-signing in to the same account replaces the token, so the session is reopened.
        if let session, session.account == account, session.token == token { return }
        session?.close()
        session = nil
        sessionError = nil
        guard let token else {
            sessionError = "The sign-in for \(account.email) is missing from the Keychain. Sign in again."
            return
        }
        do {
            let session = try LibrarySession(
                account: account, token: token, provider: provider,
                mediaSession: mediaSession, originalsSession: originalsSession
            )
            self.session = session
            LaunchTiming.mark("session")
            session.serverChanged(connection.activeServer)
        } catch {
            Log.database.error("Opening library failed: \(String(describing: error), privacy: .public)")
            sessionError = "The library on this phone could not be opened: \(error.localizedDescription)"
        }
    }

    // MARK: Diagnostics

    /// Pings each configured address separately and reports the result, so the
    /// App Transport Security behaviour can be checked on a device.
    /// Run with the launch argument `-ConnectivitySelfTest`.
    public func connectivityReport() async -> [String] {
        let addresses = serverSettings.addresses
        var lines: [String] = []
        for (label, url) in [("Local", addresses.local), ("Remote", addresses.remote)] {
            guard let url else {
                lines.append("\(label): not configured")
                continue
            }
            switch await prober.ping(url, timeout: .seconds(5)) {
            case .success: lines.append("\(label) \(url.absoluteString): OK")
            case .failure(let error): lines.append("\(label) \(url.absoluteString): FAILED – \(error.message)")
            }
        }
        return lines
    }

    /// `-SelfTestURL <url>` adds an extra address to the self-test (e.g. one without an ATS exception, as a control).
    private func runConnectivitySelfTest() async {
        var lines = await connectivityReport()
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-SelfTestURL"), arguments.indices.contains(flag + 1),
           let url = URL(string: arguments[flag + 1]) {
            switch await prober.ping(url, timeout: .seconds(5)) {
            case .success: lines.append("Extra \(url.absoluteString): OK")
            case .failure(let error): lines.append("Extra \(url.absoluteString): FAILED – \(error.message)")
            }
        }
        for line in lines {
            Log.networking.notice("SELFTEST \(line, privacy: .public)")
            print("SELFTEST \(line)")
        }
    }
}
