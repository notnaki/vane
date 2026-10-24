import Security
import XCTest
@testable import vane

enum ClientCertificateFixture {
    static func identity(_ name: String, usage: String = "clientAuth") throws -> SecIdentity {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for args in [
            ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=\(name)",
             "-keyout", "key.pem", "-out", "cert.pem", "-addext", "extendedKeyUsage=\(usage)"],
            ["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "identity.p12",
             "-passout", "pass:fixture"]
        ] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            p.arguments = args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("identity.p12"))
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: "fixture",
                       kSecImportToMemoryOnly as String: true] as [String: Any]
        XCTAssertEqual(SecPKCS12Import(data as CFData, options as CFDictionary, &items), errSecSuccess)
        let entry = try XCTUnwrap((items as? [[String: Any]])?.first)
        let identity = try XCTUnwrap(entry[kSecImportItemIdentity as String]) as! SecIdentity
        return identity
    }

}
