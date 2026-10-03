import Foundation
import Security
import Testing
@testable import OpenMojiCore

// MARK: - Fake keychain

/// A stateful stand-in for the SecItem calls, with the semantics the store
/// relies on (add on an existing item fails, update and delete need a match)
/// and a call log. It lets the add-or-update and not-found logic run on macOS,
/// where the real Keychain needs entitlements the `swift test` host lacks. The
/// real thing is covered by the simulator round-trip in `OpenMojiMessagesTests`.
///
/// Not thread-safe: each test drives its own instance from one task.
private final class FakeKeychain: KeychainOperations, @unchecked Sendable {
    enum Call: Equatable {
        case add, copyMatching, update, delete
    }

    private(set) var calls: [Call] = []
    private(set) var addQueries: [[String: Any]] = []
    private(set) var copyQueries: [[String: Any]] = []
    private(set) var updateQueries: [[String: Any]] = []
    private(set) var updateAttributes: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    private var items: [String: Data] = [:]
    private var forced: [Call: OSStatus] = [:]

    /// What the process's default access group (the first `keychain-access-groups`
    /// entry) resolves to, as reported back by the probe item.
    let defaultGroup: String?

    init(defaultGroup: String? = "TEAM123456.com.backhaushold.openmoji.shared") {
        self.defaultGroup = defaultGroup
    }

    /// Makes every call of this kind fail with `status` (and change nothing).
    func fail(_ call: Call, with status: OSStatus) {
        forced[call] = status
    }

    private func itemKey(_ query: [String: Any]) -> String {
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return "\(service)/\(account)"
    }

    private var groupAttributes: [String: Any]? {
        defaultGroup.map { [kSecAttrAccessGroup as String: $0] }
    }

    func add(_ attributes: [String: Any]) -> (status: OSStatus, result: Any?) {
        calls.append(.add)
        addQueries.append(attributes)
        if let status = forced[.add] { return (status, nil) }
        let key = itemKey(attributes)
        if items[key] != nil { return (errSecDuplicateItem, nil) }
        items[key] = attributes[kSecValueData as String] as? Data ?? Data()
        let wantsAttributes = attributes[kSecReturnAttributes as String] as? Bool == true
        return (errSecSuccess, wantsAttributes ? groupAttributes : nil)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        calls.append(.copyMatching)
        copyQueries.append(query)
        if let status = forced[.copyMatching] { return (status, nil) }
        guard let data = items[itemKey(query)] else { return (errSecItemNotFound, nil) }
        let wantsAttributes = query[kSecReturnAttributes as String] as? Bool == true
        return (errSecSuccess, wantsAttributes ? groupAttributes : data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        calls.append(.update)
        updateQueries.append(query)
        updateAttributes.append(attributes)
        if let status = forced[.update] { return status }
        let key = itemKey(query)
        guard items[key] != nil else { return errSecItemNotFound }
        if let data = attributes[kSecValueData as String] as? Data {
            items[key] = data
        }
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        calls.append(.delete)
        deleteQueries.append(query)
        if let status = forced[.delete] { return status }
        return items.removeValue(forKey: itemKey(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
}

// MARK: - Tests

/// `KeychainCredentialStore` against `FakeKeychain` (tech spec §8, ADR-0006,
/// ADR-0007).
struct KeychainCredentialStoreTests {
    // A fake key on purpose: it must not look like `sk-...`.
    private let key = "test-fake-key-0000"
    private let sharedGroup = "TEAM123456.com.backhaushold.openmoji.shared"

    private func makeStore(_ keychain: FakeKeychain) -> KeychainCredentialStore {
        KeychainCredentialStore(keychain: keychain)
    }

    /// The queries that carry the key item's identity (everything but the probe).
    private func itemQueries(_ queries: [[String: Any]]) -> [[String: Any]] {
        queries.filter { $0[kSecAttrAccount as String] as? String == "api-key" }
    }

    // MARK: Attributes (§8)

    @Test func theDefaultItemIdentityIsTheSpecifiedServiceAndAccount() {
        #expect(KeychainCredentialStore.defaultService == "com.backhaushold.openmoji.openai")
        #expect(KeychainCredentialStore.defaultAccount == "api-key")
    }

    @Test func saveAddsAGenericPasswordWithTheSpecifiedAttributes() throws {
        let keychain = FakeKeychain()
        try makeStore(keychain).save(key)

        let adds = itemQueries(keychain.addQueries)
        try #require(adds.count == 1)
        let attributes = adds[0]
        #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attributes[kSecAttrService as String] as? String == "com.backhaushold.openmoji.openai")
        #expect(attributes[kSecAttrAccount as String] as? String == "api-key")
        #expect(attributes[kSecAttrAccessGroup as String] as? String == sharedGroup)
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecValueData as String] as? Data == Data(key.utf8))
    }

    @Test func loadQueriesTheSameItemAndAsksForTheData() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(key)
        _ = try store.load()

        let queries = itemQueries(keychain.copyQueries)
        try #require(queries.count == 1)
        let query = queries[0]
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "com.backhaushold.openmoji.openai")
        #expect(query[kSecAttrAccessGroup as String] as? String == sharedGroup)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }

    @Test func serviceAndAccountCanBeOverriddenForIsolation() throws {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(keychain: keychain, service: "svc", account: "acct")
        try store.save(key)

        let add = try #require(keychain.addQueries.last)
        #expect(add[kSecAttrService as String] as? String == "svc")
        #expect(add[kSecAttrAccount as String] as? String == "acct")
    }

    // MARK: load

    @Test func loadReturnsNilWhenNothingIsStored() throws {
        #expect(try makeStore(FakeKeychain()).load() == nil)
    }

    @Test func loadReturnsTheSavedKey() throws {
        let store = makeStore(FakeKeychain())
        try store.save(key)
        #expect(try store.load() == key)
    }

    @Test func loadThrowsTheOSStatusForAnyOtherFailure() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(key)
        keychain.fail(.copyMatching, with: errSecInteractionNotAllowed)

        #expect(throws: CredentialStoreError.keychain(errSecInteractionNotAllowed)) {
            try store.load()
        }
    }

    // MARK: save: add, then update on duplicate

    @Test func saveWithNoExistingItemOnlyAdds() throws {
        let keychain = FakeKeychain()
        try makeStore(keychain).save(key)
        #expect(!keychain.calls.contains(.update))
    }

    @Test func saveOnADuplicateUpdatesTheExistingItem() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(key)
        try store.save("test-fake-key-1111")

        #expect(try store.load() == "test-fake-key-1111")
        let calls = keychain.calls.filter { $0 == .add || $0 == .update }
        // The probe's add, the first save's add, then the second save's
        // add -> duplicate -> update.
        #expect(calls == [.add, .add, .add, .update])
    }

    @Test func theUpdateTargetsTheItemAndOnlyChangesValueAndAccessibility() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(key)
        try store.save("test-fake-key-1111")

        let query = try #require(keychain.updateQueries.first)
        #expect(query[kSecAttrService as String] as? String == "com.backhaushold.openmoji.openai")
        #expect(query[kSecAttrAccount as String] as? String == "api-key")
        #expect(query[kSecAttrAccessGroup as String] as? String == sharedGroup)
        #expect(query[kSecValueData as String] == nil)

        let attributes = try #require(keychain.updateAttributes.first)
        #expect(attributes[kSecValueData as String] as? Data == Data("test-fake-key-1111".utf8))
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }

    @Test func saveThrowsTheOSStatusWhenTheAddFails() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        // Resolve the group first (its probe also goes through add).
        _ = try store.load()
        keychain.fail(.add, with: errSecMissingEntitlement)

        #expect(throws: CredentialStoreError.keychain(errSecMissingEntitlement)) {
            try store.save(key)
        }
        #expect(!keychain.calls.contains(.update))
    }

    @Test func saveThrowsTheOSStatusWhenTheUpdateFails() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(key)
        keychain.fail(.update, with: errSecInteractionNotAllowed)

        #expect(throws: CredentialStoreError.keychain(errSecInteractionNotAllowed)) {
            try store.save("test-fake-key-1111")
        }
    }

    // MARK: clear

    @Test func clearRemovesTheKey() throws {
        let store = makeStore(FakeKeychain())
        try store.save(key)
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func clearTreatsItemNotFoundAsSuccess() throws {
        let keychain = FakeKeychain()
        try makeStore(keychain).clear()

        #expect(itemQueries(keychain.deleteQueries).count == 1)
    }

    @Test func clearDeletesFromTheSharedGroup() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(key)
        try store.clear()

        let query = try #require(itemQueries(keychain.deleteQueries).last)
        #expect(query[kSecAttrAccessGroup as String] as? String == sharedGroup)
    }

    @Test func clearThrowsTheOSStatusForAnyOtherFailure() {
        let keychain = FakeKeychain()
        keychain.fail(.delete, with: errSecInteractionNotAllowed)
        let store = makeStore(keychain)

        #expect(throws: CredentialStoreError.keychain(errSecInteractionNotAllowed)) {
            try store.clear()
        }
    }

    // MARK: Access group (§8, ADR-0006)

    @Test func theSharedGroupIsTheResolvedPrefixPlusTheSharedSuffix() throws {
        // The probe reports the process's default group; only its prefix is
        // used, so the answer doesn't depend on which group is listed first.
        let keychain = FakeKeychain(defaultGroup: "ZZZZ999999.some.other.group")
        try makeStore(keychain).save(key)

        let add = try #require(itemQueries(keychain.addQueries).first)
        #expect(
            add[kSecAttrAccessGroup as String] as? String
                == "ZZZZ999999.com.backhaushold.openmoji.shared"
        )
    }

    @Test func resolvingTheGroupDoesNotTouchTheKeyItem() throws {
        let keychain = FakeKeychain()
        try makeStore(keychain).clear()

        // Only the delete (and the probe) ran: the key was never added or read.
        #expect(itemQueries(keychain.addQueries).isEmpty)
        #expect(itemQueries(keychain.copyQueries).isEmpty)
    }

    @Test func aProbeFailureThrowsTheOSStatus() {
        let keychain = FakeKeychain()
        keychain.fail(.copyMatching, with: errSecMissingEntitlement)
        let store = makeStore(keychain)

        #expect(throws: CredentialStoreError.keychain(errSecMissingEntitlement)) {
            try store.save(key)
        }
        #expect(itemQueries(keychain.addQueries).isEmpty)
    }

    @Test func aProbeWithNoGroupThrowsAccessGroupUnavailable() {
        let keychain = FakeKeychain(defaultGroup: nil)
        let store = makeStore(keychain)

        #expect(throws: CredentialStoreError.accessGroupUnavailable) {
            try store.save(key)
        }
    }
}
