import Foundation

/// Deterministic, transport-free remote-auth lifecycle. Network and crypto
/// adapters emit events carrying the session identifier they observed; an
/// event from an older session cannot mutate a newer session.
public struct AuthStateMachine: Sendable {
    public private(set) var state: RemoteAuthState

    public init(initialState: RemoteAuthState = .idle) {
        self.state = initialState
    }

    @discardableResult
    public mutating func apply(_ event: AuthEvent) throws -> RemoteAuthState {
        let next: RemoteAuthState

        switch (state, event) {
        case (.idle, .begin(let session)),
             (.cancelled, .begin(let session)),
             (.expired, .begin(let session)),
             (.rejected, .begin(let session)),
             (.failed, .begin(let session)),
             (.loggedOut, .begin(let session)),
             (.invalidated, .begin(let session)):
            next = .awaitingQRCode(session)

        case (.awaitingQRCode(let session), .qrScanned(let sessionID, let at, let hint)):
            try validate(sessionID: sessionID, matches: session)
            try validateActiveTimestamp(at, in: session)
            next = .pendingApproval(session: session, hint: hint)

        case (.pendingApproval(let session, let hint), .approvalGranted(let sessionID, let at, let account)):
            try validate(sessionID: sessionID, matches: session)
            try validateActiveTimestamp(at, in: session)
            if let hint, hint.account != account.identifier {
                throw AuthTransitionError.accountMismatch
            }
            next = .approved(session: session, account: account)

        case (.awaitingQRCode(let session), .approvalRejected(let sessionID, let at, let reason)),
             (.pendingApproval(let session, _), .approvalRejected(let sessionID, let at, let reason)):
            try validate(sessionID: sessionID, matches: session)
            try validateActiveTimestamp(at, in: session)
            next = .rejected(reason)

        case (.awaitingQRCode(let session), .cancelled(let sessionID)),
             (.pendingApproval(let session, _), .cancelled(let sessionID)):
            try validate(sessionID: sessionID, matches: session)
            next = .cancelled

        case (.awaitingQRCode(let session), .expired(let sessionID, let at)),
             (.pendingApproval(let session, _), .expired(let sessionID, let at)):
            try validate(sessionID: sessionID, matches: session)
            guard at == session.expiresAt else {
                throw AuthTransitionError.timestampOutsideSession
            }
            next = .expired

        case (.awaitingQRCode(let session), .tick(let sessionID, let now)),
             (.pendingApproval(let session, _), .tick(let sessionID, let now)):
            try validate(sessionID: sessionID, matches: session)
            guard now >= session.issuedAt else {
                throw AuthTransitionError.timestampOutsideSession
            }
            next = now >= session.expiresAt ? .expired : state

        case (.idle, .restoreRequested(let sessionID, let account)),
             (.loggedOut, .restoreRequested(let sessionID, let account)),
             (.failed, .restoreRequested(let sessionID, let account)):
            try validateSessionID(sessionID)
            next = .restoring(sessionID: sessionID, account: account)

        case (.invalidated(_, let currentAccount), .restoreRequested(let sessionID, let account)):
            guard currentAccount == account else { throw AuthTransitionError.accountMismatch }
            try validateSessionID(sessionID)
            next = .restoring(sessionID: sessionID, account: account)

        case (.restoring(let activeSessionID, let account), .restorationSucceeded(let sessionID, let restored)):
            try validate(sessionID: sessionID, matches: activeSessionID)
            guard account == restored.identifier else { throw AuthTransitionError.accountMismatch }
            next = .restored(sessionID: sessionID, account: restored)

        case (.restoring(let activeSessionID, let account), .restorationFailed(let sessionID, let failure)):
            try validate(sessionID: sessionID, matches: activeSessionID)
            switch failure {
            case .missingCredential:
                next = .loggedOut
            case .credentialStoreUnavailable:
                next = .failed(.credentialStoreUnavailable)
            case .invalidated:
                next = .invalidated(sessionID: sessionID, account: account)
            case .cancelled:
                next = .cancelled
            case .expired:
                next = .expired
            case .rejected(let reason):
                next = .rejected(reason)
            }

        case (.approved(let session, _), .logout(let sessionID)):
            try validate(sessionID: sessionID, matches: session)
            next = .loggedOut

        case (.restored(let activeSessionID, _), .logout(let sessionID)):
            try validate(sessionID: sessionID, matches: activeSessionID)
            next = .loggedOut

        case (.approved(let session, let account), .invalidate(let sessionID)):
            try validate(sessionID: sessionID, matches: session)
            next = .invalidated(sessionID: sessionID, account: account.identifier)

        case (.restored(let activeSessionID, let account), .invalidate(let sessionID)):
            try validate(sessionID: sessionID, matches: activeSessionID)
            next = .invalidated(sessionID: sessionID, account: account.identifier)

        default:
            throw AuthTransitionError.invalidTransition
        }

        self.state = next
        return next
    }

    private func validate(sessionID: String, matches session: RemoteAuthSession) throws {
        try validateSessionID(sessionID)
        guard sessionID == session.identifier else {
            throw AuthTransitionError.sessionMismatch
        }
    }

    private func validate(sessionID: String, matches activeSessionID: String) throws {
        try validateSessionID(sessionID)
        guard sessionID == activeSessionID else {
            throw AuthTransitionError.sessionMismatch
        }
    }

    private func validateSessionID(_ sessionID: String) throws {
        guard !sessionID.isEmpty else { throw AuthTransitionError.sessionMismatch }
    }

    /// The active interval is half-open: issuedAt is valid and expiresAt is
    /// the deadline. Expiry itself is represented by the dedicated `expired`
    /// event or by a local clock `tick`.
    private func validateActiveTimestamp(_ timestamp: Int64, in session: RemoteAuthSession) throws {
        guard timestamp >= session.issuedAt else {
            throw AuthTransitionError.timestampOutsideSession
        }
        guard timestamp < session.expiresAt else {
            throw AuthTransitionError.expiredSession
        }
    }
}
