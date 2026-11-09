import Foundation
import Testing
@testable import Core

@MainActor
@Suite struct AccountStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let me = Account(userID: "u1", email: "me@example.com", name: "Me", isAdmin: true)
    private let partner = Account(userID: "u2", email: "partner@example.com", name: "Partner", isAdmin: false)

    @Test func signInStoresTokenAndActivates() throws {
        let secrets = InMemorySecretStore()
        let store = AccountStore(defaults: makeDefaults(), secrets: secrets)
        try store.signIn(me, token: "t1")
        #expect(store.activeAccount == me)
        #expect(store.token(for: me) == "t1")
    }

    @Test func switchingAccountsKeepsBothTokens() throws {
        let defaults = makeDefaults()
        let secrets = InMemorySecretStore()
        let store = AccountStore(defaults: defaults, secrets: secrets)
        try store.signIn(me, token: "t1")
        try store.signIn(partner, token: "t2")
        #expect(store.activeAccount == partner)
        store.switchTo(me)
        #expect(store.activeAccount == me)
        #expect(store.token(for: partner) == "t2")

        // Survives relaunch.
        let reloaded = AccountStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.accounts == [me, partner])
        #expect(reloaded.activeAccount == me)
    }

    @Test func signOutRemovesTokenAndFallsBack() throws {
        let store = AccountStore(defaults: makeDefaults(), secrets: InMemorySecretStore())
        try store.signIn(me, token: "t1")
        try store.signIn(partner, token: "t2")
        store.signOut(partner)
        #expect(store.activeAccount == me)
        #expect(store.token(for: partner) == nil)
    }

    @Test func reSignInUpdatesTokenWithoutDuplicating() throws {
        let store = AccountStore(defaults: makeDefaults(), secrets: InMemorySecretStore())
        try store.signIn(me, token: "old")
        try store.signIn(me, token: "new")
        #expect(store.accounts.count == 1)
        #expect(store.token(for: me) == "new")
    }
}
