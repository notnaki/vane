enum PasswordGenerator {
    /// Swift's system generator uses the platform's secure random source. Pick from each
    /// character group, fill from the whole alphabet, then shuffle their positions.
    static func generate(length: Int = 20) -> String {
        let groups = [Array("abcdefghijklmnopqrstuvwxyz"), Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
                      Array("0123456789"), Array("!@#$%&*-_=+?")]
        let alphabet = groups.flatMap { $0 }
        let count = min(max(length, 12), 64)
        var random = SystemRandomNumberGenerator()
        var characters = groups.map { $0.randomElement(using: &random)! }
        while characters.count < count {
            characters.append(alphabet.randomElement(using: &random)!)
        }
        characters.shuffle(using: &random)
        return String(characters)
    }
}
