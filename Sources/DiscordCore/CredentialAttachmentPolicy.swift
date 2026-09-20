import Foundation

/// The result of evaluating whether a Discord credential may be attached to a
/// URL.  This policy is deliberately a pure value type: URLSession delegates
/// and redirect handling can ask it about every destination independently.
public enum CredentialAttachmentDecision: Equatable, Sendable {
    case attach
    case omit(CredentialAttachmentOmissionReason)
}

public enum CredentialAttachmentOmissionReason: Equatable, Sendable {
    case nonHTTPScheme
    case nonDefaultPort
    case missingHost
    case userInfoPresent
    case disallowedHost
    case disallowedPath
}

/// Allows credentials only on the known Discord API origins.
///
/// Host matching is exact rather than suffix-based.  In particular,
/// `discord.com.attacker.example` and `discord.com.evil` are not Discord
/// origins.  CDN, attachment, and arbitrary upload hosts are intentionally
/// excluded even when they are subdomains of Discord-owned domains.
public struct CredentialAttachmentPolicy: Equatable, Sendable {
    public static let defaultAPIHosts: Set<String> = [
        "discord.com",
        "api.discord.com"
    ]

    private let apiHosts: Set<String>

    public init(apiHosts: Set<String> = CredentialAttachmentPolicy.defaultAPIHosts) {
        // Callers may narrow the allowlist for a deployment, but cannot add a
        // host outside this compiled-in Discord API origin set.
        self.apiHosts = Set(apiHosts.map { $0.lowercased() }).intersection(Self.defaultAPIHosts)
    }

    /// Evaluates a request destination without inspecting or mutating a
    /// URLSession. Call this again for every redirect destination.
    public func evaluate(_ url: URL) -> CredentialAttachmentDecision {
        guard url.scheme?.lowercased() == "https" else {
            return .omit(.nonHTTPScheme)
        }
        guard url.port == nil || url.port == 443 else {
            return .omit(.nonDefaultPort)
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return .omit(.missingHost)
        }
        guard url.user == nil && url.password == nil else {
            return .omit(.userInfoPresent)
        }
        guard apiHosts.contains(host) else {
            return .omit(.disallowedHost)
        }

        let path = url.path
        guard path == "/api" || path.hasPrefix("/api/") else {
            return .omit(.disallowedPath)
        }
        return .attach
    }

    public func shouldAttachCredential(to url: URL) -> Bool {
        evaluate(url) == .attach
    }

    /// Redirects are not trusted transitively. The destination is evaluated
    /// from scratch, so a redirect to a CDN or upload service drops the
    /// credential while a redirect back to a valid API origin can be checked
    /// normally by the caller.
    public func evaluateRedirect(to destination: URL) -> CredentialAttachmentDecision {
        evaluate(destination)
    }
}
