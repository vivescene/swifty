import AuthFeature
import Observation
import SwiftUI

/// A transport-free authentication surface for exercising the AuthFeature state
/// machine. It intentionally has no credential field, QR payload, web view, or
/// Discord endpoint. The fixture interaction surface is rendered only in
/// Debug builds.
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
    private var fixtureSessionNumber = 0
    private var operationTask: Task<Void, Never>?

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
        .task(id: viewModel.sessionID) {
            guard viewModel.sessionID != nil else { return }
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
                Text("Live Discord authentication is not connected.")
                    .font(.headline)
                Text("This screen uses fabricated state only. It does not accept credentials, render QR secrets, open arbitrary web content, or contact Discord.")
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
        .accessibilityLabel("Live Discord authentication is not connected. This screen uses fabricated state only and does not contact Discord.")
    }

    private var releaseNotice: some View {
        ContentUnavailableView {
            Label("Authentication is not available yet", systemImage: "lock.shield")
        } description: {
            Text("Swifty's live Discord authentication is not connected in this release. Protocol feasibility, account protection, and supervised interoperability testing must be completed before sign-in can be offered.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Authentication is not available yet. Swifty's live Discord authentication is not connected in this release. Protocol feasibility, account protection, and supervised interoperability testing must be completed before sign-in can be offered.")
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
        Text("No account, credential, QR secret, or message is sent to Swifty infrastructure by this screen. The in-memory fixture is discarded when the app exits.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("No account, credential, QR secret, or message is sent to Swifty infrastructure. The in-memory fixture is discarded when the app exits.")
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
