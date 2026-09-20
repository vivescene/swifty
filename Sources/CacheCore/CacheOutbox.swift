import Foundation

public struct DraftRecord: Codable, Equatable, Sendable {
    public let id: CacheObjectID
    public let namespace: CacheAccountNamespace
    public let channelID: CacheChannelID
    public let text: String
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(
        id: CacheObjectID,
        namespace: CacheAccountNamespace,
        channelID: CacheChannelID,
        text: String,
        createdAt: Int64,
        updatedAt: Int64
    ) throws {
        guard createdAt <= updatedAt else { throw CacheOutboxError.invalidDraftDates }
        self.id = id
        self.namespace = namespace
        self.channelID = channelID
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum PendingSendStatus: Codable, Equatable, Sendable {
    case queued
    case sending(attempt: Int)
    case awaitingAcknowledgement(attempt: Int)
    case failed(message: String, retryable: Bool)
    case cancelled
    case acknowledged(serverMessageID: String, acknowledgedAt: Int64)
}

public struct PendingSendRecord: Codable, Equatable, Sendable {
    public let id: CacheObjectID
    public let namespace: CacheAccountNamespace
    public let channelID: CacheChannelID
    public let text: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let status: PendingSendStatus

    public init(
        id: CacheObjectID,
        namespace: CacheAccountNamespace,
        channelID: CacheChannelID,
        text: String,
        createdAt: Int64,
        updatedAt: Int64,
        status: PendingSendStatus
    ) throws {
        guard createdAt <= updatedAt else { throw CacheOutboxError.invalidPendingSendDates }
        self.id = id
        self.namespace = namespace
        self.channelID = channelID
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
    }
}

public enum CacheOutboxError: Error, Equatable, Sendable {
    case invalidDraftDates
    case invalidPendingSendDates
}
