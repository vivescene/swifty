import Foundation
import XCTest
@testable import AuthFeature

final class CredentialStoreTests: XCTestCase {
    func testCredentialMaterialIsRedactedWhenDescribed() {
        let secret = Data("fixture-only-secret".utf8)
        let material = CredentialMaterial(secret: secret)

        XCTAssertEqual(material.description, "credential(redacted)")
        XCTAssertEqual(material.debugDescription, "CredentialMaterial(redacted)")
        XCTAssertFalse(material.description.contains("fixture-only-secret"))

        var observedByteCount = 0
        material.withSecretData { observedByteCount = $0.count }
        XCTAssertEqual(observedByteCount, secret.count)
    }

    func testCoordinatorRestoresOnlyWithStoredCredentialAndRemovesOnLogout() async throws {
        let store = InMemoryCredentialStore()
        let account = AccountIdentifier("account-1")
        let authenticated = AuthenticatedAccount(identifier: account, displayLabel: "fixture")
        let material = CredentialMaterial(secret: Data([1, 2, 3]))
        try await store.save(material, for: account)
        let coordinator = AuthCoordinator(credentialStore: store)

        let restored = try await coordinator.restore(authenticated, sessionID: "restore-session-1")
        XCTAssertEqual(
            restored,
            .restored(sessionID: "restore-session-1", account: authenticated)
        )
        let stateAfterRestore = await coordinator.state
        XCTAssertEqual(
            stateAfterRestore,
            .restored(sessionID: "restore-session-1", account: authenticated)
        )
        let loggedOut = try await coordinator.apply(.logout(sessionID: "restore-session-1"))
        XCTAssertEqual(loggedOut, .loggedOut)
        let credentialAfterLogout = try await store.load(for: account)
        XCTAssertNil(credentialAfterLogout)
    }

    func testMissingCredentialRestoresToLoggedOut() async throws {
        let account = AccountIdentifier("account-1")
        let authenticated = AuthenticatedAccount(identifier: account, displayLabel: "fixture")
        let coordinator = AuthCoordinator(credentialStore: InMemoryCredentialStore())

        let restored = try await coordinator.restore(authenticated, sessionID: "restore-session-1")
        XCTAssertEqual(restored, .loggedOut)
        let stateAfterRestore = await coordinator.state
        XCTAssertEqual(stateAfterRestore, .loggedOut)
    }

    func testInvalidationRemovesCredential() async throws {
        let store = InMemoryCredentialStore()
        let account = AccountIdentifier("account-1")
        let authenticated = AuthenticatedAccount(identifier: account, displayLabel: "fixture")
        try await store.save(CredentialMaterial(secret: Data([9])), for: account)
        let coordinator = AuthCoordinator(credentialStore: store)

        let restored = try await coordinator.restore(authenticated, sessionID: "restore-session-1")
        XCTAssertEqual(restored, .restored(sessionID: "restore-session-1", account: authenticated))
        let invalidated = try await coordinator.apply(.invalidate(sessionID: "restore-session-1"))
        XCTAssertEqual(
            invalidated,
            .invalidated(sessionID: "restore-session-1", account: account)
        )
        let credentialAfterInvalidation = try await store.load(for: account)
        XCTAssertNil(credentialAfterInvalidation)
    }

    func testRestorationInvalidationRemovesCredentialForRestoringAccount() async throws {
        let store = InMemoryCredentialStore()
        let account = AccountIdentifier("account-1")
        try await store.save(CredentialMaterial(secret: Data([7, 8])), for: account)
        let coordinator = AuthCoordinator(
            credentialStore: store,
            initialState: .restoring(sessionID: "restore-session-1", account: account)
        )

        let invalidated = try await coordinator.apply(
            .restorationFailed(sessionID: "restore-session-1", failure: .invalidated)
        )
        XCTAssertEqual(
            invalidated,
            .invalidated(sessionID: "restore-session-1", account: account)
        )
        let credentialAfterInvalidation = try await store.load(for: account)
        XCTAssertNil(credentialAfterInvalidation)
    }

    func testCredentialStoreFailureDoesNotLeaveCoordinatorRestoring() async throws {
        let account = AccountIdentifier("account-1")
        let authenticated = AuthenticatedAccount(identifier: account, displayLabel: "fixture")
        let coordinator = AuthCoordinator(credentialStore: FailingCredentialStore())

        let restored = try await coordinator.restore(authenticated, sessionID: "restore-session-1")
        XCTAssertEqual(restored, .failed(.credentialStoreUnavailable))
        let stateAfterFailure = await coordinator.state
        XCTAssertEqual(stateAfterFailure, .failed(.credentialStoreUnavailable))
    }

    func testStaleRestoreCannotCompleteAfterACompetingInvalidation() async throws {
        let account = AccountIdentifier("account-1")
        let authenticated = AuthenticatedAccount(identifier: account, displayLabel: "fixture")
        let material = CredentialMaterial(secret: Data([4, 5, 6]))
        let store = SuspendingCredentialStore(credential: material, suspendLoad: true)
        let coordinator = AuthCoordinator(credentialStore: store)
        let restoreTask = Task<RemoteAuthState, Error> {
            try await coordinator.restore(authenticated, sessionID: "restore-session-1")
        }

        await store.waitUntilLoadReady()
        let invalidated = try await coordinator.apply(
            .restorationFailed(sessionID: "restore-session-1", failure: .invalidated)
        )
        XCTAssertEqual(
            invalidated,
            .invalidated(sessionID: "restore-session-1", account: account)
        )
        await store.releaseLoad()

        do {
            _ = try await restoreTask.value
            XCTFail("stale restore unexpectedly completed")
        } catch let error as AuthTransitionError {
            XCTAssertEqual(error, .staleOperation)
            XCTAssertFalse(String(describing: error).contains("restore-session-1"))
            XCTAssertFalse(String(describing: error).contains("account-1"))
        }
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .invalidated(sessionID: "restore-session-1", account: account))
        let credentialAfterInvalidation = try await store.load(for: account)
        XCTAssertNil(credentialAfterInvalidation)
    }

    func testStaleCleanupCannotCommitAfterAnotherOperationStarts() async throws {
        let account = AccountIdentifier("account-1")
        let material = CredentialMaterial(secret: Data([3]))
        let store = SuspendingCredentialStore(credential: material, suspendRemove: true)
        let coordinator = AuthCoordinator(
            credentialStore: store,
            initialState: .restored(sessionID: "session-1", account: AuthenticatedAccount(
                identifier: account,
                displayLabel: "fixture"
            ))
        )
        let logoutTask = Task<RemoteAuthState, Error> {
            try await coordinator.apply(.logout(sessionID: "session-1"))
        }

        await store.waitUntilRemoveReady()
        do {
            _ = try await coordinator.apply(.logout(sessionID: "wrong-session"))
            XCTFail("invalid logout unexpectedly completed")
        } catch let error as AuthTransitionError {
            XCTAssertEqual(error, .sessionMismatch)
        }
        await store.releaseRemove()

        do {
            _ = try await logoutTask.value
            XCTFail("stale cleanup unexpectedly completed")
        } catch let error as AuthTransitionError {
            XCTAssertEqual(error, .staleOperation)
        }
        let finalState = await coordinator.state
        XCTAssertEqual(
            finalState,
            .restored(sessionID: "session-1", account: AuthenticatedAccount(
                identifier: account,
                displayLabel: "fixture"
            ))
        )
    }
}

private enum FixtureStoreError: Error, Sendable {
    case unavailable
}

private actor FailingCredentialStore: CredentialStore {
    func load(for account: AccountIdentifier) async throws -> CredentialMaterial? {
        throw FixtureStoreError.unavailable
    }

    func save(_ credential: CredentialMaterial, for account: AccountIdentifier) async throws {
        throw FixtureStoreError.unavailable
    }

    func remove(for account: AccountIdentifier) async throws {
        throw FixtureStoreError.unavailable
    }
}

private actor SuspendingCredentialStore: CredentialStore {
    private var credential: CredentialMaterial?
    private let suspendLoad: Bool
    private let suspendRemove: Bool
    private var loadContinuation: CheckedContinuation<CredentialMaterial?, Error>?
    private var loadReadyWaiter: CheckedContinuation<Void, Never>?
    private var removeContinuation: CheckedContinuation<Void, Error>?
    private var removeReadyWaiter: CheckedContinuation<Void, Never>?

    init(
        credential: CredentialMaterial?,
        suspendLoad: Bool = false,
        suspendRemove: Bool = false
    ) {
        self.credential = credential
        self.suspendLoad = suspendLoad
        self.suspendRemove = suspendRemove
    }

    func load(for account: AccountIdentifier) async throws -> CredentialMaterial? {
        let value = credential
        guard suspendLoad else { return value }
        return try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            loadReadyWaiter?.resume()
            loadReadyWaiter = nil
        }
    }

    func save(_ credential: CredentialMaterial, for account: AccountIdentifier) async throws {
        self.credential = credential
    }

    func remove(for account: AccountIdentifier) async throws {
        guard suspendRemove else {
            credential = nil
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            removeContinuation = continuation
            removeReadyWaiter?.resume()
            removeReadyWaiter = nil
        }
        credential = nil
    }

    func waitUntilLoadReady() async {
        guard loadContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            loadReadyWaiter = continuation
        }
    }

    func releaseLoad() {
        guard let continuation = loadContinuation else {
            preconditionFailure("load is not suspended")
        }
        loadContinuation = nil
        continuation.resume(returning: credential)
    }

    func waitUntilRemoveReady() async {
        guard removeContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            removeReadyWaiter = continuation
        }
    }

    func releaseRemove() {
        guard let continuation = removeContinuation else {
            preconditionFailure("remove is not suspended")
        }
        removeContinuation = nil
        continuation.resume()
    }
}
