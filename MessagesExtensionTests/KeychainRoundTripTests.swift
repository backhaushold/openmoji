import Foundation
import OpenMojiCore
import Security
import Testing

/// The real Keychain, in the shared access group (tech spec §8, §11,
/// ADR-0006/0007). `OpenMojiCoreTests` covers the add-or-update and not-found
/// logic against a fake on macOS; only a hosted simulator run, with the shell
/// app's `keychain-access-groups` entitlement applied, can prove the Keychain
/// accepts the items.
///
/// Each test uses its own random account, so it can't see or clobber a real
/// key in the simulator's Keychain.
struct KeychainRoundTripTests {
    // A fake key on purpose: it must not look like `sk-...`.
    private let key = "test-fake-key-0000"

    /// `AB5S94XWRQ.com.backhaushold.openmoji.shared`: the prefix is the team ID
    /// in `project.yml`. Hardcoded on purpose, so a wrong resolved group fails
    /// the test rather than being echoed back.
    private let sharedGroup = "AB5S94XWRQ.com.backhaushold.openmoji.shared"

    private let account = "test-\(UUID().uuidString)"

    private func makeStore() -> KeychainCredentialStore {
        KeychainCredentialStore(account: account)
    }

    @Test func loadReturnsNilWhenNothingIsStored() throws {
        #expect(try makeStore().load() == nil)
    }

    @Test func saveLoadUpdateAndClearRoundTrip() throws {
        let store = makeStore()
        defer { try? store.clear() }

        try store.save(key)
        #expect(try store.load() == key)

        // A second save hits errSecDuplicateItem and takes the update path.
        try store.save("test-fake-key-1111")
        #expect(try store.load() == "test-fake-key-1111")

        try store.clear()
        #expect(try store.load() == nil)

        // Clearing an absent item is success (errSecItemNotFound).
        try store.clear()
    }

    @Test func theItemIsInTheSharedGroupWithTheSpecifiedAttributes() throws {
        let store = makeStore()
        defer { try? store.clear() }
        try store.save(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainCredentialStore.defaultService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: sharedGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try #require(status == errSecSuccess, "no item in \(sharedGroup): OSStatus \(status)")

        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessGroup as String] as? String == sharedGroup)
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        // Absent or 0 both mean not synchronizable.
        let synchronizable = attributes[kSecAttrSynchronizable as String] as? Bool
        #expect(synchronizable != true)
    }
}
