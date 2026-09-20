import AppKit
import AuthFeature
import CoreImage
import Observation
import RemoteAuthTransport
import SwiftUI

/// Authentication UI for the experimental credential-free Discord remote-auth
/// QR checkpoint and the local AuthFeature fixture state machine. The live
/// flow never accepts credentials, opens a web view, or imports a token. The
/// fixture interaction surface is rendered only in Debug builds.
@MainActor
@Observable
final class AuthenticationViewModel {
    private let credentialStore: InMemoryCredentialStore
    private let coordinator: AuthCoordinator
    private let fixtureAccount = AuthenticatedAccount(
        identifier: AccountIdentifier("fixture-account"),
        displayLabel: "Fixture account"
    )

    private(set) var state: RemoteAuthState = .idle
    private(set) var isWorking = false
    private(set) var notice: String?
    private(set) var now = Date()
    private(set) var livePhase: LiveAuthenticationPhase = .idle
    private(set) var liveQRCode: NSImage?
    private var fixtureSessionNumber = 0
    private var operationTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveGateway: RemoteAuthGateway?
    private var liveAttemptID = 0

    init() {
        let store = InMemoryCredentialStore()
        credentialStore = store
        coordinator = AuthCoordinator(credentialStore: store)
    }

    var sessionID: String? {
        switch state {
        case .awaitingQRCode(let session), .pendingApproval(let session, _):
            return session.identifier
        default:
            return nil
        }
    }

    var expirationDate: Date? {
        switch state {
        case .awaitingQRCode(let session), .pendingApproval(let session, _):
            return Date(timeIntervalSince1970: TimeInterval(session.expiresAt))
        default:
            return nil
        }
    }

    var secondsRemaining: Int? {
        guard let expirationDate else { return nil }
        return max(0, Int(expirationDate.timeIntervalSince(now).rounded(.down)))
    }

    var liveSecondsRemaining: Int? {
        guard case .waitingForScan(_, let expiresAt) = livePhase else { return nil }
        return max(0, Int(expiresAt.timeIntervalSince(now).rounded(.down)))
    }

    var statusTitle: String {
        switch state {
        case .idle: return "Ready for a fixture session"
        case .awaitingQRCode: return "Waiting for QR scan"
        case .pendingApproval: return "Approval requested"
        case .approved: return "Fixture account approved"
        case .restoring: return "Restoring fixture account"
        case .restored: return "Fixture account restored"
        case .cancelled: return "Session cancelled"
        case .expired: return "Session expired"
        case .rejected(let reason): return "Approval rejected: \(reason.label)"
        case .failed(let failure): return "Authentication failed: \(failure.label)"
        case .invalidated: return "Session invalidated"
        case .loggedOut: return "Logged out"
        }
    }

    var statusDescription: String {
        switch state {
        case .idle:
            return "Start a local, fabricated session to exercise the lifecycle."
        case .awaitingQRCode:
            return "No QR payload is generated. This state represents the waiting phase only."
        case .pendingApproval(_, let hint):
            if let hint { return "A fixture scan identified \(hint.displayLabel)." }
            return "A fixture scan has requested approval."
        case .approved(_, let account), .restored(_, let account):
            return "\(account.displayLabel) exists only in memory and is not connected to Discord."
        case .restoring:
            return "The injected in-memory credential store is being checked."
        case .cancelled:
            return "The fixture session can be started again."
        case .expired:
            return "The session reached its deadline and cannot be approved."
        case .rejected(let reason):
            return reason.explanation
        case .failed(let failure):
            return failure.explanation
        case .invalidated:
            return "The fixture credential was removed from the in-memory store."
        case .loggedOut:
            return "No account is active. A fixture restore can be requested."
        }
    }

    var isAuthenticated: Bool {
        switch state {
        case .approved, .restored: return true
        default: return false
        }
    }

    var authenticatedAccount: AuthenticatedAccount? {
        switch state {
        case .approved(_, let account), .restored(_, let account):
            return account
        default:
            return nil
        }
    }

    func cancelOperations() {
        operationTask?.cancel()
        operationTask = nil
        isWorking = false
        cancelLiveAuthentication()
    }

    /// Starts the intentionally experimental first half of Discord desktop
    /// remote-auth. It stops at the scannable QR checkpoint and never imports
    /// a ticket, user payload, or Discord token.
    func startLiveAuthentication() {
        guard liveTask == nil else { return }

        liveAttemptID += 1
        let attemptID = liveAttemptID
        livePhase = .connecting
        liveQRCode = nil
        notice = nil

        liveTask = Task { @MainActor [weak self] in
            await self?.runLiveAuthentication(attemptID: attemptID)
        }
    }

    func cancelLiveAuthentication() {
        liveAttemptID += 1
        liveTask?.cancel()
        liveTask = nil
        let gateway = liveGateway
        liveGateway = nil
        liveQRCode = nil
        livePhase = .cancelled
        Task { await gateway?.close() }
    }

    private func runLiveAuthentication(attemptID: Int) async {
        var gateway: RemoteAuthGateway?
        defer {
            let taskGateway = gateway
            if liveAttemptID == attemptID {
                liveGateway = nil
                liveTask = nil
            }
            Task { await taskGateway?.close() }
        }

        do {
            try Task.checkCancellation()
            let keyPair = try RemoteAuthKeyPair()
            // Bind the gateway attempt to this ephemeral key before any
            // server frames are accepted. The transport then performs the
            // canonical, constant-time fingerprint check for
            // pending_remote_init before returning that event to this UI.
            let connectedGateway = try RemoteAuthGateway(
                expectedPublicKeyFingerprint: keyPair.publicKeyFingerprint
            )
            gateway = connectedGateway

            guard liveAttemptID == attemptID else { throw CancellationError() }
            liveGateway = connectedGateway
            try await connectedGateway.connect()
            livePhase = .awaitingHello

            var timeoutMilliseconds = 120_000
            while liveAttemptID == attemptID {
                try Task.checkCancellation()
                let event = try await connectedGateway.receiveEvent()
                try Task.checkCancellation()

                switch event {
                case .hello(let hello):
                    timeoutMilliseconds = hello.timeoutMilliseconds
                    let payload = try RemoteAuthInitPayload(
                        encodedPublicKey: keyPair.publicKeyBase64,
                        fingerprint: keyPair.publicKeyFingerprint
                    )
                    try await connectedGateway.initialize(payload)
                    livePhase = .awaitingNonceProof

                case .nonceProof(let challenge):
                    let ciphertext = try RemoteAuthBase64.decode(challenge.encryptedNonce)
                    let plaintextNonce = try keyPair.decryptRSAOAEP(ciphertext: ciphertext)
                    let proof = RemoteAuthBase64.encodeURLSafeUnpadded(plaintextNonce)
                    try await connectedGateway.sendNonceProof(try RemoteAuthNonceProof(nonce: proof))

                case .pendingRemoteInit(let pending):
                    // receiveEvent() only returns this event after the
                    // gateway has verified the bound fingerprint. Keep the
                    // phase assertion here as a second boundary so no QR is
                    // rendered if the transport contract ever regresses.
                    guard await connectedGateway.phase == .awaitingPendingTicket,
                          pending.fingerprint == keyPair.publicKeyFingerprint else {
                        throw LiveAuthenticationError.fingerprintMismatch
                    }

                    let qrPayload = "https://discord.com/ra/\(keyPair.publicKeyFingerprint)"
                    guard let qrImage = makeQRCode(for: qrPayload) else {
                        throw LiveAuthenticationError.qrGenerationFailed
                    }
                    liveQRCode = qrImage
                    livePhase = .waitingForScan(
                        fingerprint: keyPair.publicKeyFingerprint,
                        expiresAt: Date().addingTimeInterval(TimeInterval(timeoutMilliseconds) / 1_000)
                    )

                case .pendingTicket, .pendingLogin:
                    // This checkpoint deliberately never advances to login.
                    // Close immediately if a later server event arrives.
                    await connectedGateway.close()
                    throw LiveAuthenticationError.loginEventRejected

                case .cancel:
                    liveQRCode = nil
                    livePhase = .cancelled
                    return

                case .timeout:
                    liveQRCode = nil
                    livePhase = .expired
                    return

                case .close:
                    liveQRCode = nil
                    livePhase = .failed("The Discord remote-auth connection closed.")
                    return

                case .heartbeat, .heartbeatAck:
                    continue
                case .unknown:
                    throw LiveAuthenticationError.unsupportedEvent
                }
            }
        } catch is CancellationError {
            // Explicit cancellation already published its state and closed
            // the actor. Do not replace it with a generic error.
        } catch {
            guard liveAttemptID == attemptID else { return }
            liveQRCode = nil
            livePhase = .failed("The experimental remote-auth handshake could not be completed. The connection was closed.")
        }
    }

    private func makeQRCode(for payload: String) -> NSImage? {
        guard let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    private func expireLiveAuthentication() {
        guard case .waitingForScan = livePhase else { return }
        liveAttemptID += 1
        liveTask?.cancel()
        liveTask = nil
        let gateway = liveGateway
        liveGateway = nil
        liveQRCode = nil
        livePhase = .expired
        Task { await gateway?.close() }
    }

    func startFixtureSession() {
        guard !isWorking else { return }
        fixtureSessionNumber += 1
        let issuedAt = Int64(Date().timeIntervalSince1970)
        let session: RemoteAuthSession
        do {
            session = try RemoteAuthSession(
                identifier: "fixture-session-\(fixtureSessionNumber)",
                issuedAt: issuedAt,
                expiresAt: issuedAt + 120
            )
        } catch {
            notice = "The local fixture could not create a session."
            return
        }

        now = Date(timeIntervalSince1970: TimeInterval(issuedAt))
        apply(.begin(session), notice: "Fixture QR session started.")
    }

    #if DEBUG
    func simulateScan() {
        guard let session = activeSession else { return }
        let scanTime = Int64(now.timeIntervalSince1970)
        apply(
            .qrScanned(
                sessionID: session.identifier,
                at: scanTime,
                hint: AccountApprovalHint(
                    account: fixtureAccount.identifier,
                    displayLabel: fixtureAccount.displayLabel
                )
            ),
            notice: "Fixture scan received."
        )
    }

    func approveFixture() {
        guard let session = activeSession else { return }
        apply(
            .approvalGranted(
                sessionID: session.identifier,
                at: Int64(now.timeIntervalSince1970),
                account: fixtureAccount
            ),
            notice: "Fixture approval accepted."
        )
    }

    func rejectFixture() {
        guard let session = activeSession else { return }
        apply(
            .approvalRejected(
                sessionID: session.identifier,
                at: Int64(now.timeIntervalSince1970),
                reason: .userDeclined
            ),
            notice: "Fixture approval rejected."
        )
    }

    func cancelFixture() {
        guard let session = activeSession else { return }
        apply(
            .cancelled(sessionID: session.identifier),
            notice: "Fixture session cancelled."
        )
    }

    func restoreFixture() {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        let sessionID = restoreSessionID

        let store = credentialStore
        let coordinator = coordinator
        let account = fixtureAccount
        operationTask = Task { @MainActor [weak self, store, coordinator, account, sessionID] in
            do {
                try Task.checkCancellation()

                // This is deliberately recognizable fixture material. It is
                // never shown, transmitted, or used as a Discord credential.
                do {
                    try await store.save(
                        CredentialMaterial(secret: Data("swifty-debug-fixture".utf8)),
                        for: account.identifier
                    )
                } catch {
                    // A store may fail after a partial write. Remove the
                    // fixture value before surfacing the failure.
                    try? await store.remove(for: account.identifier)
                    throw error
                }

                do {
                    try Task.checkCancellation()
                    let next = try await coordinator.restore(account, sessionID: sessionID)
                    guard case .restored = next else {
                        throw FixtureRestoreError.notRestored
                    }

                    guard let self else { return }
                    self.state = next
                    self.now = .now
                    self.notice = "Fixture credential restored in memory."
                } catch {
                    // Restore failures and cancellation after the write must
                    // never leave even fixture material behind.
                    try? await store.remove(for: account.identifier)
                    throw error
                }
            } catch is CancellationError {
                // Cancellation is intentionally silent; the operation did
                // not establish an authenticated account.
            } catch {
                guard let self else { return }
                self.notice = "The fixture restore could not be completed."
            }

            guard let self else { return }
            self.isWorking = false
            self.operationTask = nil
        }
    }

    func logoutFixture() {
        guard let sessionID = authenticatedSessionID else { return }
        apply(.logout(sessionID: sessionID), notice: "Fixture account logged out.")
    }

    func invalidateFixture() {
        guard let sessionID = authenticatedSessionID else { return }
        apply(.invalidate(sessionID: sessionID), notice: "Fixture credential invalidated.")
    }
    #endif

    /// Advances the local fixture clock and lets the state machine own expiry.
    func tick() async {
        now = .now
        if let remaining = liveSecondsRemaining, remaining <= 0 {
            expireLiveAuthentication()
        }
        guard !isWorking, let session = activeSession else { return }
        do {
            state = try await coordinator.apply(
                .tick(
                    sessionID: session.identifier,
                    now: Int64(now.timeIntervalSince1970)
                )
            )
        } catch {
            // A session can expire between the guard and the event. The next
            // tick or an explicit fixture action will present the stable state.
        }
    }

    private var activeSession: RemoteAuthSession? {
        switch state {
        case .awaitingQRCode(let session), .pendingApproval(let session, _):
            return session
        default:
            return nil
        }
    }

    private var authenticatedSessionID: String? {
        switch state {
        case .approved(let session, _): return session.identifier
        case .restored(let sessionID, _): return sessionID
        default: return nil
        }
    }

    private var restoreSessionID: String {
        if case .invalidated(let sessionID, _) = state { return sessionID }
        return "fixture-restore-session"
    }

    private func apply(_ event: AuthEvent, notice successNotice: String) {
        guard !isWorking else { return }
        isWorking = true
        notice = nil

        let coordinator = coordinator
        operationTask = Task { @MainActor [weak self, coordinator, event, successNotice] in
            do {
                try Task.checkCancellation()
                let next = try await coordinator.apply(event)

                // Once the actor has committed a valid transition, publish
                // that result even if cancellation arrived during the await.
                guard let self else { return }
                self.state = next
                self.notice = successNotice
            } catch is CancellationError {
                // The task is deliberately silent when the view is torn down.
            } catch {
                guard let self else { return }
                self.notice = "That fixture action is not valid for the current state."
            }

            guard let self else { return }
            self.isWorking = false
            self.operationTask = nil
        }
    }
}

enum LiveAuthenticationPhase: Equatable, Sendable {
    case idle
    case connecting
    case awaitingHello
    case awaitingNonceProof
    case waitingForScan(fingerprint: String, expiresAt: Date)
    case cancelled
    case expired
    case failed(String)
}

private enum LiveAuthenticationError: LocalizedError {
    case fingerprintMismatch
    case qrGenerationFailed
    case loginEventRejected
    case unsupportedEvent

    var errorDescription: String? {
        switch self {
        case .fingerprintMismatch:
            return "Discord returned a key fingerprint that did not match this session. The connection was closed."
        case .qrGenerationFailed:
            return "Swifty could not render the QR checkpoint. The connection was closed."
        case .loginEventRejected:
            return "A login event arrived before this experimental checkpoint was approved. The connection was closed."
        case .unsupportedEvent:
            return "Discord returned an unsupported remote-auth event. The connection was closed."
        }
    }
}

private enum FixtureRestoreError: Error {
    case notRestored
}

struct AuthenticationView: View {
    @Bindable var viewModel: AuthenticationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                limitationNotice
                liveAuthenticationSection
                #if DEBUG
                statusCard
                fixtureControls
                privacyNote
                #else
                releaseNotice
                #endif
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await viewModel.tick()
            }
        }
        .onDisappear {
            viewModel.cancelOperations()
        }
        .accessibilityLabel("Swifty authentication")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect Swifty", systemImage: "person.crop.circle.badge.plus")
                .font(.largeTitle.weight(.semibold))
            Text("Authentication is isolated here while the protocol adapter is being researched.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var limitationNotice: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Experimental live QR authentication")
                    .font(.headline)
                Text("Swifty can now perform the credential-free remote-auth handshake through Discord's exact gateway endpoint. It stops at the QR checkpoint and never imports a token.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Experimental live QR authentication. Swifty stops at the QR checkpoint and never imports a token.")
    }

    private var liveAuthenticationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label("Live QR checkpoint", systemImage: liveStatusSymbol)
                    .font(.title3.weight(.semibold))
                Spacer()
                if let remaining = viewModel.liveSecondsRemaining {
                    Text("expires in \(remaining)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(remaining < 20 ? .red : .secondary)
                }
            }

            Text(liveStatusDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let qrCode = viewModel.liveQRCode {
                VStack(spacing: 10) {
                    Image(nsImage: qrCode)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Discord remote-auth QR code. Scan it with the already signed-in Discord mobile app.")

                    Text("Scan this with the already signed-in Discord mobile app. Swifty will only wait for the approval checkpoint.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch viewModel.livePhase {
            case .idle, .cancelled, .expired, .failed:
                Button("Start real QR authentication", systemImage: "qrcode") {
                    viewModel.startLiveAuthentication()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Connects directly to Discord's remote-auth gateway and stops before login completion")
            case .connecting, .awaitingHello, .awaitingNonceProof, .waitingForScan:
                Button("Cancel live authentication", systemImage: "xmark.circle") {
                    viewModel.cancelLiveAuthentication()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private var liveStatusDescription: String {
        switch viewModel.livePhase {
        case .idle:
            return "This is an experimental, credential-free checkpoint. No username, password, token, web view, or CAPTCHA bypass is involved."
        case .connecting:
            return "Connecting to Discord's remote-auth gateway…"
        case .awaitingHello:
            return "Connected. Waiting for Discord's handshake hello before sending the ephemeral public key."
        case .awaitingNonceProof:
            return "The ephemeral key was sent. Decrypting Discord's nonce locally and sending only its proof."
        case .waitingForScan:
            return "The QR is ready. Swifty will close if Discord sends a later login event because this build does not import accounts yet."
        case .cancelled:
            return "The socket, ephemeral key, and QR code were cleared. You can start another attempt."
        case .expired:
            return "The Discord handshake expired. The socket, ephemeral key, and QR code were cleared."
        case .failed(let message):
            return message
        }
    }

    private var liveStatusSymbol: String {
        switch viewModel.livePhase {
        case .waitingForScan: return "qrcode"
        case .connecting, .awaitingHello, .awaitingNonceProof: return "arrow.triangle.2.circlepath"
        case .cancelled, .expired, .failed: return "xmark.shield"
        case .idle: return "shield"
        }
    }

    private var releaseNotice: some View {
        ContentUnavailableView {
            Label("Fixture controls are debug-only", systemImage: "hammer")
        } description: {
            Text("The experimental live QR checkpoint remains available. Local fabricated account controls are omitted from release builds.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fixture controls are debug-only. The experimental live QR checkpoint remains available in this release.")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(viewModel.statusTitle, systemImage: statusSymbol)
                    .font(.title3.weight(.semibold))
                Spacer()
                if let secondsRemaining = viewModel.secondsRemaining {
                    Text("expires in \(secondsRemaining)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(secondsRemaining < 20 ? .red : .secondary)
                }
            }
            Text(viewModel.statusDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.sessionID != nil {
                Label("QR payload withheld in fixture mode", systemImage: "qrcode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("QR payload withheld in fixture mode")
            }

            if let notice = viewModel.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(notice)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var fixtureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fixture controls")
                .font(.headline)

            if viewModel.sessionID == nil && !viewModel.isAuthenticated {
                Button("Start QR fixture session", systemImage: "qrcode") {
                    viewModel.startFixtureSession()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isWorking)
                .accessibilityHint("Starts a local fabricated session without contacting Discord")
            }

            #if DEBUG
            switch viewModel.state {
            case .awaitingQRCode:
                Button("Simulate QR scan", systemImage: "viewfinder") {
                    viewModel.simulateScan()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isWorking)
            case .pendingApproval:
                HStack {
                    Button("Approve fixture", systemImage: "checkmark.circle") {
                        viewModel.approveFixture()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Reject", systemImage: "xmark.circle") {
                        viewModel.rejectFixture()
                    }
                    .buttonStyle(.bordered)
                    Button("Cancel", systemImage: "slash.circle") {
                        viewModel.cancelFixture()
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(viewModel.isWorking)
            case .approved, .restored:
                HStack {
                    Button("Log out fixture", systemImage: "rectangle.portrait.and.arrow.right") {
                        viewModel.logoutFixture()
                    }
                    .buttonStyle(.bordered)
                    Button("Invalidate fixture", systemImage: "trash") {
                        viewModel.invalidateFixture()
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(viewModel.isWorking)
            case .idle, .loggedOut, .invalidated, .failed:
                Button("Restore fixture account", systemImage: "arrow.clockwise") {
                    viewModel.restoreFixture()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isWorking)
            case .cancelled, .expired, .rejected, .restoring:
                EmptyView()
            }
            #else
            Text("Additional fixture actions are available in Debug builds.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    private var privacyNote: some View {
        Text("Swifty has no project-operated auth service. The live checkpoint connects directly to Discord, keeps the ephemeral private key in memory, and discards the key and QR when the attempt ends. The fixture is also discarded when the app exits.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Swifty has no project-operated authentication service. The live checkpoint connects directly to Discord, keeps the ephemeral private key in memory, and discards the key and QR when the attempt ends. The fixture is also discarded when the app exits.")
    }

    private var statusSymbol: String {
        switch viewModel.state {
        case .approved, .restored: return "checkmark.shield"
        case .rejected, .failed, .expired, .invalidated: return "xmark.shield"
        case .cancelled, .loggedOut: return "slash.circle"
        case .restoring: return "arrow.clockwise"
        default: return "shield"
        }
    }
}

private extension AuthRejectionReason {
    var label: String {
        switch self {
        case .userDeclined: return "user declined"
        case .mfaRequired: return "MFA required"
        case .captchaRequired: return "CAPTCHA required"
        case .protocolUnavailable: return "protocol unavailable"
        case .invalidResponse: return "invalid response"
        case .unknown: return "unknown reason"
        }
    }

    var explanation: String {
        switch self {
        case .userDeclined: return "The fixture approval was declined."
        case .mfaRequired: return "The fixture requires an additional verification step."
        case .captchaRequired: return "The fixture requires a challenge that this prototype does not bypass."
        case .protocolUnavailable: return "No authentication protocol adapter is connected."
        case .invalidResponse: return "The fixture returned an invalid response."
        case .unknown: return "The fixture rejected the request for an unspecified reason."
        }
    }
}

private extension AuthFailure {
    var label: String {
        switch self {
        case .missingCredential: return "missing credential"
        case .credentialStoreUnavailable: return "credential store unavailable"
        case .invalidated: return "invalidated"
        case .cancelled: return "cancelled"
        case .expired: return "expired"
        case .rejected: return "rejected"
        }
    }

    var explanation: String {
        switch self {
        case .missingCredential: return "No fixture credential is available."
        case .credentialStoreUnavailable: return "The in-memory fixture store is unavailable."
        case .invalidated: return "The fixture credential is no longer valid."
        case .cancelled: return "The fixture operation was cancelled."
        case .expired: return "The fixture session expired."
        case .rejected: return "The fixture approval was rejected."
        }
    }
}
