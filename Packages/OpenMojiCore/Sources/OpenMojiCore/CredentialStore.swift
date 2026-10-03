import Foundation

/// Where the OpenAI API key lives (tech spec §8, FR-1 to FR-5).
///
/// A protocol so tests and previews use `InMemoryCredentialStore`; production
/// uses `KeychainCredentialStore`. Implementations never log the key and never
/// put it in an error (NFR-6).
public protocol CredentialStore: Sendable {
    /// The stored key, or `nil` when there is none (FR-5).
    func load() throws -> String?
    /// Stores `key`, replacing any existing one.
    func save(_ key: String) throws
    /// Removes the key. Succeeds when there was none.
    func clear() throws
}

/// Why a credential operation failed. Cases carry an `OSStatus` at most: never
/// the key, a query, or a stored value (NFR-6).
public enum CredentialStoreError: Error, Equatable, Sendable {
    /// A Keychain call failed with this status (for example
    /// `errSecMissingEntitlement`, -34018, when the access group isn't
    /// entitled).
    case keychain(OSStatus)
    /// The shared access group couldn't be worked out from the process's
    /// entitlements (ADR-0006).
    case accessGroupUnavailable
    /// An item was found but its data isn't a UTF-8 string.
    case unreadableValue
}

/// A `CredentialStore` that keeps the key in memory only, for tests and
/// previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func load() throws -> String? {
        lock.withLock { key }
    }

    public func save(_ key: String) throws {
        lock.withLock { self.key = key }
    }

    public func clear() throws {
        lock.withLock { key = nil }
    }
}
