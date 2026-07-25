import Foundation
import CoreServices
import AppKit

enum DictionaryError: LocalizedError {
    case notFound(String)
    case network(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let w): return "No definition found for “\(w)”."
        case .network(let m): return "Couldn't reach the dictionary — \(m)"
        }
    }
}

/// Looks up a word: the free dictionaryapi.dev JSON API (no key), with the on-device macOS
/// dictionary (`DCSCopyTextDefinition`) as an offline / not-found fallback. Dictionary plugin.
enum DictionaryService {

    static func lookup(_ raw: String) async throws -> [WordEntry] {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return [] }
        do {
            return try await fetchOnline(word)
        } catch let e as DictionaryError {
            // Offline or unknown to the web dictionary → try the local macOS dictionaries.
            if let sys = systemDefinition(word) { return [sys] }
            throw e
        }
    }

    // MARK: - Web (dictionaryapi.dev)

    private static func fetchOnline(_ word: String) async throws -> [WordEntry] {
        guard let enc = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(enc)") else {
            throw DictionaryError.notFound(word)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw DictionaryError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw DictionaryError.notFound(word) }
        guard code == 200 else { throw DictionaryError.network("HTTP \(code)") }
        return try parse(data, word: word)
    }

    private static func parse(_ data: Data, word: String) throws -> [WordEntry] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DictionaryError.notFound(word)
        }
        var out: [WordEntry] = []
        for obj in arr {
            let w = (obj["word"] as? String) ?? word
            let phonetics = obj["phonetics"] as? [[String: Any]] ?? []
            let phonetic = (obj["phonetic"] as? String)
                ?? phonetics.compactMap { ($0["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } }.first
            let audioStr = phonetics.compactMap { ($0["audio"] as? String).flatMap { $0.isEmpty ? nil : $0 } }.first
            let audioURL = audioStr.flatMap { s -> URL? in
                s.hasPrefix("http") ? URL(string: s) : URL(string: "https:\(s)")
            }
            var meanings: [WordMeaning] = []
            for m in (obj["meanings"] as? [[String: Any]] ?? []) {
                let pos = (m["partOfSpeech"] as? String) ?? ""
                let defs = (m["definitions"] as? [[String: Any]] ?? []).compactMap { d -> WordDefinition? in
                    guard let t = d["definition"] as? String, !t.isEmpty else { return nil }
                    return WordDefinition(text: t, example: (d["example"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                }
                let syn = (m["synonyms"] as? [String]) ?? []
                let ant = (m["antonyms"] as? [String]) ?? []
                if !defs.isEmpty || !syn.isEmpty || !ant.isEmpty {
                    meanings.append(WordMeaning(partOfSpeech: pos, definitions: defs, synonyms: syn, antonyms: ant))
                }
            }
            if !meanings.isEmpty { out.append(WordEntry(word: w, phonetic: phonetic, audioURL: audioURL, meanings: meanings)) }
        }
        if out.isEmpty { throw DictionaryError.notFound(word) }
        return out
    }

    // MARK: - Spelling suggestions (macOS spell checker)

    /// Spelling corrections for a not-found word ("profligracy" → "profligacy"), best first.
    @MainActor static func suggestions(for word: String) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let guesses = NSSpellChecker.shared.guesses(forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
        var seen = Set<String>()
        return guesses.filter {
            $0.caseInsensitiveCompare(word) != .orderedSame && seen.insert($0.lowercased()).inserted
        }.prefix(6).map { $0 }
    }

    // MARK: - Offline (macOS system dictionaries / Look Up)

    private static func systemDefinition(_ word: String) -> WordEntry? {
        let range = CFRangeMake(0, (word as NSString).length)
        guard let def = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?,
              !def.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return WordEntry(
            word: word, phonetic: nil, audioURL: nil,
            meanings: [WordMeaning(partOfSpeech: "", definitions: [WordDefinition(text: def, example: nil)], synonyms: [], antonyms: [])],
            sourceNote: "macOS dictionary (offline)")
    }
}
