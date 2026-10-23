import XCTest
import SQLite3
@testable import vane

/// Fault injection stays outside production APIs. These tests alter the same interactive
/// connection used by Store, preserving the commit/bind/rollback failure scenarios.
@MainActor enum StoreSQLiteFixture {
    static func writer(_ store: Store, file: StaticString = #filePath, line: UInt = #line) throws -> OpaquePointer {
        let connection = try XCTUnwrap(Mirror(reflecting: store).children.first { $0.label == "connection" }?.value,
                                       "Store's interactive connection is missing", file: file, line: line)
        return try XCTUnwrap(Mirror(reflecting: connection).children.first { $0.label == "db" }?.value as? OpaquePointer,
                             "The interactive SQLite handle is unavailable", file: file, line: line)
    }
}
