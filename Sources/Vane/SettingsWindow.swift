import AppKit
import SwiftUI

/// Preferences that are not owned by the thing they configure. Everything else already has
/// a home (`Settings` in Develop.swift, `Blocker.enabled`, `Search.current`) and is read
/// straight from there.
@MainActor enum Prefs {
    /// Empty means "whatever the current search engine's front page is", so switching
    /// engines moves the homepage with it until the user pins one down.
    static var homepage: URL {
        let stored = UserDefaults.standard.string(forKey: "homepage") ?? ""
        return Search.url(for: stored) ?? Search.current.home ?? Search.builtIn[0].home!
    }

    /// Off is a real preference (a fresh window every launch), so it persists; on is the
    /// behaviour main.swift already had.
    static var restoreSession: Bool {
        get { UserDefaults.standard.object(forKey: "restoreSession") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "restoreSession") }
    }
}

/// The settings window. ponytail: one NSWindow we own, made once and reused — the app has
/// no AppDelegate and no `Settings` scene to hang a SwiftUI settings scene off, and the
/// frame autosave gives "remembers where it was" for free.
@MainActor enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Settings"
        w.isReleasedWhenClosed = false        // closing must not free the instance we keep
        w.contentView = NSHostingView(rootView: SettingsView())
        // Position first, autosave second: setFrameUsingName reports whether there was one.
        if !w.setFrameUsingName("VaneSettings") { w.center() }
        w.setFrameAutosaveName("VaneSettings")
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - Views

/// ponytail: plain TabView + grouped Forms, no design work — this is being redesigned, so
/// it borrows System Settings' shape and stops there.
private struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
            PrivacyPane().tabItem { Label("Privacy", systemImage: "hand.raised") }
            DeveloperPane().tabItem { Label("Developer", systemImage: "hammer") }
        }
        .padding(14)
        .frame(width: 520, height: 430)
    }
}

private struct GeneralPane: View {
    // The key `Search.current` reads. AppStorage so the picker redraws itself.
    @AppStorage("searchEngine") private var engineID = Search.builtIn[0].id
    @AppStorage("homepage") private var homepage = ""
    @State private var engines = Search.all
    @State private var newName = ""
    @State private var newTemplate = ""
    @State private var restore = Prefs.restoreSession

    private var isValid: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty && newTemplate.contains("%s")
            && newTemplate.contains("://")
    }

    var body: some View {
        Form {
            Section {
                Picker("Search engine", selection: $engineID) {
                    ForEach(engines) { Text($0.name).tag($0.id) }
                }
                if !Search.custom.isEmpty {
                    ForEach(Search.custom) { engine in
                        HStack {
                            Text(engine.name)
                            Text(engine.queryTemplate).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                Search.remove(engine)
                                engines = Search.all
                                engineID = Search.current.id
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Remove this engine")
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField("Name", text: $newName).frame(width: 110)
                    TextField("https://example.com/search?q=%s", text: $newTemplate)
                    Button("Add") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        Search.add(SearchEngine(id: id(for: name), name: name,
                                                queryTemplate: newTemplate.trimmingCharacters(in: .whitespaces)))
                        engines = Search.all
                        newName = ""; newTemplate = ""
                    }
                    .disabled(!isValid)
                }
                .font(.system(size: 12))
            } footer: {
                Text("A custom engine's address needs %s where the search words go.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Homepage", text: $homepage, prompt: Text(Prefs.homepage.absoluteString))
                    .onSubmit {
                        // Same parser as the address bar, so "example.com" is enough.
                        if let u = Search.url(for: homepage) { homepage = u.absoluteString }
                    }
                Toggle("Reopen windows and tabs on launch", isOn: $restore)
                    .onChange(of: restore) { Prefs.restoreSession = restore }
            }
        }
        .formStyle(.grouped)
    }

    /// ponytail: slugged name plus a counter. Two engines called the same thing is the
    /// only collision that matters and this is enough to stop it.
    private func id(for name: String) -> String {
        let base = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let slug = base.isEmpty ? "custom" : base
        var candidate = slug
        var n = 2
        while Search.all.contains(where: { $0.id == candidate }) {
            candidate = slug + String(n)
            n += 1
        }
        return candidate
    }
}

private struct PrivacyPane: View {
    // Blocker's own key. Writing it directly skips Blocker.enabled's setter, so the
    // recompile-and-reattach it would have done is hung off onChange instead.
    @AppStorage("blockerEnabled") private var blocking = true
    // Absent = off. Deliberately not defaulted on: turning this on sends what you type to
    // the search engine before you press Return.
    @AppStorage("searchSuggestions") private var suggestions = false
    @AppStorage("instantLinks") private var instant = true

    var body: some View {
        Form {
            Section {
                Toggle("Block ads and trackers", isOn: $blocking)
                    .onChange(of: blocking) { Blocker.refresh() }
                Button("Add Filter List…") { Blocker.chooseAndAddList() }
            } footer: {
                Text("Filter lists in EasyList syntax — an EasyList, EasyPrivacy or uBlock "
                     + "Origin subscription file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Instant Links", isOn: $instant)
            } footer: {
                Text("Shift-Return on a search opens the top result directly instead of the "
                     + "results page. The query goes to DuckDuckGo whichever engine you use, "
                     + "because it is the only one that answers without JavaScript. Never in "
                     + "a private window, and never for anything that looks like an address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Search suggestions", isOn: $suggestions)
            } footer: {
                Text("Sends what you type in the address bar to your search engine as you "
                     + "type it, to offer completions. Never in a private window, and never "
                     + "for anything that looks like an address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Clear History…") {
                    if confirm("Clear all browsing history?", "Clear",
                               "Bookmarks and saved passwords are not affected.") {
                        Store.shared.clearHistory()
                        rebuild()          // the History menu lists what was just deleted
                    }
                }
                Button("Reset Camera & Microphone Permissions…") {
                    if confirm("Forget camera and microphone permissions for every site?", "Reset") {
                        SitePermissions.resetAll()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeveloperPane: View {
    @AppStorage("userAgent") private var userAgent = safariUA
    @AppStorage("inspector") private var inspector = true

    var body: some View {
        Form {
            Section {
                Picker("User agent", selection: $userAgent) {
                    ForEach(Settings.userAgents, id: \.value) { Text($0.name).tag($0.value) }
                }
                .onChange(of: userAgent) { Settings.apply(); rebuild() }
            } footer: {
                Text("Sites that sniff the browser see this instead. Reload the page to "
                     + "apply it.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Allow Web Inspector", isOn: $inspector)
                    .onChange(of: inspector) { Settings.apply(); rebuild() }
                if !Inspector.available {
                    Text("The in-app inspector is unavailable on this macOS — right-click → "
                         + "Inspect Element still works.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The same NSAlert shape the menus use, so a destructive settings button asks the same way.
@MainActor private func confirm(_ message: String, _ verb: String, _ detail: String = "") -> Bool {
    let a = NSAlert()
    a.messageText = message
    a.informativeText = detail
    a.addButton(withTitle: verb)
    a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}
