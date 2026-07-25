import Foundation

/// A single sense of a word.
struct WordDefinition: Identifiable {
    let id = UUID()
    let text: String
    let example: String?
}

/// One part-of-speech grouping (noun / verb / …) with its senses + thesaurus links.
struct WordMeaning: Identifiable {
    let id = UUID()
    let partOfSpeech: String
    var definitions: [WordDefinition]
    var synonyms: [String]
    var antonyms: [String]
}

/// A dictionary entry for a word (there can be several per word).
struct WordEntry: Identifiable {
    let id = UUID()
    let word: String
    let phonetic: String?
    var audioURL: URL?
    var meanings: [WordMeaning]
    /// Set when the result came from the offline macOS dictionary rather than the web API.
    var sourceNote: String? = nil
}
