import CryptoKit
import Foundation
import Security

/// Errors intentionally describe only a failure category. They never retain
/// ciphertext, plaintext, keys, account identifiers, or protocol payloads.
public enum RemoteAuthCryptoError: Error, Equatable, Sendable {
    case keyGenerationFailed
    case publicKeyExportFailed
    case invalidPublicKeyEncoding
    case invalidKeyAttributes
    case unsupportedRSAAlgorithm
    case invalidCiphertextLength
    case plaintextTooLong
    case decryptionFailed
    case invalidBase64
    case invalidBase64URL
}

/// Base64 encodings used by the unofficial Discord desktop remote-auth
/// protocol reference (observed and documented here on 2026-09-20).
public enum RemoteAuthBase64 {
    private static let maximumEncodedLength = 1_048_576

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    public static func decode(_ string: String) throws -> Data {
        guard string.utf8.count <= maximumEncodedLength,
              let data = Data(base64Encoded: string),
              data.base64EncodedString() == string else {
            throw RemoteAuthCryptoError.invalidBase64
        }
        return data
    }

    /// Standard base64 with `+`/`/` replaced by `-`/`_` and trailing padding
    /// removed. This is the protocol's URL-safe, unpadded representation.
    public static func encodeURLSafeUnpadded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeURLSafeUnpadded(_ string: String) throws -> Data {
        guard string.utf8.count <= maximumEncodedLength,
              string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              string.count % 4 != 1 else {
            throw RemoteAuthCryptoError.invalidBase64URL
        }

        let paddingCount = (4 - (string.count % 4)) % 4
        let padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: paddingCount)

        guard let data = Data(base64Encoded: padded),
              encodeURLSafeUnpadded(data) == string else {
            throw RemoteAuthCryptoError.invalidBase64URL
        }
        return data
    }
}

/// The RSA public-key portion of SubjectPublicKeyInfo.
///
/// Security.framework exports an RSA public key as PKCS#1 DER. The remote-auth
/// protocol expects the standard X.509 SubjectPublicKeyInfo wrapper, so this
/// type performs that small, deterministic DER conversion without introducing
/// a general-purpose ASN.1 dependency.
enum RemoteAuthSubjectPublicKeyInfo {
    // Internal on purpose: only the generated Security.framework key path
    // should publish an SPKI. It remains @testable for deterministic DER
    // fixtures without expanding the transport's public API.
    static func encode(pkcs1PublicKey: Data) throws -> Data {
        guard isValidPKCS1RSAPublicKey(pkcs1PublicKey) else {
            throw RemoteAuthCryptoError.invalidPublicKeyEncoding
        }

        // rsaEncryption OBJECT IDENTIFIER plus the required NULL parameters.
        let algorithmIdentifier = Data([
            0x30, 0x0D,
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00
        ])
        let bitString = Data([0x03]) + derLength(1 + pkcs1PublicKey.count)
            + Data([0x00]) + pkcs1PublicKey
        let body = algorithmIdentifier + bitString
        return Data([0x30]) + derLength(body.count) + body
    }

    private static func isValidPKCS1RSAPublicKey(_ data: Data) -> Bool {
        var parser = DERParser(data: data)
        guard let sequence = parser.read(tag: 0x30), sequence.end == data.count else { return false }

        var contents = DERParser(data: sequence.content)
        guard let modulus = contents.read(tag: 0x02),
              let exponent = contents.read(tag: 0x02),
              contents.isAtEnd,
              !modulus.content.isEmpty,
              !exponent.content.isEmpty else { return false }

        // INTEGERs must be positive. A leading zero is allowed only as the
        // sign-protection byte required when the high bit is set.
        return isValidModulus(modulus.content) && isValidExponent(exponent.content)
    }

    private static func isValidModulus(_ bytes: Data) -> Bool {
        guard let first = bytes.first else { return false }
        if first == 0x00 {
            guard bytes.count > 1, let second = bytes.dropFirst().first else { return false }
            return second & 0x80 != 0 && bytes.dropFirst().contains(where: { $0 != 0 })
        }
        return first & 0x80 == 0 && bytes.contains(where: { $0 != 0 })
    }

    private static func isValidExponent(_ bytes: Data) -> Bool {
        guard let first = bytes.first else { return false }
        if first == 0x00 {
            guard bytes.count > 1, let second = bytes.dropFirst().first else { return false }
            guard second & 0x80 != 0 else { return false }
        } else if first & 0x80 != 0 {
            return false
        }
        guard bytes.count <= 8 else { return false }
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return value >= 3 && value % 2 == 1
    }

    private static func derLength(_ length: Int) -> Data {
        precondition(length >= 0)
        if length < 0x80 { return Data([UInt8(length)]) }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    private struct DERParser {
        let data: Data
        var offset: Int = 0

        var isAtEnd: Bool { offset == data.count }

        mutating func read(tag expectedTag: UInt8) -> (content: Data, end: Int)? {
            guard offset < data.count, data[offset] == expectedTag else { return nil }
            offset += 1
            guard let length = readLength(), offset + length <= data.count else { return nil }
            let contentStart = offset
            offset += length
            return (Data(data[contentStart..<offset]), offset)
        }

        mutating private func readLength() -> Int? {
            guard offset < data.count else { return nil }
            let first = data[offset]
            offset += 1
            if first < 0x80 { return Int(first) }
            let octetCount = Int(first & 0x7F)
            guard octetCount > 0, octetCount <= 4, offset + octetCount <= data.count else { return nil }
            guard data[offset] != 0 else { return nil }
            guard octetCount > 1 || data[offset] >= 0x80 else { return nil }
            var length = 0
            for _ in 0..<octetCount {
                length = (length << 8) | Int(data[offset])
                offset += 1
            }
            return length
        }
    }
}

/// An immutable, in-memory RSA key pair used by the remote-auth handshake.
///
/// The private SecKey is intentionally not exposed. The class is Sendable-safe
/// because it owns immutable key handles and offers only value-type inputs and
/// outputs; Security.framework performs the cryptographic operation atomically.
/// No key material or decrypted bytes are logged by this type.
public final class RemoteAuthKeyPair: @unchecked Sendable {
    // SecKey is a CoreFoundation reference and has no compiler-provided
    // Sendable conformance. This lock-backed wrapper makes the two operations
    // safe when one immutable key pair is shared across concurrent transport
    // tasks; callers never receive the handles themselves.
    private let lock = NSLock()
    private let privateKey: SecKey
    private let publicKey: SecKey
    private let publicKeySPKIStorage: Data

    public let publicKeyFingerprint: String

    public var publicKeySPKI: Data { publicKeySPKIStorage }

    public var publicKeyBase64: String {
        RemoteAuthBase64.encode(publicKeySPKIStorage)
    }

    public convenience init() throws {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false
        ]

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            error?.release()
            throw RemoteAuthCryptoError.keyGenerationFailed
        }
        try self.init(privateKey: privateKey, publicKey: publicKey)
    }

    /// Test-only injection point for a private key generated by an external
    /// fixture tool. It remains internal so production callers cannot provide
    /// arbitrary key handles.
    convenience init(privateKey: SecKey) throws {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw RemoteAuthCryptoError.publicKeyExportFailed
        }
        try self.init(privateKey: privateKey, publicKey: publicKey)
    }

    private init(privateKey: SecKey, publicKey: SecKey) throws {
        guard Self.isRSA2048(privateKey), Self.isRSA2048(publicKey) else {
            throw RemoteAuthCryptoError.invalidKeyAttributes
        }
        self.privateKey = privateKey
        self.publicKey = publicKey

        var exportError: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            exportError?.release()
            throw RemoteAuthCryptoError.publicKeyExportFailed
        }
        guard let spki = try? RemoteAuthSubjectPublicKeyInfo.encode(pkcs1PublicKey: pkcs1) else {
            throw RemoteAuthCryptoError.invalidPublicKeyEncoding
        }
        self.publicKeySPKIStorage = spki
        self.publicKeyFingerprint = RemoteAuthBase64.encodeURLSafeUnpadded(Data(SHA256.hash(data: spki)))
    }

    private static func isRSA2048(_ key: SecKey) -> Bool {
        guard let attributes = SecKeyCopyAttributes(key) as NSDictionary?,
              let type = attributes[kSecAttrKeyType] as? String,
              let size = attributes[kSecAttrKeySizeInBits] as? NSNumber else {
            return false
        }
        return type == (kSecAttrKeyTypeRSA as String) && size.intValue == 2048
    }

    public func decryptRSAOAEP(ciphertext: Data) throws -> Data {
        guard ciphertext.count == 256 else {
            throw RemoteAuthCryptoError.invalidCiphertextLength
        }
        guard Self.isRSA2048(privateKey),
              SecKeyIsAlgorithmSupported(privateKey, .decrypt, SecKeyAlgorithm.rsaEncryptionOAEPSHA256) else {
            throw RemoteAuthCryptoError.unsupportedRSAAlgorithm
        }

        return try withSecKeyLock {
            var error: Unmanaged<CFError>?
            guard let plaintext = SecKeyCreateDecryptedData(
                privateKey,
                SecKeyAlgorithm.rsaEncryptionOAEPSHA256,
                ciphertext as CFData,
                &error
            ) as Data? else {
                error?.release()
                throw RemoteAuthCryptoError.decryptionFailed
            }
            return plaintext
        }
    }

    /// Encrypts a value with the public half of this pair. This is useful for
    /// protocol fixture generation and keeps the private key behind the same
    /// narrow boundary as decryption.
    public func encryptRSAOAEP(plaintext: Data) throws -> Data {
        guard plaintext.count <= 190 else {
            throw RemoteAuthCryptoError.plaintextTooLong
        }
        guard Self.isRSA2048(publicKey),
              SecKeyIsAlgorithmSupported(publicKey, .encrypt, SecKeyAlgorithm.rsaEncryptionOAEPSHA256) else {
            throw RemoteAuthCryptoError.unsupportedRSAAlgorithm
        }

        return try withSecKeyLock {
            var error: Unmanaged<CFError>?
            guard let ciphertext = SecKeyCreateEncryptedData(
                publicKey,
                SecKeyAlgorithm.rsaEncryptionOAEPSHA256,
                plaintext as CFData,
                &error
            ) as Data? else {
                error?.release()
                throw RemoteAuthCryptoError.decryptionFailed
            }
            guard ciphertext.count == 256 else {
                throw RemoteAuthCryptoError.decryptionFailed
            }
            return ciphertext
        }
    }

    private func withSecKeyLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
