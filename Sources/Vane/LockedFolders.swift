import AppKit
import LocalAuthentication

/// Unlock grants are scoped to a profile and folder, live only in memory, and are shared
/// by all windows. Locking invalidates outstanding authentication replies as well.
@MainActor final class FolderAuthentication {
    struct Key: Hashable { let profile: UUID; let folder: UUID }
    typealias Reply = @MainActor (Bool) -> Void
    typealias Authenticator = @MainActor (String, @escaping Reply) -> LAContext?

    static let shared = FolderAuthentication(observingSession: true)
    private var unlocked: Set<Key> = []
    private struct Pending {
        let token: UUID
        var context: LAContext?
        var replies: [Reply]
    }
    private var pending: [Key: Pending] = [:]
    private let authenticate: Authenticator
    let needsInlineAuthentication: Bool
    var inlineAvailable: @MainActor () -> Bool = {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
    var systemAuthenticator: Authenticator = FolderAuthentication.systemAuthentication
    private var observers: [NSObjectProtocol] = []

    init(observingSession: Bool = false,
         authenticate: Authenticator? = nil) {
        self.authenticate = authenticate ?? FolderAuthentication.systemAuthentication
        needsInlineAuthentication = authenticate == nil
        if observingSession {
            for name in [NSWorkspace.sessionDidResignActiveNotification,
                         NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.lockAll() } })
            }
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.lockAll() } })
        }
    }

    static func systemAuthentication(_ reason: String, _ reply: @escaping Reply) -> LAContext? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            reply(false)
            return nil
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            Task { @MainActor in reply(success) }
        }
        return context
    }

    func grants(for profile: UUID) -> Set<UUID> {
        Set(unlocked.filter { $0.profile == profile }.map(\.folder))
    }

    func unlock(_ folder: UUID, profile: UUID, reason: String,
                using override: Authenticator? = nil, then reply: @escaping Reply) {
        let key = Key(profile: profile, folder: folder)
        if unlocked.contains(key) { reply(true); return }
        if pending[key] != nil { pending[key]?.replies.append(reply); return }
        let token = UUID()
        pending[key] = Pending(token: token, replies: [reply])
        let context = (override ?? authenticate)(reason) { [weak self] success in
            guard let self, let request = pending[key], request.token == token else { return }
            pending[key] = nil
            if success { unlocked.insert(key); changed(profile) }
            request.replies.forEach { $0(success) }
        }
        // A test authenticator or unavailable system policy may finish synchronously.
        if pending[key]?.token == token { pending[key]?.context = context }
    }

    func lock(_ folder: UUID, profile: UUID) {
        let key = Key(profile: profile, folder: folder)
        unlocked.remove(key)
        let request = pending.removeValue(forKey: key)
        request?.context?.invalidate()
        changed(profile)
        request?.replies.forEach { $0(false) }
    }

    func lockAll() {
        unlocked.removeAll()
        let requests = Array(pending.values)
        pending.removeAll()
        requests.forEach { $0.context?.invalidate() }
        for profile in Set(TabStore.all.map(\.profileID)) { changed(profile) }
        requests.flatMap(\.replies).forEach { $0(false) }
    }

    private func changed(_ profile: UUID) {
        let stores = TabStore.all.filter { $0.profileID == profile && $0.folderAuthentication === self }
        // All windows capture before the first one releases a shared live page.
        for store in stores { store.captureLockedFolderBackdrop() }
        for store in stores { store.enforceFolderLocks() }
    }
}

extension Pins {
    /// Outer protections must be satisfied before inner protections, including the row
    /// itself when it is a folder. A collapsed ordinary folder never blocks tab selection.
    func lockedFolders(for row: String, unlocked: Set<UUID>) -> [Folder] {
        guard let index = index(of: row) else { return [] }
        let path = ancestors(of: index).reversed() + [entries[index].folder?.id].compactMap { $0 }
        return path.compactMap { folder($0) }.filter {
            $0.requiresAuthentication == true && !unlocked.contains($0.id)
        }
    }
}

/// A sidebar unlock request is presented inside the page card, never in a Vane popup.
@MainActor final class FolderUnlockRequest {
    let id = UUID()
    let target: UUID
    var replies: [FolderAuthentication.Reply]
    init(target: UUID, reply: @escaping FolderAuthentication.Reply) {
        self.target = target
        self.replies = [reply]
    }
}

extension TabStore {
    var usesInlineFolderUnlock: Bool {
        Prefs.folderUnlockMethod == .touchID && folderAuthentication.inlineAvailable()
    }

    var folderUnlockPage: Folder? {
        if let request = folderUnlockRequest,
           let shape = holder(of: request.target) {
            return lockedFolders(for: request.target.uuidString).first
                ?? self[keyPath: shape].folder(request.target)
        }
        return lockedPageFolder
    }

    func cancelFolderUnlock() {
        guard let request = folderUnlockRequest else { return }
        folderUnlockRequest = nil
        for folder in lockedFolders(for: request.target.uuidString) {
            folderAuthentication.lock(folder.id, profile: profileID)
        }
        request.replies.forEach { $0(false) }
    }

    func runFolderUnlock(using authenticate: @escaping FolderAuthentication.Authenticator,
                         then done: @escaping FolderAuthentication.Reply) {
        guard let request = folderUnlockRequest else { done(false); return }
        unlockFolder(request.target, using: authenticate) { [weak self] success in
            guard let self, folderUnlockRequest === request else { done(false); return }
            if success {
                Motion.list { folderUnlockRequest = nil }
                request.replies.forEach { $0(true) }
            }
            done(success)
        }
    }

    var unlockedFolders: Set<UUID> { folderAuthentication.grants(for: profileID) }

    func lockedFolders(for row: String) -> [Folder] {
        for shape in [pins, todayShape] where shape.index(of: row) != nil {
            return shape.lockedFolders(for: row, unlocked: unlockedFolders)
        }
        for stash in stashes.values {
            for shape in [stash.pins, stash.todayShape] where shape.index(of: row) != nil {
                return shape.lockedFolders(for: row, unlocked: unlockedFolders)
            }
        }
        return []
    }

    func isFolderLocked(_ id: UUID) -> Bool { !lockedFolders(for: id.uuidString).isEmpty }
    func isTabLocked(_ id: UUID) -> Bool { !lockedFolders(for: id.uuidString).isEmpty }
    var accessibleTabs: [Tab] { tabs.filter { !isTabLocked($0.id) } }

    var lockedPageFolder: Folder? {
        guard let current else { return nil }
        let shown = splits.first { $0.contains(current) }?.tabs ?? [current]
        return shown.compactMap { lockedFolders(for: $0.uuidString).first }.first
    }

    /// Called before a locked page can wake or acquire a live presentation.
    func unlockFolder(_ id: UUID, then done: @escaping FolderAuthentication.Reply = { _ in }) {
        unlockFolder(id, using: nil, then: done)
    }

    private func unlockFolder(_ id: UUID, using authenticate: FolderAuthentication.Authenticator?,
                              then done: @escaping FolderAuthentication.Reply) {
        guard let shape = holder(of: id), self[keyPath: shape].folder(id) != nil else {
            done(false); return
        }
        guard let blocked = lockedFolders(for: id.uuidString).first else { done(true); return }
        if authenticate == nil, folderAuthentication.needsInlineAuthentication {
            if !usesInlineFolderUnlock {
                if let request = folderUnlockRequest {
                    if request.target == id {
                        runFolderUnlock(using: folderAuthentication.systemAuthenticator, then: done)
                        return
                    }
                    cancelFolderUnlock()
                }
                unlockFolder(id, using: folderAuthentication.systemAuthenticator, then: done)
                return
            }
            if let request = folderUnlockRequest, request.target == id {
                request.replies.append(done)
            } else {
                cancelFolderUnlock()
                Motion.list { folderUnlockRequest = FolderUnlockRequest(target: id, reply: done) }
            }
            return
        }
        folderAuthentication.unlock(blocked.id, profile: profileID,
                                    reason: "Unlock the folder “\(blocked.name)”.", using: authenticate) { [weak self] success in
            guard let self, success, holder(of: id) != nil else { done(false); return }
            unlockFolder(id, using: authenticate, then: done)
        }
    }

    func lockFolder(_ id: UUID) {
        guard let shape = holder(of: id) else { return }
        Motion.list {
            self[keyPath: shape].edit(folder: id) {
                $0.requiresAuthentication = true
                $0.collapsed = true
            }
        }
        SharedTabs.flush()
        let nested = self[keyPath: shape].entries.filter {
            guard let index = self[keyPath: shape].index(of: $0.id) else { return false }
            return self[keyPath: shape].ancestors(of: index).contains(id)
        }.compactMap(\.folder)
        for folder in nested { folderAuthentication.lock(folder.id, profile: profileID) }
        folderAuthentication.lock(id, profile: profileID)
        savePins()
        axAnnounce("Folder locked.")
    }

    func removeFolderLock(_ id: UUID) {
        // Removing a protection always requires a fresh system authentication, even if
        // the folder is currently open. Revoke the existing grant before asking again.
        guard let shape = holder(of: id), let folder = self[keyPath: shape].folder(id),
              folder.requiresAuthentication == true else { return }
        folderAuthentication.lock(id, profile: profileID)
        unlockFolder(id) { [weak self] success in
            guard let self, success, let currentShape = holder(of: id) else { return }
            Motion.list { self[keyPath: currentShape].edit(folder: id) { $0.requiresAuthentication = nil } }
            savePins()
            enforceFolderLocks()
        }
    }

    func captureLockedFolderBackdrop() {
        if lockedPageFolder != nil, lockedFolderBackdrop == nil,
           let tab = tabs.first(where: { $0.id == current }) {
            lockedFolderBackdrop = LockedFolderBackdrop.capture(tab)
        }
    }

    func enforceFolderLocks() {
        objectWillChange.send()
        selection.keep(accessibleTabs.map(\.id))
        if lockedPageFolder != nil {
            captureLockedFolderBackdrop()
            findOpen = false
            palette = nil
        } else {
            lockedFolderBackdrop = nil
        }
        renamingTab = renamingTab.flatMap { isTabLocked($0) ? nil : $0 }
        spaceGesture.previews.removeAll()
        let blocked = everyTab.filter { isTabLocked($0.id) }
        if let peek = Peek.live, peek.parent === self,
           blocked.contains(where: { $0.id == peek.source }) { Peek.close(animated: false) }
        if !blocked.isEmpty, let window { MinimizedWindowIcon.protect(window) }
        for tab in blocked { tab.suspendForFolderLock() }
        extensions.sync()
        if lockedPageFolder == nil, let current { self.current = current }
        SharedTabs.refreshPresentation()
    }
}
