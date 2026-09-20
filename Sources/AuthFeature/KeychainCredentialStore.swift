import Foundation
import Security

/// The operation category is deliberately small so errors can be handled
/// without exposing the account identifier or credential material.
public enum KeychainCredentialOperation: String, Equatable, Sendable {
    case add
    case update
    case load
    case remove
}

/// Errors from the credential store contain only a category and an OSStatus.
/// They never retain a query, account identifier, or secret bytes.
public enum KeychainCredentialStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidAccount
    case operationFailed(KeychainCredentialOperation, status: Int32)

    public var description: String {
        switch self {
        case .invalidAccount:
            return "keychain credential operation rejected"
        case let .operationFailed(operation, status):
            return "keychain \(operation.rawValue) failed (status \(status))"
        }
    }
}

/// A non-secret, exact Keychain item scope. The synchronizable flag is part of
/// the scope so every operation is testable and cannot silently broaden to
/// iCloud-synchronized items.
public struct KeychainItemQuery: Equatable, Sendable {
    public let service: String
    public let account: String
    public let synchronizable: Bool

    public init(service: String, account: String, synchronizable: Bool = false) {
        self.service = service
        self.account = account
        self.synchronizable = synchronizable
    }
}

/// The narrow Security.framework seam keeps production calls isolated and
/// lets tests use a deterministic fake without touching the user's Keychain.
public protocol KeychainClient: Sendable {
    func add(_ query: KeychainItemQuery, secret: Data) -> Int32
    func update(_ query: KeychainItemQuery, secret: Data) -> Int32
    func load(_ query: KeychainItemQuery) -> (status: Int32, data: Data?)
    func remove(_ query: KeychainItemQuery) -> Int32
}

/// Stores one credential per account in a generic-password Keychain item.
///
/// Items are device-bound and available after the first unlock. They do not
/// opt into iCloud Keychain synchronization. The service is fixed so account
/// identifiers remain the only lookup partition within Swifty's namespace.
public actor KeychainCredentialStore: CredentialStore {
    public static let service = "dev.vivescene.Swifty.credentials.v1"

    private let client: any KeychainClient

    public init() {
        self.client = SystemKeychainClient()
    }

    /// Internal injection point for deterministic tests and protocol fixtures.
    init(client: any KeychainClient) {
        self.client = client
    }

    public func load(for account: AccountIdentifier) async throws -> CredentialMaterial? {
        let accountValue = try accountValue(for: account)
        let result = client.load(query(for: accountValue))

        switch result.status {
        case errSecSuccess:
            guard let data = result.data else {
                throw KeychainCredentialStoreError.operationFailed(.load, status: errSecDecode)
            }
            return CredentialMaterial(secret: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainCredentialStoreError.operationFailed(.load, status: result.status)
        }
    }

    public func save(_ credential: CredentialMaterial, for account: AccountIdentifier) async throws {
        let accountValue = try accountValue(for: account)
        var secret = Data()
        credential.withSecretData { secret = $0 }

        var status = client.update(
            query(for: accountValue),
            secret: secret
        )
        if status == errSecItemNotFound {
            status = client.add(
                query(for: accountValue),
                secret: secret
            )
        }
        // An add racing another writer is still an update-or-add success path.
        if status == errSecDuplicateItem {
            status = client.update(
                query(for: accountValue),
                secret: secret
            )
        }
        guard status == errSecSuccess else {
            let operation: KeychainCredentialOperation = status == errSecItemNotFound ? .add : .update
            throw KeychainCredentialStoreError.operationFailed(operation, status: status)
        }
    }

    public func remove(for account: AccountIdentifier) async throws {
        let accountValue = try accountValue(for: account)
        let status = client.remove(query(for: accountValue))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.operationFailed(.remove, status: status)
        }
    }

    private func accountValue(for account: AccountIdentifier) throws -> String {
        guard !account.value.isEmpty else {
            throw KeychainCredentialStoreError.invalidAccount
        }
        return account.value
    }

    private func query(for account: String) -> KeychainItemQuery {
        KeychainItemQuery(service: Self.service, account: account, synchronizable: false)
    }
}

private struct SystemKeychainClient: KeychainClient {
    func add(_ item: KeychainItemQuery, secret: Data) -> Int32 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: item.synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(_ item: KeychainItemQuery, secret: Data) -> Int32 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: item.synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        ]
        let attributes: [String: Any] = [kSecValueData as String: secret]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func load(_ item: KeychainItemQuery) -> (status: Int32, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: item.synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func remove(_ item: KeychainItemQuery) -> Int32 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: item.synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
