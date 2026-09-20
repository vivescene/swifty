import Foundation
import Security
import XCTest
@testable import AuthFeature

final class KeychainCredentialStoreTests: XCTestCase {
    private let account = AccountIdentifier("account-one")
    private let secondAccount = AccountIdentifier("account-two")
    private let secret = Data("fixture-secret-never-logged".utf8)

    func testSaveAddsWhenItemIsMissingAndLoadReturnsOpaqueMaterial() async throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)

        try await store.save(CredentialMaterial(secret: secret), for: account)

        XCTAssertEqual(client.updateCalls.count, 1)
        XCTAssertEqual(client.addCalls.count, 1)
        let loaded = try await store.load(for: account)
        XCTAssertEqual(loaded, CredentialMaterial(secret: secret))
        XCTAssertEqual(client.lastService, KeychainCredentialStore.service)
        assertAllQueriesAreDeviceOnlyAndAccountScoped(client)
    }

    func testSaveUpdatesExistingItem() async throws {
        let client = FakeKeychainClient()
        client.values[account.value] = Data("old-secret".utf8)
        let store = KeychainCredentialStore(client: client)
        let replacement = Data("replacement-secret".utf8)

        try await store.save(CredentialMaterial(secret: replacement), for: account)

        XCTAssertEqual(client.updateCalls.count, 1)
        XCTAssertEqual(client.addCalls.count, 0)
        let loaded = try await store.load(for: account)
        XCTAssertEqual(loaded, CredentialMaterial(secret: replacement))
        assertAllQueriesAreDeviceOnlyAndAccountScoped(client)
    }

    func testMissingLoadReturnsNil() async throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)
        let loaded = try await store.load(for: account)
        XCTAssertNil(loaded)
        XCTAssertEqual(client.queries.last?.synchronizable, false)
    }

    func testRemoveDeletesOnlyTheRequestedAccount() async throws {
        let client = FakeKeychainClient()
        client.values[account.value] = secret
        client.values[secondAccount.value] = Data("second-secret".utf8)
        let store = KeychainCredentialStore(client: client)

        try await store.remove(for: account)

        let removedAccountCredential = try await store.load(for: account)
        let remainingAccountCredential = try await store.load(for: secondAccount)
        XCTAssertNil(removedAccountCredential)
        XCTAssertEqual(
            remainingAccountCredential,
            CredentialMaterial(secret: Data("second-secret".utf8))
        )
        XCTAssertEqual(client.removeCalls, [account.value])
        assertAllQueriesAreDeviceOnlyAndAccountScoped(client)
    }

    func testKeychainFailureIsCategorizedAndRedacted() async throws {
        let client = FakeKeychainClient()
        client.updateStatus = -50
        let store = KeychainCredentialStore(client: client)

        do {
            try await store.save(CredentialMaterial(secret: secret), for: account)
            XCTFail("save unexpectedly succeeded")
        } catch let error as KeychainCredentialStoreError {
            XCTAssertEqual(error, .operationFailed(.update, status: -50))
            XCTAssertFalse(String(describing: error).contains("fixture-secret-never-logged"))
            XCTAssertFalse(String(describing: error).contains(account.value))
        }
    }

    func testEmptyAccountIsRejectedWithoutCallingKeychain() async throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)

        do {
            try await store.save(CredentialMaterial(secret: secret), for: AccountIdentifier(""))
            XCTFail("empty account unexpectedly succeeded")
        } catch let error as KeychainCredentialStoreError {
            XCTAssertEqual(error, .invalidAccount)
            XCTAssertEqual(client.updateCalls.count, 0)
            XCTAssertFalse(String(describing: error).contains(secret.description))
        }
    }

    private func assertAllQueriesAreDeviceOnlyAndAccountScoped(_ client: FakeKeychainClient) {
        XCTAssertFalse(client.queries.isEmpty)
        for query in client.queries {
            XCTAssertEqual(query.service, KeychainCredentialStore.service)
            XCTAssertFalse(query.synchronizable)
            XCTAssertFalse(query.account.isEmpty)
            XCTAssertTrue([account.value, secondAccount.value].contains(query.account))
        }
    }
}

private final class FakeKeychainClient: KeychainClient, @unchecked Sendable {
    var values: [String: Data] = [:]
    var updateStatus: Int32 = errSecSuccess
    var addStatus: Int32 = errSecSuccess
    var loadStatus: Int32?
    var removeStatus: Int32 = errSecSuccess
    var updateCalls: [(service: String, account: String, secret: Data)] = []
    var addCalls: [(service: String, account: String, secret: Data)] = []
    var removeCalls: [String] = []
    var lastService: String?
    var queries: [KeychainItemQuery] = []

    func add(_ query: KeychainItemQuery, secret: Data) -> Int32 {
        queries.append(query)
        lastService = query.service
        addCalls.append((query.service, query.account, secret))
        guard addStatus == errSecSuccess else { return addStatus }
        guard values[query.account] == nil else { return errSecDuplicateItem }
        values[query.account] = secret
        return errSecSuccess
    }

    func update(_ query: KeychainItemQuery, secret: Data) -> Int32 {
        queries.append(query)
        lastService = query.service
        updateCalls.append((query.service, query.account, secret))
        if updateStatus != errSecSuccess { return updateStatus }
        guard values[query.account] != nil else { return errSecItemNotFound }
        values[query.account] = secret
        return errSecSuccess
    }

    func load(_ query: KeychainItemQuery) -> (status: Int32, data: Data?) {
        queries.append(query)
        lastService = query.service
        if let loadStatus { return (loadStatus, nil) }
        guard let value = values[query.account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, value)
    }

    func remove(_ query: KeychainItemQuery) -> Int32 {
        queries.append(query)
        lastService = query.service
        removeCalls.append(query.account)
        guard removeStatus == errSecSuccess else { return removeStatus }
        guard values.removeValue(forKey: query.account) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}
