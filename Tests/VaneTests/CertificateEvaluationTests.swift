import Security
import XCTest
@testable import vane

@MainActor final class CertificateEvaluationTests: XCTestCase {
    func testSameLeafAtDifferentVerifyDateDoesNotReuseSuccessfulOutcome() async throws {
        let certificate = try certificate()
        let host = "date-\(UUID()).invalid"
        let current = try trust(certificate, anchored: true, date: .now.addingTimeInterval(60))
        let expired = try trust(certificate, anchored: true, date: .now.addingTimeInterval(3 * 86400))
        let first = await CertificateTrust.evaluate(current, host: host, port: 443)
        let second = await CertificateTrust.evaluate(expired, host: host, port: 443)
        XCTAssertTrue(first.ok)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertFalse(second.ok, "The supplied trust has expired even though its leaf has not changed")
    }

    func testSameLeafWithDifferentAnchorsDoesNotReuseEitherOutcome() async throws {
        let certificate = try certificate()
        let host = "chain-\(UUID()).invalid"
        let unanchored = try trust(certificate, anchored: false, date: .now.addingTimeInterval(60))
        let anchored = try trust(certificate, anchored: true, date: .now.addingTimeInterval(60))
        let first = await CertificateTrust.evaluate(unanchored, host: host, port: 443)
        let second = await CertificateTrust.evaluate(anchored, host: host, port: 443)
        let third = await CertificateTrust.evaluate(try trust(certificate, anchored: false,
            date: .now.addingTimeInterval(60)), host: host, port: 443)
        XCTAssertFalse(first.ok)
        XCTAssertTrue(second.ok, "A previous failure cannot replace evaluation of the new chain")
        XCTAssertFalse(third.ok, "A previous success cannot approve a different chain")
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    private func trust(_ certificate: SecCertificate, anchored: Bool, date: Date) throws -> SecTrust {
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let result = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(result, (anchored ? [certificate] : []) as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(result, true), errSecSuccess)
        XCTAssertEqual(SecTrustSetNetworkFetchAllowed(result, false), errSecSuccess)
        XCTAssertEqual(SecTrustSetVerifyDate(result, date as CFDate), errSecSuccess)
        return result
    }

    private func certificate() throws -> SecCertificate {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for arguments in [
            ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=trust-fixture.invalid",
             "-keyout", dir.appendingPathComponent("key.pem").path, "-out", dir.appendingPathComponent("cert.pem").path],
            ["x509", "-in", dir.appendingPathComponent("cert.pem").path, "-outform", "der", "-out", dir.appendingPathComponent("cert.der").path]
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        return try XCTUnwrap(SecCertificateCreateWithData(nil,
            Data(contentsOf: dir.appendingPathComponent("cert.der")) as CFData))
    }
}
