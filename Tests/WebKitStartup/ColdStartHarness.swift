import AppKit
import WebKit

/// A separate process is essential: XCTest and browser fixtures already initialize WebKit.
@main enum ColdStartHarness {
    @MainActor static func main() {
        WebKitStartup.prepare()
        WebKitStartup.prepare()
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { _ in
            WebKitStartup.prepare()
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { _ in
                print("PASS cold WebKit registry queries without a web view")
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            fputs("FAIL cold WebKit registry query timed out\n", stderr)
            exit(1)
        }
        NSApplication.shared.run()
    }
}
