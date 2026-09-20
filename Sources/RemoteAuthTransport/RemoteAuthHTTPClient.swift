import Foundation

public struct RemoteAuthHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol RemoteAuthHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> RemoteAuthHTTPResponse
}

/// URLSession adapter with an ephemeral, no-cookie/no-credential session.
/// URLSession may materialize a redirect before its delegate callback runs;
/// the delegate rejects every redirect, and the request is independently
/// validated before URLSession receives it. The endpoint is not configurable.
public final class URLSessionRemoteAuthHTTPTransport: RemoteAuthHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: RemoteAuthRedirectDelegate(), delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> RemoteAuthHTTPResponse {
        guard RemoteAuthLoginExchange.isExactEndpoint(request.url),
              request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization") == nil else {
            throw RemoteAuthHTTPError.invalidEndpoint
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw RemoteAuthHTTPError.invalidResponse
        }
        guard data.count <= RemoteAuthLoginExchange.maximumResponseBytes else {
            throw RemoteAuthHTTPError.responseTooLarge
        }
        return RemoteAuthHTTPResponse(statusCode: response.statusCode, data: data)
    }
}

enum RemoteAuthRedirectPolicy {
    static func shouldFollow(_ request: URLRequest) -> Bool { false }
}

private final class RemoteAuthRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never follow a redirect before a ticket-bearing request can be
        // replayed. This remains false even for an apparently equivalent URL.
        completionHandler(RemoteAuthRedirectPolicy.shouldFollow(request) ? request : nil)
    }
}

public enum RemoteAuthHTTPError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidRequest
    case transportFailure
    case invalidResponse
    case unexpectedStatus(Int)
    case malformedResponse
    case ticketTooLarge
    case responseTooLarge
}

/// Internal capability gate: phase-1 app code cannot instantiate the login
/// exchange. A later security-reviewed integration may issue this capability
/// from the authentication coordinator without making it a general API.
public struct RemoteAuthLoginExchangeCapability: Sendable {
    init() {}
}

/// This exchange carries a server-issued remote-auth ticket only. It has no
/// token parameter, no Authorization header, and no API for serializing or
/// logging a decrypted credential. Decryption/persistence belong to a future
/// security-reviewed adapter.
public actor RemoteAuthLoginExchange {
    public static let endpoint = URL(string: "https://discord.com/api/v9/users/@me/remote-auth/login")!
    public static let maximumTicketBytes = 4 * 1024
    public static let maximumResponseBytes = 64 * 1024

    private let transport: any RemoteAuthHTTPTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(capability: RemoteAuthLoginExchangeCapability, transport: any RemoteAuthHTTPTransport) {
        self.transport = transport
    }

    public func exchange(ticket: String) async throws -> RemoteAuthEncryptedLoginResponse {
        guard !ticket.isEmpty, ticket.utf8.count <= Self.maximumTicketBytes, Self.isExactEndpoint(Self.endpoint) else {
            if ticket.utf8.count > Self.maximumTicketBytes { throw RemoteAuthHTTPError.ticketTooLarge }
            throw RemoteAuthHTTPError.invalidRequest
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Deliberately no Authorization header. The ticket is in the JSON body.
        let body = RemoteAuthLoginRequest(ticket: ticket)
        request.httpBody = try encoder.encode(body)

        let response: RemoteAuthHTTPResponse
        do {
            response = try await transport.data(for: request)
        } catch let error as RemoteAuthHTTPError {
            throw error
        } catch {
            throw RemoteAuthHTTPError.transportFailure
        }
        guard response.data.count <= Self.maximumResponseBytes else {
            throw RemoteAuthHTTPError.responseTooLarge
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteAuthHTTPError.unexpectedStatus(response.statusCode)
        }

        do {
            let wire = try decoder.decode(RemoteAuthEncryptedLoginResponse.Wire.self, from: response.data)
            guard let encryptedToken = wire.encryptedToken, !encryptedToken.isEmpty else {
                throw RemoteAuthHTTPError.malformedResponse
            }
            return RemoteAuthEncryptedLoginResponse(encryptedToken: encryptedToken)
        } catch let error as RemoteAuthHTTPError {
            throw error
        } catch {
            throw RemoteAuthHTTPError.malformedResponse
        }
    }

    public static func isExactEndpoint(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == "discord.com",
              components.port == nil,
              components.path == "/api/v9/users/@me/remote-auth/login",
              components.queryItems == nil,
              components.fragment == nil else { return false }
        return true
    }
}

public struct RemoteAuthEncryptedLoginResponse: Sendable, Equatable, CustomStringConvertible {
    public let encryptedToken: String

    fileprivate init(encryptedToken: String) {
        self.encryptedToken = encryptedToken
    }

    public var description: String { "remote-auth-encrypted-login-response(redacted)" }

    fileprivate struct Wire: Decodable {
        let encryptedToken: String?

        enum CodingKeys: String, CodingKey {
            case encryptedToken = "encrypted_token"
        }
    }
}

private struct RemoteAuthLoginRequest: Encodable {
    let ticket: String
}
