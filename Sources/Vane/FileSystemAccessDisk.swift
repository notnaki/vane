import Foundation
import UniformTypeIdentifiers

/// What a page is told when a file operation fails: a DOMException name (or `TypeError`)
/// and the text Chrome uses for it.
struct FileAccessError: Error, Equatable, Sendable {
    let name: String
    let message: String

    static func type(_ message: String) -> FileAccessError { FileAccessError(name: "TypeError", message: message) }
    static func notAllowed(_ message: String = "The request is not allowed by the user agent or the platform in the current context.")
        -> FileAccessError { FileAccessError(name: "NotAllowedError", message: message) }
    static let badName = type("Name is not allowed.")
    static let abort = FileAccessError(name: "AbortError", message: "The user aborted a request.")
    static let notFound = FileAccessError(
        name: "NotFoundError", message: "A requested file or directory could not be found at the time an operation was processed.")
    static let typeMismatch = FileAccessError(name: "TypeMismatchError", message: "The path supplied exists, but was not an entry of requested type.")
    static let notEmpty = FileAccessError(name: "InvalidModificationError", message: "The object can not be modified in this way.")
    static let changed = FileAccessError(
        name: "NotReadableError", message: "The requested file could not be read, typically due to permission problems that have occurred after a reference to a file was acquired.")
    /// A symlink that leads out of the folder the user picked. Never followed.
    static let escapes = notAllowed("This entry points outside the folder you picked.")

    static func errno(_ code: Int32 = Darwin.errno) -> FileAccessError {
        switch code {
        case ENOENT: .notFound
        case ENOTDIR, EISDIR: .typeMismatch
        case ENOTEMPTY: .notEmpty
        case EACCES, EPERM, EROFS: .notAllowed()
        case ENOSPC, EDQUOT: FileAccessError(name: "QuotaExceededError", message: "There is not enough space on the disk.")
        default: FileAccessError(name: "InvalidStateError", message: String(cString: strerror(code)))
        }
    }
}

/// Everything the File System Access API does to the disk. Nothing here knows about pages,
/// origins or grants (see FileSystemAccess.swift); it is handed a root the user picked and
/// names the page supplied, and it never touches anything outside that root.
///
/// A root is the real path (`realpath(3)`) of what was picked, taken when it was picked.
/// Every operation resolves its entry again and checks the result is still inside, so a
/// symlink that leads out is refused at the moment it is used, whatever it pointed at
/// earlier. Names are single components: no `/`, no NUL, never `.` or `..`.
enum FileAccessDisk {
    enum Kind: String, Sendable { case file, directory }

    nonisolated static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    nonisolated static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    nonisolated static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Follows links; callers pass paths that are already real.
    nonisolated static func kind(_ path: String) -> Kind? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        default: return nil
        }
    }

    /// The real path of `components` under `root`. The root itself must still be where it
    /// was picked: a folder renamed, deleted, or swapped for a link is gone.
    nonisolated static func resolve(root: String, _ components: [String]) throws(FileAccessError) -> String {
        guard components.allSatisfy(isValidName) else { throw .badName }
        guard real(root) == root else { throw .notFound }
        guard let resolved = real(components.reduce(root) { $0 + "/" + $1 }) else { throw .notFound }
        guard contains(root, resolved) else { throw .escapes }
        return resolved
    }

    private nonisolated static func directory(root: String, _ components: [String]) throws(FileAccessError) -> String {
        let path = try resolve(root: root, components)
        guard kind(path) == .directory else { throw .typeMismatch }
        return path
    }

    /// `getFileHandle` / `getDirectoryHandle`: the entry exists with that kind afterwards.
    nonisolated static func child(root: String, _ components: [String], name: String, kind wanted: Kind,
                                  create: Bool) throws(FileAccessError) {
        guard isValidName(name) else { throw .badName }
        let parent = try directory(root: root, components)
        let entry = parent + "/" + name
        if let resolved = real(entry) {
            guard contains(root, resolved) else { throw .escapes }
            guard kind(resolved) == wanted else { throw .typeMismatch }
            return
        }
        var info = stat()
        if lstat(entry, &info) == 0 { throw .escapes }    // a dangling link is not nothing
        guard create else { throw .notFound }
        if wanted == .directory {
            guard mkdir(entry, 0o777) == 0 || Darwin.errno == EEXIST else { throw .errno() }
        } else {
            let fd = open(entry, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o666)
            guard fd >= 0 else { throw .errno() }
            close(fd)
        }
        guard kind(try resolve(root: root, components + [name])) == wanted else { throw .typeMismatch }
    }

    /// A directory's entries. Links are listed only when they land inside the root; sockets,
    /// devices and dangling links are left out, as Chrome leaves them out.
    nonisolated static func list(root: String, _ components: [String]) throws(FileAccessError) -> [(name: String, kind: Kind)] {
        let path = try directory(root: root, components)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { throw .notFound }
        return names.compactMap { name in
            guard isValidName(name) else { return nil }
            let entry = path + "/" + name
            var info = stat()
            guard lstat(entry, &info) == 0 else { return nil }
            switch info.st_mode & S_IFMT {
            case S_IFREG: return (name, .file)
            case S_IFDIR: return (name, .directory)
            case S_IFLNK:
                guard let resolved = real(entry), contains(root, resolved), let kind = kind(resolved) else { return nil }
                return (name, kind)
            default: return nil
            }
        }
    }

    /// `removeEntry`. A link is removed itself, never what it points at.
    nonisolated static func remove(root: String, _ components: [String], name: String,
                                   recursive: Bool) throws(FileAccessError) {
        guard isValidName(name) else { throw .badName }
        let entry = try directory(root: root, components) + "/" + name
        var info = stat()
        guard lstat(entry, &info) == 0 else { throw .notFound }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            // Hidden from `list` when it leads out, so it is not there to remove either.
            guard let resolved = real(entry), contains(root, resolved), kind(resolved) != nil else { throw .notFound }
            guard unlink(entry) == 0 else { throw .errno() }
        case S_IFREG:
            guard unlink(entry) == 0 else { throw .errno() }
        case S_IFDIR:
            if rmdir(entry) == 0 { return }
            guard Darwin.errno == ENOTEMPTY || Darwin.errno == EEXIST else { throw .errno() }
            guard recursive else { throw .notEmpty }
            // FileManager removes links inside as links; it does not descend through them.
            do { try FileManager.default.removeItem(atPath: entry) } catch { throw .errno(EACCES) }
        default: throw .notFound
        }
    }

    /// `resolve()` and `isSameEntry()` across roots: the components from one real path to another.
    nonisolated static func relative(from parent: String, to child: String) -> [String]? {
        if parent == child { return [] }
        guard child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/") else { return nil }
        return child.dropFirst(parent.count).split(separator: "/").map(String.init)
    }

    // MARK: - Reading

    struct Chunk: Sendable {
        let data: Data
        let size: Int64
        /// Milliseconds since 1970, as `File.lastModified` has it.
        let modified: Int64
    }

    /// One piece of a file. `expect` is the size and time the first piece saw: a file that
    /// changes while it is being read is an error, as it is for a `File` in Chrome.
    nonisolated static func read(_ path: String, at offset: Int64, length: Int,
                                 expect: (size: Int64, modified: Int64)?) throws(FileAccessError) -> Chunk {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw .errno() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .errno() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .typeMismatch }
        let size = Int64(info.st_size)
        let modified = Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000
        if let expect, expect.size != size || expect.modified != modified { throw .changed }
        let count = Int(max(0, min(Int64(length), size - max(0, offset))))
        var data = Data(count: count)
        var done = 0
        while done < count {
            let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            if n < 0, Darwin.errno == EINTR { continue }
            guard n > 0 else { throw n == 0 ? .changed : .errno() }
            done += n
        }
        return Chunk(data: data, size: size, modified: modified)
    }

    nonisolated static func mimeType(of name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "" : UTType(filenameExtension: ext)?.preferredMIMEType ?? ""
    }

    // MARK: - Writing

    /// A `createWritable()` stream's file. Writes go to a copy and replace the original only
    /// on `close()`, so an abandoned, aborted or crashed write leaves the file as it was.
    /// FileSystemAccess lets one call at a time use one of these.
    final class Swap: @unchecked Sendable {
        let temp: String
        /// The item-replacement directory holding `temp`, removed with it.
        let holder: String?
        var fd: Int32
        var cursor: Int64 = 0
        init(temp: String, holder: String?, fd: Int32) { self.temp = temp; self.holder = holder; self.fd = fd }
    }

    /// The copy lives where macOS's own safe-save puts it (`.itemReplacementDirectory`, on the
    /// target's volume), because a sandboxed app picked a single file may not create files
    /// beside it. Where that is refused, beside the target like Chrome's `.crswap`.
    nonisolated static func openSwap(_ target: String, keepExistingData: Bool) throws(FileAccessError) -> Swap {
        guard kind(target) == .file else { throw .typeMismatch }
        let url = URL(fileURLWithPath: target)
        let holder = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: url, create: true).path
        let temp = holder.map { $0 + "/" + url.lastPathComponent }
            ?? target + "." + String(UInt32.random(in: 0...UInt32.max), radix: 36) + ".crswap"
        func clean() {
            unlink(temp)
            if let holder { rmdir(holder) }
        }
        if keepExistingData {
            // A clone on APFS: instant, whatever the size.
            guard copyfile(target, temp, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_EXCL)) == 0 else {
                let code = Darwin.errno; clean(); throw .errno(code)
            }
        }
        let fd = open(temp, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (keepExistingData ? 0 : O_EXCL), 0o644)
        guard fd >= 0 else { let code = Darwin.errno; clean(); throw .errno(code) }
        return Swap(temp: temp, holder: holder, fd: fd)
    }

    /// At `position` when given (past the end leaves zeros between), else at the cursor.
    nonisolated static func write(_ swap: Swap, _ data: Data, at position: Int64?) throws(FileAccessError) {
        if let position { swap.cursor = position }
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { pwrite(swap.fd, $0.baseAddress! + done, data.count - done, off_t(swap.cursor) + off_t(done)) }
            if n < 0, Darwin.errno == EINTR { continue }
            guard n > 0 else { throw .errno() }
            done += n
        }
        swap.cursor += Int64(done)
    }

    nonisolated static func truncate(_ swap: Swap, to size: Int64) throws(FileAccessError) {
        guard ftruncate(swap.fd, off_t(size)) == 0 else { throw .errno() }
        swap.cursor = min(swap.cursor, size)
    }

    /// `close()`: the copy replaces `target`, which is resolved again first. The original's
    /// permissions and other metadata are kept.
    nonisolated static func commit(_ swap: Swap, root: String, _ components: [String]) throws(FileAccessError) -> String {
        defer { discard(swap) }
        guard fsync(swap.fd) == 0 else { throw .errno() }
        close(swap.fd)
        swap.fd = -1
        let target = try resolve(root: root, components)
        guard kind(target) == .file else { throw .typeMismatch }
        do {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: swap.temp))
        } catch {
            // Not the error's own text: that names the real path, which the page never sees.
            throw .errno(EIO)
        }
        return target
    }

    /// `abort()`, a failed write, or the document going away: the copy goes, the file stays.
    nonisolated static func discard(_ swap: Swap) {
        if swap.fd >= 0 { close(swap.fd); swap.fd = -1 }
        unlink(swap.temp)
        if let holder = swap.holder { rmdir(holder) }
    }

    // MARK: - What may be picked

    /// Chromium's blocklist (chrome_file_system_access_permission_context.cc), in real paths.
    /// `children` says whether things inside may still be picked: the home folder itself
    /// can't be shared, a project folder inside it can. The deepest rule that covers a path
    /// decides.
    struct Rule: Equatable, Sendable {
        let path: String
        let children: Bool
    }

    nonisolated static func rules(home: String, extra: [String] = []) -> [Rule] {
        let open = ["/", "/Users", "/Volumes", "/private/tmp", "/private/var/folders",
                    home, home + "/Desktop", home + "/Documents", home + "/Downloads",
                    // Cloud drives and other apps' sandboxed documents, as Chrome allows.
                    home + "/Library/CloudStorage", home + "/Library/Containers",
                    home + "/Library/Mobile Documents", home + "/Library/Mobile Documents/com~apple~CloudDocs"]
        let closed = [home + "/Library", home + "/.ssh", home + "/.gnupg", home + "/Applications",
                      "/System", "/Library", "/Applications", "/bin", "/sbin", "/usr", "/dev", "/private", "/cores"] + extra
        return open.map { Rule(path: $0, children: true) } + closed.map { Rule(path: $0, children: false) }
    }

    nonisolated static func isBlocked(_ path: String, rules: [Rule]) -> Bool {
        guard let rule = rules.filter({ contains($0.path, path) }).max(by: { $0.path.count < $1.path.count }) else { return false }
        return rule.path == path || !rule.children
    }

    /// The real home folder: inside the sandbox `NSHomeDirectory()` is the container.
    nonisolated static var home: String {
        let path = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return real(path) ?? path
    }

    /// This app and its own data are never a site's to read.
    nonisolated static var defaultRules: [Rule] {
        let home = home
        var extra = [Bundle.main.bundleURL.path]
        if let container = real(NSHomeDirectory()), container != home { extra.append(container) }
        return rules(home: home, extra: extra.compactMap { real($0) })
    }

    /// What the picker returned, made real and checked. A save target that doesn't exist is
    /// created empty; one that does is left as it is until the page writes to it.
    nonisolated static func picked(_ path: String, kind wanted: Kind, create: Bool,
                                   rules: [Rule]) throws(FileAccessError) -> String {
        if create, real(path) == nil {
            var info = stat()
            guard lstat(path, &info) != 0 else { throw .escapes }
            let fd = open(path, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o666)
            guard fd >= 0 else { throw .errno() }
            close(fd)
        }
        guard let resolved = real(path) else { throw .notFound }
        guard !isBlocked(path, rules: rules), !isBlocked(resolved, rules: rules) else {
            throw .notAllowed("This location contains system files and can't be opened by a website.")
        }
        guard kind(resolved) == wanted else { throw .typeMismatch }
        return resolved
    }
}
