import Foundation

/// Opaque credential material. The feature never decodes, prints, serializes,
/// or sends this value. A production implementation should back the protocol
/// with Keychain Services; this in-memory actor exists only for deterministic
/// tests and local scaffolding.
public struct CredentialMaterial: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let bytes: Data

    public init(secret: Data) {
        self.bytes = secret
    }

    /// Gives a concrete Keychain-backed store a short-lived view for writing
    /// the secret. The bytes cannot be returned through this API, and callers
    /// must not log, persist elsewhere, or transmit them.
    public func withSecretData(_ body: (Data) throws -> Void) rethrows {
        try body(bytes)
    }

    public var description: String { "credential(redacted)" }
    public var debugDescription: String { "CredentialMaterial(redacted)" }
}

public protocol CredentialStore: Sendable {
    func load(for account: AccountIdentifier) async throws -> CredentialMaterial?
    func save(_ credential: CredentialMaterial, for account: AccountIdentifier) async throws
    func remove(for account: AccountIdentifier) async throws
}

public actor InMemoryCredentialStore: CredentialStore {
    private var values: [AccountIdentifier: CredentialMaterial] = [:]

    public init() {}

    public func load(for account: AccountIdentifier) async throws -> CredentialMaterial? {
        values[account]
    }

    public func save(_ credential: CredentialMaterial, for account: AccountIdentifier) async throws {
        values[account] = credential
    }

    public func remove(for account: AccountIdentifier) async throws {
        values[account] = nil
    }
}
