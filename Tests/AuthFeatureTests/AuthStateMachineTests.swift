import XCTest
@testable import AuthFeature

final class AuthStateMachineTests: XCTestCase {
    private let account = AccountIdentifier("account-1")

    private func session() throws -> RemoteAuthSession {
        try RemoteAuthSession(identifier: "session-1", issuedAt: 100, expiresAt: 200)
    }

    private func authenticatedAccount() -> AuthenticatedAccount {
        AuthenticatedAccount(identifier: account, displayLabel: "local test account")
    }

    func testQRCodeApprovalLifecycleAndLogout() throws {
        var machine = AuthStateMachine()
        let remoteSession = try session()
        let hint = AccountApprovalHint(account: account, displayLabel: "local test account")

        let awaiting = try machine.apply(.begin(remoteSession))
        XCTAssertEqual(awaiting, .awaitingQRCode(remoteSession))
        let pending = try machine.apply(.qrScanned(sessionID: "session-1", at: 150, hint: hint))
        XCTAssertEqual(pending, .pendingApproval(session: remoteSession, hint: hint))
        let approved = try machine.apply(
            .approvalGranted(sessionID: "session-1", at: 151, account: authenticatedAccount())
        )
        XCTAssertEqual(approved, .approved(session: remoteSession, account: authenticatedAccount()))
        let loggedOut = try machine.apply(.logout(sessionID: "session-1"))
        XCTAssertEqual(loggedOut, .loggedOut)
    }

    func testExpiryIsDeterministicAndApprovalAfterExpiryCannotSucceed() throws {
        var machine = AuthStateMachine()
        let remoteSession = try session()
        let account = authenticatedAccount()

        _ = try machine.apply(.begin(remoteSession))
        _ = try machine.apply(.qrScanned(sessionID: "session-1", at: 150, hint: nil))
        let expired = try machine.apply(.expired(sessionID: "session-1", at: 200))
        XCTAssertEqual(expired, .expired)
        XCTAssertThrowsError(
            try machine.apply(.approvalGranted(sessionID: "session-1", at: 201, account: account))
        ) { error in
            XCTAssertEqual(
                error as? AuthTransitionError,
                .invalidTransition
            )
            XCTAssertFalse(String(describing: error).contains("session-1"))
            XCTAssertFalse(String(describing: error).contains("account-1"))
        }
    }

    func testCancellationRejectionAndRestart() throws {
        var machine = AuthStateMachine()
        let first = try session()
        let second = try RemoteAuthSession(identifier: "session-2", issuedAt: 300, expiresAt: 400)

        _ = try machine.apply(.begin(first))
        let cancelled = try machine.apply(.cancelled(sessionID: "session-1"))
        XCTAssertEqual(cancelled, .cancelled)
        _ = try machine.apply(.begin(second))
        _ = try machine.apply(.qrScanned(sessionID: "session-2", at: 350, hint: nil))
        let rejected = try machine.apply(
            .approvalRejected(sessionID: "session-2", at: 351, reason: .mfaRequired)
        )
        XCTAssertEqual(rejected, .rejected(.mfaRequired))
        let restarted = try machine.apply(.begin(first))
        XCTAssertEqual(restarted, .awaitingQRCode(first))
    }

    func testAccountHintMustMatchApprovedAccount() throws {
        var machine = AuthStateMachine()
        let remoteSession = try session()
        let hint = AccountApprovalHint(account: account, displayLabel: "local test account")
        let different = AuthenticatedAccount(
            identifier: AccountIdentifier("different-account"),
            displayLabel: "different account"
        )

        _ = try machine.apply(.begin(remoteSession))
        _ = try machine.apply(.qrScanned(sessionID: "session-1", at: 150, hint: hint))
        XCTAssertThrowsError(
            try machine.apply(.approvalGranted(sessionID: "session-1", at: 151, account: different))
        ) { error in
            XCTAssertEqual(error as? AuthTransitionError, .accountMismatch)
        }
        XCTAssertEqual(machine.state, .pendingApproval(session: remoteSession, hint: hint))
    }

    func testStaleSessionEventsCannotMutateNewSession() throws {
        var machine = AuthStateMachine()
        let first = try session()
        let second = try RemoteAuthSession(identifier: "session-2", issuedAt: 300, expiresAt: 400)
        let account = AuthenticatedAccount(identifier: self.account, displayLabel: "fixture")

        _ = try machine.apply(.begin(first))
        _ = try machine.apply(.cancelled(sessionID: "session-1"))
        _ = try machine.apply(.begin(second))

        XCTAssertThrowsError(
            try machine.apply(.qrScanned(sessionID: "session-1", at: 350, hint: nil))
        ) { XCTAssertEqual($0 as? AuthTransitionError, .sessionMismatch) }
        XCTAssertEqual(machine.state, .awaitingQRCode(second))

        _ = try machine.apply(.qrScanned(sessionID: "session-2", at: 350, hint: nil))
        XCTAssertThrowsError(
            try machine.apply(.approvalRejected(sessionID: "session-1", at: 351, reason: .userDeclined))
        ) { XCTAssertEqual($0 as? AuthTransitionError, .sessionMismatch) }
        XCTAssertThrowsError(
            try machine.apply(.expired(sessionID: "session-1", at: 400))
        ) { XCTAssertEqual($0 as? AuthTransitionError, .sessionMismatch) }
        XCTAssertEqual(
            machine.state,
            .pendingApproval(session: second, hint: nil)
        )

        _ = try machine.apply(.approvalGranted(sessionID: "session-2", at: 351, account: account))
        XCTAssertThrowsError(try machine.apply(.invalidate(sessionID: "session-1"))) {
            XCTAssertEqual($0 as? AuthTransitionError, .sessionMismatch)
        }
        XCTAssertEqual(machine.state, .approved(session: second, account: account))
        XCTAssertEqual(
            try machine.apply(.invalidate(sessionID: "session-2")),
            .invalidated(sessionID: "session-2", account: self.account)
        )
    }

    func testTransportTimestampsAreBoundedToSessionLifetime() throws {
        var machine = AuthStateMachine()
        let remoteSession = try session()
        _ = try machine.apply(.begin(remoteSession))

        XCTAssertThrowsError(
            try machine.apply(.qrScanned(sessionID: "session-1", at: 99, hint: nil))
        ) { XCTAssertEqual($0 as? AuthTransitionError, .timestampOutsideSession) }
        XCTAssertEqual(machine.state, .awaitingQRCode(remoteSession))

        XCTAssertThrowsError(
            try machine.apply(.qrScanned(sessionID: "session-1", at: 200, hint: nil))
        ) { XCTAssertEqual($0 as? AuthTransitionError, .expiredSession) }
        XCTAssertEqual(machine.state, .awaitingQRCode(remoteSession))

        _ = try machine.apply(.qrScanned(sessionID: "session-1", at: 150, hint: nil))
        XCTAssertThrowsError(
            try machine.apply(.approvalRejected(sessionID: "session-1", at: 201, reason: .unknown))
        ) { XCTAssertEqual($0 as? AuthTransitionError, .expiredSession) }
        XCTAssertEqual(machine.state, .pendingApproval(session: remoteSession, hint: nil))
    }
}
