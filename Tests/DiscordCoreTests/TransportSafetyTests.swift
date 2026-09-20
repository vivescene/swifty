import Foundation
import XCTest
@testable import DiscordCore

final class TransportSafetyTests: XCTestCase {
    func testCredentialPolicyAllowsOnlyExactDiscordAPIOrigins() throws {
        let policy = CredentialAttachmentPolicy()

        XCTAssertEqual(
            policy.evaluate(URL(string: "https://discord.com/api/v10/channels")!),
            .attach
        )
        XCTAssertEqual(
            policy.evaluate(URL(string: "https://api.discord.com/api/v10/channels")!),
            .attach
        )
        XCTAssertFalse(policy.shouldAttachCredential(to: URL(string: "https://cdn.discordapp.com/file.png")!))
        XCTAssertFalse(policy.shouldAttachCredential(to: URL(string: "https://discord.com.attacker.example/api/v10")!))
        XCTAssertFalse(policy.shouldAttachCredential(to: URL(string: "https://discord.com.evil/api/v10")!))
    }

    func testCredentialPolicyRejectsUnsafeOriginProperties() throws {
        let policy = CredentialAttachmentPolicy()

        XCTAssertEqual(
            policy.evaluate(URL(string: "http://discord.com/api/v10")!),
            .omit(.nonHTTPScheme)
        )
        XCTAssertEqual(
            policy.evaluate(URL(string: "https://discord.com:8443/api/v10")!),
            .omit(.nonDefaultPort)
        )
        XCTAssertEqual(
            policy.evaluate(URL(string: "https://user:secret@discord.com/api/v10")!),
            .omit(.userInfoPresent)
        )
        XCTAssertEqual(
            policy.evaluate(URL(string: "https://discord.com/channels")!),
            .omit(.disallowedPath)
        )
    }

    func testRedirectDestinationIsReevaluated() throws {
        let policy = CredentialAttachmentPolicy()
        let thirdParty = URL(string: "https://uploads.example.test/file")!
        let api = URL(string: "https://discord.com/api/v10/channels")!

        XCTAssertEqual(policy.evaluateRedirect(to: thirdParty), .omit(.disallowedHost))
        XCTAssertEqual(policy.evaluateRedirect(to: api), .attach)
    }

    func testRateLimitObservationParsesHeadersAndGlobalBodyWithoutBudgets() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "global": true,
            "retry_after": 2.5,
            "unrecognized": ["ignored"]
        ])
        let observation = RateLimitObservation(
            route: "GET /channels/:id",
            headers: [
                "X-RateLimit-Limit": "not-a-number",
                "X-RateLimit-Remaining": "7",
                "X-RateLimit-Reset-After": "4.25",
                "X-Unrelated": "ignored"
            ],
            body: body
        )

        XCTAssertEqual(observation.scope, .global)
        XCTAssertEqual(observation.retryAfter, .milliseconds(2500))
        XCTAssertNil(observation.limit)
        XCTAssertEqual(observation.remaining, 7)
        XCTAssertEqual(observation.resetAfter, .milliseconds(4250))
    }

    func testRateLimitSnapshotPreservesPartialDataAndHonorsBothScopes() {
        var snapshot = RateLimitSnapshot()
        snapshot.record(RateLimitObservation(
            scope: .route("GET /channels/:id"),
            retryAfter: .seconds(1),
            limit: 50,
            remaining: 0
        ))
        snapshot.record(RateLimitObservation(
            scope: .route("GET /channels/:id"),
            resetAfter: .seconds(2)
        ))
        snapshot.record(RateLimitObservation(scope: .global, retryAfter: .seconds(3)))

        let route = snapshot.observation(forRoute: "GET /channels/:id")
        XCTAssertEqual(route?.limit, 50)
        XCTAssertEqual(route?.remaining, 0)
        XCTAssertEqual(route?.resetAfter, .seconds(2))
        XCTAssertEqual(snapshot.effectiveRetryAfter(forRoute: "GET /channels/:id"), .seconds(3))
    }

    func testMalformedRateLimitValuesAreDroppedIndividually() {
        let observation = RateLimitObservation(
            route: "GET /messages",
            headers: [
                "Retry-After": "-1",
                "X-RateLimit-Limit": "100",
                "X-RateLimit-Remaining": "wat",
                "X-RateLimit-Reset-After": "0.1234567891"
            ]
        )

        XCTAssertEqual(observation.scope, .route("GET /messages"))
        XCTAssertNil(observation.retryAfter)
        XCTAssertEqual(observation.limit, 100)
        XCTAssertNil(observation.remaining)
        XCTAssertNil(observation.resetAfter)
    }

    func testRateLimitDurationRejectsNonASCIIDigits() {
        let observation = RateLimitObservation(
            route: "GET /messages",
            headers: ["Retry-After": "0.٢"]
        )

        XCTAssertNil(observation.retryAfter)
    }
}
