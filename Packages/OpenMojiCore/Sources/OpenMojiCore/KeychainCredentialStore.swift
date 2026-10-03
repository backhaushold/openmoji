import Foundation
import Security

/// The four SecItem calls the store makes, behind a seam so the add-or-update
/// and not-found logic is testable on macOS, where the real Keychain needs
/// entitlements a `swift test` host lacks. Results are plain `OSStatus` values.
protocol KeychainOperations: Sendable {
    /// `SecItemAdd`. `result` is set only when `attributes` asks for one.
    func add(_ attributes: [String: Any]) -> (status: OSStatus, result: Any?)
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// The real Keychain.
struct SystemKeychain: KeychainOperations {
    func add(_ attributes: [String: Any]) -> (status: OSStatus, result: Any?) {
        var result: CFTypeRef?
        let status = SecItemAdd(attributes as CFDictionary, &result)
        return (status, result)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// The API key as a generic-password Keychain item shared by the shell app and
/// the Messages extension (tech spec §8, ADR-0006, ADR-0007):
///
/// - service `com.backhaushold.openmoji.openai`, account `api-key`
/// - access group `<AppIdentifierPrefix>com.backhaushold.openmoji.shared`
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable
/// - save is add, then update on `errSecDuplicateItem`; clear treats
///   `errSecItemNotFound` as success; load returns `nil` when absent.
///
/// There are no log statements here: the key is only ever in the item's data,
/// in the `String` the caller holds, and in the `Data` handed to the Keychain
/// for the duration of a call. Errors carry an `OSStatus` only (NFR-6).
///
/// The access group is resolved from the process's entitlements on first use
/// (see `resolveAccessGroup()`), so nothing hardcodes the team prefix.
public struct KeychainCredentialStore: CredentialStore {
    public static let defaultService = "com.backhaushold.openmoji.openai"
    public static let defaultAccount = "api-key"

    /// Everything after the app identifier prefix in the shared group (ADR-0006).
    static let sharedGroupSuffix = "com.backhaushold.openmoji.shared"

    /// A non-secret item used only to learn the process's default access group.
    private static let probeService = "com.backhaushold.openmoji.access-group-probe"
    private static let probeAccount = "default-group"

    private let keychain: any KeychainOperations
    private let service: String
    private let account: String

    /// The production store. `service` and `account` default to the specified
    /// identity; tests pass their own so a round-trip can't touch a real key.
    public init(
        service: String = KeychainCredentialStore.defaultService,
        account: String = KeychainCredentialStore.defaultAccount
    ) {
        self.init(keychain: SystemKeychain(), service: service, account: account)
    }

    init(
        keychain: any KeychainOperations,
        service: String = KeychainCredentialStore.defaultService,
        account: String = KeychainCredentialStore.defaultAccount
    ) {
        self.keychain = keychain
        self.service = service
        self.account = account
    }

    public func load() throws -> String? {
        var query = try itemQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.unreadableValue
        }
        return key
    }

    public func save(_ key: String) throws {
        let query = try itemQuery()
        let accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let data = Data(key.utf8)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = accessible

        var status = keychain.add(attributes).status
        if status == errSecDuplicateItem {
            // Also re-asserts the accessibility, in case an older item differs.
            status = keychain.update(
                query,
                attributes: [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
            )
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    public func clear() throws {
        let status = keychain.delete(try itemQuery())
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    // MARK: Query construction

    /// The attributes that identify the key item (§8).
    private func itemQuery() throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: try resolveAccessGroup(),
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// `<AppIdentifierPrefix>com.backhaushold.openmoji.shared`, worked out from
    /// the process's resolved entitlements.
    ///
    /// iOS has no public API to read an entitlement, so this asks the Keychain
    /// where an item with no explicit group lands: that is the first entry of
    /// `keychain-access-groups`, already resolved (`AB5S94XWRQ.` rather than
    /// `$(AppIdentifierPrefix)`). Only its prefix is kept, so the answer
    /// doesn't depend on which entitled group is listed first. The probe item
    /// is created once and left in place: it holds no secret and keeping it
    /// avoids a delete racing with the other process's probe.
    private func resolveAccessGroup() throws -> String {
        var probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.probeService,
            kSecAttrAccount as String: Self.probeAccount,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
        ]
        var (status, result) = keychain.copyMatching(probe)
        if status == errSecItemNotFound {
            probe[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            (status, result) = keychain.add(probe)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }

        guard let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".", maxSplits: 1).first
        else { throw CredentialStoreError.accessGroupUnavailable }
        return "\(prefix).\(Self.sharedGroupSuffix)"
    }
}
