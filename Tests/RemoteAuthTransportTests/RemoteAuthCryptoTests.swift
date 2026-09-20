import Foundation
import CryptoKit
import Security
import XCTest
@testable import RemoteAuthTransport

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class RemoteAuthCryptoTests: XCTestCase {
    // RSAPublicKey { modulus INTEGER 1, publicExponent INTEGER 3 }.
    // This is deliberately tiny and synthetic; it is only a DER fixture.
    private let syntheticPKCS1 = Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x03])

    private let expectedSPKI = Data([
        0x30, 0x1A,
        0x30, 0x0D,
        0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
        0x05, 0x00,
        0x03, 0x09, 0x00,
        0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x03
    ])

    // Generated with OpenSSL 3.x using RSA-2048, rsaEncryption SPKI, and
    // RSA-OAEP with SHA-256 for both the digest and MGF1. The public key,
    // fingerprint, plaintext, and ciphertext are non-secret test vectors.
    private let opensslSPKIBase64 = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzWQXNtOvvSeyMwkYNlJup2vcsBo0r3RwC8PqYXR+Np/GSiuok2aI+7vCoawRXAHkkxW7OziC3fCBb6Ae+mzqeMejksELjrmCRcgX2nL9c5XTHbuhmXOo92tycPBszlgrgVEwJfW7+IOMPhmF2oOM3wxfj+bHs6QF1My05kGECM8BxawZmVcsRgWziFQPO8a1BOpIkT5sZ7c7r0KapXsFB6rsn/aq8NFVjVxgVghS71dRp6h3AzQwpB4fv4QM5Y4+c3v4HXHJ6IFgZoVgi1Tnuo4BdbKdVP3Ka2Gnrdd/doTmoWXCLqn+UYYl/YA3Hiy00hO1hbuFZ6gucu1TUNv07QIDAQAB"
    private let opensslFingerprint = "l0x78zbmJl-NwrcfzyVYlbkmBH5JzceRHN0ImWNd5M4"
    private let opensslOAEPPlaintext = Data("openssl remote-auth oaep fixture".utf8)
    private let opensslOAEPCiphertextBase64 = "c+mhvxWtekLE16LiS5yf37ECVT0NwmXQGz4OOoxtFhopqRXpLL8hsAVno6S23wHOhdvs+tMQdQSdfsg8CxrmXMABCQKtSg4o2kYtebiDikKtL5uRXqrRyVgg26CzVkfuAYzHvOdh+9yrK09KYoiY4GBHejjOd+9KHF+5/sfdyzj6+yPJA7/GDgC7TbKRGIf08SoOAZMWdASyjAFshfwzcSC5qZj4HWIrcFq53mw0BECwH6A+vtqFyyuu996RcMgMijAOUkwbt/rDi8i07JoSOgZDE+n0Sp5/I4UsNUUv24QrsuuzDmNuT/E40eFoQqH7+SAW5VfQo1YGAsOyJ96pNQ=="

    func testSubjectPublicKeyInfoEncodingIsDeterministic() throws {
        XCTAssertEqual(
            try RemoteAuthSubjectPublicKeyInfo.encode(pkcs1PublicKey: syntheticPKCS1),
            expectedSPKI
        )
        XCTAssertEqual(
            try RemoteAuthSubjectPublicKeyInfo.encode(pkcs1PublicKey: syntheticPKCS1),
            try RemoteAuthSubjectPublicKeyInfo.encode(pkcs1PublicKey: syntheticPKCS1)
        )
    }

    func testKnownBase64AndURLSafeEncodings() throws {
        let bytes = Data([0xFB, 0xFF, 0xEF])
        XCTAssertEqual(RemoteAuthBase64.encode(bytes), "+//v")
        XCTAssertEqual(RemoteAuthBase64.encodeURLSafeUnpadded(bytes), "-__v")
        XCTAssertEqual(try RemoteAuthBase64.decode("+//v"), bytes)
        XCTAssertEqual(try RemoteAuthBase64.decodeURLSafeUnpadded("-__v"), bytes)
    }

    func testBase64RejectsNonCanonicalAndMalformedInput() {
        XCTAssertThrowsError(try RemoteAuthBase64.decode("YQ"))
        XCTAssertThrowsError(try RemoteAuthBase64.decode("YQ==\n"))
        XCTAssertThrowsError(try RemoteAuthBase64.decodeURLSafeUnpadded("a"))
        XCTAssertThrowsError(try RemoteAuthBase64.decodeURLSafeUnpadded("abc="))
        XCTAssertThrowsError(try RemoteAuthBase64.decodeURLSafeUnpadded("ab+c"))
        XCTAssertThrowsError(try RemoteAuthBase64.decode(String(repeating: "A", count: 1_048_577)))
    }

    func testKnownFingerprintIsStable() throws {
        let digest = Data(SHA256.hash(data: expectedSPKI))
        let expected = RemoteAuthBase64.encodeURLSafeUnpadded(digest)
        XCTAssertEqual(expected, "tL5AnoZo4cgXmdtiZK5alHAIsYiYlUxWAvHeirpaTVU")
        XCTAssertEqual(RemoteAuthBase64.encodeURLSafeUnpadded(digest), expected)
    }

    func testOpenSSLSPKIAndFingerprintVector() throws {
        let spki = try RemoteAuthBase64.decode(opensslSPKIBase64)
        XCTAssertEqual(spki.count, 294)
        XCTAssertEqual(spki.first, 0x30)
        XCTAssertEqual(
            RemoteAuthBase64.encodeURLSafeUnpadded(Data(SHA256.hash(data: spki))),
            opensslFingerprint
        )
    }

    func testOpenSSLOAEPVectorHasExpectedPublicCiphertextShape() throws {
        let ciphertext = try RemoteAuthBase64.decode(opensslOAEPCiphertextBase64)
        XCTAssertEqual(ciphertext.count, 256)
        XCTAssertEqual(opensslOAEPPlaintext.count, 32)
        XCTAssertNotEqual(ciphertext, Data(repeating: 0, count: 256))
    }

    func testMalformedDERIsRejected() {
        XCTAssertThrowsError(
            try RemoteAuthSubjectPublicKeyInfo.encode(pkcs1PublicKey: Data([0x30, 0x01, 0x00]))
        )
        XCTAssertThrowsError(
            try RemoteAuthSubjectPublicKeyInfo.encode(pkcs1PublicKey: Data([0x30, 0x06, 0x02, 0x01, 0x80, 0x02, 0x01, 0x03]))
        )
        XCTAssertThrowsError(
            try RemoteAuthSubjectPublicKeyInfo.encode(pkcs1PublicKey: Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01]))
        )
        XCTAssertThrowsError(
            try RemoteAuthSubjectPublicKeyInfo.encode(pkcs1PublicKey: Data([0x30, 0x81, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x03]))
        )
    }

    func testGeneratedKeyExportsSPKIAndFingerprint() throws {
        let keyPair = try RemoteAuthKeyPair()
        XCTAssertFalse(keyPair.publicKeySPKI.isEmpty)
        XCTAssertFalse(keyPair.publicKeyFingerprint.isEmpty)
        XCTAssertEqual(keyPair.publicKeyFingerprint.count, 43)
        XCTAssertFalse(keyPair.publicKeyBase64.contains("\n"))
        XCTAssertEqual(
            keyPair.publicKeyFingerprint,
            RemoteAuthBase64.encodeURLSafeUnpadded(Data(SHA256.hash(data: keyPair.publicKeySPKI)))
        )
    }

    func testRSAOAEPDecryptsTestOnlyCiphertextAndRejectsTampering() throws {
        let keyPair = try RemoteAuthKeyPair()
        let plaintext = Data("fixture remote-auth secret".utf8)
        let ciphertext = try keyPair.encryptRSAOAEP(plaintext: plaintext)
        XCTAssertEqual(try keyPair.decryptRSAOAEP(ciphertext: ciphertext), plaintext)

        var tampered = ciphertext
        tampered[tampered.startIndex] ^= 0x01
        XCTAssertThrowsError(try keyPair.decryptRSAOAEP(ciphertext: tampered))
        XCTAssertThrowsError(try keyPair.decryptRSAOAEP(ciphertext: Data(repeating: 0, count: 255)))
    }

    func testRSAOAEPSizeBounds() throws {
        let keyPair = try RemoteAuthKeyPair()
        XCTAssertThrowsError(try keyPair.decryptRSAOAEP(ciphertext: Data(repeating: 0, count: 256))) {
            XCTAssertEqual($0 as? RemoteAuthCryptoError, .decryptionFailed)
        }
        XCTAssertThrowsError(try keyPair.encryptRSAOAEP(plaintext: Data(repeating: 0, count: 191))) {
            XCTAssertEqual($0 as? RemoteAuthCryptoError, .plaintextTooLong)
        }
        XCTAssertThrowsError(try keyPair.decryptRSAOAEP(ciphertext: Data(repeating: 0, count: 255))) {
            XCTAssertEqual($0 as? RemoteAuthCryptoError, .invalidCiphertextLength)
        }
        XCTAssertThrowsError(try keyPair.decryptRSAOAEP(ciphertext: Data(repeating: 0, count: 257))) {
            XCTAssertEqual($0 as? RemoteAuthCryptoError, .invalidCiphertextLength)
        }
    }

    func testKeyPairCanBeSharedAcrossConcurrentOperations() throws {
        let keyPair = try RemoteAuthKeyPair()
        let plaintext = Data("concurrent fixture".utf8)
        let failures = FailureBox()

        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            do {
                let ciphertext = try keyPair.encryptRSAOAEP(plaintext: plaintext)
                guard try keyPair.decryptRSAOAEP(ciphertext: ciphertext) == plaintext else {
                    failures.record()
                    return
                }
            } catch {
                failures.record()
            }
        }

        XCTAssertEqual(failures.count, 0)
    }

    func testOAEPDecryptionAgainstEphemeralOpenSSLFixture() throws {
        let openssl = try findOpenSSLExecutable()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifty-remote-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plaintextURL = directory.appendingPathComponent("plaintext")
        let privateURL = directory.appendingPathComponent("private.pem")
        let privateDERURL = directory.appendingPathComponent("private.der")
        let publicURL = directory.appendingPathComponent("public.pem")
        let ciphertextURL = directory.appendingPathComponent("ciphertext")
        let plaintext = Data("openssl runtime remote-auth fixture".utf8)
        try plaintext.write(to: plaintextURL)

        try runOpenSSL(openssl, ["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", privateURL.path], in: directory)
        try runOpenSSL(openssl, ["pkey", "-in", privateURL.path, "-traditional", "-outform", "DER", "-out", privateDERURL.path], in: directory)
        try runOpenSSL(openssl, ["pkey", "-in", privateURL.path, "-pubout", "-out", publicURL.path], in: directory)
        try runOpenSSL(openssl, [
            "pkeyutl", "-encrypt", "-pubin", "-inkey", publicURL.path, "-in", plaintextURL.path,
            "-out", ciphertextURL.path, "-pkeyopt", "rsa_padding_mode:oaep",
            "-pkeyopt", "rsa_oaep_md:sha256", "-pkeyopt", "rsa_mgf1_md:sha256"
        ], in: directory)

        let privateDER = try Data(contentsOf: privateDERURL)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(privateDER as CFData, attributes as CFDictionary, &error) else {
            error?.release()
            throw XCTSkip("Security.framework could not import the runtime OpenSSL fixture")
        }
        let keyPair = try RemoteAuthKeyPair(privateKey: privateKey)
        let ciphertext = try Data(contentsOf: ciphertextURL)
        XCTAssertEqual(ciphertext.count, 256)
        XCTAssertEqual(try keyPair.decryptRSAOAEP(ciphertext: ciphertext), plaintext)
    }

    private func findOpenSSLExecutable() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/openssl",
            "/usr/local/bin/openssl",
            "/usr/bin/openssl"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["version"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let version = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus == 0, version.hasPrefix("OpenSSL ") {
                return URL(fileURLWithPath: path)
            }
        }
        throw XCTSkip("an OpenSSL executable with OAEP-SHA256 support is unavailable")
    }

    private func runOpenSSL(_ executable: URL, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RemoteAuthCryptoTests", code: Int(process.terminationStatus))
        }
    }
}
