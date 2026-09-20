import Foundation

public protocol RemoteAuthClock: Sendable {
    func nowMilliseconds() -> Int64
    func sleep(milliseconds: Int) async throws
}

public struct SystemRemoteAuthClock: RemoteAuthClock, Sendable {
    public init() {}
    public func nowMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    public func sleep(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}

public protocol RemoteAuthWebSocket: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

/// URLSession is hidden behind the protocol above. Tests supply an in-memory
/// socket; production uses an ephemeral session locked to Discord's endpoint.
public final class URLSessionRemoteAuthWebSocket: RemoteAuthWebSocket, @unchecked Sendable {
    public static let endpoint = URL(string: "wss://remote-auth-gateway.discord.gg/?v=2")!
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let maximumMessageBytes: Int

    public init(maximumMessageBytes: Int = 1_048_576) throws {
        guard maximumMessageBytes > 0 else { throw RemoteAuthGatewayError.invalidMessageLimit }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: RemoteAuthNoRedirectDelegate(), delegateQueue: nil)
        var request = URLRequest(url: Self.endpoint)
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        guard Self.isExactEndpoint(request.url) else { throw RemoteAuthGatewayError.invalidEndpoint }
        self.session = session
        self.task = session.webSocketTask(with: request)
        self.maximumMessageBytes = maximumMessageBytes
    }

    deinit { session.invalidateAndCancel() }
    public func connect() async throws { task.resume() }
    public func send(_ data: Data) async throws {
        guard data.count <= maximumMessageBytes else { throw RemoteAuthGatewayError.messageTooLarge }
        try await task.send(.data(data))
    }
    public func receive() async throws -> Data {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value):
            guard let valueData = value.data(using: .utf8) else { throw RemoteAuthGatewayError.invalidTextMessage }
            data = valueData
        @unknown default: throw RemoteAuthGatewayError.invalidTextMessage
        }
        guard data.count <= maximumMessageBytes else { throw RemoteAuthGatewayError.messageTooLarge }
        return data
    }
    public func close() async { task.cancel(with: .normalClosure, reason: nil) }

    public static func isExactEndpoint(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "wss", components.host == "remote-auth-gateway.discord.gg",
              components.port == nil, components.path == "/",
              components.queryItems == [URLQueryItem(name: "v", value: "2")],
              components.fragment == nil else { return false }
        return true
    }
}

/// URLSession may materialize a redirect before its delegate callback runs;
/// this is why the delegate rejects every redirect and the initial URL is
/// separately validated. No redirect target is accepted for auth.
final class RemoteAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum RemoteAuthGatewayState: Equatable, Sendable {
    case idle, connecting, awaitingHello, active, closing
    case closed(RemoteAuthCloseReason)
}

public enum RemoteAuthHandshakePhase: Equatable, Sendable {
    case idle, awaitingHello, awaitingInit, awaitingNonceChallenge, awaitingNonceProof
    case awaitingPendingRemoteInit, awaitingPendingTicket, awaitingPendingLogin, completed, closed
}

public enum RemoteAuthCloseReason: Equatable, Sendable {
    case cancelled, timeout, serverClosed, transportFailure
}

public enum RemoteAuthGatewayError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidMessageLimit, invalidState, invalidPhase, staleAttempt
    case messageTooLarge, invalidTextMessage, malformedMessage, socketClosed, transportFailure
    case heartbeatNotAcknowledged, fingerprintMismatch
}

/// Actor-owned transport for the unofficial desktop QR protocol. It does not
/// perform key generation/decryption or retain a plaintext token.
public actor RemoteAuthGateway {
    public static let endpoint = URLSessionRemoteAuthWebSocket.endpoint
    public static let origin = "https://discord.com"

    private let makeSocket: @Sendable () throws -> any RemoteAuthWebSocket
    private let clock: any RemoteAuthClock
    private let maximumMessageBytes: Int
    private var expectedFingerprint: Data?
    private let decoder = JSONDecoder()
    private var socket: (any RemoteAuthWebSocket)?
    private var heartbeatTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var heartbeatAwaitingAcknowledgement = false
    private var attemptGeneration: UInt64 = 0
    private var _state: RemoteAuthGatewayState = .idle
    private var _phase: RemoteAuthHandshakePhase = .idle

    public init(clock: any RemoteAuthClock = SystemRemoteAuthClock(), maximumMessageBytes: Int = 1_048_576,
                expectedPublicKeyFingerprint: String? = nil,
                socketFactory: @escaping @Sendable () throws -> any RemoteAuthWebSocket = {
                    try URLSessionRemoteAuthWebSocket()
                }) throws {
        guard maximumMessageBytes > 0 else { throw RemoteAuthGatewayError.invalidMessageLimit }
        if let expectedPublicKeyFingerprint,
           RemoteAuthWireValidation.canonicalFingerprint(expectedPublicKeyFingerprint) == nil {
            throw RemoteAuthGatewayError.fingerprintMismatch
        }
        self.clock = clock
        self.maximumMessageBytes = maximumMessageBytes
        self.expectedFingerprint = expectedPublicKeyFingerprint.flatMap(RemoteAuthWireValidation.canonicalFingerprint)
        self.makeSocket = socketFactory
    }

    public var state: RemoteAuthGatewayState { _state }
    public var phase: RemoteAuthHandshakePhase { _phase }
    public var generation: UInt64 { attemptGeneration }

    public func connect() async throws {
        guard case .idle = _state else { throw RemoteAuthGatewayError.invalidState }
        attemptGeneration &+= 1
        let generation = attemptGeneration
        _state = .connecting
        _phase = .awaitingHello
        do {
            let socket = try makeSocket()
            self.socket = socket
            try await socket.connect()
            guard generation == attemptGeneration, self.socket != nil else {
                await socket.close()
                throw RemoteAuthGatewayError.staleAttempt
            }
            _state = .awaitingHello
        } catch let error as RemoteAuthGatewayError {
            if error == .staleAttempt { throw error }
            if generation != attemptGeneration { throw RemoteAuthGatewayError.staleAttempt }
            if generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
            throw error
        } catch {
            if generation != attemptGeneration { throw RemoteAuthGatewayError.staleAttempt }
            if generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
            throw RemoteAuthGatewayError.transportFailure
        }
    }

    /// Read one server frame. Every suspension revalidates the current attempt.
    public func receiveEvent() async throws -> RemoteAuthServerEvent {
        guard let socket else { throw RemoteAuthGatewayError.socketClosed }
        let generation = attemptGeneration
        let data: Data
        do {
            data = try await socket.receive()
            guard generation == attemptGeneration else { throw RemoteAuthGatewayError.staleAttempt }
        } catch let error as RemoteAuthGatewayError {
            if error == .staleAttempt { throw error }
            if generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
            throw error
        } catch {
            if generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
            throw RemoteAuthGatewayError.transportFailure
        }
        guard data.count <= maximumMessageBytes else {
            failCurrentAttempt(.transportFailure)
            throw RemoteAuthGatewayError.messageTooLarge
        }
        let event: RemoteAuthServerEvent
        do {
            let envelope = try decoder.decode(RemoteAuthEnvelope.self, from: data)
            event = try RemoteAuthServerEvent(envelope: envelope)
        } catch let error as RemoteAuthMessageError {
            if generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
            throw error == .messageTooLarge ? RemoteAuthGatewayError.messageTooLarge : RemoteAuthGatewayError.malformedMessage
        } catch {
            if generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
            throw RemoteAuthGatewayError.malformedMessage
        }
        try await handle(event, generation: generation)
        if generation != attemptGeneration {
            switch event { case .cancel, .timeout, .close: break; default: throw RemoteAuthGatewayError.staleAttempt }
        }
        return event
    }

    public func initialize(_ payload: RemoteAuthInitPayload) async throws {
        guard let fingerprint = payload.fingerprint,
              let canonical = RemoteAuthWireValidation.canonicalFingerprint(fingerprint) else {
            failCurrentAttempt(.transportFailure)
            throw RemoteAuthGatewayError.fingerprintMismatch
        }
        guard _phase == .awaitingInit else {
            failCurrentAttempt(.transportFailure)
            throw RemoteAuthGatewayError.invalidPhase
        }
        if let expectedFingerprint {
            guard RemoteAuthWireValidation.constantTimeEqual(expectedFingerprint, canonical) else {
                failCurrentAttempt(.transportFailure)
                throw RemoteAuthGatewayError.fingerprintMismatch
            }
        } else {
            expectedFingerprint = canonical
        }
        let generation = attemptGeneration
        do {
            try await send(RemoteAuthEnvelope(operation: .initSession, fields: payload.fields), generation: generation)
            guard generation == attemptGeneration else { throw RemoteAuthGatewayError.staleAttempt }
            _phase = .awaitingNonceChallenge
        } catch {
            if generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
            throw error
        }
    }

    public func sendNonceProof(_ nonceProof: RemoteAuthNonceProof) async throws {
        guard _phase == .awaitingNonceProof else {
            failCurrentAttempt(.transportFailure)
            throw RemoteAuthGatewayError.invalidPhase
        }
        let generation = attemptGeneration
        do {
            try await send(RemoteAuthEnvelope(operation: .nonceProof, fields: nonceProof.fields), generation: generation)
            guard generation == attemptGeneration else { throw RemoteAuthGatewayError.staleAttempt }
            _phase = .awaitingPendingRemoteInit
        } catch {
            if generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
            throw error
        }
    }

    public func cancel() async throws {
        guard !isClosed else { return }
        guard socket != nil else { throw RemoteAuthGatewayError.socketClosed }
        let generation = attemptGeneration
        _state = .closing
        do {
            try await send(RemoteAuthEnvelope(operation: .cancel), generation: generation)
            guard generation == attemptGeneration else { throw RemoteAuthGatewayError.staleAttempt }
        } catch {
            if generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
            throw error
        }
        heartbeatTask?.cancel(); timeoutTask?.cancel()
        let socket = self.socket; self.socket = nil
        await socket?.close()
        guard generation == attemptGeneration else { throw RemoteAuthGatewayError.staleAttempt }
        _state = .closed(.cancelled); _phase = .closed; attemptGeneration &+= 1
    }

    public func close() async {
        attemptGeneration &+= 1
        heartbeatTask?.cancel(); heartbeatTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        let socket = self.socket; self.socket = nil
        await socket?.close()
        _state = .closed(.serverClosed); _phase = .closed
    }

    private var isClosed: Bool { if case .closed = _state { return true }; return false }

    private func handle(_ event: RemoteAuthServerEvent, generation: UInt64) async throws {
        guard generation == attemptGeneration else { throw RemoteAuthGatewayError.staleAttempt }
        switch event {
        case .hello(let hello):
            guard _phase == .awaitingHello else { failInvalidPhase(); throw RemoteAuthGatewayError.invalidPhase }
            _phase = .awaitingInit; _state = .active; heartbeatAwaitingAcknowledgement = false
            startHeartbeat(intervalMilliseconds: hello.heartbeatIntervalMilliseconds, generation: generation)
            startTimeout(timeoutMilliseconds: hello.timeoutMilliseconds, generation: generation)
        case .heartbeat:
            guard _phase != .idle, _phase != .completed, _phase != .closed else { failInvalidPhase(); throw RemoteAuthGatewayError.invalidPhase }
            try await send(RemoteAuthEnvelope(operation: .heartbeat), generation: generation)
        case .heartbeatAck:
            guard _phase != .idle, heartbeatAwaitingAcknowledgement else { failInvalidPhase(); throw RemoteAuthGatewayError.invalidPhase }
            heartbeatAwaitingAcknowledgement = false
        case .nonceProof:
            guard _phase == .awaitingNonceChallenge else { failInvalidPhase(); throw RemoteAuthGatewayError.invalidPhase }
            _phase = .awaitingNonceProof
        case .pendingRemoteInit:
            guard _phase == .awaitingPendingRemoteInit else { failInvalidPhase(); throw RemoteAuthGatewayError.invalidPhase }
            guard case .pendingRemoteInit(let pending) = event,
                  let expectedFingerprint,
                  let receivedFingerprint = RemoteAuthWireValidation.canonicalFingerprint(pending.fingerprint),
                  RemoteAuthWireValidation.constantTimeEqual(expectedFingerprint, receivedFingerprint) else {
                failCurrentAttempt(.transportFailure)
                throw RemoteAuthGatewayError.fingerprintMismatch
            }
            _phase = .awaitingPendingTicket
        case .pendingTicket:
            guard _phase == .awaitingPendingTicket else { failInvalidPhase(); throw RemoteAuthGatewayError.invalidPhase }
            _phase = .awaitingPendingLogin
        case .pendingLogin:
            guard _phase == .awaitingPendingLogin else { failInvalidPhase(); throw RemoteAuthGatewayError.invalidPhase }
            _phase = .completed
        case .cancel:
            guard _phase != .idle else { failInvalidPhase(); throw RemoteAuthGatewayError.invalidPhase }
            await finishServerClose(.cancelled)
        case .timeout: await finishServerClose(.timeout)
        case .close: await finishServerClose(.serverClosed)
        case .unknown:
            failInvalidPhase(); throw RemoteAuthGatewayError.invalidPhase
        }
    }

    private func startHeartbeat(intervalMilliseconds: Int, generation: UInt64) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await self?.clock.sleep(milliseconds: intervalMilliseconds) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.sendHeartbeat(generation: generation)
            }
        }
    }

    private func startTimeout(timeoutMilliseconds: Int, generation: UInt64) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await self?.clock.sleep(milliseconds: timeoutMilliseconds) } catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.handleLocalTimeout(generation: generation)
        }
    }

    private func handleLocalTimeout(generation: UInt64) async {
        guard generation == attemptGeneration, !isClosed else { return }
        await finishServerClose(.timeout)
    }

    private func sendHeartbeat(generation: UInt64) async {
        guard generation == attemptGeneration, _phase != .idle, _phase != .completed, _phase != .closed else { return }
        guard !heartbeatAwaitingAcknowledgement else { failCurrentAttempt(.transportFailure); return }
        do {
            try await send(RemoteAuthEnvelope(operation: .heartbeat), generation: generation)
            guard generation == attemptGeneration else { return }
            heartbeatAwaitingAcknowledgement = true
        } catch let error as RemoteAuthGatewayError {
            if error != .staleAttempt && generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
        } catch {
            if generation == attemptGeneration { failCurrentAttempt(.transportFailure) }
        }
    }

    private func send(_ envelope: RemoteAuthEnvelope, generation: UInt64) async throws {
        guard generation == attemptGeneration, let socket else { throw RemoteAuthGatewayError.staleAttempt }
        let data: Data
        do { data = try envelope.data(maximumBytes: maximumMessageBytes) }
        catch RemoteAuthMessageError.messageTooLarge { throw RemoteAuthGatewayError.messageTooLarge }
        catch RemoteAuthMessageError.fieldTooLarge { throw RemoteAuthGatewayError.messageTooLarge }
        catch { throw RemoteAuthGatewayError.malformedMessage }
        do {
            try await socket.send(data)
        } catch let error as RemoteAuthGatewayError {
            throw error
        } catch {
            throw RemoteAuthGatewayError.transportFailure
        }
        guard generation == attemptGeneration else { throw RemoteAuthGatewayError.staleAttempt }
    }

    private func failInvalidPhase() {
        failCurrentAttempt(.transportFailure)
    }

    private func failCurrentAttempt(_ reason: RemoteAuthCloseReason) {
        attemptGeneration &+= 1
        heartbeatTask?.cancel(); timeoutTask?.cancel()
        let socket = self.socket
        self.socket = nil
        Task { await socket?.close() }
        _state = .closed(reason); _phase = .closed
    }

    private func finishServerClose(_ reason: RemoteAuthCloseReason) async {
        attemptGeneration &+= 1
        heartbeatTask?.cancel(); timeoutTask?.cancel()
        _state = .closed(reason); _phase = .closed
        let socket = self.socket
        self.socket = nil
        await socket?.close()
    }
}
