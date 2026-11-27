import AppKit
import UniformTypeIdentifiers
import WebKit

/// `chrome.downloads` for system WebKit, which has no such API, over Vane's own download
/// list: an extension's downloads are rows in the Library like any other, and it sees the
/// profile's rows as Chrome shows an extension every download. Private windows keep their
/// own list, which no extension sees. Vendor resources remain unchanged.
@MainActor enum ExtensionDownloadsAPI {
    nonisolated static let permission = "downloads"
    /// Chrome's separate permission for `open`, which launches a file.
    nonisolated static let openPermission = "downloads.open"

    /// Required, not optional, as for the other stand-ins.
    nonisolated static func declared(_ manifest: [String: Any], _ name: String = permission) -> Bool {
        (manifest["permissions"] as? [String])?.contains(name) == true
    }

    /// `filename` as folders and a name under the download folder, or nil for anything
    /// Chrome refuses: empty, absolute, `.` or `..`, or a part no file system takes as is.
    nonisolated static func relativePath(_ filename: String) -> [String]? {
        let parts = filename.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let refused = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\\:*?\"<>|"))
        guard !filename.isEmpty, !filename.hasPrefix("~"), parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.count <= 255
                && part.rangeOfCharacter(from: refused) == nil
                && Downloads.filenameWithoutBidiControls(part) == part
                && !part.hasPrefix(" ") && !part.hasSuffix(" ") && !part.hasSuffix(".")
        }) else { return nil }
        return parts
    }

    /// A row's state as Chrome names it: one the user paused is still in progress; one the
    /// network broke off, though Vane keeps it as resumable, is interrupted.
    static func state(_ status: Downloads.Item.Status, reason: String) -> (state: String, paused: Bool, error: String?) {
        switch status {
        case .running: ("in_progress", false, nil)
        case .paused: ["Paused", "Pausing…"].contains(reason) ? ("in_progress", true, nil) : ("interrupted", false, "NETWORK_FAILED")
        case .done, .missing: ("complete", false, nil)
        case .failed: ("interrupted", false, reason == Downloads.cancelledText ? "USER_CANCELED" : "NETWORK_FAILED")
        }
    }

    /// Headers a page may not set (Fetch's list): Chrome refuses them too.
    nonisolated static func unsafeHeader(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("proxy-") || name.hasPrefix("sec-") || [
            "accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
            "connection", "content-length", "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive",
            "origin", "referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade", "via"
        ].contains(name)
    }

    /// What a row reports as its `url`: a data: URL cut short, as it can be a whole file.
    nonisolated static func reported(_ url: String) -> String {
        url.lowercased().hasPrefix("data:") && url.count > 100 ? String(url.prefix(100)) + "…" : url
    }

    // Requests travel over `ExtensionChromiumGaps`' `ask`, as `downloads.<op>`. Events come
    // from one call the host holds open until the list changes: each context compares the
    // list it last saw, as Chrome reports changes, and stays awake while it listens. A
    // failed call is retried after a moment, so a context never goes deaf.
    // ponytail: the first answer is the baseline, so a download started while a context
    // adds its first listener may come without `onCreated`.
    /// Run inside `ExtensionChromiumGaps.script`, with its `api`, `ask`, `answer` and `declared`.
    nonisolated static let script = #"""
        if (declared.has('downloads')) {
          const call = (op, args = {}) => ask('downloads.' + op, args);
          const listeners = {created: new Set(), changed: new Set(), erased: new Set()};
          const listening = () => Object.values(listeners).some(set => set.size > 0);
          const fire = (set, value) => { for (const listener of [...set]) try { listener(value); } catch (error) { console.error(error); } };
          let polling = false, stamp, known = new Map();
          const poll = async () => {
            if (polling || !listening()) return;
            polling = true;
            while (listening()) {
              try {
                const reply = await call('watch', stamp === undefined ? {} : {after: stamp});
                const baseline = stamp === undefined, next = new Map(reply.items.map(item => [item.id, item]));
                stamp = reply.stamp;
                if (!baseline) {
                  for (const [id, item] of next) {
                    const before = known.get(id);
                    if (!before) { fire(listeners.created, item); continue; }
                    const delta = {id};
                    for (const key of new Set([...Object.keys(before), ...Object.keys(item)]))
                      if (key !== 'bytesReceived' && JSON.stringify(before[key]) !== JSON.stringify(item[key]))
                        delta[key] = {...(key in before ? {previous: before[key]} : {}), ...(key in item ? {current: item[key]} : {})};
                    if (Object.keys(delta).length > 1) fire(listeners.changed, delta);
                  }
                  for (const id of known.keys()) if (!next.has(id)) fire(listeners.erased, id);
                }
                known = next;
              } catch (error) {
                console.error(error);
                await new Promise(resolve => setTimeout(resolve, 2000));
              }
            }
            polling = false;
          };
          const channel = set => Object.freeze({
            addListener(listener) { if (typeof listener !== 'function') throw new TypeError('Listener must be a function'); set.add(listener); poll(); },
            removeListener(listener) { set.delete(listener); },
            hasListener: listener => set.has(listener),
            hasListeners: () => set.size > 0
          });
          const exact = ['id', 'url', 'finalUrl', 'filename', 'danger', 'mime', 'startTime', 'endTime', 'state', 'paused', 'error',
                         'bytesReceived', 'totalBytes', 'fileSize', 'exists'];
          const time = value => value === undefined ? NaN : Date.parse(value);
          const matches = (item, query) => Object.entries(query ?? {}).every(([key, wanted]) => {
            if (wanted === undefined || wanted === null) return true;
            const text = (item.url + ' ' + item.finalUrl + ' ' + item.filename).toLowerCase();
            switch (key) {
              case 'query': return [wanted].flat().map(term => String(term).toLowerCase())
                .every(term => term.startsWith('-') ? !text.includes(term.slice(1)) : text.includes(term));
              case 'startedBefore': return time(item.startTime) < time(wanted);
              case 'startedAfter': return time(item.startTime) > time(wanted);
              case 'endedBefore': return time(item.endTime) < time(wanted);
              case 'endedAfter': return time(item.endTime) > time(wanted);
              case 'totalBytesGreater': return item.totalBytes > wanted;
              case 'totalBytesLess': return item.totalBytes < wanted;
              case 'filenameRegex': return new RegExp(wanted).test(item.filename);
              case 'urlRegex': return new RegExp(wanted).test(item.url);
              case 'finalUrlRegex': return new RegExp(wanted).test(item.finalUrl);
              default: return !exact.includes(key) || item[key] === wanted;
            }
          });
          const search = (items, query) => {
            const found = items.filter(item => matches(item, query));
            for (const key of [...(query?.orderBy ?? [])].reverse()) {
              const name = String(key).replace(/^-/, ''), sign = String(key).startsWith('-') ? -1 : 1;
              found.sort((a, b) => a[name] === b[name] ? 0 : (a[name] ?? '') < (b[name] ?? '') ? -sign : sign);
            }
            const limit = query?.limit ?? 1000;
            return limit > 0 ? found.slice(0, limit) : found;
          };
          const each = (op, extra = () => ({})) => (id, callback) => answer(call(op, {id, ...extra()}).then(() => {}), callback);
          // `show` and `showDefaultFolder` answer nothing in Chrome, not even a promise.
          const quiet = promise => { promise.catch(error => console.error(error)); };
          const toData = async blob => {
            const bytes = new Uint8Array(await blob.arrayBuffer());
            let text = '';
            for (let at = 0; at < bytes.length; at += 0x8000) text += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
            return 'data:' + (blob.type || 'application/octet-stream') + ';base64,' + btoa(text);
          };
          Object.defineProperty(api, 'downloads', {configurable: true, value: {
            download(options, callback) {
              return answer((async () => {
                let url = String(options?.url ?? ''), reported;
                if (/^blob:/i.test(url)) {
                  // Only the extension's own blobs, read here: the host cannot reach them.
                  const inner = new URL(url.slice(5));
                  if (inner.protocol !== globalThis.location?.protocol || inner.host !== globalThis.location?.host) throw new Error('Invalid URL.');
                  reported = url;
                  url = await toData(await (await fetch(url)).blob());
                }
                const args = {url, ...(reported ? {reported} : {})};
                for (const key of ['filename', 'saveAs', 'conflictAction', 'method', 'body']) if (options?.[key] !== undefined) args[key] = options[key];
                if (options?.headers !== undefined) args.headers = [...options.headers].map(header => [String(header?.name), String(header?.value)]);
                return call('download', args);
              })(), callback);
            },
            search(query, callback) { return answer(call('list').then(items => search(items, query)), callback); },
            pause: each('pause'),
            resume: each('resume'),
            cancel: each('cancel'),
            erase(query, callback) {
              return answer(call('list').then(items => call('erase', {ids: search(items, query).map(item => item.id)})), callback);
            },
            // The host decides whether the user just clicked; nothing reported here counts.
            open: each('open'),
            show(id) { quiet(call('show', {id})); },
            showDefaultFolder() { quiet(call('showDefaultFolder')); },
            getFileIcon(id, options, callback) {
              if (typeof options === 'function') [options, callback] = [{}, options];
              return answer(call('icon', {id, size: options?.size ?? 32}), callback);
            },
            onCreated: channel(listeners.created),
            onChanged: channel(listeners.changed),
            onErased: channel(listeners.erased)
          }});
        }
        """#
}

/// The host's side of `chrome.downloads` for one profile: Chrome's integer ids over the
/// list's UUIDs. Which extension started what lives on the row (`Item.byExtension`).
// ponytail: ids and `byExtensionId` live as long as the host, so they change on relaunch.
// Persist them beside the list if an extension keeps ids across a restart.
@MainActor final class ExtensionDownloads {
    let profileID: UUID
    private var ids: [UUID: Int] = [:]
    private var nextID = 1
    /// Once: asking by id per call would bring a deleted profile's list back.
    private lazy var manager = Downloads.manager(for: profileID)
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(profileID: UUID) { self.profileID = profileID }

    private func id(_ item: Downloads.Item) -> Int {
        if let id = ids[item.id] { return id }
        defer { nextID += 1 }
        ids[item.id] = nextID
        return nextID
    }

    /// Each row in Chrome's shape, oldest first, as Chrome numbers them.
    private func list() -> [[String: Any]] {
        manager.items.reversed().map { item in
            let id = id(item)
            var reason = ""
            if case .failed(let why) = item.state { reason = why }
            let (state, paused, error) = ExtensionDownloadsAPI.state(item.status, reason: reason)
            let url = ExtensionDownloadsAPI.reported(item.byExtension?.url ?? item.source?.absoluteString ?? "")
            let size: Int64 = item.total > 0 ? item.total : -1
            var entry: [String: Any] = [
                "id": id, "url": url, "finalUrl": item.transfer.map { ExtensionDownloadsAPI.reported($0.absoluteString) } ?? url,
                "referrer": "", "filename": item.url?.path ?? "",
                "incognito": false, "danger": "safe", "state": state, "paused": paused, "canResume": manager.canResume(item),
                "bytesReceived": item.received, "totalBytes": size, "fileSize": item.status == .done ? size : -1,
                "exists": item.status != .missing, "startTime": Self.iso.string(from: item.started),
                "mime": item.url.flatMap { UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType } ?? ""
            ]
            if let completed = item.completed { entry["endTime"] = Self.iso.string(from: completed) }
            if let error { entry["error"] = error }
            if let by = item.byExtension { entry["byExtensionId"] = by.id; entry["byExtensionName"] = by.name }
            return entry
        }
    }

    private func item(_ arguments: [String: Any]) throws -> Downloads.Item {
        guard let id = (arguments["id"] as? NSNumber)?.intValue,
              let item = manager.items.first(where: { ids[$0.id] == id }) else { throw ExtensionHost.Failure("Invalid downloadId.") }
        return item
    }

    /// `gesture`: the host saw the user click one of this extension's pages a moment ago.
    func answer(_ operation: String, _ arguments: [String: Any], for context: WKWebExtensionContext,
                extensionID: String, window: NSWindow?, gesture: () -> Bool) async throws -> Any {
        switch operation {
        case "download":
            // The URL the extension named: its blob: one, not the data: it was read into.
            let named = (arguments["reported"] as? String).flatMap { $0.lowercased().hasPrefix("blob:") ? $0 : nil }
                ?? arguments["url"] as? String ?? ""
            let item = try await manager.start(try request(arguments), path: try path(arguments),
                                               overwrite: arguments["conflictAction"] as? String == "overwrite",
                                               saveAs: arguments["saveAs"] as? Bool == true,
                                               by: (extensionID, context.webExtension.displayName ?? "", ExtensionDownloadsAPI.reported(named)),
                                               in: window)
            return id(item)
        case "list":
            return list()
        case "watch":
            // Wakes on the list's saves, not the clock; a save that only moved bytes, which
            // Chrome does not report, keeps waiting.
            // ponytail: polls an integer a few times a second per listening context; observe
            // `revision` instead if that ever shows up in a profile.
            let after = arguments["after"] as? String, deadline = ContinuousClock.now + .seconds(25)
            var seen: Int?
            while true {
                if seen != manager.revision {
                    seen = manager.revision
                    let items = list()
                    let quiet = items.map { $0.filter { $0.key != "bytesReceived" } }
                    let data = try JSONSerialization.data(withJSONObject: quiet, options: [.sortedKeys])
                    let stamp = String(data.hashValue)
                    if stamp != after { return ["stamp": stamp, "items": items] }
                }
                if ContinuousClock.now >= deadline { return ["stamp": after ?? "", "items": list()] }
                try await Task.sleep(for: .milliseconds(250))
            }
        case "pause":
            let item = try item(arguments)
            guard item.status.isLive else { throw ExtensionHost.Failure("Download must be in progress.") }
            manager.pause(item)
        case "resume":
            let item = try item(arguments)
            guard manager.resume(item) else { throw ExtensionHost.Failure("DownloadItem.canResume must be true.") }
        case "cancel":
            manager.cancel(try item(arguments))
        case "erase":
            let wanted = Set((arguments["ids"] as? [NSNumber] ?? []).map(\.intValue))
            let erased = manager.items.filter { ids[$0.id].map(wanted.contains) == true }
            for item in erased { manager.forget(item) }
            return erased.compactMap { ids.removeValue(forKey: $0.id) }
        case "open":
            guard ExtensionDownloadsAPI.declared(context.webExtension.manifest, ExtensionDownloadsAPI.openPermission) else {
                throw ExtensionHost.Failure("The \"downloads.open\" permission is required.")
            }
            guard gesture() else { throw ExtensionHost.Failure("User gesture required.") }
            let item = try item(arguments)
            guard item.status == .done else { throw ExtensionHost.Failure("Download must be complete.") }
            manager.open(item)
        case "show":
            manager.reveal(try item(arguments))
        case "showDefaultFolder":
            NSWorkspace.shared.open(manager.destinationDirectory)
        case "icon":
            let item = try item(arguments)
            let size = (arguments["size"] as? NSNumber)?.intValue ?? 32
            guard [16, 32].contains(size) else { throw ExtensionHost.Failure("Invalid icon size.") }
            guard let path = item.url?.path else { throw ExtensionHost.Failure("Icon not found.") }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: size, height: size)
            guard let tiff = icon.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw ExtensionHost.Failure("Icon not found.")
            }
            return "data:image/png;base64," + png.base64EncodedString()
        default:
            throw ExtensionHost.Failure("Vane does not answer downloads.\(operation).")
        }
        return NSNull()
    }

    private func path(_ arguments: [String: Any]) throws -> [String]? {
        guard let filename = arguments["filename"] else { return nil }
        guard let filename = filename as? String, let path = ExtensionDownloadsAPI.relativePath(filename) else {
            throw ExtensionHost.Failure("Invalid filename.")
        }
        return path
    }

    /// The request as the extension asked for it: http(s) with the profile's cookies (and
    /// HTTPS-Only's upgrade), or a data: URL. Anything else fails before it reaches WebKit.
    private func request(_ arguments: [String: Any]) throws -> URLRequest {
        guard let raw = arguments["url"] as? String, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https", "data"].contains(scheme),
              scheme == "data" || url.host?.isEmpty == false else { throw ExtensionHost.Failure("Invalid URL.") }
        guard ["uniquify", "overwrite", "prompt"].contains(arguments["conflictAction"] as? String ?? "uniquify") else {
            throw ExtensionHost.Failure("Invalid conflictAction.")
        }
        var request = scheme == "data" ? URLRequest(url: url) : HTTPSOnly.downloadRequest(url, profileID: profileID)
        let method = (arguments["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST"].contains(method) else { throw ExtensionHost.Failure("Invalid method.") }
        request.httpMethod = method
        for case let pair as [String] in arguments["headers"] as? [Any] ?? [] {
            guard pair.count == 2, !pair[0].isEmpty,
                  pair[0].unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic || "0123456789!#$%&'*+-.^_`|~".unicodeScalars.contains($0) }),
                  !pair[1].contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
                throw ExtensionHost.Failure("Invalid request header name.")
            }
            guard !ExtensionDownloadsAPI.unsafeHeader(pair[0]) else { throw ExtensionHost.Failure("Unsafe request header name.") }
            request.setValue(pair[1], forHTTPHeaderField: pair[0])
        }
        if method == "POST", let body = arguments["body"] as? String { request.httpBody = Data(body.utf8) }
        return request
    }
}
