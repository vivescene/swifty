import Foundation

/// Local data can remain after authorization is lost or unavailable. Presence
/// and authorization are intentionally separate values so callers cannot
/// mistake cached data for proof of access to Discord.
public enum CachePresence: Codable, Equatable, Sendable {
    case absent
    case present(lastUpdatedAt: Int64)
}

public enum CacheAuthorization: Codable, Equatable, Sendable {
    case authorized
    case unauthorized
    case unknown
    case revoked
}

public struct CacheAccountSnapshot: Codable, Equatable, Sendable {
    public let namespace: CacheAccountNamespace
    public let presence: CachePresence
    public let authorization: CacheAuthorization

    public init(
        namespace: CacheAccountNamespace,
        presence: CachePresence,
        authorization: CacheAuthorization
    ) {
        self.namespace = namespace
        self.presence = presence
        self.authorization = authorization
    }
}

public enum CacheRemovalScope: String, Codable, Equatable, Sendable {
    case messages
    case media
    case drafts
    case pendingSends
    case all
}

/// A persistence layer consumes these commands. The contract intentionally
/// has no implementation or implicit network side effects.
public enum CacheAccessCommand: Codable, Equatable, Sendable {
    case revokeAuthorization(namespace: CacheAccountNamespace)
    case remove(namespace: CacheAccountNamespace, scope: CacheRemovalScope)
}
