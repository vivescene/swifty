import Foundation

/// Coordinates the state machine with credential lifecycle without knowing any
/// Discord endpoint or authentication protocol details.
public actor AuthCoordinator {
    private let credentialStore: any CredentialStore
    private var machine: AuthStateMachine
    private var operationGeneration: UInt64 = 0

    public init(credentialStore: any CredentialStore, initialState: RemoteAuthState = .idle) {
        self.credentialStore = credentialStore
        self.machine = AuthStateMachine(initialState: initialState)
    }

    public var state: RemoteAuthState { machine.state }

    @discardableResult
    public func apply(_ event: AuthEvent) async throws -> RemoteAuthState {
        let generation = beginOperation()
        let previousState = machine.state
        var candidate = machine
        let next = try candidate.apply(event)
        let accountToRemove = accountForCredentialRemoval(for: event, in: previousState)

        guard let accountToRemove else {
            machine = candidate
            return next
        }

        do {
            try await credentialStore.remove(for: accountToRemove)
        } catch {
            try revalidate(
                generation: generation,
                expectedState: previousState,
                account: accountToRemove
            )
            throw AuthCoordinatorError.credentialStoreUnavailable
        }

        // The actor may have re-entered while the store was suspended. Do not
        // commit a transition or report cleanup success for a stale operation.
        try revalidate(
            generation: generation,
            expectedState: previousState,
            account: accountToRemove
        )
        machine = candidate
        return next
    }

    /// Restores only when a credential exists in the injected store. The
    /// credential itself remains opaque and never enters the state machine.
    @discardableResult
    public func restore(
        _ account: AuthenticatedAccount,
        sessionID: String
    ) async throws -> RemoteAuthState {
        let generation = beginOperation()
        var restoringMachine = machine
        _ = try restoringMachine.apply(
            .restoreRequested(sessionID: sessionID, account: account.identifier)
        )
        machine = restoringMachine
        let restoringState = restoringMachine.state

        do {
            let credential = try await credentialStore.load(for: account.identifier)

            try revalidate(
                generation: generation,
                expectedState: restoringState,
                account: account.identifier
            )

            var completedMachine = machine
            let event: AuthEvent
            if credential == nil {
                event = .restorationFailed(
                    sessionID: sessionID,
                    failure: .missingCredential
                )
            } else {
                event = .restorationSucceeded(sessionID: sessionID, account: account)
            }
            let next = try completedMachine.apply(event)
            machine = completedMachine
            return next
        } catch let transitionError as AuthTransitionError {
            throw transitionError
        } catch {
            // Store details are intentionally not surfaced. Re-check before
            // converting the failure because another operation may have won.
            try revalidate(
                generation: generation,
                expectedState: restoringState,
                account: account.identifier
            )
            var failedMachine = machine
            let next = try failedMachine.apply(
                .restorationFailed(
                    sessionID: sessionID,
                    failure: .credentialStoreUnavailable
                )
            )
            machine = failedMachine
            return next
        }
    }

    private func beginOperation() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }

    private func revalidate(
        generation: UInt64,
        expectedState: RemoteAuthState,
        account: AccountIdentifier
    ) throws {
        guard operationGeneration == generation else {
            throw AuthTransitionError.staleOperation
        }
        guard machine.state == expectedState else {
            throw AuthTransitionError.staleOperation
        }
        guard accountForCurrentState(machine.state) == account else {
            throw AuthTransitionError.staleOperation
        }
    }

    private func accountForCredentialRemoval(
        for event: AuthEvent,
        in state: RemoteAuthState
    ) -> AccountIdentifier? {
        switch event {
        case .logout, .invalidate:
            return accountForCurrentState(state)
        case .restorationFailed(_, .invalidated):
            guard case .restoring(_, let account) = state else { return nil }
            return account
        default:
            return nil
        }
    }

    private func accountForCurrentState(_ state: RemoteAuthState) -> AccountIdentifier? {
        switch state {
        case .approved(_, let account), .restored(_, let account):
            return account.identifier
        case .restoring(_, let account), .invalidated(_, let account):
            return account
        default:
            return nil
        }
    }
}
