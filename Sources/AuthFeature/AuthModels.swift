import Foundation

/// An account identifier is intentionally separate from any credential or
/// remote-auth payload. It is safe to use as a Keychain/database lookup key,
/// but it is not itself a login secret.
public struct AccountIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String { "account(redacted)" }
}

/// A server-issued reference only. QR contents, session secrets, and public
/// keys deliberately do not cross this model boundary.
public struct RemoteAuthSession: Hashable, Codable, Sendable, CustomStringConvertible {
    public let identifier: String
    public let issuedAt: Int64
    public let expiresAt: Int64

    public init(identifier: String, issuedAt: Int64, expiresAt: Int64) throws {
        guard !identifier.isEmpty else { throw RemoteAuthSessionError.emptyIdentifier }
        guard expiresAt > issuedAt else { throw RemoteAuthSessionError.invalidLifetime }
        self.identifier = identifier
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public var description: String { "remote-auth-session(redacted)" }
}

public enum RemoteAuthSessionError: Error, Equatable, Sendable {
    case emptyIdentifier
    case invalidLifetime
}

/// Information that may be shown to a user after a QR scan. It is not an
/// authentication secret and never contains QR payload bytes.
public struct AccountApprovalHint: Hashable, Codable, Sendable, CustomStringConvertible {
    public let account: AccountIdentifier
    public let displayLabel: String

    public init(account: AccountIdentifier, displayLabel: String) {
        self.account = account
        self.displayLabel = displayLabel
    }

    public var description: String { "account-approval-hint(redacted)" }
}

public struct AuthenticatedAccount: Hashable, Codable, Sendable, CustomStringConvertible {
    public let identifier: AccountIdentifier
    public let displayLabel: String

    public init(identifier: AccountIdentifier, displayLabel: String) {
        self.identifier = identifier
        self.displayLabel = displayLabel
    }

    public var description: String { "authenticated-account(redacted)" }
}

public enum AuthRejectionReason: Equatable, Sendable {
    case userDeclined
    case mfaRequired
    case captchaRequired
    case protocolUnavailable
    case invalidResponse
    case unknown
}

public enum AuthFailure: Equatable, Sendable {
    case missingCredential
    case credentialStoreUnavailable
    case invalidated
    case cancelled
    case expired
    case rejected(AuthRejectionReason)
}

public enum RemoteAuthState: Equatable, Sendable, CustomStringConvertible {
    case idle
    case awaitingQRCode(RemoteAuthSession)
    case pendingApproval(session: RemoteAuthSession, hint: AccountApprovalHint?)
    case approved(session: RemoteAuthSession, account: AuthenticatedAccount)
    case restoring(sessionID: String, account: AccountIdentifier)
    case restored(sessionID: String, account: AuthenticatedAccount)
    case cancelled
    case expired
    case rejected(AuthRejectionReason)
    case failed(AuthFailure)
    case invalidated(sessionID: String, account: AccountIdentifier)
    case loggedOut

    /// State descriptions never include identifiers, account labels, or
    /// protocol material. This makes accidental diagnostic logging safer.
    public var description: String {
        switch self {
        case .idle: return "idle"
        case .awaitingQRCode: return "awaiting-qr-code"
        case .pendingApproval: return "pending-approval"
        case .approved: return "approved"
        case .restoring: return "restoring"
        case .restored: return "restored"
        case .cancelled: return "cancelled"
        case .expired: return "expired"
        case .rejected: return "rejected"
        case .failed: return "failed"
        case .invalidated: return "invalidated"
        case .loggedOut: return "logged-out"
        }
    }
}

public enum AuthEvent: Equatable, Sendable {
    case begin(RemoteAuthSession)
    case qrScanned(sessionID: String, at: Int64, hint: AccountApprovalHint?)
    case approvalGranted(sessionID: String, at: Int64, account: AuthenticatedAccount)
    case approvalRejected(sessionID: String, at: Int64, reason: AuthRejectionReason)
    case cancelled(sessionID: String)
    case expired(sessionID: String, at: Int64)
    case tick(sessionID: String, now: Int64)
    case restoreRequested(sessionID: String, account: AccountIdentifier)
    case restorationSucceeded(sessionID: String, account: AuthenticatedAccount)
    case restorationFailed(sessionID: String, failure: AuthFailure)
    case logout(sessionID: String)
    case invalidate(sessionID: String)
}

/// Category-only errors. In particular, errors never retain or stringify an
/// event, session identifier, account identifier, or account label.
public enum AuthTransitionError: Error, Equatable, Sendable {
    case invalidTransition
    case expiredSession
    case timestampOutsideSession
    case sessionMismatch
    case accountMismatch
    case staleOperation
}

public enum AuthCoordinatorError: Error, Equatable, Sendable {
    case credentialStoreUnavailable
}
