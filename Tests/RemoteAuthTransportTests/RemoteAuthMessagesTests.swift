import Foundation
import XCTest
@testable import RemoteAuthTransport

final class RemoteAuthMessagesTests: XCTestCase {
    func testEnvelopePreservesUnknownFieldsAndKnownPayloads() throws {
        let data = Data("{\"op\":\"pending_login\",\"ticket\":\"fixture-ticket\",\"future_field\":{\"enabled\":true}}".utf8)
        let envelope = try JSONDecoder().decode(RemoteAuthEnvelope.self, from: data)
        XCTAssertEqual(envelope.operation, .pendingLogin)
        XCTAssertEqual(envelope.string("ticket"), "fixture-ticket")
        XCTAssertNotNil(envelope.fields["future_field"])
    }

    func testUnknownOperationDoesNotExposeRawValueInDescription() throws {
        let envelope = try JSONDecoder().decode(
            RemoteAuthEnvelope.self,
            from: Data("{\"op\":\"future\",\"token\":\"must-not-be-printed\"}".utf8)
        )
        XCTAssertEqual(envelope.operation.description, "unknown")
    }

    func testHelloRequiresPositiveTimingValues() {
        let envelope = RemoteAuthEnvelope(
            operation: .hello,
            fields: ["timeout_ms": .number(20_000), "heartbeat_interval": .number(41_250)]
        )
        XCTAssertNoThrow(try RemoteAuthHello(envelope: envelope))
        XCTAssertThrowsError(try RemoteAuthHello(envelope: RemoteAuthEnvelope(operation: .hello)))
    }

    func testOutboundKeyAndNonceValidationRejectsNonCanonicalForms() {
        XCTAssertThrowsError(try RemoteAuthInitPayload(encodedPublicKey: "not-a-key"))
        XCTAssertThrowsError(try RemoteAuthNonceProof(nonce: "AQ=="))
        XCTAssertThrowsError(try RemoteAuthNonceProof(nonce: String(repeating: "A", count: 300)))
    }
}
