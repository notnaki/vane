import AppKit
import Darwin
import WebKit

/// Opt-in real-WebKit ownership/performance fixture, in browsercheck's isolated bundle.
@MainActor enum BrowserLifecycleChecks {
    private final class WeakObject {
        weak var value: AnyObject?
        init(_ value: AnyObject?) { self.value = value }
    }
    private struct Failure: Error { let message: String }

    private static func residentMB() throws -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw Failure(message: "task_info failed: \(result)") }
        return Double(info.resident_size) / 1_048_576
    }

    private static func cpuSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure(message: "getrusage failed") }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func load(_ tab: Tab) async throws {
        tab.web.loadHTMLString("<title>Lifecycle</title><input id='draft'><audio></audio>", baseURL: URL(string: "https://lifecycle.invalid"))
        let deadline = ContinuousClock.now + .seconds(8)
        while tab.existingWeb?.title != "Lifecycle" || tab.existingWeb?.isLoading != false {
            guard ContinuousClock.now < deadline else { throw Failure(message: "fixture load timed out") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    static func run() async -> Never {
        var closedViews: [WeakObject] = [], closedWindows: [WeakObject] = [], closedStores: [WeakObject] = []
        var pendingWindow: NSWindow?
        var pendingTab: Tab?
        do {
            HTTPSOnly.enabled = false
            let profile = ProfileManager.shared.active.id
            _ = ProfileManager.shared.ensureSpaces(for: ProfileManager.shared.active)
            let store = TabStore(profileID: profile, isLittle: true, session: [])
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            pendingWindow = window
            store.window = window
            let host = WebHost(nil)
            window.contentView = host
            window.orderFront(nil)
            // Warm WebKit, SwiftUI and Little Vane chrome before measuring growth.
            for _ in 0..<3 {
                let floating = LittleArc.open(nil, profileID: profile)
                pendingWindow = floating.window
                let tab = floating.newBlankTab()
                pendingTab = tab
                try await load(tab)
                _ = LittleArc.spaceMenu(floating)
                floating.window?.close()
                pendingTab = nil
                pendingWindow = window
            }
            try await Task.sleep(for: .seconds(3))
            let baseline = try residentMB()
            print(String(format: "LIFECYCLE baseline RSS: %.2f MiB", baseline))
            fflush(stdout)
            for cycle in 1...100 {
                let tab = store.newBlankTab()
                pendingTab = tab
                host.show(tab.web)
                try await load(tab)
                closedViews.append(WeakObject(tab.existingWeb))
                store.close(tab.id)
                pendingTab = nil
                if cycle % 25 == 0 { print("LIFECYCLE tab cycles: \(cycle)"); fflush(stdout) }
            }
            for cycle in 1...100 {
                let floating = LittleArc.open(nil, profileID: profile)
                pendingWindow = floating.window
                let tab = floating.newBlankTab()
                pendingTab = tab
                try await load(tab)
                _ = LittleArc.spaceMenu(floating)
                closedViews.append(WeakObject(tab.existingWeb))
                closedWindows.append(WeakObject(floating.window))
                closedStores.append(WeakObject(floating))
                floating.window?.close()
                pendingTab = nil
                pendingWindow = window
                if cycle % 25 == 0 { print("LIFECYCLE Little Vane cycles: \(cycle)"); fflush(stdout) }
            }
            let entries = (0..<200).map {
                Session.Entry(id: UUID().uuidString, url: "https://lifecycle.invalid/\($0)",
                              title: "Saved page \($0)", kind: .pinned)
            }
            let restored = TabStore(profileID: profile, session: entries)
            guard restored.tabs.count == 200, restored.tabs.allSatisfy({ $0.existingWeb == nil }) else {
                throw Failure(message: "200 parked tabs allocated a WebView")
            }
            print("LIFECYCLE 200 restored parked rows: 0 WebViews")
            restored.tabs.forEach { $0.tearDown() }
            restored.tabs.removeAll()
            TabStore.all.removeAll { $0 === restored }
            store.tabs.forEach { $0.tearDown() }
            store.tabs.removeAll()
            TabStore.all.removeAll { $0 === store }
            host.removePage()
            window.close()
            pendingWindow = nil
            let settleStart = ContinuousClock.now
            try await Task.sleep(for: .seconds(30))
            print("LIFECYCLE settling duration: \(settleStart.duration(to: .now))")
            print("LIFECYCLE suspension timer running with no stores: \(Suspension.isRunning)")
            let settled = try residentMB()
            let views = closedViews.filter { $0.value != nil }.count
            let windows = closedWindows.filter { $0.value != nil }.count
            let stores = closedStores.filter { $0.value != nil }.count
            print("LIFECYCLE retained after 30s: views=\(views)/200 windows=\(windows)/100 stores=\(stores)/100")
            print(String(format: "LIFECYCLE settled RSS: %.2f MiB, growth: %.2f MiB, limit: %.2f MiB", settled, settled - baseline, max(50_000_000 / 1_048_576.0, baseline * 0.1)))
            fflush(stdout)
            let start = ContinuousClock.now
            let cpuStart = try cpuSeconds()
            try await Task.sleep(for: .seconds(60))
            let elapsed = start.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let cpu = (try cpuSeconds() - cpuStart) / seconds * 100
            print(String(format: "LIFECYCLE average idle parent CPU over %.1fs: %.3f%%", seconds, cpu))
            print("LIFECYCLE metrics exclude WebKit helper processes; no real-site/media energy claim.")
            let passed = !Suspension.isRunning && views == 0 && windows == 0 && stores == 0 && settled - baseline <= max(50_000_000 / 1_048_576.0, baseline * 0.1) && cpu < 3
            print("\(passed ? "PASS" : "FAIL") lifecycle targets")
            fflush(stdout)
            exit(passed ? 0 : 1)
        } catch {
            pendingTab?.tearDown()
            pendingWindow?.close()
            LittleArc.windows.forEach { $0.close() }
            print("FAIL lifecycle: \(error)")
            fflush(stdout)
            exit(1)
        }
    }
}
