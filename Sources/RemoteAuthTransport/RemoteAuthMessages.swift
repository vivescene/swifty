import Foundation

/// The desktop remote-auth protocol is unofficial and may add fields without
/// notice.  Keep the wire envelope open-ended so an unfamiliar field or
/// operation does not become a credential leak or crash the auth session.
public enum RemoteAuthOperation: Hashable, Sendable, Codable, CustomStringConvertible {
    case hello
    case heartbeat
    case heartbeatAck
    case initSession
    case nonceProof
    case pendingRemoteInit
    case pendingTicket
    case pendingLogin
    case cancel
    case timeout
    case close
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "hello": self = .hello
        case "heartbeat": self = .heartbeat
        case "heartbeat_ack": self = .heartbeatAck
        case "init": self = .initSession
        case "nonce_proof": self = .nonceProof
        case "pending_remote_init": self = .pendingRemoteInit
        case "pending_ticket": self = .pendingTicket
        case "pending_login": self = .pendingLogin
        case "cancel": self = .cancel
        case "timeout": self = .timeout
        case "close": self = .close
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .hello: return "hello"
        case .heartbeat: return "heartbeat"
        case .heartbeatAck: return "heartbeat_ack"
        case .initSession: return "init"
        case .nonceProof: return "nonce_proof"
        case .pendingRemoteInit: return "pending_remote_init"
        case .pendingTicket: return "pending_ticket"
        case .pendingLogin: return "pending_login"
        case .cancel: return "cancel"
        case .timeout: return "timeout"
        case .close: return "close"
        case .unknown(let value): return value
        }
    }

    public var description: String {
        // Never include the raw value for unknown operations: a future server
        // field could accidentally contain sensitive material.
        switch self {
        case .unknown: return "unknown"
        default: return rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A deliberately small JSON value used only for protocol fields.  It keeps
/// unknown fields available for diagnostics/tests while CustomStringConvertible
/// never prints their contents.
public indirect enum RemoteAuthJSONValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: RemoteAuthJSONValue])
    case array([RemoteAuthJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: RemoteAuthJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([RemoteAuthJSONValue].self) {
            self = .array(value)
        } else {
            throw RemoteAuthMessageError.invalidJSONValue
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value): try value.encode(to: encoder)
        case .number(let value): try value.encode(to: encoder)
        case .bool(let value): try value.encode(to: encoder)
        case .object(let value): try value.encode(to: encoder)
        case .array(let value): try value.encode(to: encoder)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    fileprivate var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    fileprivate var integerValue: Int? {
        guard case .number(let value) = self,
              value.isFinite,
              value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    public var description: String { "remote-auth-json-value(redacted)" }

    fileprivate func isWithinBounds(maximumFieldBytes: Int, depth: Int = 0) -> Bool {
        guard depth <= 8 else { return false }
        switch self {
        case .string(let value):
            return value.utf8.count <= maximumFieldBytes
        case .object(let values):
            return values.count <= 64 && values.allSatisfy {
                $0.key.utf8.count <= 256 && $0.value.isWithinBounds(maximumFieldBytes: maximumFieldBytes, depth: depth + 1)
            }
        case .array(let values):
            return values.count <= 256 && values.allSatisfy {
                $0.isWithinBounds(maximumFieldBytes: maximumFieldBytes, depth: depth + 1)
            }
        case .number, .bool, .null:
            return true
        }
    }
}

/// Top-level remote-auth frame. The protocol places operation-specific keys
/// beside `op`, rather than under a single data object.
public struct RemoteAuthEnvelope: Codable, Hashable, Sendable, CustomStringConvertible {
    public static let maximumFieldBytes = 64 * 1024
    public let operation: RemoteAuthOperation
    public let fields: [String: RemoteAuthJSONValue]

    public init(operation: RemoteAuthOperation, fields: [String: RemoteAuthJSONValue] = [:]) {
        self.operation = operation
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard let operation = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("op")) else {
            throw RemoteAuthMessageError.missingOperation
        }
        self.operation = RemoteAuthOperation(rawValue: operation)
        var fields = [String: RemoteAuthJSONValue]()
        for key in container.allKeys where key.stringValue != "op" {
            if let value = try? container.decode(RemoteAuthJSONValue.self, forKey: key) {
                fields[key.stringValue] = value
            }
        }
        guard fields.count <= 64,
              fields.allSatisfy({ key, value in
                  key.utf8.count <= 256 && value.isWithinBounds(maximumFieldBytes: Self.maximumFieldBytes)
              }) else {
            throw RemoteAuthMessageError.fieldTooLarge
        }
        self.fields = fields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(operation.rawValue, forKey: DynamicCodingKey("op"))
        for (key, value) in fields {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }

    public func string(_ key: String) -> String? { fields[key]?.stringValue }
    public func integer(_ key: String) -> Int? { fields[key]?.integerValue }

    public var description: String { "remote-auth-envelope(redacted)" }

    public func data(maximumBytes: Int = 1_048_576) throws -> Data {
        guard fields.count <= 64,
              fields.allSatisfy({ key, value in
                  key.utf8.count <= 256 && value.isWithinBounds(maximumFieldBytes: Self.maximumFieldBytes)
              }) else {
            throw RemoteAuthMessageError.fieldTooLarge
        }
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        guard data.count <= maximumBytes else { throw RemoteAuthMessageError.messageTooLarge }
        return data
    }
}

public struct RemoteAuthHello: Hashable, Sendable, CustomStringConvertible {
    public let timeoutMilliseconds: Int
    public let heartbeatIntervalMilliseconds: Int

    public init(envelope: RemoteAuthEnvelope) throws {
        guard envelope.operation == .hello,
              let timeout = envelope.integer("timeout_ms"), timeout > 0,
              let interval = envelope.integer("heartbeat_interval"), interval > 0 else {
            throw RemoteAuthMessageError.invalidHello
        }
        timeoutMilliseconds = timeout
        heartbeatIntervalMilliseconds = interval
    }

    public var description: String { "remote-auth-hello(redacted)" }
}

public struct RemoteAuthInitPayload: Hashable, Sendable, CustomStringConvertible {
    public let encodedPublicKey: String
    public let fingerprint: String?

    public init(encodedPublicKey: String, fingerprint: String? = nil) throws {
        guard let der = RemoteAuthWireValidation.canonicalStandardBase64(encodedPublicKey),
              RemoteAuthWireValidation.isRSA2048SubjectPublicKeyInfo(der) else {
            throw RemoteAuthMessageError.invalidPublicKey
        }
        if let fingerprint, RemoteAuthWireValidation.canonicalFingerprint(fingerprint) == nil {
            throw RemoteAuthMessageError.invalidFingerprint
        }
        self.encodedPublicKey = encodedPublicKey
        self.fingerprint = fingerprint
    }

    var fields: [String: RemoteAuthJSONValue] {
        // `fingerprint` is local verification metadata; the desktop Init
        // command contains only the encoded public key.
        return ["encoded_public_key": .string(encodedPublicKey)]
    }

    public var description: String { "remote-auth-init(redacted)" }
}

public struct RemoteAuthNonceProof: Hashable, Sendable, CustomStringConvertible {
    public let nonce: String

    public init(nonce: String) throws {
        guard RemoteAuthWireValidation.canonicalUnpaddedBase64URL(nonce) != nil else {
            throw RemoteAuthMessageError.invalidNonce
        }
        self.nonce = nonce
    }

    var fields: [String: RemoteAuthJSONValue] { ["nonce": .string(nonce)] }

    public var description: String { "remote-auth-nonce-proof(redacted)" }
}

public struct RemoteAuthPendingRemoteInit: Hashable, Sendable, CustomStringConvertible {
    public let fingerprint: String
    /// Kept optional for tolerant decoding of older observed transcripts.
    /// Current desktop payloads put `encrypted_nonce` in `nonce_proof`, not
    /// in `pending_remote_init`.
    public let encryptedNonce: String?

    init(envelope: RemoteAuthEnvelope) throws {
        guard let fingerprint = envelope.string("fingerprint"),
              RemoteAuthWireValidation.canonicalFingerprint(fingerprint) != nil else {
            throw RemoteAuthMessageError.invalidPayload
        }
        self.fingerprint = fingerprint
        encryptedNonce = envelope.string("encrypted_nonce")
    }

    public var description: String { "remote-auth-pending-remote-init(redacted)" }
}

public struct RemoteAuthPendingTicket: Hashable, Sendable, CustomStringConvertible {
    public let encryptedUserPayload: String

    init(envelope: RemoteAuthEnvelope) throws {
        guard let payload = envelope.string("encrypted_user_payload"), !payload.isEmpty else {
            throw RemoteAuthMessageError.invalidPayload
        }
        encryptedUserPayload = payload
    }

    public var description: String { "remote-auth-pending-ticket(redacted)" }
}

public struct RemoteAuthNonceChallenge: Hashable, Sendable, CustomStringConvertible {
    public let encryptedNonce: String

    init(envelope: RemoteAuthEnvelope) throws {
        guard let nonce = envelope.string("encrypted_nonce"), !nonce.isEmpty else {
            throw RemoteAuthMessageError.invalidPayload
        }
        encryptedNonce = nonce
    }

    public var description: String { "remote-auth-nonce-challenge(redacted)" }
}

public struct RemoteAuthPendingLogin: Hashable, Sendable, CustomStringConvertible {
    public let ticket: String
    public let encryptedUserPayload: String?

    init(envelope: RemoteAuthEnvelope) throws {
        guard let ticket = envelope.string("ticket"), !ticket.isEmpty else {
            throw RemoteAuthMessageError.invalidPayload
        }
        self.ticket = ticket
        encryptedUserPayload = envelope.string("encrypted_user_payload")
    }

    public var description: String { "remote-auth-pending-login(redacted)" }
}

public enum RemoteAuthServerEvent: Hashable, Sendable, CustomStringConvertible {
    case hello(RemoteAuthHello)
    case heartbeat
    case heartbeatAck
    case nonceProof(RemoteAuthNonceChallenge)
    case pendingRemoteInit(RemoteAuthPendingRemoteInit)
    case pendingTicket(RemoteAuthPendingTicket)
    case pendingLogin(RemoteAuthPendingLogin)
    case cancel
    case timeout
    case close
    case unknown(RemoteAuthOperation)

    public var description: String { "remote-auth-server-event(redacted)" }

    init(envelope: RemoteAuthEnvelope) throws {
        switch envelope.operation {
        case .hello: self = .hello(try RemoteAuthHello(envelope: envelope))
        case .heartbeat: self = .heartbeat
        case .heartbeatAck: self = .heartbeatAck
        case .nonceProof: self = .nonceProof(try RemoteAuthNonceChallenge(envelope: envelope))
        case .pendingRemoteInit: self = .pendingRemoteInit(try RemoteAuthPendingRemoteInit(envelope: envelope))
        case .pendingTicket: self = .pendingTicket(try RemoteAuthPendingTicket(envelope: envelope))
        case .pendingLogin: self = .pendingLogin(try RemoteAuthPendingLogin(envelope: envelope))
        case .cancel: self = .cancel
        case .timeout: self = .timeout
        case .close: self = .close
        case .initSession, .unknown: self = .unknown(envelope.operation)
        }
    }
}

public enum RemoteAuthMessageError: Error, Equatable, Sendable {
    case invalidJSONValue
    case missingOperation
    case invalidHello
    case invalidPayload
    case emptyField
    case fieldTooLarge
    case messageTooLarge
    case invalidPublicKey
    case invalidNonce
    case invalidFingerprint
}

public enum RemoteAuthWireValidation {
    public static func canonicalStandardBase64(_ value: String, maximumBytes: Int = 64 * 1024) -> Data? {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              let data = Data(base64Encoded: value), data.base64EncodedString() == value else { return nil }
        return data
    }

    public static func canonicalUnpaddedBase64URL(_ value: String, minimumBytes: Int = 1, maximumBytes: Int = 190) -> Data? {
        guard !value.isEmpty,
              value.utf8.count <= 4 * maximumBytes / 3 + 4,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              value.count % 4 != 1 else { return nil }
        let padding = (4 - value.count % 4) % 4
        let padded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: padded), data.count >= minimumBytes, data.count <= maximumBytes else { return nil }
        let canonical = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return canonical == value ? data : nil
    }

    public static func canonicalFingerprint(_ value: String) -> Data? {
        canonicalUnpaddedBase64URL(value, minimumBytes: 32, maximumBytes: 32)
    }

    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    /// Validates canonical DER shape; Security.framework remains responsible
    /// for cryptographic operations.
    public static func isRSA2048SubjectPublicKeyInfo(_ data: Data) -> Bool {
        var reader = DERReader(data: data)
        guard let outer = reader.read(tag: 0x30), reader.isAtEnd else { return false }
        var body = DERReader(data: outer)
        guard let algorithm = body.read(tag: 0x30),
              algorithm == Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]),
              let bitString = body.read(tag: 0x03), body.isAtEnd,
              bitString.first == 0 else { return false }
        var rsa = DERReader(data: Data(bitString.dropFirst()))
        guard let rsaSequence = rsa.read(tag: 0x30), rsa.isAtEnd else { return false }
        var key = DERReader(data: rsaSequence)
        guard let modulus = key.read(tag: 0x02), let exponent = key.read(tag: 0x02), key.isAtEnd else { return false }
        guard modulus.count == 257, modulus.first == 0, modulus.dropFirst().first ?? 0 >= 0x80,
              exponent == Data([0x01, 0x00, 0x01]) else { return false }
        return true
    }

    private struct DERReader {
        let data: Data
        var offset = 0
        var isAtEnd: Bool { offset == data.count }

        mutating func read(tag: UInt8) -> Data? {
            guard offset < data.count, data[offset] == tag else { return nil }
            offset += 1
            guard let length = readLength(), offset + length <= data.count else { return nil }
            let result = Data(data[offset..<(offset + length)])
            offset += length
            return result
        }

        private mutating func readLength() -> Int? {
            guard offset < data.count else { return nil }
            let first = data[offset]; offset += 1
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 3, offset + count <= data.count, data[offset] != 0 else { return nil }
            var result = 0
            for _ in 0..<count { result = (result << 8) | Int(data[offset]); offset += 1 }
            guard result >= 0x80 else { return nil }
            return result
        }
    }
}

private struct DynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
