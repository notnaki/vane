import Foundation
import Darwin
import CryptoKit

/// A crash-recoverable app-bundle replacement. All paths written by a transaction are
/// siblings of its target, so staging and the final rename stay on the same volume.
enum BundleReplacement {
    enum Fault: Error {
        case injected, busy, invalidStage, staleTarget, unsupportedSwap, filesystem
    }
    enum Step {
        case beforeCopy, afterCopy, beforeStageSync, beforeJournal,
             beforeJournalSync, beforeSwap, afterSwapBeforeSync, afterSwap,
             afterLaunchJournal, beforeRollback, afterRollback,
             afterHealthyJournal, beforeCleanup, afterCleanup
    }
    enum Launch { case unchanged, waitingForHealth, rolledBack, needsAttention }

    private enum State: String, Codable { case prepared, launching, healthy }
    private struct Journal: Codable {
        let stageName: String
        let newID: UInt64
        let oldID: UInt64?
        let keepPrevious: Bool
        var state: State
        var launchPID: Int32?
        var launchStart: UInt64?
        var launchDeadline: TimeInterval? = nil
        // Optional only to decode transactions written by an older Vane. Those require
        // independent bundle verification before they can be upgraded or recovered.
        var targetPath: String? = nil
        var volumeID: UInt64? = nil
        var newDigest: String? = nil
        var oldDigest: String? = nil
    }

    private static func journalURL(_ target: URL) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).vane-transaction.json")
    }

    private static func lockURL(_ target: URL) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).vane-transaction.lock")
    }

    private static func stageURL(_ target: URL, _ journal: Journal) -> URL? {
        // A journal is a file on disk, not authority to delete an arbitrary path.
        let prefix = ".\(target.lastPathComponent).vane-stage-"
        guard journal.stageName.hasPrefix(prefix),
              UUID(uuidString: String(journal.stageName.dropFirst(prefix.count))) != nil,
              journal.stageName == (journal.stageName as NSString).lastPathComponent
        else { return nil }
        return target.deletingLastPathComponent().appendingPathComponent(journal.stageName)
    }

    private static func orphanStages(_ target: URL) -> [URL] {
        let prefix = ".\(target.lastPathComponent).vane-stage-"
        let parent = target.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(at: parent,
                    includingPropertiesForKeys: nil)) ?? []).filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix(prefix)
                && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
    }

    private static func removeOrphanStages(_ target: URL) throws {
        // A live transaction owns its stage. Only unjournaled, generated names are ours
        // to discard; the lock also excludes another process while it is copying.
        guard !entryExists(journalURL(target)) else { return }
        for stage in orphanStages(target) { try FileManager.default.removeItem(at: stage) }
    }

    private static func backupURL(_ stage: URL) -> URL {
        stage.deletingLastPathComponent().appendingPathComponent(
            stage.lastPathComponent.replacingOccurrences(of: ".vane-stage-",
                                                          with: ".vane-backup-"))
    }

    private static func sync(_ url: URL, directory: Bool) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw filesystemError(url) }
        defer { close(descriptor) }
        // F_FULLFSYNC requests that macOS flush the device cache as well as the file.
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw filesystemError(url) }
    }

    private static func syncTree(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw Fault.filesystem }
        switch metadata.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            for child in try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: nil) {
                try syncTree(child)
            }
            try sync(url, directory: true)
        case mode_t(S_IFREG):
            try sync(url, directory: false)
        case mode_t(S_IFLNK):
            // The parent directory sync persists the symlink itself.
            break
        default:
            throw Fault.filesystem
        }
    }

    static func processStart(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    enum ParentExit { case waiting, exited, unavailable }
    static func parentExit(_ pid: Int32, start: UInt64,
                           observeStart: (Int32) -> UInt64? = processStart,
                           exists: (Int32) -> Bool = { kill($0, 0) == 0 || errno != ESRCH }) -> ParentExit {
        if let observed = observeStart(pid) { return observed == start ? .waiting : .exited }
        return exists(pid) ? .unavailable : .exited
    }

    private static let fallbackLease: TimeInterval = 120

    private static func sameProcess(_ pid: Int32, _ start: UInt64?,
                                    _ deadline: TimeInterval?) -> Bool {
        sameProcess(start: start, deadline: deadline, observedStart: processStart(pid),
                    pidExists: { kill(pid, 0) == 0 || errno == EPERM },
                    now: Date().timeIntervalSince1970)
    }

    private static func sameProcess(start: UInt64?, deadline: TimeInterval?,
                                    observedStart: UInt64?, pidExists: () -> Bool,
                                    now: TimeInterval) -> Bool {
        if let start, let observedStart { return observedStart == start }
        // proc_pidinfo can be denied for a protected PID while kill(pid, 0) still
        // reports EPERM. Trust that weaker check only during the startup lease.
        guard let deadline, deadline > now, deadline - now <= fallbackLease else {
            return false
        }
        return pidExists()
    }

    /// Kernel vnode path follows an executable when its bundle is atomically exchanged.
    /// argv/Bundle.main paths alone can still name the new copy under an old process.
    static func executing(_ expected: URL) -> Bool {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
            == expected.resolvingSymlinksInPath()
    }

    private static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func metadata(_ url: URL, type: mode_t) -> stat? {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & mode_t(S_IFMT) == type else { return nil }
        return value
    }

    private static func fileID(_ url: URL) -> UInt64? {
        metadata(url, type: mode_t(S_IFDIR)).map { UInt64($0.st_ino) }
    }

    /// A directory inode survives edits and partial recursive deletion. Snapshot all
    /// bundle contents, permissions and link destinations, without following symlinks.
    private static func digest(_ root: URL) throws -> String {
        guard fileID(root) != nil else { throw Fault.invalidStage }
        var hash = SHA256()
        func field(_ value: String) {
            let data = Data(value.utf8)
            hash.update(data: Data("\(data.count):".utf8))
            hash.update(data: data)
        }
        func visit(_ url: URL, relative: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw filesystemError(url) }
            field(relative); field(String(info.st_mode))
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                for child in try FileManager.default.contentsOfDirectory(at: url,
                        includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    if relative.isEmpty, child.lastPathComponent == "Icon\r" { continue }
                    try visit(child, relative: relative + "/" + child.lastPathComponent)
                }
            case mode_t(S_IFREG):
                field(String(info.st_size))
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw filesystemError(url) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    hash.update(data: data)
                }
            case mode_t(S_IFLNK):
                field(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            default: throw Fault.invalidStage
            }
        }
        try visit(root, relative: "")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func filesystemError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path])
    }

    private static func intact(_ url: URL, _ expected: String?) -> Bool {
        guard let expected else { return false }
        return (try? digest(url)) == expected
    }

    private static func bound(_ journal: Journal, to target: URL) -> Bool {
        journal.targetPath == target.standardizedFileURL.path
            && journal.volumeID == metadata(target.deletingLastPathComponent(), type: mode_t(S_IFDIR)).map { UInt64($0.st_dev) }
            && journal.newDigest != nil && (journal.oldID == nil || journal.oldDigest != nil || journal.state == .healthy)
    }

    private static func read(_ target: URL) -> Journal? {
        guard metadata(journalURL(target), type: mode_t(S_IFREG)) != nil,
              let data = try? Data(contentsOf: journalURL(target)) else { return nil }
        return try? JSONDecoder().decode(Journal.self, from: data)
    }

    private static func write(_ journal: Journal, for target: URL,
                              durable: Bool = true) throws {
        try JSONEncoder().encode(journal).write(to: journalURL(target), options: .atomic)
        if durable { try syncJournal(target) }
    }

    private static func syncJournal(_ target: URL) throws {
        try sync(journalURL(target), directory: false)
        try sync(target.deletingLastPathComponent(), directory: true)
    }

    private static func withLock<T>(_ target: URL, _ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL(target).path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw filesystemError(lockURL(target)) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Fault.busy }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Swaps two existing directory names in one operation. Unsupported filesystems fail
    /// closed: the old target stays at its original path and the staged copy is removed.
    private static func swap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { a in
            second.path.withCString { b in
                renameatx_np(AT_FDCWD, a, AT_FDCWD, b, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            if errno == ENOTSUP || errno == EOPNOTSUPP || errno == EINVAL {
                throw Fault.unsupportedSwap
            }
            throw filesystemError(first)
        }
    }

    /// The empty-destination case is an exclusive, same-volume rename. A concurrent app
    /// that appeared at the target cannot be overwritten by a stale relocation decision.
    private static func moveIntoEmptyTarget(_ stage: URL, _ target: URL) throws {
        let result = stage.path.withCString { a in
            target.path.withCString { b in renamex_np(a, b, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else { throw filesystemError(target) }
    }

    /// The caller supplies the same signature check it used on the unpacked source. It is
    /// run again on the *copied* bundle before any installed bundle can move. The target
    /// policy is mandatory and runs under the transaction lock at both decision points.
    static func install(source: URL, at target: URL, keepPrevious: Bool,
                        verify: (URL) throws -> Bool,
                        mayReplaceTarget: (URL) -> Bool,
                        prepare: (URL) throws -> Void = { _ in },
                        fault: ((Step) -> Bool)? = nil,
                        swapOperation: (URL, URL) throws -> Void = swap) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try withLock(target) {
            // The original copy can be reopened from Downloads after an interruption
            // before the swap. Clear only that provably uncommitted transaction so it can
            // retry; a transaction whose new bundle reached the target belongs to launch
            // recovery and must not be overwritten by this process.
            if let pending = read(target), pending.state == .prepared,
               let priorStage = stageURL(target, pending),
               bound(pending, to: target),
               fileID(target) == pending.oldID, (fileID(priorStage) == pending.newID || !entryExists(priorStage)),
               pending.oldID == nil || intact(target, pending.oldDigest) {
                if entryExists(priorStage) { try fm.removeItem(at: priorStage) }
                try fm.removeItem(at: journalURL(target))
            }
            guard !entryExists(journalURL(target)) else { throw Fault.busy }
            try removeOrphanStages(target)
            guard target.standardizedFileURL == target.resolvingSymlinksInPath(),
                  mayReplaceTarget(target) else { throw Fault.staleTarget }
            let originalID = fileID(target)
            let originalDigest = originalID == nil ? nil : try digest(target)
            let stage = target.deletingLastPathComponent().appendingPathComponent(
                ".\(target.lastPathComponent).vane-stage-\(UUID().uuidString)")
            var committed = false
            var journalWritten = false
            defer {
                if !committed {
                    try? fm.removeItem(at: stage)
                    if journalWritten { try? fm.removeItem(at: journalURL(target)) }
                }
            }
            if fault?(.beforeCopy) == true { throw Fault.injected }
            try fm.copyItem(at: source, to: stage)
            if fault?(.afterCopy) == true { throw Fault.injected }
            guard try verify(stage), let newID = fileID(stage) else { throw Fault.invalidStage }
            // Installer preparation happens on the final, verified copy while the
            // transaction lock is held and before any journal or swap is committed.
            try prepare(stage)
            if fault?(.beforeStageSync) == true { throw Fault.injected }
            try syncTree(stage)
            try sync(target.deletingLastPathComponent(), directory: true)
            let oldID = originalID
            var journal = Journal(stageName: stage.lastPathComponent, newID: newID,
                                  oldID: oldID, keepPrevious: keepPrevious, state: .prepared,
                                  launchPID: nil, launchStart: nil)
            journal.targetPath = target.standardizedFileURL.path
            journal.volumeID = metadata(target.deletingLastPathComponent(), type: mode_t(S_IFDIR)).map { UInt64($0.st_dev) }
            journal.newDigest = try digest(stage)
            journal.oldDigest = originalDigest
            if fault?(.beforeJournal) == true { throw Fault.injected }
            journalWritten = true
            try write(journal, for: target, durable: false)
            if fault?(.beforeJournalSync) == true { throw Fault.injected }
            try syncJournal(target)
            if fault?(.beforeSwap) == true { throw Fault.injected }
            // Another Vane installer cannot mutate this target while we hold the lock.
            // Also refuse an external change that happened while staging the copy.
            guard fileID(target) == oldID, mayReplaceTarget(target),
                  oldID == nil || intact(target, originalDigest),
                  intact(stage, journal.newDigest), try verify(stage) else {
                throw Fault.staleTarget
            }
            if oldID != nil { try swapOperation(target, stage) }
            else { try moveIntoEmptyTarget(stage, target) }
            committed = true
            if fault?(.afterSwapBeforeSync) == true { throw Fault.injected }
            try sync(target.deletingLastPathComponent(), directory: true)
            if fault?(.afterSwap) == true { throw Fault.injected }
        }
    }

    /// Run before opening a window. A prepared transaction that never swapped is discarded.
    /// A second attempt to start a replacement that never reached a healthy launch swaps
    /// the old bundle back, then asks the caller to relaunch that restored bundle.
    static func beginLaunch(at target: URL,
                            processAlive: (Int32, UInt64?, TimeInterval?) -> Bool = sameProcess,
                            verifyRecovery: ((URL) -> Bool)? = nil,
                            verifyPrevious: ((URL) -> Bool)? = nil,
                            expectedExecutable: URL? = nil,
                            fault: ((Step) -> Bool)? = nil) -> Launch {
        guard entryExists(journalURL(target)) else {
            if !orphanStages(target).isEmpty {
                _ = try? withLock(target) { try removeOrphanStages(target) }
            }
            return .unchanged
        }
        do { return try withLock(target) {
            let fm = FileManager.default
            guard target.standardizedFileURL == target.resolvingSymlinksInPath(),
                  var journal = read(target), let stage = stageURL(target, journal),
                  expectedExecutable.map(executing) != false else {
                return Launch.needsAttention
            }
            let targetID = fileID(target), stageID = fileID(stage)
            let previousVerifier = verifyPrevious ?? verifyRecovery
            if !bound(journal, to: target) {
                // A legacy journal has no content snapshot. Only independently verified
                // bundles can authorize migration; malformed/current records fail closed.
                guard journal.targetPath == nil, journal.volumeID == nil,
                      journal.newDigest == nil, journal.oldDigest == nil,
                      let verifyRecovery else { return Launch.needsAttention }
                if targetID == journal.oldID, previousVerifier?(target) == true,
                   stageID == journal.newID || !entryExists(stage) {
                    journal.oldDigest = try digest(target)
                    journal.newDigest = stageID == nil ? "discarded" : try digest(stage)
                } else if targetID == journal.newID {
                    let newVerified = verifyRecovery(target)
                    if journal.oldID != nil {
                        if stageID == journal.oldID, previousVerifier?(stage) == true {
                            journal.oldDigest = try digest(stage)
                            if !newVerified { journal.state = .launching }
                        } else if newVerified, journal.state == .healthy, !entryExists(stage), !journal.keepPrevious {
                            // The durable healthy record precedes old-bundle deletion.
                        } else if newVerified, journal.state == .healthy, journal.keepPrevious,
                                  fileID(backupURL(stage)) == journal.oldID, previousVerifier?(backupURL(stage)) == true {
                            journal.oldDigest = try digest(backupURL(stage))
                        } else { return Launch.needsAttention }
                    } else if entryExists(stage) || !newVerified { return Launch.needsAttention }
                    journal.newDigest = newVerified ? try digest(target) : "rejected"
                } else { return Launch.needsAttention }
                journal.targetPath = target.standardizedFileURL.path
                journal.volumeID = metadata(target.deletingLastPathComponent(), type: mode_t(S_IFDIR)).map { UInt64($0.st_dev) }
                try write(journal, for: target)
            }
            if targetID == journal.oldID,
               stageID == journal.newID || !entryExists(stage),
               journal.oldID == nil || intact(target, journal.oldDigest) {
                // The app crashed before the rename; the original installation is intact.
                if stageID != nil { try fm.removeItem(at: stage) }
                try fm.removeItem(at: journalURL(target))
                try sync(target.deletingLastPathComponent(), directory: true)
                return .unchanged
            }
            if journal.state == .healthy, targetID == journal.newID,
               intact(target, journal.newDigest), verifyRecovery?(target) != false {
                // Cleanup may have removed the old bundle and crashed before deleting the
                // journal. Missing stage is valid only in this already-healthy state.
                if let stageID, journal.oldID != stageID { return .needsAttention }
                finish(journal, stage: stage, target: target, fault: fault)
                return .unchanged
            }
            guard targetID == journal.newID,
                  journal.oldID == nil ? !entryExists(stage) : stageID == journal.oldID else {
                return .needsAttention
            }
            if journal.oldID != nil, journal.state == .launching || !intact(target, journal.newDigest) || verifyRecovery?(target) == false {
                if let pid = journal.launchPID,
                   processAlive(pid, journal.launchStart, journal.launchDeadline) {
                    // Another copy is still starting. Its health decision owns this
                    // transaction; a second launch must not roll it back underneath it.
                    return .needsAttention
                }
                guard intact(stage, journal.oldDigest), previousVerifier?(stage) != false else { return .needsAttention }
                if fault?(.beforeRollback) == true { throw Fault.injected }
                try swap(target, stage)
                if fault?(.afterRollback) == true { throw Fault.injected }
                try sync(target.deletingLastPathComponent(), directory: true)
                // Only the staged failed version is removed. The restored old app is now
                // at the original target path and can be opened by the caller.
                try fm.removeItem(at: stage)
                try fm.removeItem(at: journalURL(target))
                try sync(target.deletingLastPathComponent(), directory: true)
                return .rolledBack
            }
            guard intact(target, journal.newDigest), verifyRecovery?(target) != false else { return .needsAttention }
            journal.state = .launching
            journal.launchPID = getpid()
            journal.launchStart = processStart(getpid())
            journal.launchDeadline = Date().timeIntervalSince1970 + fallbackLease
            try write(journal, for: target)
            if fault?(.afterLaunchJournal) == true { throw Fault.injected }
            return .waitingForHealth
        } } catch {
            NSLog("[vane] update recovery at %@ failed: %@", target.path, String(describing: error))
            return .needsAttention
        }
    }

    static func hasPendingRecord(at target: URL) -> Bool { entryExists(journalURL(target)) }

    struct LaunchWitness {
        fileprivate let targetPath: String
        fileprivate let volumeID: UInt64
        fileprivate let oldID: UInt64?
        fileprivate let oldDigest: String?
        fileprivate let newID: UInt64
        fileprivate let newDigest: String
    }

    /// Read-only evidence retained by the unsandboxed supervisor while browser
    /// bootstrap may finish a rollback and remove its journal.
    static func launchWitness(at target: URL, verifyReplacement: ((URL) -> Bool)? = nil,
                              verifyPrevious: ((URL) -> Bool)? = nil) -> LaunchWitness? {
        try? withLock(target) {
            guard let journal = read(target) else { return nil }
            if bound(journal, to: target), let newDigest = journal.newDigest,
               let volumeID = journal.volumeID {
                return LaunchWitness(targetPath: target.path, volumeID: volumeID,
                    oldID: journal.oldID, oldDigest: journal.oldDigest,
                    newID: journal.newID, newDigest: newDigest)
            }
            // Legacy records acquire read-only evidence only after independent
            // signatures and exact inode/path checks. Browser bootstrap still owns
            // migration and every mutation of the record.
            guard journal.targetPath == nil, journal.volumeID == nil,
                  journal.newDigest == nil, journal.oldDigest == nil,
                  target.standardizedFileURL == target.resolvingSymlinksInPath(),
                  fileID(target) == journal.newID, verifyReplacement?(target) == true,
                  let stage = stageURL(target, journal),
                  let volume = metadata(target.deletingLastPathComponent(), type: mode_t(S_IFDIR)).map({ UInt64($0.st_dev) }) else { return nil }
            if journal.oldID != nil, journal.state != .healthy {
                guard fileID(stage) == journal.oldID, verifyPrevious?(stage) == true else { return nil }
            }
            let oldDigest = fileID(stage) == journal.oldID && journal.oldID != nil
                && verifyPrevious?(stage) == true ? try digest(stage) : nil
            return LaunchWitness(targetPath: target.path, volumeID: volume,
                oldID: journal.oldID, oldDigest: oldDigest,
                newID: journal.newID, newDigest: try digest(target))
        }
    }

    static func isRestoredPrevious(at target: URL, witness: LaunchWitness,
                                   verifyPrevious: (URL) -> Bool) -> Bool {
        (try? withLock(target) {
            witness.oldID != nil && witness.oldDigest != nil
                && !entryExists(journalURL(target)) && target.path == witness.targetPath
                && target.standardizedFileURL == target.resolvingSymlinksInPath()
                && metadata(target.deletingLastPathComponent(), type: mode_t(S_IFDIR)).map({ UInt64($0.st_dev) }) == witness.volumeID
                && fileID(target) == witness.oldID
                && intact(target, witness.oldDigest) && verifyPrevious(target)
        }) == true
    }

    static func hasCompletedReplacement(at target: URL, witness: LaunchWitness,
                                         verifyReplacement: (URL) -> Bool) -> Bool {
        (try? withLock(target) {
            let pending = entryExists(journalURL(target))
            let journal = pending ? read(target) : nil
            if pending {
                guard let journal, bound(journal, to: target), journal.state == .healthy,
                      journal.newID == witness.newID, journal.newDigest == witness.newDigest else { return false }
            }
            guard target.path == witness.targetPath,
                  target.standardizedFileURL == target.resolvingSymlinksInPath(),
                  metadata(target.deletingLastPathComponent(), type: mode_t(S_IFDIR)).map({ UInt64($0.st_dev) }) == witness.volumeID,
                  fileID(target) == witness.newID, intact(target, witness.newDigest),
                  verifyReplacement(target) else { return false }
            return true
        }) == true
    }

    static func launchClaimed(at target: URL, by pid: Int32,
                              observeStart: (Int32) -> UInt64? = processStart) -> Bool {
        guard let journal = read(target), let recordedStart = journal.launchStart,
              let observedStart = observeStart(pid) else { return false }
        return bound(journal, to: target) && journal.state == .launching
            && journal.launchPID == pid && recordedStart == observedStart
            && fileID(target) == journal.newID
    }

    static func awaitingBootstrap(at target: URL) -> Bool {
        guard let journal = read(target) else { return false }
        return bound(journal, to: target) && journal.state == .prepared && fileID(target) == journal.newID
    }

    /// The detached relaunch helper calls this only after proving no application remains
    /// at this destination. A replacement that died before browser bootstrap never wrote
    /// a launching journal, so normal next-launch recovery cannot run inside it.
    static func restoreUnlaunched(at target: URL, verifyPrevious: (URL) -> Bool,
                                  fault: ((Step) -> Bool)? = nil) throws -> Launch {
        guard entryExists(journalURL(target)) else { return .unchanged }
        return try withLock(target) {
            guard let journal = read(target), let stage = stageURL(target, journal),
                  target.standardizedFileURL == target.resolvingSymlinksInPath(),
                  bound(journal, to: target) else { return .needsAttention }
            // A process that reached bootstrap owns its own health/rollback decision.
            guard journal.state == .prepared else { return .unchanged }
            guard fileID(target) == journal.newID, let oldID = journal.oldID,
                  fileID(stage) == oldID, intact(stage, journal.oldDigest),
                  verifyPrevious(stage) else { return .needsAttention }
            if fault?(.beforeRollback) == true { throw Fault.injected }
            try swap(target, stage)
            if fault?(.afterRollback) == true { throw Fault.injected }
            try sync(target.deletingLastPathComponent(), directory: true)
            try FileManager.default.removeItem(at: stage)
            try FileManager.default.removeItem(at: journalURL(target))
            try sync(target.deletingLastPathComponent(), directory: true)
            return .rolledBack
        }
    }

    /// Called after AppKit has entered its run loop. A previous copy is retained until
    /// this point; a relocation leaves it on disk for the user, while an update removes it.
    static func markHealthy(at target: URL, verifyRecovery: ((URL) -> Bool)? = nil,
                            verifyPrevious: ((URL) -> Bool)? = nil,
                            expectedExecutable: URL? = nil, fault: ((Step) -> Bool)? = nil) {
        guard entryExists(journalURL(target)) else { return }
        _ = try? withLock(target) {
            guard var journal = read(target), let stage = stageURL(target, journal),
                  bound(journal, to: target),
                  target.standardizedFileURL == target.resolvingSymlinksInPath(),
                  intact(target, journal.newDigest), verifyRecovery?(target) != false,
                  expectedExecutable.map(executing) != false,
                  journal.state == .launching, journal.launchPID == getpid(),
                  journal.launchStart == processStart(getpid()),
                  fileID(target) == journal.newID,
                  journal.oldID == nil || (fileID(stage) == journal.oldID && intact(stage, journal.oldDigest) && (verifyPrevious ?? verifyRecovery)?(stage) != false) else { return }
            journal.state = .healthy
            try write(journal, for: target)
            if fault?(.afterHealthyJournal) == true { throw Fault.injected }
            finish(journal, stage: stage, target: target, fault: fault)
        }
    }

    private static func finish(_ journal: Journal, stage: URL, target: URL,
                               fault: ((Step) -> Bool)? = nil) {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        if fault?(.beforeCleanup) == true { return }
        if journal.keepPrevious, let oldID = journal.oldID {
            let backup = backupURL(stage)
            if fileID(stage) == oldID {
                do { try moveIntoEmptyTarget(stage, backup) } catch { return }
            } else if fileID(backup) != oldID {
                return
            }
        }
        if !journal.keepPrevious, let oldID = journal.oldID, fileID(stage) == oldID {
            do { try fm.removeItem(at: stage) } catch { return }
        }
        guard (try? sync(parent, directory: true)) != nil else { return }
        if fault?(.afterCleanup) == true { return }
        try? fm.removeItem(at: journalURL(target))
        try? sync(parent, directory: true)
    }

    /// Disposable directory fixtures exercise each failure boundary without touching an
    /// installed app, a release, or the user's application folders.
    static func check() -> [(String, Bool)] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "vane-bundle-transaction-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var results: [(String, Bool)] = []

        func bundle(_ url: URL, _ label: String) throws {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(label.utf8).write(to: url.appendingPathComponent("fixture"))
        }
        func label(_ url: URL) -> String? {
            (try? Data(contentsOf: url.appendingPathComponent("fixture")))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        func scene(_ name: String, old: Bool = true) throws -> (URL, URL) {
            let dir = root.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let source = dir.appendingPathComponent("incoming.app")
            let target = dir.appendingPathComponent("Vane.app")
            try bundle(source, "new")
            if old { try bundle(target, "old") }
            return (source, target)
        }
        func stages(_ target: URL) -> [URL] {
            let prefix = ".\(target.lastPathComponent).vane-stage-"
            return ((try? fm.contentsOfDirectory(at: target.deletingLastPathComponent(),
                                                 includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
        }
        func backups(_ target: URL) -> [URL] {
            let prefix = ".\(target.lastPathComponent).vane-backup-"
            return ((try? fm.contentsOfDirectory(at: target.deletingLastPathComponent(),
                                                 includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
        }
        let verify: (URL) -> Bool = { label($0) == "new" }
        func fixtureInstall(source: URL, at target: URL, keepPrevious: Bool,
                            verify: (URL) -> Bool,
                            fault: ((Step) -> Bool)? = nil,
                            swapOperation: ((URL, URL) throws -> Void)? = nil) throws {
            try install(source: source, at: target, keepPrevious: keepPrevious,
                        verify: verify, mayReplaceTarget: { _ in true },
                        fault: fault, swapOperation: swapOperation ?? BundleReplacement.swap)
        }

        do {
            let (source, target) = try scene("normal")
            try fixtureInstall(source: source, at: target, keepPrevious: false, verify: verify)
            results.append(("replacement is atomic and retains the old bundle before launch",
                            label(target) == "new" && stages(target).count == 1
                                && label(stages(target)[0]) == "old"))
            markHealthy(at: target)
            results.append(("the updating process cannot mark its own replacement healthy",
                            stages(target).count == 1
                                && entryExists(journalURL(target))))
            results.append(("first launch keeps the previous app until healthy",
                            beginLaunch(at: target) == .waitingForHealth
                                && stages(target).count == 1))
            markHealthy(at: target)
            results.append(("healthy update removes only its own previous copy",
                            stages(target).isEmpty && !entryExists(journalURL(target))
                                && label(target) == "new"))
        } catch { results.append(("normal replacement fixture", false)) }

        for (name, step) in [("before-copy", Step.beforeCopy),
                             ("after-copy", .afterCopy),
                             ("before-stage-sync", .beforeStageSync),
                             ("before-journal", .beforeJournal),
                             ("before-journal-sync", .beforeJournalSync),
                             ("before-swap", .beforeSwap)] {
            do {
                let (source, target) = try scene(name)
                do {
                    try fixtureInstall(source: source, at: target, keepPrevious: false,
                                verify: verify, fault: { $0 == step })
                } catch { /* expected */ }
                results.append(("\(name) failure preserves the installed app and cleans staging",
                                label(target) == "old" && stages(target).isEmpty
                                    && !entryExists(journalURL(target))))
            } catch { results.append(("\(name) fixture", false)) }
        }

        do {
            let (source, target) = try scene("unsupported-volume")
            do {
                try fixtureInstall(source: source, at: target, keepPrevious: false, verify: verify,
                            swapOperation: { _, _ in throw Fault.unsupportedSwap })
            } catch { /* expected */ }
            results.append(("unsupported atomic swap refuses the update safely",
                            label(target) == "old" && stages(target).isEmpty
                                && !entryExists(journalURL(target))))
        } catch { results.append(("unsupported-volume fixture", false)) }

        do {
            let (source, target) = try scene("invalid-copied-bundle")
            do {
                try fixtureInstall(source: source, at: target, keepPrevious: false,
                            verify: { _ in false })
            } catch { /* expected verification failure */ }
            results.append(("a failed check of the copied bundle leaves the old app in place",
                            label(target) == "old" && stages(target).isEmpty
                                && !entryExists(journalURL(target))))
        } catch { results.append(("invalid-copied-bundle fixture", false)) }

        do {
            let (source, target) = try scene("newer-installer-won")
            try Data("2".utf8).write(to: source.appendingPathComponent("fixture"))
            try Data("1".utf8).write(to: target.appendingPathComponent("fixture"))
            let preflightAllowed = label(target) == "1"
            // A second installer commits version 3 before this version 2 installer
            // acquires the transaction lock. Its old preflight result is stale.
            try Data("3".utf8).write(to: target.appendingPathComponent("fixture"))
            var rejected = false
            do {
                try install(source: source, at: target, keepPrevious: false,
                            verify: { label($0) == "2" },
                            mayReplaceTarget: { label($0) == "1" })
            } catch Fault.staleTarget { rejected = true }
            results.append(("older installer rejects a newer target under the lock",
                            preflightAllowed && rejected && label(target) == "3"
                                && stages(target).isEmpty
                                && !entryExists(journalURL(target))))
        } catch { results.append(("newer-installer-won fixture", false)) }

        do {
            let (source, target) = try scene("target-changed-during-stage")
            try Data("2".utf8).write(to: source.appendingPathComponent("fixture"))
            try Data("1".utf8).write(to: target.appendingPathComponent("fixture"))
            var checks = 0
            var rejected = false
            do {
                try install(source: source, at: target, keepPrevious: false,
                            verify: { label($0) == "2" },
                            mayReplaceTarget: { url in
                                checks += 1
                                return label(url) == "1"
                            },
                            fault: { step in
                                if step == .beforeSwap {
                                    try? Data("3".utf8).write(to: target.appendingPathComponent("fixture"))
                                }
                                return false
                            })
            } catch Fault.staleTarget { rejected = true }
            results.append(("target version is rechecked immediately before swap",
                            checks == 2 && rejected && label(target) == "3"
                                && stages(target).isEmpty
                                && !entryExists(journalURL(target))))
        } catch { results.append(("target-changed-during-stage fixture", false)) }

        do {
            let (_, target) = try scene("orphan-copy")
            let partial = target.deletingLastPathComponent().appendingPathComponent(
                ".\(target.lastPathComponent).vane-stage-\(UUID().uuidString)")
            try bundle(partial, "partial")
            results.append(("startup removes an unjournaled stage left by process death",
                            beginLaunch(at: target) == .unchanged && label(target) == "old"
                                && stages(target).isEmpty))
        } catch { results.append(("orphan-copy fixture", false)) }

        do {
            let (source, target) = try scene("orphan-retry")
            let partial = target.deletingLastPathComponent().appendingPathComponent(
                ".\(target.lastPathComponent).vane-stage-\(UUID().uuidString)")
            try bundle(partial, "partial")
            try fixtureInstall(source: source, at: target, keepPrevious: false, verify: verify)
            results.append(("retry cleans a dead copy before making a fresh stage",
                            label(target) == "new" && stages(target).count == 1
                                && label(stages(target)[0]) == "old"))
        } catch { results.append(("orphan-retry fixture", false)) }

        do {
            let (source, target) = try scene("interrupted-before-swap")
            let stage = target.deletingLastPathComponent().appendingPathComponent(
                ".\(target.lastPathComponent).vane-stage-\(UUID().uuidString)")
            try fm.copyItem(at: source, to: stage)
            guard let stagedID = fileID(stage) else { throw Fault.filesystem }
            var journal = Journal(stageName: stage.lastPathComponent, newID: stagedID,
                                  oldID: fileID(target), keepPrevious: false, state: .prepared,
                                  launchPID: nil, launchStart: nil)
            journal.targetPath = target.standardizedFileURL.path
            journal.volumeID = metadata(target.deletingLastPathComponent(), type: mode_t(S_IFDIR)).map { UInt64($0.st_dev) }
            journal.newDigest = try digest(stage)
            journal.oldDigest = try digest(target)
            try write(journal, for: target)
            results.append(("startup cleans an interrupted pre-swap transaction",
                            beginLaunch(at: target) == .unchanged && label(target) == "old"
                                && stages(target).isEmpty
                                && !entryExists(journalURL(target))))
        } catch { results.append(("interrupted-before-swap fixture", false)) }

        do {
            let (source, target) = try scene("retry-before-swap")
            let stage = target.deletingLastPathComponent().appendingPathComponent(
                ".\(target.lastPathComponent).vane-stage-\(UUID().uuidString)")
            try fm.copyItem(at: source, to: stage)
            guard let stagedID = fileID(stage) else { throw Fault.filesystem }
            var journal = Journal(stageName: stage.lastPathComponent, newID: stagedID,
                                  oldID: fileID(target), keepPrevious: false,
                                  state: .prepared, launchPID: nil, launchStart: nil)
            journal.targetPath = target.standardizedFileURL.path
            journal.volumeID = metadata(target.deletingLastPathComponent(), type: mode_t(S_IFDIR)).map { UInt64($0.st_dev) }
            journal.newDigest = try digest(stage)
            journal.oldDigest = try digest(target)
            try write(journal, for: target)
            try fixtureInstall(source: source, at: target, keepPrevious: false, verify: verify)
            results.append(("a reopened source retries after an interrupted pre-swap copy",
                            label(target) == "new" && stages(target).count == 1
                                && label(stages(target)[0]) == "old"))
        } catch { results.append(("retry-before-swap fixture", false)) }

        do {
            let (source, target) = try scene("crash-after-swap")
            do {
                try fixtureInstall(source: source, at: target, keepPrevious: false, verify: verify,
                            fault: { $0 == .afterSwap })
            } catch { /* simulates process loss after the atomic rename */ }
            let first = beginLaunch(at: target)
            let concurrent = beginLaunch(at: target)
            let concurrentKeptNew = label(target) == "new"
            let second = beginLaunch(at: target, processAlive: { _, _, _ in false })
            results.append(("a concurrent launch cannot roll back a live replacement",
                            concurrent == .needsAttention && concurrentKeptNew))
            results.append(("an interrupted first launch rolls back on the next attempt",
                            first == .waitingForHealth && second == .rolledBack
                                && label(target) == "old" && stages(target).isEmpty))
        } catch { results.append(("rollback fixture", false)) }

        do {
            let (source, target) = try scene("reused-pid")
            try fixtureInstall(source: source, at: target, keepPrevious: false, verify: verify)
            guard beginLaunch(at: target) == .waitingForHealth,
                  var journal = read(target), let start = journal.launchStart else {
                throw Fault.filesystem
            }
            journal.launchStart = start &+ 1
            try write(journal, for: target)
            results.append(("reused PID cannot indefinitely block rollback",
                            beginLaunch(at: target) == .rolledBack && label(target) == "old"))
        } catch { results.append(("reused-pid fixture", false)) }

        do {
            let (source, target) = try scene("protected-reused-pid")
            try fixtureInstall(source: source, at: target, keepPrevious: false, verify: verify)
            guard beginLaunch(at: target) == .waitingForHealth,
                  var journal = read(target), let start = journal.launchStart,
                  let deadline = journal.launchDeadline else { throw Fault.filesystem }
            let protectedPIDExists = { true } // kill(pid, 0) returned EPERM.
            let duringLease = sameProcess(start: start, deadline: deadline,
                                          observedStart: nil, pidExists: protectedPIDExists,
                                          now: deadline - 1)
            let missingLease = sameProcess(start: start, deadline: nil,
                                           observedStart: nil, pidExists: protectedPIDExists,
                                           now: deadline - 1)
            let clockMovedBack = sameProcess(start: start, deadline: deadline,
                                             observedStart: nil, pidExists: protectedPIDExists,
                                             now: deadline - fallbackLease - 1)
            journal.launchDeadline = Date().timeIntervalSince1970 - 1
            try write(journal, for: target)
            let afterLease = beginLaunch(at: target, processAlive: { _, start, deadline in
                sameProcess(start: start, deadline: deadline, observedStart: nil,
                            pidExists: protectedPIDExists, now: Date().timeIntervalSince1970)
            })
            results.append(("protected reused PID blocks rollback only during startup lease",
                            duringLease && !missingLease && !clockMovedBack
                                && afterLease == .rolledBack && label(target) == "old"))
        } catch { results.append(("protected-reused-pid fixture", false)) }

        do {
            let (source, target) = try scene("interrupted-cleanup")
            try fixtureInstall(source: source, at: target, keepPrevious: false, verify: verify)
            _ = beginLaunch(at: target)
            guard var journal = read(target), let stage = stageURL(target, journal) else {
                throw Fault.filesystem
            }
            journal.state = .healthy
            try write(journal, for: target)
            try fm.removeItem(at: stage)
            results.append(("startup finishes cleanup interrupted after deleting the backup",
                            beginLaunch(at: target) == .unchanged && label(target) == "new"
                                && !entryExists(journalURL(target))))
        } catch { results.append(("interrupted-cleanup fixture", false)) }

        do {
            let (source, target) = try scene("relocation")
            try fixtureInstall(source: source, at: target, keepPrevious: true, verify: verify)
            let first = beginLaunch(at: target)
            markHealthy(at: target)
            results.append(("relocation keeps the displaced installed bundle",
                            first == .waitingForHealth && label(target) == "new"
                                && stages(target).isEmpty && backups(target).count == 1
                                && label(backups(target)[0]) == "old"))
        } catch { results.append(("relocation fixture", false)) }

        do {
            let (source, target) = try scene("relocation-cleanup")
            try fixtureInstall(source: source, at: target, keepPrevious: true, verify: verify)
            _ = beginLaunch(at: target)
            guard var journal = read(target), let stage = stageURL(target, journal) else {
                throw Fault.filesystem
            }
            journal.state = .healthy
            try write(journal, for: target)
            try moveIntoEmptyTarget(stage, backupURL(stage))
            results.append(("startup finishes a relocation interrupted after backup rename",
                            beginLaunch(at: target) == .unchanged && label(target) == "new"
                                && stages(target).isEmpty && backups(target).count == 1
                                && label(backups(target)[0]) == "old"
                                && !entryExists(journalURL(target))))
        } catch { results.append(("relocation-cleanup fixture", false)) }

        do {
            let (source, target) = try scene("empty-destination", old: false)
            try fixtureInstall(source: source, at: target, keepPrevious: false, verify: verify)
            let first = beginLaunch(at: target)
            markHealthy(at: target)
            results.append(("first install uses an exclusive rename and completes cleanly",
                            first == .waitingForHealth && label(target) == "new"
                                && stages(target).isEmpty
                                && !entryExists(journalURL(target))))
        } catch { results.append(("empty-destination fixture", false)) }

        return results
    }
}
