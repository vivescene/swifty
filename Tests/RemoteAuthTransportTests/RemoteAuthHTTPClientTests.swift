import Foundation
import XCTest
@testable import RemoteAuthTransport

final class RemoteAuthHTTPClientTests: XCTestCase {
    func testLoginExchangeUsesExactEndpointAndDoesNotAttachAuthorization() async throws {
        let transport = RecordingHTTPTransport(response: RemoteAuthHTTPResponse(
            statusCode: 200,
            data: Data("{\"encrypted_token\":\"ciphertext\"}".utf8)
        ))
        let exchange = RemoteAuthLoginExchange(capability: RemoteAuthLoginExchangeCapability(), transport: transport)
        let result = try await exchange.exchange(ticket: "fixture-ticket")
        XCTAssertEqual(result.encryptedToken, "ciphertext")

        let request = await transport.lastRequest
        XCTAssertEqual(request?.url, RemoteAuthLoginExchange.endpoint)
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testLoginExchangeRejectsNonSuccessResponseAndMalformedResponse() async throws {
        let denied = RecordingHTTPTransport(response: RemoteAuthHTTPResponse(statusCode: 401, data: Data()))
        do {
            _ = try await RemoteAuthLoginExchange(capability: RemoteAuthLoginExchangeCapability(), transport: denied).exchange(ticket: "fixture")
            XCTFail("expected status failure")
        } catch let error as RemoteAuthHTTPError {
            XCTAssertEqual(error, .unexpectedStatus(401))
        }

        let malformed = RecordingHTTPTransport(response: RemoteAuthHTTPResponse(statusCode: 200, data: Data("{}".utf8)))
        do {
            _ = try await RemoteAuthLoginExchange(capability: RemoteAuthLoginExchangeCapability(), transport: malformed).exchange(ticket: "fixture")
            XCTFail("expected response failure")
        } catch let error as RemoteAuthHTTPError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }

    func testExactEndpointRejectsQueryAndRedirectHosts() {
        XCTAssertTrue(RemoteAuthLoginExchange.isExactEndpoint(RemoteAuthLoginExchange.endpoint))
        XCTAssertFalse(RemoteAuthLoginExchange.isExactEndpoint(URL(string: "https://discord.com/api/v9/users/@me/remote-auth/login?x=1")))
        XCTAssertFalse(RemoteAuthLoginExchange.isExactEndpoint(URL(string: "https://evil.example/api/v9/users/@me/remote-auth/login")))
    }

    func testRedirectPolicyNeverFollowsAndWireDescriptionsAreRedacted() {
        let request = URLRequest(url: URL(string: "https://evil.example/redirect")!)
        XCTAssertFalse(RemoteAuthRedirectPolicy.shouldFollow(request))
        XCTAssertEqual(String(describing: RemoteAuthJSONValue.string("fixture-secret")), "remote-auth-json-value(redacted)")
        let envelope = RemoteAuthEnvelope(operation: .pendingLogin, fields: ["ticket": .string("fixture-ticket")])
        XCTAssertEqual(String(describing: envelope), "remote-auth-envelope(redacted)")
    }

    func testTicketAndResponseBoundsAreEnforcedAndExchangeIsCapabilityGated() async throws {
        let transport = RecordingHTTPTransport(response: RemoteAuthHTTPResponse(statusCode: 200, data: Data(repeating: 0, count: RemoteAuthLoginExchange.maximumResponseBytes + 1)))
        let exchange = RemoteAuthLoginExchange(capability: RemoteAuthLoginExchangeCapability(), transport: transport)
        do {
            _ = try await exchange.exchange(ticket: String(repeating: "x", count: RemoteAuthLoginExchange.maximumTicketBytes + 1))
            XCTFail("expected ticket bound")
        } catch let error as RemoteAuthHTTPError {
            XCTAssertEqual(error, .ticketTooLarge)
        }
        do {
            _ = try await exchange.exchange(ticket: "fixture-ticket")
            XCTFail("expected response bound")
        } catch let error as RemoteAuthHTTPError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }
}

private actor RecordingHTTPTransport: RemoteAuthHTTPTransport {
    let response: RemoteAuthHTTPResponse
    private(set) var lastRequest: URLRequest?

    init(response: RemoteAuthHTTPResponse) { self.response = response }

    func data(for request: URLRequest) async throws -> RemoteAuthHTTPResponse {
        lastRequest = request
        return response
    }
}
