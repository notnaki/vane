import Foundation

@MainActor enum EaselChecks {
    static func check() -> [(String, Bool)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var results: [(String, Bool)] = []
        func expect(_ name: String, _ value: Bool) { results.append((name, value)) }
        do {
            let profile = UUID(), other = UUID()
            let store = EaselStore(profileID: profile, directory: root)
            let board = try store.create(title: "Trip ideas")
            var edited = board
            edited.items.append(EaselItem(kind: .note, text: "Remember the museum", x: 120, y: 80))
            try store.save(edited)
            let reopened = EaselStore(profileID: profile, directory: root)
            expect("notes and placement survive a relaunch", reopened.boards.first?.items.first?.text == "Remember the museum" && reopened.boards.first?.items.first?.x == 120)
            expect("another profile cannot read these boards", EaselStore(profileID: other, directory: root).boards.isEmpty)
            try store.undo(board.id)
            expect("undo restores the last saved board", store.board(board.id)?.items.isEmpty == true)
            try store.redo(board.id)
            expect("redo restores the note", store.board(board.id)?.items.count == 1)
            try store.undo(board.id)
            var branch = store.board(board.id)!
            branch.title = "New direction"
            try store.save(branch)
            expect("editing after undo clears redo", !store.canRedo(board.id))
            let imported = try store.importBoard(JSONEncoder().encode(edited))
            expect("import copies a board without duplicate identities", imported.id != board.id && imported.items.first?.id != edited.items.first?.id && imported.items.first?.text == "Remember the museum")
            try store.delete(imported.id)
            expect("deleted boards stay deleted after relaunch", EaselStore(profileID: profile, directory: root).boards.count == 1)
            var invalid = branch
            invalid.items = [EaselItem(kind: .note, x: .nan)]
            do { try store.save(invalid); expect("nonfinite placement is rejected", false) }
            catch { expect("nonfinite placement is rejected", store.board(board.id)?.title == "New direction") }
            var unsupported = branch
            unsupported.version = 99
            do { _ = try store.importBoard(JSONEncoder().encode(unsupported)); expect("future document versions are rejected", false) }
            catch { expect("future document versions are rejected", store.boards.count == 1) }
            var duplicate = edited
            duplicate.items.append(duplicate.items[0])
            do { try store.save(duplicate); expect("duplicate item identities are rejected", false) }
            catch { expect("duplicate item identities are rejected", store.boards.count == 1) }
            var badImage = edited
            badImage.items = [EaselItem(kind: .image, image: Data("not an image".utf8))]
            do { try store.save(badImage); expect("invalid image payloads are rejected", false) }
            catch { expect("invalid image payloads are rejected", store.board(board.id)?.items.isEmpty == true) }
            let disk = root.appendingPathComponent("disk")
            let failing = EaselStore(profileID: other, directory: disk)
            var saved = try failing.create(title: "Last saved")
            saved.title = "Saved edit"; try failing.save(saved)
            try FileManager.default.removeItem(at: disk)
            try Data().write(to: disk)
            do { try failing.undo(saved.id); expect("failed undo preserves the saved board and undo history", false) }
            catch { expect("failed undo preserves the saved board and undo history", failing.board(saved.id)?.title == "Saved edit" && failing.canUndo(saved.id) && !failing.canRedo(saved.id)) }
            saved.title = "Not saved"
            do { try failing.save(saved); expect("failed edits preserve the last committed state", false) }
            catch { expect("failed edits preserve the last committed state", failing.board(saved.id)?.title == "Saved edit") }
            let retiredProfile = UUID()
            let retired = EaselStore.shared(profileID: retiredProfile, directory: root)
            let retiredBoard = try retired.create()
            EaselStore.forget(retiredProfile, directory: root)
            do { try retired.save(retiredBoard); expect("forgotten repositories cannot recreate deleted profile data", false) }
            catch { expect("forgotten repositories cannot recreate deleted profile data", !FileManager.default.fileExists(atPath: EaselStore.file(profileID: retiredProfile, directory: root).path)) }
            do { _ = try retired.create(); expect("stale windows cannot create boards for deleted profiles", false) }
            catch { expect("stale windows cannot create boards for deleted profiles", true) }
            let file = EaselStore.file(profileID: profile, directory: root)
            try Data("broken json".utf8).write(to: file)
            let corrupt = EaselStore(profileID: profile, directory: root)
            do { _ = try corrupt.create(); expect("corrupt storage is protected from replacement", false) }
            catch { expect("corrupt storage is protected from replacement", try Data(contentsOf: file) == Data("broken json".utf8)) }
            let wall = root.appendingPathComponent("wall")
            try Data().write(to: wall)
            let unwritable = EaselStore(profileID: other, directory: wall)
            do { _ = try unwritable.create(); expect("a failed write does not publish a phantom board", false) }
            catch { expect("a failed write does not publish a phantom board", unwritable.boards.isEmpty) }
            expect("links accept web addresses only", EaselItem.webURL("https://example.com/a") != nil && EaselItem.webURL("javascript:alert(1)") == nil && EaselItem.webURL("file:///etc/passwd") == nil)
        } catch { expect("easel fixture completes: \(error)", false) }
        return results
    }
}
