import Foundation

/// A non-secret account identity used to partition local cache state.
///
/// This value must never contain credentials, session material, or a path
/// separator. It is an identity for namespacing only; it does not prove that
/// the account is currently authorized.
public struct CacheAccountNamespace: Codable, Hashable, Sendable, CustomStringConvertible {
    public let accountID: String

    public init(accountID: String) throws {
        guard !accountID.isEmpty else { throw CacheIdentityError.emptyAccountID }
        guard !accountID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CacheIdentityError.invalidAccountID
        }
        guard !accountID.contains("/") && !accountID.contains("\\") else {
            throw CacheIdentityError.invalidAccountID
        }
        self.accountID = accountID
    }

    /// A stable logical key. Persistence implementations must still scope
    /// every query by this namespace and must not treat this as a filesystem
    /// path.
    public var storageKey: String { "account:\(accountID)" }

    public var description: String { "cache-account(redacted)" }
}

public struct CacheObjectID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else { throw CacheIdentityError.emptyObjectID }
        guard !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CacheIdentityError.invalidObjectID
        }
        self.rawValue = rawValue
    }

    public var description: String { "cache-object(redacted)" }
}

public struct CacheChannelID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else { throw CacheIdentityError.emptyChannelID }
        guard !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CacheIdentityError.invalidChannelID
        }
        self.rawValue = rawValue
    }

    public var description: String { "cache-channel(redacted)" }
}

public enum CacheIdentityError: Error, Equatable, Sendable {
    case emptyAccountID
    case invalidAccountID
    case emptyObjectID
    case invalidObjectID
    case emptyChannelID
    case invalidChannelID
}
