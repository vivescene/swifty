import Foundation

/// Explicit bounds for local retention. These values describe policy only;
/// they do not imply encryption, secure deletion, or a database engine.
public struct CacheRetentionPolicy: Codable, Equatable, Sendable {
    public let maxMessagesPerChannel: Int
    public let maxMediaBytes: Int64
    public let maxMediaItems: Int
    public let maxDraftAgeSeconds: Int64
    public let maxPendingSendAgeSeconds: Int64

    public init(
        maxMessagesPerChannel: Int,
        maxMediaBytes: Int64,
        maxMediaItems: Int,
        maxDraftAgeSeconds: Int64,
        maxPendingSendAgeSeconds: Int64
    ) throws {
        guard maxMessagesPerChannel > 0 else { throw CacheRetentionError.invalidMessageLimit }
        guard maxMediaBytes > 0 else { throw CacheRetentionError.invalidMediaByteLimit }
        guard maxMediaItems > 0 else { throw CacheRetentionError.invalidMediaItemLimit }
        guard maxDraftAgeSeconds > 0 else { throw CacheRetentionError.invalidDraftAge }
        guard maxPendingSendAgeSeconds > 0 else {
            throw CacheRetentionError.invalidPendingSendAge
        }

        self.maxMessagesPerChannel = maxMessagesPerChannel
        self.maxMediaBytes = maxMediaBytes
        self.maxMediaItems = maxMediaItems
        self.maxDraftAgeSeconds = maxDraftAgeSeconds
        self.maxPendingSendAgeSeconds = maxPendingSendAgeSeconds
    }
}

public enum CacheRetentionError: Error, Equatable, Sendable {
    case invalidMessageLimit
    case invalidMediaByteLimit
    case invalidMediaItemLimit
    case invalidDraftAge
    case invalidPendingSendAge
}
