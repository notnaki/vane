import AppKit
import WebKit
import XCTest
@testable import vane

/// `showOpenFilePicker`, `showSaveFilePicker` and `showDirectoryPicker` as a real page sees
/// them, in a real tab, on a temporary folder. The fixtures answer the panel and the
/// permission bubble themselves; nothing here shows a window.
@MainActor final class FileSystemAccessWebKitTests: XCTestCase {
    private var server: NavigationHTTPFixture!
    private var profile = UUID()
    private var tabs: [Tab] = []
    private var folder = ""
    private var picks: [URL] = []
    private var requests: [FileSystemAccess.PickRequest] = []
    private var prompts: [String] = []
    private var answer = NSApplication.ModalResponse.alertFirstButtonReturn

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        server = try NavigationHTTPFixture()
        try await compatibilityWait { self.server.port != nil }
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("fsa-web-\(UUID().uuidString)/project")
        try FileManager.default.createDirectory(at: made.appendingPathComponent("src"), withIntermediateDirectories: true)
        folder = try XCTUnwrap(FileAccessDisk.real(made.path))
        try Data("hello".utf8).write(to: URL(fileURLWithPath: folder + "/readme.txt"))
        try FileManager.default.createSymbolicLink(atPath: folder + "/escape", withDestinationPath: "/etc")
        picks = [URL(fileURLWithPath: folder)]
        requests = []; prompts = []
        answer = .alertFirstButtonReturn
        FileSystemAccess.pickerForTesting = { [unowned self] request in requests.append(request); return picks }
        FileSystemAccess.promptForTesting = { [unowned self] mode, name in
            prompts.append("\(mode == .readwrite ? "edit" : "view") \(name)")
            return answer
        }
    }

    override func tearDown() async throws {
        tabs.forEach { $0.tearDown() }
        tabs = []
        FileSystemAccess.pickerForTesting = nil
        FileSystemAccess.promptForTesting = nil
        server.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: (folder as NSString).deletingLastPathComponent)
    }

    private func load(_ path: String, in existing: Tab? = nil) async throws -> Tab {
        let tab = existing ?? Tab(profileID: profile)
        if existing == nil { tabs.append(tab) }
        let url = try server.url(path)
        tab.navigate(to: url)
        try await compatibilityWait { tab.web.url == url && !tab.web.isLoading }
        return tab
    }

    /// Runs as the body of an async function in the page. WebKit runs it as a user gesture,
    /// which is what a click on an Open button is. A hung promise fails instead of stalling CI.
    /// Each call is one click: WebKit's gesture has no trusted input event to reset the
    /// one-request-per-click flag, so the fixture resets it.
    private func js(_ tab: Tab, _ body: String) async throws -> String? {
        _ = try await tab.web.callAsyncJavaScript("\(FileSystemAccess.gestureUsed) = false", arguments: [:], in: nil,
                                                  contentWorld: FileSystemAccess.gestureWorld)
        return try await tab.web.callAsyncJavaScript("""
            return await Promise.race([(async () => { \(body) })(),
                new Promise((_, reject) => setTimeout(() => reject(new Error('file access fixture timed out')), 20000))]);
            """, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    private let outcome = "promise => promise.then(value => 'ok:' + value, error => error.constructor.name + ':' + error.name)"

    func testAFolderIsListedReadAndEditedThroughNativeHandleClasses() async throws {
        let tab = try await load("/fsa")
        let result = try await js(tab, """
            const name = \(outcome);
            const dir = await showDirectoryPicker({ mode: 'readwrite' });
            const entries = [];
            for await (const [key, handle] of dir) entries.push(key + ':' + handle.kind);
            const readme = await dir.getFileHandle('readme.txt');
            const text = await (await readme.getFile()).text();
            const src = await dir.getDirectoryHandle('src');
            const made = await src.getFileHandle('main.js', { create: true });
            const writer = await made.createWritable();
            await writer.write('let x = 1;');
            await writer.seek(4);
            await writer.write({ type: 'write', data: new Blob(['y']) });
            await writer.close();
            const again = await src.getFileHandle('main.js');
            return JSON.stringify({
              classes: [dir instanceof FileSystemDirectoryHandle, dir instanceof FileSystemHandle, readme instanceof FileSystemFileHandle,
                        writer instanceof FileSystemWritableFileStream, writer instanceof WritableStream, String(dir), dir.name],
              entries: entries.sort(), text, written: await (await again.getFile()).text(),
              same: [await made.isSameEntry(again), await made.isSameEntry(readme)],
              resolved: await dir.resolve(again),
              permission: await dir.queryPermission({ mode: 'readwrite' }),
              escape: await name(dir.getDirectoryHandle('escape')),
              bad: await name(dir.getFileHandle('../readme.txt')),
              mismatch: await name(dir.getFileHandle('src')),
              notEmpty: await name(dir.removeEntry('src')),
              removed: await name(src.removeEntry('main.js')),
            });
            """)
        let data = try XCTUnwrap(result?.data(using: .utf8))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["classes"] as? [AnyHashable], [true, true, true, true, true, "[object FileSystemDirectoryHandle]", "project"])
        XCTAssertEqual(report["entries"] as? [String], ["readme.txt:file", "src:directory"], "a link out of the folder is not listed")
        XCTAssertEqual(report["text"] as? String, "hello")
        XCTAssertEqual(report["written"] as? String, "let y = 1;")
        XCTAssertEqual(report["same"] as? [Bool], [true, false])
        XCTAssertEqual(report["resolved"] as? [String], ["src", "main.js"])
        XCTAssertEqual(report["permission"] as? String, "granted")
        XCTAssertEqual(report["escape"] as? String, "DOMException:NotAllowedError")
        XCTAssertEqual(report["bad"] as? String, "TypeError:TypeError")
        XCTAssertEqual(report["mismatch"] as? String, "DOMException:TypeMismatchError")
        XCTAssertEqual(report["notEmpty"] as? String, "DOMException:InvalidModificationError")
        XCTAssertEqual(report["removed"] as? String, "ok:undefined")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/src/main.js"))
        XCTAssertEqual(prompts, ["edit project"], "readwrite on a folder asks after the pick")
        XCTAssertEqual(requests.first?.kind, .directory)
    }

    func testSaveThenOpenAFileBiggerThanOneMessage() async throws {
        let target = URL(fileURLWithPath: folder + "/drawing.excalidraw")
        picks = [target]
        let tab = try await load("/fsa")
        let size = FileSystemAccess.chunk + 123_457
        let saved = try await js(tab, """
            const name = \(outcome);
            const handle = await showSaveFilePicker({ suggestedName: 'a/b.excalidraw', excludeAcceptAllOption: true,
              types: [{ description: 'Drawing', accept: { 'application/json': ['.excalidraw'] } }] });
            const data = new Uint8Array(\(size));
            for (let i = 0; i < data.length; i++) data[i] = i * 13;
            const writer = await handle.createWritable();
            await writer.write(new Blob([data]));
            await writer.close();
            const aborted = await handle.createWritable({ keepExistingData: true });
            await aborted.truncate(1);
            await aborted.abort();
            window.saved = handle;
            return handle.queryPermission({ mode: 'readwrite' });
            """)
        XCTAssertEqual(saved, "granted")
        // Their own click: WebKit stops carrying the first one's activation across a slow write.
        let invalid = try await js(tab, """
            const name = \(outcome);
            return [await name(showSaveFilePicker({ excludeAcceptAllOption: true })),
                    await name(showOpenFilePicker({ types: [{ accept: { 'nonsense': ['.x'] } }] })),
                    await name(showOpenFilePicker({ id: 'no spaces' }))].join(' ');
            """)
        XCTAssertEqual(invalid, "TypeError:TypeError TypeError:TypeError TypeError:TypeError")
        XCTAssertEqual(requests.first?.suggestedName, "a_b.excalidraw")
        XCTAssertEqual(requests.first?.acceptAll, false)
        let disk = try Data(contentsOf: target)
        XCTAssertEqual(disk.count, size, "an aborted write leaves the file as it was")
        XCTAssertTrue(disk.enumerated().allSatisfy { $0.element == UInt8(truncatingIfNeeded: $0.offset * 13) })

        picks = [target, URL(fileURLWithPath: folder + "/readme.txt")]
        let read = try await js(tab, """
            const [handle, other] = await showOpenFilePicker({ multiple: true });
            const file = await handle.getFile();
            const bytes = new Uint8Array(await file.arrayBuffer());
            let intact = bytes.length === \(size);
            for (let i = 0; intact && i < bytes.length; i++) intact = bytes[i] === ((i * 13) & 255);
            return [file instanceof File, file.name, intact, await handle.queryPermission({ mode: 'readwrite' }),
                    await other.queryPermission({ mode: 'readwrite' }),
                    await other.createWritable().then(() => 'writable', error => error.name)].join(' ');
            """)
        // The saved file is the same pick as before, so it keeps this page's edit grant.
        XCTAssertEqual(read, "true drawing.excalidraw true granted prompt NotAllowedError", "an opened file is read-only until asked")
    }

    func testOnlyAUserGestureCanAskAndFramesHaveNoPickers() async throws {
        server.pages["/eager"] = """
            <iframe srcdoc="<p>frame</p>"></iframe>
            <script>
            window.results = {};
            showDirectoryPicker().then(() => results.api = 'picked', error => results.api = error.name);
            const bridge = webkit.messageHandlers.\(FileSystemAccess.messageName);
            const raw = (key, message) => bridge.postMessage(message).then(reply => results[key] = reply.error ? reply.error[0] : 'ok');
            raw('raw', { op: 'pick', type: 'directory', options: {} });
            raw('forgedToken', { op: 'list', h: { root: 'not-a-grant', path: [] } });
            dispatchEvent(new Event('\(FileSystemAccess.gestureEvent)'));
            raw('forged', { op: 'pick', type: 'directory', options: {} });
            </script>
            """
        let tab = try await load("/eager")
        try await compatibilityWait {
            try await tab.web.evaluateJavaScript("Object.keys(window.results).length") as? Int == 4
        }
        let results = try await tab.web.evaluateJavaScript("JSON.stringify(results, Object.keys(results).sort())") as? String
        XCTAssertEqual(results, #"{"api":"SecurityError","forged":"SecurityError","forgedToken":"NotFoundError","raw":"SecurityError"}"#)
        XCTAssertTrue(requests.isEmpty, "No panel may open without the user asking for it")
        let frame = try await tab.web.evaluateJavaScript("typeof frames[0].showOpenFilePicker + ',' + typeof showOpenFilePicker") as? String
        XCTAssertEqual(frame, "undefined,function", "Only the main frame gets the pickers")

        // A read-only folder: writing needs a separate yes. Not Now leaves it at 'prompt'; Don't Allow is 'denied'.
        answer = .abort
        let denied = try await js(tab, """
            window.dir = await showDirectoryPicker();
            const before = await dir.getFileHandle('new.txt', { create: true }).then(() => 'made', error => error.name);
            const chained = await dir.requestPermission({ mode: 'readwrite' }).then(v => v, error => error.name);
            const second = await showOpenFilePicker().then(() => 'picked', error => error.name);
            return [before, chained, second].join(' ');
            """)
        XCTAssertEqual(denied, "NotAllowedError SecurityError SecurityError", "one click is one picker or one question")
        XCTAssertEqual(requests.count, 1)
        let later = try await js(tab, "return dir.requestPermission({ mode: 'readwrite' });")
        XCTAssertEqual(later, "prompt")
        answer = .alertThirdButtonReturn
        let refused = try await js(tab, "return dir.requestPermission({ mode: 'readwrite' });")
        XCTAssertEqual(refused, "denied")
        let remembered = try await js(tab, """
            return [await dir.queryPermission({ mode: 'readwrite' }), await dir.requestPermission({ mode: 'readwrite' })].join(' ');
            """)
        XCTAssertEqual(remembered, "denied denied", "Don't Allow is remembered for this document")
        XCTAssertEqual(prompts.count, 2, "and not asked again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/new.txt"))
    }

    func testAHandleInIndexedDBCanAskAgainAfterAReload() async throws {
        let tab = try await load("/fsa")
        let stored = try await js(tab, """
            const dir = await showDirectoryPicker();
            const db = await new Promise((resolve, reject) => {
              const open = indexedDB.open('fsa-fixture', 1);
              open.onupgradeneeded = () => open.result.createObjectStore('handles');
              open.onsuccess = () => resolve(open.result);
              open.onerror = () => reject(open.error);
            });
            await new Promise((resolve, reject) => {
              const put = db.transaction('handles', 'readwrite').objectStore('handles').put(dir, 'recent');
              put.onsuccess = resolve; put.onerror = () => reject(put.error);
            });
            db.close();
            return 'stored';
            """)
        XCTAssertEqual(stored, "stored")
        _ = try await load("/fsa", in: tab)
        let revived = try await js(tab, """
            const db = await new Promise(resolve => { const open = indexedDB.open('fsa-fixture', 1); open.onsuccess = () => resolve(open.result); });
            const dir = await new Promise(resolve => {
              const get = db.transaction('handles').objectStore('handles').get('recent');
              get.onsuccess = () => resolve(get.result);
            });
            const before = [dir instanceof FileSystemDirectoryHandle, dir.name, await dir.queryPermission()];
            const blocked = await dir.getFileHandle('readme.txt').then(() => 'read', error => error.name);
            window.dir = dir;
            return [...before, blocked].join(' ');
            """)
        let asked = try await js(tab, """
            const asked = await dir.requestPermission();
            const text = await (await (await dir.getFileHandle('readme.txt')).getFile()).text();
            return [asked, text].join(' ');
            """)
        XCTAssertEqual(revived, "true project prompt NotAllowedError", "a reload ends the grant")
        XCTAssertEqual(asked, "granted hello", "asking again restores it")
        XCTAssertEqual(prompts, ["view project"])
    }
}
