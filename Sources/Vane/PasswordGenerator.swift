enum PasswordGenerator {
    struct Options: Equatable {
        var length = 20
        var lowercase = true
        var uppercase = true
        var digits = true
        var symbols = true
        var hasCharacters: Bool { lowercase || uppercase || digits || symbols }
    }

    /// Swift's system generator uses the platform's secure random source.
    static func generate(length: Int = 20) -> String {
        generate(options: Options(length: length))
    }

    static func generate(options: Options) -> String {
        var groups: [[Character]] = []
        if options.lowercase { groups.append(Array("abcdefghijklmnopqrstuvwxyz")) }
        if options.uppercase { groups.append(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")) }
        if options.digits { groups.append(Array("0123456789")) }
        if options.symbols { groups.append(Array("!@#$%&*-_=+?")) }
        // Callers disable Use when every group is off; keep the API safe for other callers.
        if groups.isEmpty { groups = [Array("abcdefghijklmnopqrstuvwxyz")] }
        let alphabet = groups.flatMap { $0 }
        let count = min(max(options.length, 12), 64)
        var random = SystemRandomNumberGenerator()
        var characters = groups.map { $0.randomElement(using: &random)! }
        while characters.count < count {
            characters.append(alphabet.randomElement(using: &random)!)
        }
        characters.shuffle(using: &random)
        return String(characters)
    }
}
