import Foundation
import Testing
@testable import OpenMojiCore

/// The fake used by tests and previews has to behave like the real store.
struct InMemoryCredentialStoreTests {
    // A fake key on purpose: it must not look like `sk-...`.
    private let key = "test-fake-key-0000"

    @Test func loadReturnsNilWhenNothingIsStored() throws {
        let store: any CredentialStore = InMemoryCredentialStore()
        #expect(try store.load() == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store: any CredentialStore = InMemoryCredentialStore()
        try store.save(key)
        #expect(try store.load() == key)
    }

    @Test func saveReplacesAnExistingKey() throws {
        let store: any CredentialStore = InMemoryCredentialStore()
        try store.save(key)
        try store.save("test-fake-key-1111")
        #expect(try store.load() == "test-fake-key-1111")
    }

    @Test func clearRemovesTheKey() throws {
        let store: any CredentialStore = InMemoryCredentialStore()
        try store.save(key)
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func clearWithNothingStoredSucceeds() throws {
        let store: any CredentialStore = InMemoryCredentialStore()
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func canStartWithAKeyForPreviews() throws {
        let store: any CredentialStore = InMemoryCredentialStore(key: key)
        #expect(try store.load() == key)
    }
}
