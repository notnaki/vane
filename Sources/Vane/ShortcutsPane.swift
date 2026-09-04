import AppKit
import SwiftUI

/// The Shortcuts tab of Settings: every rebindable command, searchable, with its key cap
/// shown on the right the way Arc does it.
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
    @State private var hovered: Command?
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
        // The same rhythm as the other panes' `Pane`: cards a gap and a half apart.
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Look.inset * 1.5) {
                    let groups = cards
                    if groups.isEmpty {
                        Text("No shortcuts match \u{201C}\(query)\u{201D}")
                            .font(Look.text).foregroundStyle(.secondary)
                            .padding(.horizontal, Look.cardInset)
                    }
                    ForEach(groups, id: \.0) { title, commands in
                        if title.isEmpty {
                            card(commands)
                        } else {
                            SettingsSection(title) { card(commands) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            Text("Click a shortcut to change it. \u{201C}Page\u{201D} lets a website\u{2019}s own "
                 + "shortcut win — Vane keeps out of the way while the page has focus.")
                .font(Look.text).foregroundStyle(.secondary)
                .padding(.horizontal, Look.cardInset)
        }
        .padding(.top, Look.inset * 2)
        .onDisappear { stopRecording() }
    }

    /// SwiftUI only redraws for the state a body actually reads, and the rows read the
    /// store rather than any state — so touching `revision` here is what turns a write to
    /// Keybindings into a redraw.
    private var cards: [(String, [Command])] {
        _ = revision
        return Self.groups(query, Keybindings.search(query))
    }

    /// One settings card of rows; the card draws the hairlines between them.
    private func card(_ commands: [Command]) -> some View {
        SettingsCard {
            ForEach(commands, id: \.self) { row($0) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Look.inset) {
            HStack(spacing: Look.inset - 2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search shortcuts", text: $query)
                    .textFieldStyle(.plain)
                    .font(Look.text)
                    .onChange(of: query) { stopRecording() }
            }
            .padding(.horizontal, Look.inset)
            .frame(height: Look.rowHeight)
            .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
            .hairline(radius: Look.pillRadius)
            .accessibilityLabel("Search Shortcuts")
            .accessibilityHint("Matches a command by name or by its keys — \u{201C}new tab\u{201D} "
                               + "or \u{201C}cmd t\u{201D}.")

            Button("Reset All…") {
                guard confirm("Reset every shortcut to its default?", "Reset All",
                              "Any keys you have changed go back to what Vane ships with.")
                else { return }
                Keybindings.resetAll()
                rebuild()
                notes = [:]
                revision += 1
                axAnnounce("All shortcuts reset to their defaults.")
            }
            .buttonStyle(.plain)
            .font(Look.text)
            .padding(.horizontal, Look.inset + 2)
            .frame(height: Look.rowHeight)
            .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
            .hairline(radius: Look.pillRadius)
        }
    }

    // MARK: - Row

    private func row(_ command: Command) -> some View {
        let binding = Keybindings.binding(for: command)
        let note = notes[command]
        let isHovered = hovered == command
        let priority = Keybindings.priority(for: command)
        // The same row every other pane is built from; only what trails the title is
        // this pane's own, and it comes and goes with the pointer.
        return VStack(alignment: .leading, spacing: 0) {
            SettingsRow(command.title) {
                if isHovered || priority == .page { priorityMenu(command, priority) }
                if isHovered && binding != command.defaultBinding {
                    Button { reset(command) } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .font(Look.caption)
                    .foregroundStyle(.secondary)
                    .help("Reset to \(command.defaultBinding.display)")
                }
                chip(command, binding)
            }
            if let note {
                Text(note.text)
                    .font(Look.caption)
                    .foregroundStyle(note.bad ? Color.red : Color.orange)
                    .padding(.horizontal, Look.cardInset)
                    .padding(.bottom, Look.inset)
            }
        }
        .contentShape(.rect)
        .background(isHovered ? Look.hovered : .clear)
        .animation(reduceMotion ? nil : Look.quick, value: isHovered)
        .onHover { inside in
            if inside { hovered = command } else if hovered == command { hovered = nil }
        }
        // One element per row: the chip, the reset button and the priority menu are all
        // reachable as named actions instead, which is fewer stops for the same reach.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.title)
        .accessibilityValue(recording == command ? "recording a shortcut"
                            : binding.isAssigned ? "shortcut \(binding.display)" : "no shortcut")
        .accessibilityHint(note?.text ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Change Shortcut") { startRecording(command) }
        .accessibilityAction(named: "Reset") { reset(command) }
        .accessibilityAction(named: priority == .page ? "Let Vane Win" : "Let the Page Win") {
            setPriority(priority == .page ? .browser : .page, for: command)
        }
    }

    /// The key cap. Clicking it is how you rebind — there is no separate edit affordance,
    /// which is the whole of Arc's shortcuts UI.
    private func chip(_ command: Command, _ binding: Keybinding) -> some View {
        let live = recording == command
        return Button {
            live ? stopRecording() : startRecording(command)
        } label: {
            Text(live ? "Type shortcut…" : binding.isAssigned ? binding.display : "—")
                .font(Look.text.monospacedDigit())
                .foregroundStyle(live ? Color.accentColor
                                 : binding.isAssigned ? Color.primary : Color.secondary)
                .padding(.horizontal, Look.inset)
                .frame(height: Look.chip)
                .frame(minWidth: Look.chip * 2)
                .background(Look.chipFill, in: .rect(cornerRadius: Look.chipRadius))
                .hairline(radius: Look.chipRadius, live ? Color.accentColor : Look.hairline)
        }
        .buttonStyle(.plain)
        .help(live ? "Press the keys, or Escape to cancel" : "Click to change")
    }

    private func priorityMenu(_ command: Command, _ priority: Keybindings.Priority) -> some View {
        Menu {
            Button("Browser") { setPriority(.browser, for: command) }
            Button("Page") { setPriority(.page, for: command) }
        } label: {
            Text(priority == .page ? "Page" : "Browser")
                .font(Look.caption).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Who gets this key first: Vane, or the website.")
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
            guard let pressed = Keybinding(event: event) else { return nil }
            MainActor.assumeIsolated { apply(Self.capture(pressed), to: command) }
            return nil          // swallowed: nothing else should act on the keys being typed
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
        revision += 1
        notes[command] = nil
        axAnnounce("Shortcut for \(command.title) reset to "
                   + "\(Keybindings.binding(for: command).display).")
    }

    private func setPriority(_ priority: Keybindings.Priority, for command: Command) {
        Keybindings.setPriority(priority, for: command)
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

    /// The cards to draw. An empty query is the whole list in menu order, one card per
    /// category; a query is a single card that keeps the search's ranking, because the top
    /// hit is the answer and burying it under a header would hide it.
    static func groups(_ query: String, _ results: [Command]) -> [(String, [Command])] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return results.isEmpty ? [] : [("", results)]
        }
        return Command.Category.allCases.compactMap { category in
            let commands = results.filter { $0.category == category }
            return commands.isEmpty ? nil : (category.rawValue, commands)
        }
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
        let ranked = groups("new tab", [.newTab, .newWindow])
        return [
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
            ("an empty query groups by category", grouped.count == Command.Category.allCases.count),
            ("…in menu order", grouped.first?.0 == "File" && grouped.last?.0 == "Tabs"),
            ("…and lists every command once",
             grouped.flatMap(\.1).count == all.count && Set(grouped.flatMap(\.1)).count == all.count),
            ("a query is one ranked card, headerless",
             ranked.count == 1 && ranked[0].0 == "" && ranked[0].1 == [.newTab, .newWindow]),
            ("a query matching nothing draws nothing", groups("zzzz", []).isEmpty),
            ("whitespace still counts as an empty query", groups("  ", all).count == grouped.count),
        ]
    }
}
