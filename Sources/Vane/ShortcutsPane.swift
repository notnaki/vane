import AppKit
import SwiftUI

/// The Shortcuts tab of Settings: an Arc-style searchable list beside shortcut guidance.
/// Customized commands stay above the alphabetical default list.
///
/// Everything it knows lives in Keybindings.swift — this file only draws it and records the
/// next keystroke. The pure parts (what a keystroke means, how the list is grouped, how a
/// conflict is worded) are static functions with a `check()` so they can be proved headless.
@MainActor struct ShortcutsPane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    /// The row currently listening for a keystroke, if any.
    @State private var recording: Command?
    @State private var monitor: Any?
    /// Held only while recording: the window closing is the other way out — see `startRecording`.
    @State private var closing: Any?
    @State private var hovered: Command?
    /// Reveal the result when customization moves a row between sections.
    @State private var edited: Command?
    /// One line of feedback under a row: a refusal (red) or a conflict warning (amber).
    @State private var notes: [Command: Note] = [:]
    /// Keybindings is a plain store, not an ObservableObject, so a write has to say so:
    /// bumping this is what redraws the rows after a set, a reset or a reset-all.
    @State private var revision = 0
    /// Keybindings' own actions, held while recording — see `startRecording`.
    @State private var parked: [Command: @MainActor () -> Void] = [:]

    private struct Note: Equatable {
        var text: String
        var bad: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: Look.inset * 2) {
                shortcutList
                guidance
                    .frame(width: min(280, geometry.size.width * 0.36))
            }
        }
        .padding(.top, Look.inset * 3)
        .onDisappear { stopRecording() }
    }

    private var customized: Set<Command> {
        _ = revision
        return Set(Command.allCases.filter {
            Keybindings.binding(for: $0) != $0.defaultBinding
                || Keybindings.priority(for: $0) != .browser
        })
    }

    private var cards: [(String, [Command])] {
        Self.groups(query, Keybindings.search(query), customized: customized)
    }

    // MARK: - Searchable list

    private var shortcutList: some View {
        VStack(spacing: 0) {
            searchField
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        let groups = cards
                        if groups.isEmpty {
                            VStack(alignment: .leading, spacing: Look.inset) {
                                Text("No shortcuts found").font(Look.heading)
                                Text("Try a feature name or a key combination, like “Command T”.")
                                    .font(Look.text).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Look.cardInset * 2)
                        }
                        ForEach(groups, id: \.0) { title, commands in
                            Section {
                                ForEach(commands, id: \.self) { command in
                                    row(command).id(command)
                                    if command != commands.last {
                                        Hairline().padding(.horizontal, Look.cardInset * 1.5)
                                    }
                                }
                            } header: {
                                if !title.isEmpty {
                                    Text(title)
                                        .font(Look.heading)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, Look.cardInset)
                                        .padding(.vertical, Look.inset + 2)
                                        .background(.windowBackground)
                                        .overlay(alignment: .bottom) { Hairline() }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .onChange(of: revision) {
                    if let edited { proxy.scrollTo(edited, anchor: .center) }
                }
            }
        }
        .background(Look.cardFill)
        .clipShape(.rect(cornerRadius: Look.pillRadius))
        .hairline(radius: Look.pillRadius, Look.cardStroke)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: Look.inset) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Feature name or shortcut (like “Command T”)", text: $query)
                .textFieldStyle(.plain)
                .font(Look.text)
                .onChange(of: query) { stopRecording() }
                .accessibilityLabel("Search Shortcuts")
                .accessibilityHint("Search by feature name or keys, such as new tab or cmd t.")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Look.cardInset)
        .frame(height: Look.settingsRow)
        .background(Look.controlFill)
    }

    // MARK: - Guidance

    private var guidance: some View {
        VStack(alignment: .leading, spacing: Look.inset * 2) {
            HStack(spacing: Look.inset) {
                illustratedKey("command")
                illustratedKey("face.smiling")
            }
            .accessibilityHidden(true)
            .padding(.bottom, Look.inset)

            VStack(alignment: .leading, spacing: Look.inset) {
                Text("Custom Shortcuts")
                    .font(.system(size: 16, weight: .semibold))
                Text("Change shortcuts for your favorite actions, and choose whether Vane or a website takes priority.")
                    .font(Look.rowTitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }

            Text(recording == nil
                 ? "Click a shortcut, then press the keys you want to use."
                 : "Press your new shortcut. Escape cancels; Delete removes it.")
                .font(Look.footnote)
                .foregroundStyle(recording == nil ? Color.secondary : Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            Spacer(minLength: Look.inset * 3)

            HStack(spacing: Look.inset) {
                Button("Reset All Shortcuts", action: resetAll)
                    .buttonStyle(.plain)
                    .font(Look.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: Look.control + Look.inset)
                    .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
                    .disabled(customized.isEmpty)
                Menu {
                    Button("Reset All Shortcuts…", action: resetAll)
                        .disabled(customized.isEmpty)
                    if recording != nil {
                        Button("Cancel Recording") { stopRecording() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: Look.control + Look.inset, height: Look.control + Look.inset)
                        .background(Look.controlFill, in: .circle)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Shortcut options")
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func illustratedKey(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 60, height: 60)
            .background(.white.opacity(0.65), in: .rect(cornerRadius: Look.pillRadius))
            .hairline(radius: Look.pillRadius, .white.opacity(0.7))
            .padding(5)
            .background(Color.accentColor, in: .rect(cornerRadius: Look.pillRadius + 4))
            .hairline(radius: Look.pillRadius + 4, Color.accentColor.opacity(0.5))
    }

    private func resetAll() {
        stopRecording()
        guard confirm("Reset every shortcut to its default?", "Reset All",
                      "Any keys and website priorities you have changed go back to their defaults.")
        else { return }
        edited = nil
        Keybindings.resetAll()
        rebuild()
        notes = [:]
        revision += 1
        axAnnounce("All shortcuts reset to their defaults.")
    }

    // MARK: - Row

    private func row(_ command: Command) -> some View {
        let binding = Keybindings.binding(for: command)
        let note = notes[command]
        let isHovered = hovered == command
        let live = recording == command
        let priority = Keybindings.priority(for: command)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Look.inset) {
                Text(command.title)
                    .font(Look.rowTitle)
                    .foregroundStyle(Look.inkPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Look.inset)
                if isHovered || live || priority == .page {
                    priorityMenu(command, priority)
                } else {
                    Color.clear.frame(width: Look.control, height: Look.control)
                        .accessibilityHidden(true)
                }
                chip(command, binding)
            }
            .padding(.horizontal, Look.cardInset * 1.5)
            .padding(.vertical, Look.inset)
            .frame(minHeight: Look.settingsRow + Look.inset)
            if let note {
                Label(note.text, systemImage: note.bad ? "exclamationmark.circle" : "exclamationmark.triangle")
                    .font(Look.caption)
                    .foregroundStyle(note.bad ? Color.red : Color.orange)
                    .padding(.horizontal, Look.cardInset * 1.5)
                    .padding(.bottom, Look.inset)
            }
        }
        .contentShape(.rect)
        .background(live ? Look.accentSelected : isHovered ? Look.hovered : .clear)
        .animation(reduceMotion ? nil : Look.quick, value: isHovered)
        .onHover { inside in
            if inside { hovered = command } else if hovered == command { hovered = nil }
        }
        .contextMenu {
            Button("Change Shortcut") { startRecording(command) }
            Button("Reset Shortcut to Default") { reset(command) }
                .disabled(!customized.contains(command))
            Button("Remove Shortcut") {
                stopRecording()
                save(.unassigned, for: command)
            }
            .disabled(!binding.isAssigned)
            Divider()
            Button(priority == .page ? "Prefer Vane" : "Prefer Website") {
                setPriority(priority == .page ? .browser : .page, for: command)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.title)
        .accessibilityValue(live ? "recording a shortcut"
                            : binding.isAssigned ? "shortcut \(binding.display)" : "no shortcut")
        .accessibilityHint(note?.text ?? "Activate to change this shortcut.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { startRecording(command) }
        .accessibilityAction(named: "Change Shortcut") { startRecording(command) }
        .accessibilityAction(named: "Reset") { reset(command) }
        .accessibilityAction(named: "Remove Shortcut") {
            stopRecording()
            save(.unassigned, for: command)
        }
        .accessibilityAction(named: priority == .page ? "Prefer Vane" : "Prefer Website") {
            setPriority(priority == .page ? .browser : .page, for: command)
        }
    }

    private func chip(_ command: Command, _ binding: Keybinding) -> some View {
        let live = recording == command
        return Button {
            live ? stopRecording() : startRecording(command)
        } label: {
            Text(live ? "Type keys…" : binding.display)
                .font(Look.heading.monospacedDigit())
                .foregroundStyle(live ? Color.white
                                 : binding.isAssigned ? Color.primary : Color.secondary)
                .padding(.horizontal, Look.inset)
                .frame(minWidth: Look.chip * 2.5)
                .frame(height: Look.chip + 2)
                .background(live ? Color.accentColor : Look.controlFill,
                            in: .rect(cornerRadius: Look.chipRadius))
                .hairline(radius: Look.chipRadius, live ? Color.accentColor : Look.hairline)
        }
        .buttonStyle(.plain)
        .help(live ? "Press the keys, or Escape to cancel" : "Click to change; right-click for options")
    }

    private func priorityMenu(_ command: Command, _ priority: Keybindings.Priority) -> some View {
        Menu {
            Button("Prefer Vane") { setPriority(.browser, for: command) }
            Button("Prefer Website") { setPriority(.page, for: command) }
        } label: {
            Image(systemName: priority == .page ? "globe" : "ellipsis")
                .font(Look.caption).foregroundStyle(.secondary)
                .frame(width: Look.control)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Shortcut priority for \(command.title)")
        .help(priority == .page ? "Prefer Website" : "Prefer Vane")
    }

    // MARK: - Recording

    /// A local monitor is the only place that sees a key before the main menu does, so it is
    /// the only place a recorder can work.
    /// ponytail: Keybindings' own monitor (installed in main.swift) also sees this event and
    /// there is no defined order between monitors, so the actions map is emptied for the
    /// duration — a recorded ⌘T must not also open a tab. Ceiling: any code that reads
    /// `Keybindings.actions` mid-recording sees nothing; nothing does today.
    private func startRecording(_ command: Command) {
        stopRecording()
        recording = command
        notes[command] = nil
        parked = Keybindings.actions
        Keybindings.actions = [:]
        axAnnounce("Recording a shortcut for \(command.title). Press the keys, or Escape to cancel.")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // A Bool out of the isolated block, not the event: NSEvent is not Sendable.
            let passOn = MainActor.assumeIsolated { () -> Bool in
                // The monitor is app-wide; the recorder is not. See `reach`.
                guard Self.reach(inSettingsWindow: SettingsWindow.holds(event.window)) == .record
                else {
                    stopRecording()
                    return true
                }
                if let pressed = Keybinding(event: event) { apply(Self.capture(pressed), to: command) }
                return false    // swallowed: nothing else should act on the keys being typed
            }
            return passOn ? event : nil
        }
        // The other way out: Settings closing under a row that is still listening. Without
        // it the recorder stood down only on the *next* keystroke (see `reach`), and until
        // one arrived `Keybindings.actions` was empty — so every route into a command that
        // is not a key quietly did nothing: a palette row, the sidebar's Tidy, Clear, the
        // History menu. The pane's own `.onDisappear` cannot say it, because `SettingsWindow`
        // keeps the pane and its hosting view for the next time Settings is opened.
        //
        // No pure row of its own: the answer is still `reach(inSettingsWindow: false)` — a
        // closed window holds no keystroke — and this only asks it sooner.
        closing = SettingsWindow.onClose { stopRecording() }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = nil
        if recording != nil {
            Keybindings.actions = parked
            parked = [:]
        }
        recording = nil
    }

    private func apply(_ capture: Capture, to command: Command) {
        switch capture {
        case .cancel:
            stopRecording()
        case .clear:
            save(.unassigned, for: command)
        case .bind(let binding):
            // Reserved keys are refused, not saved: the user would press them and nothing
            // would happen, because macOS or Vane's own app menu takes them first.
            if let why = Keybindings.reserved(binding) {
                notes[command] = Note(text: why, bad: true)
                stopRecording()
                axAnnounce(why)
            } else {
                save(binding, for: command)
            }
        }
    }

    /// Conflicts are warned about, not refused — Arc does the same, and unassigning the
    /// other command behind the user's back is worse than two commands sharing a key.
    private func save(_ binding: Keybinding, for command: Command) {
        let others = Keybindings.conflicts(binding).filter { $0 != command }
        Keybindings.set(binding, for: command)
        rebuild()               // menu key equivalents are built from these
        edited = command
        revision += 1
        notes[command] = Self.alsoUsedBy(others).map { Note(text: $0, bad: false) }
        stopRecording()
        axAnnounce(binding.isAssigned
                   ? "Shortcut for \(command.title) set to \(binding.display)."
                   : "Shortcut for \(command.title) cleared.")
    }

    private func reset(_ command: Command) {
        stopRecording()
        Keybindings.reset(command)
        rebuild()
        edited = command
        revision += 1
        notes[command] = nil
        axAnnounce("Shortcut for \(command.title) reset to "
                   + "\(Keybindings.binding(for: command).display).")
    }

    private func setPriority(_ priority: Keybindings.Priority, for command: Command) {
        Keybindings.setPriority(priority, for: command)
        edited = command
        revision += 1
        axAnnounce(priority == .page
                   ? "\(command.title) now lets the page win."
                   : "\(command.title) now wins over the page.")
    }
}

// MARK: - Pure parts

extension ShortcutsPane {
    /// What a keystroke means while recording.
    enum Capture: Equatable {
        case cancel
        case clear
        case bind(Keybinding)
    }

    /// What the recorder does with a keystroke that reaches its monitor.
    enum Reach: Equatable {
        /// It is the shortcut being typed.
        case record
        /// It landed somewhere else entirely: stop listening and leave the key alone.
        case release
    }

    /// Only the Settings window's own keystrokes are the shortcut being recorded.
    ///
    /// `startRecording`'s monitor is app-wide and swallows *every* key, and the pane lives in
    /// a window that is only ordered out when it closes — `SettingsWindow` keeps the instance
    /// and its hosting view, so `.onDisappear` never fires. A row left listening (click a key
    /// cap, then close Settings with the red button) therefore kept a monitor on the whole app:
    /// the next keystroke anywhere was swallowed, and if it was bindable it was *saved* as that
    /// command's new shortcut. That is how ⌘W and ⌘T stopped working and stayed that way, and
    /// how ⌘V was eaten once on its way to being refused as a reserved chord.
    static func reach(inSettingsWindow: Bool) -> Reach { inSettingsWindow ? .record : .release }

    /// Escape backs out, a bare Delete unbinds, everything else is the new shortcut. Both
    /// escapes require no modifiers, so ⌘⌫ is still recordable as a shortcut.
    static func capture(_ pressed: Keybinding) -> Capture {
        guard pressed.mods.isEmpty else { return .bind(pressed) }
        switch pressed.display {
        case "⎋": return .cancel
        case "⌫": return .clear
        default:  return .bind(pressed)
        }
    }

    /// The amber line under a row after saving onto keys somebody else holds. Nil when the
    /// keys were free, which is the usual case.
    static func alsoUsedBy(_ others: [Command]) -> String? {
        guard !others.isEmpty else { return nil }
        return "Also used by " + others.map(\.title).joined(separator: ", ")
    }

    /// Customizations stay at the top; the default list is alphabetical like Arc's.
    /// Search keeps the store's ranking rather than regrouping its best matches.
    static func groups(_ query: String, _ results: [Command],
                       customized: Set<Command> = []) -> [(String, [Command])] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return results.isEmpty ? [] : [("", results)]
        }
        let sorted = results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let custom = sorted.filter { customized.contains($0) }
        let defaults = sorted.filter { !customized.contains($0) }
        return [("Custom Shortcuts", custom), ("Default Shortcuts", defaults)]
            .filter { !$0.1.isEmpty }
    }

}

// MARK: - check

extension ShortcutsPane {
    /// Only the pure parts: no defaults, no window server, no AppKit. The store's own
    /// behaviour is already asserted in Keybindings.check().
    static func check() -> [(String, Bool)] {
        let escape = Keybinding("\u{1b}")
        let delete = Keybinding("\u{7f}")
        let all = Command.allCases
        let grouped = groups("", all)
        let ranked = groups("new tab", [.newTab, .newWindow], customized: [.newWindow])
        let custom = groups("", all, customized: [.newTab, .find])
        let onlyCustom = groups("", [.newTab], customized: [.newTab])
        return [
            ("a keystroke in the Settings window is the shortcut being recorded",
             reach(inSettingsWindow: true) == .record),
            ("one anywhere else releases the recorder and is left alone — a row left "
             + "listening behind a closed Settings window used to eat the next key in the "
             + "browser and save it as that command's shortcut",
             reach(inSettingsWindow: false) == .release),

            ("Escape cancels recording", capture(escape) == .cancel),
            ("a bare Delete unbinds", capture(delete) == .clear),
            ("Backspace unbinds too", capture(Keybinding("\u{8}")) == .clear),
            ("⌘⌫ is a shortcut, not an unbind",
             capture(Keybinding("\u{7f}", .command)) == .bind(Keybinding("\u{7f}", .command))),
            ("⌘⎋ is a shortcut, not a cancel",
             capture(Keybinding("\u{1b}", .command)) == .bind(Keybinding("\u{1b}", .command))),
            ("an ordinary chord is recorded",
             capture(Keybinding("t", [.command, .shift]))
                == .bind(Keybinding("t", [.command, .shift]))),
            ("free keys warn about nothing", alsoUsedBy([]) == nil),
            ("one clash names the other command",
             alsoUsedBy([.newTab]) == "Also used by New Tab"),
            ("two clashes are listed",
             alsoUsedBy([.newTab, .newWindow]) == "Also used by New Tab, New Window"),
            ("an empty query shows one default shortcuts list",
             grouped.count == 1 && grouped.first?.0 == "Default Shortcuts"),
            ("default shortcuts are alphabetical",
             grouped.flatMap(\.1) == all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }),
            ("…and lists every command once",
             grouped.flatMap(\.1).count == all.count && Set(grouped.flatMap(\.1)).count == all.count),
            ("customized commands appear first and stay alphabetical",
             custom.first?.0 == "Custom Shortcuts" && custom.first?.1 == [.find, .newTab]),
            ("customizations do not also appear in the defaults",
             custom.count == 2 && !custom[1].1.contains(.newTab) && !custom[1].1.contains(.find)
                && custom.flatMap(\.1).count == all.count),
            ("an entirely customized list omits the empty default section",
             onlyCustom.count == 1 && onlyCustom.first?.0 == "Custom Shortcuts"),
            ("an empty list omits both section headers", groups("", []).isEmpty),
            ("a query is one ranked card, headerless",
             ranked.count == 1 && ranked[0].0 == "" && ranked[0].1 == [.newTab, .newWindow]),
            ("a query matching nothing draws nothing", groups("zzzz", []).isEmpty),
            ("whitespace still counts as an empty query", groups("  ", all).count == grouped.count),
        ]
    }
}
