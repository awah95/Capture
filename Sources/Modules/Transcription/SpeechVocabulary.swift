import Foundation

/// Speech engines receive only the user's explicit vocabulary, never captured editor
/// or clipboard prose. Canonical terms are separate from Whisper's prose prompt.
enum SpeechVocabulary {
    static let maximumTerms = 100
    static let maximumTermScalars = 80

    static func bounded(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.unicodeScalars.count <= maximumTermScalars,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !text.contains(","), seen.insert(text.lowercased()).inserted else { continue }
            result.append(text)
            if result.count == maximumTerms { break }
        }
        return result
    }
}
