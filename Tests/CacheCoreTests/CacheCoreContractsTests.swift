import XCTest
@testable import CacheCore

final class CacheCoreContractsTests: XCTestCase {
    func testNamespaceRejectsPathSeparatorsAndDoesNotExposeAccountIDInDescription() throws {
        XCTAssertThrowsError(try CacheAccountNamespace(accountID: "account/one"))
        XCTAssertThrowsError(try CacheAccountNamespace(accountID: ""))

        let namespace = try CacheAccountNamespace(accountID: "account-one")
        XCTAssertEqual(namespace.storageKey, "account:account-one")
        XCTAssertEqual(namespace.description, "cache-account(redacted)")
    }

    func testPresenceAndAuthorizationRemainIndependent() throws {
        let namespace = try CacheAccountNamespace(accountID: "account-one")
        let snapshot = CacheAccountSnapshot(
            namespace: namespace,
            presence: .present(lastUpdatedAt: 123),
            authorization: .unauthorized
        )

        XCTAssertEqual(snapshot.presence, .present(lastUpdatedAt: 123))
        XCTAssertEqual(snapshot.authorization, .unauthorized)
    }

    func testRetentionPolicyRequiresPositiveFiniteBounds() throws {
        let policy = try CacheRetentionPolicy(
            maxMessagesPerChannel: 100,
            maxMediaBytes: 10_000,
            maxMediaItems: 20,
            maxDraftAgeSeconds: 86_400,
            maxPendingSendAgeSeconds: 172_800
        )
        XCTAssertEqual(policy.maxMessagesPerChannel, 100)
        XCTAssertThrowsError(try CacheRetentionPolicy(
            maxMessagesPerChannel: 0,
            maxMediaBytes: 10_000,
            maxMediaItems: 20,
            maxDraftAgeSeconds: 86_400,
            maxPendingSendAgeSeconds: 172_800
        ))
    }

    func testRemovalAndRevocationCommandsCarryTheirNamespace() throws {
        let namespace = try CacheAccountNamespace(accountID: "account-one")
        let revoke = CacheAccessCommand.revokeAuthorization(namespace: namespace)
        let remove = CacheAccessCommand.remove(namespace: namespace, scope: .pendingSends)

        XCTAssertEqual(revoke, .revokeAuthorization(namespace: namespace))
        XCTAssertEqual(remove, .remove(namespace: namespace, scope: .pendingSends))
    }

    func testDraftAndPendingSendRejectReversedTimestamps() throws {
        let namespace = try CacheAccountNamespace(accountID: "account-one")
        let channel = try CacheChannelID("channel-one")
        let object = try CacheObjectID("object-one")

        XCTAssertThrowsError(try DraftRecord(
            id: object,
            namespace: namespace,
            channelID: channel,
            text: "draft",
            createdAt: 2,
            updatedAt: 1
        ))
        XCTAssertThrowsError(try PendingSendRecord(
            id: object,
            namespace: namespace,
            channelID: channel,
            text: "send",
            createdAt: 2,
            updatedAt: 1,
            status: .queued
        ))
    }
}
