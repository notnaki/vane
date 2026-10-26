import Darwin
import Foundation
import XCTest
@testable import vane

extension XCTestCase {
    /// Scope only fixtures asserting the preserved eager/lazy/buffered mounting
    /// strategies. Public behavior integration fixtures keep shipping defaults.
    @MainActor func useLegacySidebarMountingPolicy() {
        let flag = "VANE_EXPERIMENT_NATIVE_ROW_BATCH_CACHE"
        let previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "0", 1)
        // Registered before fixture cleanup, so XCTest's LIFO teardown closes
        // roots/windows before restoring the owner-construction policy.
        addTeardownBlock {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
    }
}
