import Combine
import Foundation

@MainActor final class WorkspaceTemplateModel: ObservableObject {
    @Published private(set) var templates: [WorkspaceTemplate] = []
    @Published var selection: UUID?
    @Published private(set) var draft: SpaceLayout?
    @Published private(set) var saving: Bool
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var notice = ""
    let request: WorkspaceSheetRequest
    let authentication: FolderAuthentication
    private weak var store: TabStore?
    private let library: WorkspaceTemplates
    private var cancelled = false
    private var generation = UUID()

    init(store: TabStore, request: WorkspaceSheetRequest, library: WorkspaceTemplates? = nil,
         authentication: FolderAuthentication? = nil) {
        self.store = store; self.request = request; self.library = library ?? WorkspaceTemplates(manager: .shared)
        self.authentication = authentication ?? store.folderAuthentication; saving = request.saving
        reload(); if saving { refreshSource() }
    }
    var selected: WorkspaceTemplate? { templates.first { $0.id == selection } }
    var preview: SpaceLayout? { saving ? draft : selected?.layout }
    var unlocked: Set<UUID> { authentication.grants(for: request.profileID) }

    func reload() {
        do {
            templates = try library.load(profile: request.profileID)
            if selection == nil || !templates.contains(where: { $0.id == selection }) { selection = templates.first?.id }
            message = ""
        } catch { message = error.localizedDescription }
    }
    func select(_ template: WorkspaceTemplate) {
        Motion.list { saving = false; selection = template.id; message = ""; notice = "" }
    }
    func refreshSource() {
        do { draft = try source().1; message = "" }
        catch { draft = nil; message = error.localizedDescription }
    }
    func beginSaving() {
        Motion.list { saving = true; notice = ""; refreshSource() }
    }
    private func source() throws -> (Space, SpaceLayout) {
        guard !cancelled, let store, !store.isPrivate, !store.isLittle, !store.isParked,
              store.profileID == request.profileID, store.currentSpaceID == request.sourceID,
              let space = store.currentSpace else { throw WorkspaceError.changed }
        return (space, store.workspaceLayout())
    }
    func cancel() { cancelled = true; generation = UUID(); busy = false }

    private func authenticate(_ layout: SpaceLayout, then done: @escaping @MainActor () throws -> Void) {
        guard !busy, !cancelled else { return }
        busy = true; message = ""; notice = ""
        let token = UUID(); generation = token
        let folders = layout.protectedFolders
        func next(_ index: Int) {
            guard !cancelled, generation == token else { return }
            if index == folders.count {
                do { try layout.requireAuthentication(unlocked); try done() }
                catch { message = error.localizedDescription }
                busy = false
                return
            }
            let folder = folders[index]
            authentication.unlock(folder.id, profile: request.profileID,
                reason: "Include locked folder “\(folder.name)” in this workspace setup.",
                using: authentication.systemAuthenticator) { [weak self] success in
                    guard let self, !cancelled, generation == token else { return }
                    guard success else { busy = false; message = WorkspaceError.authentication.localizedDescription; return }
                    next(index + 1)
                }
        }
        next(0)
    }

    func unlockPreview() {
        guard let layout = preview else { return }
        authenticate(layout) { [weak self] in self?.objectWillChange.send() }
    }
    func save(name: String) {
        guard let reviewed = draft else { return }
        authenticate(reviewed) { [weak self] in
            guard let self else { return }
            let (space, current) = try source()
            guard current == reviewed else { throw WorkspaceError.changed }
            let template = try library.save(name: name, space: space, layout: current, unlocked: unlocked)
            reload(); selection = template.id; saving = false; notice = "Template saved."
        }
    }
    func rename(name: String) {
        guard let selection, !busy, !cancelled else { return }
        do { try library.rename(selection, profile: request.profileID, name: name); reload(); notice = "Template renamed." }
        catch { message = error.localizedDescription }
    }
    /// Updating goes through a fresh source preview, then explicit replacement.
    func update() {
        guard let selection, let reviewed = draft else { return }
        authenticate(reviewed) { [weak self] in
            guard let self else { return }
            let (space, current) = try source()
            guard current == reviewed else { throw WorkspaceError.changed }
            try library.update(selection, space: space, layout: current, unlocked: unlocked)
            reload(); saving = false; notice = "Template updated."
        }
    }
    func delete() {
        guard let selection, !busy, !cancelled else { return }
        do { try library.delete(selection, profile: request.profileID); self.selection = nil; reload(); notice = "Template deleted." }
        catch { message = error.localizedDescription }
    }
    func create(name: String, then done: @escaping @MainActor (Space) -> Void) {
        guard let reviewed = selected else { return }
        authenticate(reviewed.layout) { [weak self] in
            guard let self, let store, store.profileID == request.profileID, !store.isPrivate, !store.isLittle else { throw WorkspaceError.profile }
            let latest = try library.load(profile: request.profileID).first { $0.id == reviewed.id }
            guard latest == reviewed else { throw WorkspaceError.changed }
            let space = try library.create(reviewed.id, profile: request.profileID, name: name, unlocked: unlocked)
            done(space)
        }
    }
}
