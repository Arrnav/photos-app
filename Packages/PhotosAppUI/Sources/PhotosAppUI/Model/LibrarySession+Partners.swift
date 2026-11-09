import CloudCore
import Core
import Foundation
import GRDB
import Persistence

/// Shared Library (partner sharing): each person's whole library, shared with someone else
/// on the same server. Their photos sync to this phone; showing them in the Library is a choice.
extension LibrarySession {
    typealias SharedLibraries = (sharedWithMe: [SharedLibrary], recipients: [LibraryRecipient])

    func observeSharedLibraries() -> AsyncValueObservation<SharedLibraries> {
        PartnerQuery.observe(account.userID, in: database)
    }

    func sharedLibrariesNow() -> SharedLibraries {
        let me = account.userID
        return (try? database.reader.read { db in
            (try PartnerQuery.sharedWith(me, in: db), try PartnerQuery.recipients(of: me, in: db))
        }) ?? ([], [])
    }

    /// A shared library's photos (their Library, oldest first), now and after every sync.
    func observeSharedLibrary(of partnerID: String) -> AsyncValueObservation<[TimelineItem]> {
        TimelineQuery.observeRemote(ownerID: partnerID, scope: .visibility(.timeline), in: database)
    }

    /// Shows or stops showing a shared library's photos in the Library (at once; undone if the server refuses).
    func showSharedLibraryInLibrary(_ shown: Bool, partnerID: String) async throws {
        let me = account.userID
        let connection = try connected()
        try await database.writer.write { db in try PartnerQuery.setInTimeline(shown, sharedBy: partnerID, with: me, in: db) }
        do {
            try await connection.showSharedLibraryInLibrary(shown, partnerID: partnerID)
            ActionLog.write("shared library \(shown ? "shown in" : "removed from") Library")
        } catch {
            try? await database.writer.write { db in try PartnerQuery.setInTimeline(!shown, sharedBy: partnerID, with: me, in: db) }
            throw CloudError.wrap(error, operation: "Partner Sharing")
        }
    }

    /// Everyone else on the server, to share a library with (the synced list when offline).
    func peopleOnServer() async -> [CloudUser] {
        if let connection, let users = try? await connection.otherUsers() {
            return users.filter { $0.id != account.userID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return otherUsers().map { CloudUser(id: $0.id, name: $0.name, email: $0.email) }
    }

    /// Shares the signed-in user's library (everything except Hidden) with `userID`.
    func shareLibrary(with userID: String) async throws {
        try await connected().startSharingLibrary(with: userID)
        let me = account.userID
        try? await database.writer.write { db in
            try RemoteStore.upsert([PartnerRecord(sharedById: me, sharedWithId: userID, inTimeline: false)], in: db)
        }
        ActionLog.write("library shared with someone")
        syncNow()
    }

    func stopSharingLibrary(with userID: String) async throws {
        try await connected().stopSharingLibrary(with: userID)
        let me = account.userID
        try? await database.writer.write { db in try RemoteStore.deletePartners([(me, userID)], in: db) }
        ActionLog.write("library no longer shared with someone")
        syncNow()
    }
}
