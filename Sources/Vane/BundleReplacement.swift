import Foundation
import Darwin

/// A crash-recoverable app-bundle replacement. All paths written by a transaction are
/// siblings of its target, so staging and the final rename stay on the same volume.
enum BundleReplacement {
    enum Fault: Error { case injected, busy, invalidStage, unsupportedSwap, filesystem }
    enum Step { case beforeCopy, afterCopy, beforeJournal, beforeSwap, afterSwap }
    enum Launch { case unchanged, waitingForHealth, rolledBack, needsAttention }

    private enum State: String, Codable { case prepared, launching, healthy }
    private struct Journal: Codable {
        let stageName: String
        let newID: UInt64
        let oldID: UInt64?
        let keepPrevious: Bool
        var state: State
        var launchPID: Int32?
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

    private static func fileID(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber]
            as? NSNumber)?.uint64Value
    }

    private static func read(_ target: URL) -> Journal? {
        guard let data = try? Data(contentsOf: journalURL(target)) else { return nil }
        return try? JSONDecoder().decode(Journal.self, from: data)
    }

    private static func write(_ journal: Journal, for target: URL) throws {
        try JSONEncoder().encode(journal).write(to: journalURL(target), options: .atomic)
    }

    private static func withLock<T>(_ target: URL, _ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL(target).path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Fault.filesystem }
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
            throw Fault.filesystem
        }
    }

    /// The empty-destination case is an exclusive, same-volume rename. A concurrent app
    /// that appeared at the target cannot be overwritten by a stale relocation decision.
    private static func moveIntoEmptyTarget(_ stage: URL, _ target: URL) throws {
        let result = stage.path.withCString { a in
            target.path.withCString { b in renamex_np(a, b, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else { throw Fault.filesystem }
    }

    /// The caller supplies the same signature check it used on the unpacked source. It is
    /// run again on the *copied* bundle before any installed bundle can move.
    static func install(source: URL, at target: URL, keepPrevious: Bool,
                        verify: (URL) -> Bool,
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
               fileID(target) == pending.oldID, fileID(priorStage) == pending.newID {
                try fm.removeItem(at: priorStage)
                try fm.removeItem(at: journalURL(target))
            }
            guard !fm.fileExists(atPath: journalURL(target).path) else { throw Fault.busy }
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
            guard verify(stage), let newID = fileID(stage) else { throw Fault.invalidStage }
            let oldID = fileID(target)
            let journal = Journal(stageName: stage.lastPathComponent, newID: newID,
                                  oldID: oldID, keepPrevious: keepPrevious, state: .prepared,
                                  launchPID: nil)
            if fault?(.beforeJournal) == true { throw Fault.injected }
            try write(journal, for: target)
            journalWritten = true
            if fault?(.beforeSwap) == true { throw Fault.injected }
            if oldID != nil { try swapOperation(target, stage) }
            else { try moveIntoEmptyTarget(stage, target) }
            committed = true
            if fault?(.afterSwap) == true { throw Fault.injected }
        }
    }

    /// Run before opening a window. A prepared transaction that never swapped is discarded.
    /// A second attempt to start a replacement that never reached a healthy launch swaps
    /// the old bundle back, then asks the caller to relaunch that restored bundle.
    static func beginLaunch(at target: URL,
                            processAlive: (Int32) -> Bool = { pid in
                                kill(pid, 0) == 0 || errno == EPERM
                            }) -> Launch {
        guard FileManager.default.fileExists(atPath: journalURL(target).path) else {
            return .unchanged
        }
        return (try? withLock(target) {
            let fm = FileManager.default
            guard var journal = read(target), let stage = stageURL(target, journal) else {
                return Launch.needsAttention
            }
            let targetID = fileID(target), stageID = fileID(stage)
            if targetID == journal.oldID, stageID == journal.newID {
                // The app crashed before the rename; the original installation is intact.
                try? fm.removeItem(at: stage)
                try? fm.removeItem(at: journalURL(target))
                return .unchanged
            }
            if journal.state == .healthy, targetID == journal.newID {
                // Cleanup may have removed the old bundle and crashed before deleting the
                // journal. Missing stage is valid only in this already-healthy state.
                if let stageID, journal.oldID != stageID { return .needsAttention }
                finish(journal, stage: stage, target: target)
                return .unchanged
            }
            guard targetID == journal.newID,
                  journal.oldID == nil || stageID == journal.oldID else {
                return .needsAttention
            }
            if journal.state == .launching, journal.oldID != nil {
                if let pid = journal.launchPID, processAlive(pid) {
                    // Another copy is still starting. Its health decision owns this
                    // transaction; a second launch must not roll it back underneath it.
                    return .needsAttention
                }
                do { try swap(target, stage) } catch { return .needsAttention }
                // Only the staged failed version is removed. The restored old app is now
                // at the original target path and can be opened by the caller.
                try? fm.removeItem(at: stage)
                try? fm.removeItem(at: journalURL(target))
                return .rolledBack
            }
            journal.state = .launching
            journal.launchPID = getpid()
            guard (try? write(journal, for: target)) != nil else { return .needsAttention }
            return .waitingForHealth
        }) ?? .needsAttention
    }

    /// Called after AppKit has entered its run loop. A previous copy is retained until
    /// this point; a relocation leaves it on disk for the user, while an update removes it.
    static func markHealthy(at target: URL) {
        guard FileManager.default.fileExists(atPath: journalURL(target).path) else { return }
        _ = try? withLock(target) {
            guard var journal = read(target), let stage = stageURL(target, journal),
                  journal.state == .launching, journal.launchPID == getpid(),
                  fileID(target) == journal.newID,
                  journal.oldID == nil || fileID(stage) == journal.oldID else { return }
            journal.state = .healthy
            try write(journal, for: target)
            finish(journal, stage: stage, target: target)
        }
    }

    private static func finish(_ journal: Journal, stage: URL, target: URL) {
        let fm = FileManager.default
        if !journal.keepPrevious, let oldID = journal.oldID, fileID(stage) == oldID {
            do { try fm.removeItem(at: stage) } catch { return }
        }
        try? fm.removeItem(at: journalURL(target))
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
        let verify: (URL) -> Bool = { label($0) == "new" }

        do {
            let (source, target) = try scene("normal")
            try install(source: source, at: target, keepPrevious: false, verify: verify)
            results.append(("replacement is atomic and retains the old bundle before launch",
                            label(target) == "new" && stages(target).count == 1
                                && label(stages(target)[0]) == "old"))
            markHealthy(at: target)
            results.append(("the updating process cannot mark its own replacement healthy",
                            stages(target).count == 1
                                && fm.fileExists(atPath: journalURL(target).path)))
            results.append(("first launch keeps the previous app until healthy",
                            beginLaunch(at: target) == .waitingForHealth
                                && stages(target).count == 1))
            markHealthy(at: target)
            results.append(("healthy update removes only its own previous copy",
                            stages(target).isEmpty && !fm.fileExists(atPath: journalURL(target).path)
                                && label(target) == "new"))
        } catch { results.append(("normal replacement fixture", false)) }

        for (name, step) in [("before-copy", Step.beforeCopy),
                             ("after-copy", .afterCopy),
                             ("before-journal", .beforeJournal),
                             ("before-swap", .beforeSwap)] {
            do {
                let (source, target) = try scene(name)
                do {
                    try install(source: source, at: target, keepPrevious: false,
                                verify: verify, fault: { $0 == step })
                } catch { /* expected */ }
                results.append(("\(name) failure preserves the installed app and cleans staging",
                                label(target) == "old" && stages(target).isEmpty
                                    && !fm.fileExists(atPath: journalURL(target).path)))
            } catch { results.append(("\(name) fixture", false)) }
        }

        do {
            let (source, target) = try scene("unsupported-volume")
            do {
                try install(source: source, at: target, keepPrevious: false, verify: verify,
                            swapOperation: { _, _ in throw Fault.unsupportedSwap })
            } catch { /* expected */ }
            results.append(("unsupported atomic swap refuses the update safely",
                            label(target) == "old" && stages(target).isEmpty
                                && !fm.fileExists(atPath: journalURL(target).path)))
        } catch { results.append(("unsupported-volume fixture", false)) }

        do {
            let (source, target) = try scene("invalid-copied-bundle")
            do {
                try install(source: source, at: target, keepPrevious: false,
                            verify: { _ in false })
            } catch { /* expected verification failure */ }
            results.append(("a failed check of the copied bundle leaves the old app in place",
                            label(target) == "old" && stages(target).isEmpty
                                && !fm.fileExists(atPath: journalURL(target).path)))
        } catch { results.append(("invalid-copied-bundle fixture", false)) }

        do {
            let (source, target) = try scene("interrupted-before-swap")
            let stage = target.deletingLastPathComponent().appendingPathComponent(
                ".\(target.lastPathComponent).vane-stage-\(UUID().uuidString)")
            try fm.copyItem(at: source, to: stage)
            guard let stagedID = fileID(stage) else { throw Fault.filesystem }
            let journal = Journal(stageName: stage.lastPathComponent, newID: stagedID,
                                  oldID: fileID(target), keepPrevious: false, state: .prepared,
                                  launchPID: nil)
            try write(journal, for: target)
            results.append(("startup cleans an interrupted pre-swap transaction",
                            beginLaunch(at: target) == .unchanged && label(target) == "old"
                                && stages(target).isEmpty
                                && !fm.fileExists(atPath: journalURL(target).path)))
        } catch { results.append(("interrupted-before-swap fixture", false)) }

        do {
            let (source, target) = try scene("retry-before-swap")
            let stage = target.deletingLastPathComponent().appendingPathComponent(
                ".\(target.lastPathComponent).vane-stage-\(UUID().uuidString)")
            try fm.copyItem(at: source, to: stage)
            guard let stagedID = fileID(stage) else { throw Fault.filesystem }
            try write(Journal(stageName: stage.lastPathComponent, newID: stagedID,
                              oldID: fileID(target), keepPrevious: false,
                              state: .prepared, launchPID: nil), for: target)
            try install(source: source, at: target, keepPrevious: false, verify: verify)
            results.append(("a reopened source retries after an interrupted pre-swap copy",
                            label(target) == "new" && stages(target).count == 1
                                && label(stages(target)[0]) == "old"))
        } catch { results.append(("retry-before-swap fixture", false)) }

        do {
            let (source, target) = try scene("crash-after-swap")
            do {
                try install(source: source, at: target, keepPrevious: false, verify: verify,
                            fault: { $0 == .afterSwap })
            } catch { /* simulates process loss after the atomic rename */ }
            let first = beginLaunch(at: target)
            let concurrent = beginLaunch(at: target)
            let concurrentKeptNew = label(target) == "new"
            let second = beginLaunch(at: target, processAlive: { _ in false })
            results.append(("a concurrent launch cannot roll back a live replacement",
                            concurrent == .needsAttention && concurrentKeptNew))
            results.append(("an interrupted first launch rolls back on the next attempt",
                            first == .waitingForHealth && second == .rolledBack
                                && label(target) == "old" && stages(target).isEmpty))
        } catch { results.append(("rollback fixture", false)) }

        do {
            let (source, target) = try scene("interrupted-cleanup")
            try install(source: source, at: target, keepPrevious: false, verify: verify)
            _ = beginLaunch(at: target)
            guard var journal = read(target), let stage = stageURL(target, journal) else {
                throw Fault.filesystem
            }
            journal.state = .healthy
            try write(journal, for: target)
            try fm.removeItem(at: stage)
            results.append(("startup finishes cleanup interrupted after deleting the backup",
                            beginLaunch(at: target) == .unchanged && label(target) == "new"
                                && !fm.fileExists(atPath: journalURL(target).path)))
        } catch { results.append(("interrupted-cleanup fixture", false)) }

        do {
            let (source, target) = try scene("relocation")
            try install(source: source, at: target, keepPrevious: true, verify: verify)
            let first = beginLaunch(at: target)
            markHealthy(at: target)
            results.append(("relocation keeps the displaced installed bundle",
                            first == .waitingForHealth && label(target) == "new"
                                && stages(target).count == 1
                                && label(stages(target)[0]) == "old"))
        } catch { results.append(("relocation fixture", false)) }

        do {
            let (source, target) = try scene("empty-destination", old: false)
            try install(source: source, at: target, keepPrevious: false, verify: verify)
            let first = beginLaunch(at: target)
            markHealthy(at: target)
            results.append(("first install uses an exclusive rename and completes cleanly",
                            first == .waitingForHealth && label(target) == "new"
                                && stages(target).isEmpty
                                && !fm.fileExists(atPath: journalURL(target).path)))
        } catch { results.append(("empty-destination fixture", false)) }

        return results
    }
}
