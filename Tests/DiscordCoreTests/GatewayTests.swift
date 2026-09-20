import XCTest
@testable import DiscordCore

final class GatewayTests: XCTestCase {
    func testUnknownGatewayOpcodeRoundTrips() throws {
        let opcode = GatewayOpcode(rawValue: 999)
        let data = try JSONEncoder().encode(opcode)
        XCTAssertEqual(try JSONDecoder().decode(GatewayOpcode.self, from: data), opcode)
    }

    func testGatewayStatesCarryResumeInformation() {
        let state = GatewayConnectionState.resuming(sessionID: "session", sequence: 42)
        XCTAssertEqual(state, .resuming(sessionID: "session", sequence: 42))
    }

    func testExponentialBackoffIsDeterministicAndCapped() throws {
        let policy = try ExponentialBackoff(
            base: .milliseconds(100),
            maximum: .milliseconds(350),
            multiplier: 2
        )
        XCTAssertEqual(policy.delay(forAttempt: 0), .zero)
        XCTAssertEqual(policy.delay(forAttempt: 1), .milliseconds(100))
        XCTAssertEqual(policy.delay(forAttempt: 2), .milliseconds(200))
        XCTAssertEqual(policy.delay(forAttempt: 3), .milliseconds(350))
        XCTAssertEqual(policy.delay(forAttempt: 20), .milliseconds(350))
    }
}
