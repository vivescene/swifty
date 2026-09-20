import Foundation
import XCTest
@testable import RemoteAuthTransport

final class RemoteAuthGatewayTests: XCTestCase {
    func testGatewayConnectsReceivesHelloAndSendsInitAndNonceProof() async throws {
        let socket = FakeRemoteAuthSocket(incoming: [
            Data("{\"op\":\"hello\",\"timeout_ms\":314713,\"heartbeat_interval\":41250}".utf8),
            Data("{\"op\":\"nonce_proof\",\"encrypted_nonce\":\"ciphertext\"}".utf8),
            Data("{\"op\":\"pending_remote_init\",\"fingerprint\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}".utf8)
        ])
        let gateway = try RemoteAuthGateway(clock: NoSleepClock(), expectedPublicKeyFingerprint: fixtureFingerprint(), socketFactory: { socket })

        try await gateway.connect()
        let connectingState = await gateway.state
        XCTAssertEqual(connectingState, .awaitingHello)
        guard case .hello(let hello) = try await gateway.receiveEvent() else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(hello.heartbeatIntervalMilliseconds, 41_250)
        let activeState = await gateway.state
        XCTAssertEqual(activeState, .active)

        let initPayload = try RemoteAuthInitPayload(encodedPublicKey: fixturePublicKey(), fingerprint: fixtureFingerprint())
        try await gateway.initialize(initPayload)
        guard case .nonceProof(let challenge) = try await gateway.receiveEvent() else {
            return XCTFail("expected nonce proof challenge")
        }
        XCTAssertEqual(challenge.encryptedNonce, "ciphertext")
        try await gateway.sendNonceProof(try RemoteAuthNonceProof(nonce: "AQ"))
        guard case .pendingRemoteInit(let pending) = try await gateway.receiveEvent() else {
            return XCTFail("expected pending remote init")
        }
        XCTAssertEqual(pending.fingerprint, fixtureFingerprint())

        let sent = await socket.sentMessages()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(RemoteAuthEnvelope.self, from: sent[0]).operation, .initSession)
        XCTAssertEqual(try JSONDecoder().decode(RemoteAuthEnvelope.self, from: sent[1]).operation, .nonceProof)
    }

    func testGatewayHandlesTimeoutAndCancelEvents() async throws {
        let socket = FakeRemoteAuthSocket(incoming: [Data("{\"op\":\"timeout\"}".utf8)])
        let gateway = try RemoteAuthGateway(clock: NoSleepClock(), socketFactory: { socket })
        try await gateway.connect()
        _ = try await gateway.receiveEvent()
        let state = await gateway.state
        XCTAssertEqual(state, .closed(.timeout))
    }

    func testGatewayDecodesPendingTicketAndPendingLoginWithoutPlaintextToken() async throws {
        let socket = FakeRemoteAuthSocket(incoming: [
            Data("{\"op\":\"hello\",\"timeout_ms\":314713,\"heartbeat_interval\":41250}".utf8),
            Data("{\"op\":\"nonce_proof\",\"encrypted_nonce\":\"ciphertext\"}".utf8),
            Data("{\"op\":\"pending_remote_init\",\"fingerprint\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}".utf8),
            Data("{\"op\":\"pending_ticket\",\"encrypted_user_payload\":\"ciphertext\"}".utf8),
            Data("{\"op\":\"pending_login\",\"ticket\":\"fixture-ticket\"}".utf8)
        ])
        let gateway = try RemoteAuthGateway(clock: NoSleepClock(), socketFactory: { socket })
        try await gateway.connect()
        _ = try await gateway.receiveEvent()
        try await gateway.initialize(try RemoteAuthInitPayload(encodedPublicKey: fixturePublicKey(), fingerprint: fixtureFingerprint()))
        _ = try await gateway.receiveEvent()
        try await gateway.sendNonceProof(try RemoteAuthNonceProof(nonce: "AQ"))
        _ = try await gateway.receiveEvent()
        guard case .pendingTicket(let ticket) = try await gateway.receiveEvent() else {
            return XCTFail("expected pending ticket")
        }
        XCTAssertEqual(ticket.encryptedUserPayload, "ciphertext")
        guard case .pendingLogin(let login) = try await gateway.receiveEvent() else {
            return XCTFail("expected pending login")
        }
        XCTAssertEqual(login.ticket, "fixture-ticket")
    }

    func testFingerprintMismatchFailsClosedBeforePendingRemoteInit() async throws {
        let socket = FakeRemoteAuthSocket(incoming: [
            Data("{\"op\":\"hello\",\"timeout_ms\":314713,\"heartbeat_interval\":41250}".utf8),
            Data("{\"op\":\"nonce_proof\",\"encrypted_nonce\":\"ciphertext\"}".utf8),
            Data("{\"op\":\"pending_remote_init\",\"fingerprint\":\"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE\"}".utf8)
        ])
        let gateway = try RemoteAuthGateway(expectedPublicKeyFingerprint: fixtureFingerprint(), socketFactory: { socket })
        try await gateway.connect()
        _ = try await gateway.receiveEvent()
        try await gateway.initialize(try RemoteAuthInitPayload(encodedPublicKey: fixturePublicKey(), fingerprint: fixtureFingerprint()))
        _ = try await gateway.receiveEvent()
        try await gateway.sendNonceProof(try RemoteAuthNonceProof(nonce: "AQ"))
        do {
            _ = try await gateway.receiveEvent()
            XCTFail("expected fingerprint mismatch")
        } catch let error as RemoteAuthGatewayError {
            XCTAssertEqual(error, .fingerprintMismatch)
        }
        let state = await gateway.state
        XCTAssertEqual(state, .closed(.transportFailure))
    }

    func testConfiguredFingerprintMustBeBoundDuringInit() async throws {
        let socket = FakeRemoteAuthSocket(incoming: [])
        let gateway = try RemoteAuthGateway(expectedPublicKeyFingerprint: fixtureFingerprint(), socketFactory: { socket })
        try await gateway.connect()
        do {
            try await gateway.initialize(try RemoteAuthInitPayload(encodedPublicKey: fixturePublicKey()))
            XCTFail("expected missing init fingerprint to fail")
        } catch let error as RemoteAuthGatewayError {
            XCTAssertEqual(error, .fingerprintMismatch)
        }
        let state = await gateway.state
        XCTAssertEqual(state, .closed(.transportFailure))
    }

    func testSendFailureClosesAndInvalidatesTheAttempt() async throws {
        let socket = FakeRemoteAuthSocket(incoming: [
            Data("{\"op\":\"hello\",\"timeout_ms\":314713,\"heartbeat_interval\":41250}".utf8)
        ], failSends: true)
        let gateway = try RemoteAuthGateway(socketFactory: { socket })
        try await gateway.connect()
        _ = try await gateway.receiveEvent()
        do {
            try await gateway.initialize(try RemoteAuthInitPayload(encodedPublicKey: fixturePublicKey(), fingerprint: fixtureFingerprint()))
            XCTFail("expected send failure")
        } catch let error as RemoteAuthGatewayError {
            XCTAssertEqual(error, .transportFailure)
        }
        let phase = await gateway.phase
        XCTAssertEqual(phase, .closed)
    }

    func testOversizedIncomingMessageIsRejected() async throws {
        let socket = FakeRemoteAuthSocket(incoming: [Data(repeating: 0x20, count: 128)])
        let gateway = try RemoteAuthGateway(maximumMessageBytes: 64, socketFactory: { socket })
        try await gateway.connect()
        do {
            _ = try await gateway.receiveEvent()
            XCTFail("expected bounded message failure")
        } catch let error as RemoteAuthGatewayError {
            XCTAssertEqual(error, .messageTooLarge)
        }
    }

    func testUnexpectedEventFailsClosedAndInvalidPhaseIsReported() async throws {
        let socket = FakeRemoteAuthSocket(incoming: [
            Data("{\"op\":\"hello\",\"timeout_ms\":314713,\"heartbeat_interval\":41250}".utf8),
            Data("{\"op\":\"pending_ticket\",\"encrypted_user_payload\":\"ciphertext\"}".utf8)
        ])
        let gateway = try RemoteAuthGateway(clock: NoSleepClock(), socketFactory: { socket })
        try await gateway.connect()
        _ = try await gateway.receiveEvent()
        do {
            _ = try await gateway.receiveEvent()
            XCTFail("expected phase failure")
        } catch let error as RemoteAuthGatewayError {
            XCTAssertEqual(error, .invalidPhase)
        }
        let phase = await gateway.phase
        XCTAssertEqual(phase, .closed)
    }

    func testMissingHeartbeatAckClosesTheAttempt() async throws {
        let socket = FakeRemoteAuthSocket(incoming: [
            Data("{\"op\":\"hello\",\"timeout_ms\":10000,\"heartbeat_interval\":1}".utf8)
        ])
        let gateway = try RemoteAuthGateway(clock: ImmediateHeartbeatClock(), socketFactory: { socket })
        try await gateway.connect()
        _ = try await gateway.receiveEvent()
        try await Task.sleep(for: .milliseconds(10))
        let state = await gateway.state
        XCTAssertEqual(state, .closed(.transportFailure))
    }

    func testStaleConnectCannotReactivateAfterClose() async throws {
        let socket = BlockingConnectSocket()
        let gateway = try RemoteAuthGateway(clock: NoSleepClock(), socketFactory: { socket })
        let connectTask = Task { try await gateway.connect() }
        await socket.waitForConnectStart()
        await gateway.close()
        await socket.releaseConnect()
        do {
            _ = try await connectTask.value
            XCTFail("expected stale attempt")
        } catch let error as RemoteAuthGatewayError {
            XCTAssertEqual(error, .staleAttempt)
        }
        let phase = await gateway.phase
        XCTAssertEqual(phase, .closed)
    }
}

private struct NoSleepClock: RemoteAuthClock {
    func nowMilliseconds() -> Int64 { 0 }
    func sleep(milliseconds: Int) async throws { throw CancellationError() }
}

private struct ImmediateHeartbeatClock: RemoteAuthClock {
    func nowMilliseconds() -> Int64 { 0 }
    func sleep(milliseconds: Int) async throws {
        if milliseconds > 100 { try await Task.sleep(for: .seconds(3_600)) }
    }
}

private actor FakeRemoteAuthSocket: RemoteAuthWebSocket {
    private var incoming: [Data]
    private var sent: [Data] = []
    private let failSends: Bool
    private(set) var connected = false

    init(incoming: [Data], failSends: Bool = false) {
        self.incoming = incoming
        self.failSends = failSends
    }

    func connect() async throws { connected = true }
    func send(_ data: Data) async throws {
        if failSends { throw FakeSocketError.sendFailed }
        sent.append(data)
    }
    func receive() async throws -> Data {
        guard !incoming.isEmpty else { throw FakeSocketError.empty }
        return incoming.removeFirst()
    }
    func close() async {}
    func sentMessages() -> [Data] { sent }
}

private enum FakeSocketError: Error { case empty, sendFailed }

private func fixtureFingerprint(byte: UInt8 = 0) -> String {
    Data(repeating: byte, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func fixturePublicKey() -> String {
    func length(_ value: Int) -> Data {
        if value < 0x80 { return Data([UInt8(value)]) }
        var value = value
        var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
    let algorithm = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
    let modulus = Data([0x00, 0x80]) + Data(repeating: 0xAA, count: 255)
    let rsaBody = Data([0x02]) + length(modulus.count) + modulus + Data([0x02, 0x03, 0x01, 0x00, 0x01])
    let rsa = Data([0x30]) + length(rsaBody.count) + rsaBody
    let bitString = Data([0x03]) + length(rsa.count + 1) + Data([0x00]) + rsa
    let spkiBody = algorithm + bitString
    let spki = Data([0x30]) + length(spkiBody.count) + spkiBody
    return spki.base64EncodedString()
}

private actor BlockingConnectSocket: RemoteAuthWebSocket {
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func connect() async throws {
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
        }
    }

    func waitForConnectStart() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func releaseConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func send(_ data: Data) async throws {}
    func receive() async throws -> Data { throw FakeSocketError.empty }
    func close() async { connectContinuation?.resume(throwing: CancellationError()); connectContinuation = nil }
}
