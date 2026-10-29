import Foundation

/// Searchable, offline Unicode data. Decoded only when the Emoji tab is first used.
enum SpaceEmojiCatalog {
    enum Category: String, Codable, CaseIterable, Identifiable {
        case people, nature, food, activities, travel, objects, symbols, flags
        var id: String { rawValue }
        var title: String {
            switch self {
            case .people: "Smileys & People"
            case .nature: "Animals & Nature"
            case .food: "Food & Drink"
            case .activities: "Activities"
            case .travel: "Travel & Places"
            case .objects: "Objects"
            case .symbols: "Symbols"
            case .flags: "Flags"
            }
        }
        var symbol: String {
            switch self {
            case .people: "face.smiling"
            case .nature: "leaf"
            case .food: "cup.and.saucer"
            case .activities: "rosette"
            case .travel: "car"
            case .objects: "gift"
            case .symbols: "heart"
            case .flags: "flag"
            }
        }
    }

    struct Entry: Decodable, Identifiable {
        let emoji: String
        let name: String
        let category: Category
        let searchText: String
        var id: String { emoji }
        private enum CodingKeys: String, CodingKey { case emoji, name, category }

        init(emoji: String, name: String, category: Category) {
            self.emoji = emoji
            self.name = name
            self.category = category
            let normalized = SpaceEmojiCatalog.normalized(name)
            searchText = emoji + " " + normalized + " " + normalized.replacingOccurrences(of: "turkiye", with: "turkey")
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(emoji: try values.decode(String.self, forKey: .emoji),
                      name: try values.decode(String.self, forKey: .name),
                      category: try values.decode(Category.self, forKey: .category))
        }
    }

    static let entries: [Entry] = {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json", subdirectory: "SpaceEmoji"),
              let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }()

    static func search(_ query: String, category: Category) -> [Entry] {
        let tokens = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.isEmpty { return entries.filter { $0.category == category } }
        return entries.filter { entry in tokens.allSatisfy { entry.searchText.contains($0) } }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
