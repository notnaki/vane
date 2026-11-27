import Foundation
import XCTest
@testable import vane

/// The disk side of File System Access on a real temporary folder. No window, no WebKit.
final class FileSystemAccessDiskTests: XCTestCase {
    private var base = ""
    private var root = ""
    private var outside = ""

    override func setUpWithError() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("fsa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        base = try XCTUnwrap(FileAccessDisk.real(made.path))
        root = base + "/root"
        outside = base + "/outside"
        for dir in [root, root + "/sub", outside] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        try Data("inside".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        try Data("secret".utf8).write(to: URL(fileURLWithPath: outside + "/secret.txt"))
        try FileManager.default.createSymbolicLink(atPath: root + "/out", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: root + "/out.txt", withDestinationPath: outside + "/secret.txt")
        try FileManager.default.createSymbolicLink(atPath: root + "/in.txt", withDestinationPath: root + "/a.txt")
        try FileManager.default.createSymbolicLink(atPath: root + "/dangling", withDestinationPath: base + "/nothing")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: base) }

    private func error(_ work: () throws -> Void) -> String? {
        do { try work(); return nil } catch { return (error as? FileAccessError)?.name ?? "\(error)" }
    }

    func testNamesAreSingleComponents() {
        for bad in ["", ".", "..", "a/b", "/", "a\0b"] { XCTAssertFalse(FileAccessDisk.isValidName(bad), bad) }
        for good in ["a", ".hidden", "a..b", "with space", "ü", "a\\b"] { XCTAssertTrue(FileAccessDisk.isValidName(good), good) }
        XCTAssertEqual(error { _ = try FileAccessDisk.resolve(root: root, [".."]) }, "TypeError")
        XCTAssertEqual(error { _ = try FileAccessDisk.resolve(root: root, ["sub", "..", ".."]) }, "TypeError")
        XCTAssertEqual(error { try FileAccessDisk.child(root: root, [], name: "../x", kind: .file, create: true) }, "TypeError")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + "/x"))
    }

    func testSymlinksMayNotLeadOutOfTheRoot() throws {
        XCTAssertEqual(try FileAccessDisk.resolve(root: root, ["in.txt"]), root + "/a.txt", "a link inside the root is followed")
        XCTAssertEqual(error { _ = try FileAccessDisk.resolve(root: root, ["out.txt"]) }, "NotAllowedError")
        XCTAssertEqual(error { _ = try FileAccessDisk.resolve(root: root, ["out", "secret.txt"]) }, "NotAllowedError")
        XCTAssertEqual(error { try FileAccessDisk.child(root: root, [], name: "out", kind: .directory, create: false) }, "NotAllowedError")
        XCTAssertEqual(error { try FileAccessDisk.child(root: root, [], name: "dangling", kind: .file, create: true) }, "NotAllowedError",
                       "creating through a dangling link would write wherever it points")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + "/nothing"))
        let listed = try FileAccessDisk.list(root: root, []).map { "\($0.name):\($0.kind.rawValue)" }.sorted()
        XCTAssertEqual(listed, ["a.txt:file", "in.txt:file", "sub:directory"], "links out and dangling links are not listed")
        XCTAssertEqual(error { try FileAccessDisk.remove(root: root, [], name: "out.txt", recursive: false) }, "NotFoundError")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside + "/secret.txt"))
        try FileAccessDisk.remove(root: root, [], name: "in.txt", recursive: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/a.txt"), "removing a link removes the link, not its target")
    }

    func testARootThatMovesOrBecomesALinkIsGone() throws {
        try FileManager.default.moveItem(atPath: root, toPath: base + "/moved")
        try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: outside)
        XCTAssertEqual(error { _ = try FileAccessDisk.resolve(root: root, ["secret.txt"]) }, "NotFoundError")
        XCTAssertEqual(error { _ = try FileAccessDisk.list(root: root, []) }, "NotFoundError")
    }

    func testChildrenKindsAndRemoval() throws {
        try FileAccessDisk.child(root: root, [], name: "new", kind: .directory, create: true)
        try FileAccessDisk.child(root: root, ["new"], name: "b.txt", kind: .file, create: true)
        XCTAssertEqual(error { try FileAccessDisk.child(root: root, [], name: "a.txt", kind: .directory, create: true) }, "TypeMismatchError")
        XCTAssertEqual(error { try FileAccessDisk.child(root: root, [], name: "missing", kind: .file, create: false) }, "NotFoundError")
        XCTAssertEqual(error { _ = try FileAccessDisk.list(root: root, ["a.txt"]) }, "TypeMismatchError")
        XCTAssertEqual(error { try FileAccessDisk.remove(root: root, [], name: "new", recursive: false) }, "InvalidModificationError")
        try FileAccessDisk.remove(root: root, [], name: "new", recursive: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/new"))
        XCTAssertEqual(FileAccessDisk.relative(from: root, to: root + "/sub/x"), ["sub", "x"])
        XCTAssertNil(FileAccessDisk.relative(from: root + "/sub", to: root + "/subway"))
    }

    func testReadsInPiecesAndNoticesAChange() throws {
        let path = root + "/a.txt"
        let first = try FileAccessDisk.read(path, at: 0, length: 4, expect: nil)
        XCTAssertEqual(String(decoding: first.data, as: UTF8.self), "insi")
        let rest = try FileAccessDisk.read(path, at: 4, length: 4, expect: (first.size, first.modified))
        XCTAssertEqual(String(decoding: rest.data, as: UTF8.self), "de")
        try Data("changed!".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(error { _ = try FileAccessDisk.read(path, at: 4, length: 4, expect: (first.size, first.modified)) }, "NotReadableError")
        XCTAssertEqual(FileAccessDisk.mimeType(of: "a.txt"), "text/plain")
    }

    func testWritesReplaceTheFileOnlyOnCommit() throws {
        let path = root + "/a.txt"
        let swap = try FileAccessDisk.openSwap(path, keepExistingData: true)
        try FileAccessDisk.write(swap, Data("OUT".utf8), at: 2)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "inside", "nothing changes before close")
        try FileAccessDisk.write(swap, Data("!".utf8), at: nil)
        try FileAccessDisk.write(swap, Data("Z".utf8), at: 9)
        XCTAssertEqual(try FileAccessDisk.commit(swap, root: root, ["a.txt"]), path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("inOUT!\0\0\0Z".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: swap.temp))

        let aborted = try FileAccessDisk.openSwap(path, keepExistingData: false)
        try FileAccessDisk.write(aborted, Data("gone".utf8), at: nil)
        try FileAccessDisk.truncate(aborted, to: 1)
        XCTAssertEqual(aborted.cursor, 1)
        FileAccessDisk.discard(aborted)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("inOUT!\0\0\0Z".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aborted.temp))

        // Swapped for a link out between open and close: the commit refuses and the target is untouched.
        let late = try FileAccessDisk.openSwap(path, keepExistingData: false)
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: outside + "/secret.txt")
        XCTAssertEqual(error { _ = try FileAccessDisk.commit(late, root: root, ["a.txt"]) }, "NotAllowedError")
        XCTAssertEqual(try String(contentsOfFile: outside + "/secret.txt", encoding: .utf8), "secret")
    }

    func testBlocklistFollowsChromium() {
        let rules = FileAccessDisk.rules(home: "/Users/me", extra: ["/Applications/Vane.app"])
        for blocked in ["/", "/Users", "/Users/me", "/Users/me/Desktop", "/Users/me/Documents", "/Users/me/Downloads",
                        "/Users/me/Library", "/Users/me/Library/Preferences/x.plist", "/Users/me/.ssh/id_ed25519",
                        "/System/Library", "/private/etc/hosts", "/usr/bin", "/dev/null", "/Applications/Vane.app/Contents",
                        "/Users/me/Library/Mobile Documents"] {
            XCTAssertTrue(FileAccessDisk.isBlocked(blocked, rules: rules), blocked)
        }
        for allowed in ["/Users/me/Projects", "/Users/me/Desktop/notes.txt", "/Users/me/Downloads/a.zip",
                        "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/doc", "/Users/me/Library/CloudStorage/Drive/x",
                        "/Volumes/USB", "/private/tmp/x", "/private/var/folders/ab/cd/T/x", "/Users/other/x"] {
            XCTAssertFalse(FileAccessDisk.isBlocked(allowed, rules: rules), allowed)
        }
    }

    func testPickingCreatesASaveTargetAndRefusesBlockedOnes() throws {
        let rules = FileAccessDisk.rules(home: "/Users/me", extra: [outside])
        let made = try FileAccessDisk.picked(root + "/new.txt", kind: .file, create: true, rules: rules)
        XCTAssertEqual(made, root + "/new.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: made))
        XCTAssertEqual(error { _ = try FileAccessDisk.picked(root + "/out.txt", kind: .file, create: false, rules: rules) }, "NotAllowedError",
                       "a picked link is judged by where it lands")
        XCTAssertEqual(error { _ = try FileAccessDisk.picked(root + "/sub", kind: .file, create: false, rules: rules) }, "TypeMismatchError")
    }
}
