import AppKit
import SwiftUI

/// Compact symbol and emoji palettes shared by the sidebar and theme editor.
struct SpaceIconPicker: View {
    private enum Mode: String, CaseIterable { case emoji = "Emoji", icon = "Icon" }
    @Environment(\.spaceChromeTheme) private var chromeTheme
    let current: String
    let pick: (String) -> Void
    @State private var mode: Mode
    @State private var category = SpaceEmojiCatalog.Category.people
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 4), count: 8)

    init(current: String, pick: @escaping (String) -> Void) {
        self.current = current
        self.pick = pick
        _mode = State(initialValue: current.allSatisfy(\.isASCII) ? .icon : .emoji)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Picker("Icon type", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Button { pick("cloud") } label: { Image(systemName: "trash").font(Look.icon) }
                    .buttonStyle(.plain).foregroundStyle(Look.inkSecondary)
                    .frame(width: 32, height: 32)
                    .vaneTooltip("Reset icon")
                    .accessibilityLabel("Reset Space icon")
                Spacer(minLength: 0)
            }.frame(height: 36)
            if mode == .emoji {
                search
                emojiGrid
                categories
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Spaces.pickerIcons, id: \.self) { symbol in
                            SpaceIconTile(selected: current == symbol || (current != "cloud" && current + ".fill" == symbol),
                                          title: symbol, action: { pick(symbol) }) {
                                Image(systemName: symbol).font(Look.icon)
                            }
                        }
                    }
                }.scrollIndicators(.never).frame(height: 276)
            }
        }
        .padding(12).frame(width: 340)
        .animation(Motion.reduced ? nil : Look.quick, value: mode)
        .animation(Motion.reduced ? nil : Look.quick, value: category)
        .onChange(of: mode) { searchFocused = mode == .emoji }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space icon")
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Look.inkSecondary)
            TextField("Search emoji", text: $query)
                .textFieldStyle(.plain).font(Look.text).focused($searchFocused)
                .accessibilityLabel("Search emoji")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Clear emoji search")
            }
            Button {
                searchFocused = true
                NSApp.orderFrontCharacterPalette(nil)
            } label: { Image(systemName: "face.smiling") }
                .buttonStyle(.plain).foregroundStyle(Look.inkSecondary)
                .help("Emoji & Symbols… (Control-Command-Space)")
                .accessibilityLabel("Open system emoji picker")
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(chromeTheme.pillFill, in: .rect(cornerRadius: Look.pillRadius))
    }

    private var emojiGrid: some View {
        var entries = SpaceEmojiCatalog.search(query, category: category)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 1, let emoji = Spaces.emojiIcon(trimmed), !entries.contains(where: { $0.emoji == emoji }) {
            entries.insert(.init(emoji: emoji, name: "Use \(emoji)", category: category), at: 0)
        }
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(entries) { entry in
                    SpaceIconTile(selected: current == entry.emoji, title: entry.name,
                                  action: { pick(entry.emoji) }) {
                        Text(verbatim: entry.emoji).font(.system(size: 24))
                    }
                }
            }
            if entries.isEmpty {
                Text("No emoji found").font(Look.small).foregroundStyle(Look.inkSecondary)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .scrollIndicators(.never).frame(height: 236)
        .id(category.rawValue + ":" + query)
    }

    private var categories: some View {
        VStack(spacing: 6) {
            Divider()
            HStack(spacing: 0) {
                ForEach(SpaceEmojiCatalog.Category.allCases) { item in
                    Button {
                        category = item
                        query = ""
                    } label: {
                        Image(systemName: item.symbol).font(Look.icon)
                            .foregroundStyle(category == item ? Look.inkPrimary : Look.inkSecondary)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain).help(item.title).accessibilityLabel(item.title)
                    .accessibilityAddTraits(category == item ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}

private struct SpaceIconTile<Content: View>: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    let selected: Bool
    let title: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content().foregroundStyle(Look.inkPrimary)
                .frame(width: 36, height: 36)
                .background(selected ? chromeTheme.selected : hovered ? chromeTheme.hovered : .clear,
                            in: .rect(cornerRadius: Look.pillRadius))
                .contentShape(.rect)
        }
        .buttonStyle(TactileButtonStyle())
        .onHover { inside in Motion.animate(Look.quick) { hovered = inside } }
        .help(title).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
