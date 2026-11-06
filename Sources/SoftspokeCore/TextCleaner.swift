import Foundation

/// The user's own vocabulary, read from a plain text file. Each line is either
/// a term ("Kubernetes"), which also hints Whisper, or a fix ("cooper netties -> Kubernetes").
public struct PersonalDictionary {
    public struct Entry: Equatable, Identifiable {
        public var term: String
        public var heardAs: String?
        public var id: String { (heardAs ?? "") + "->" + term }

        public init(term: String, heardAs: String? = nil) {
            self.term = term
            self.heardAs = heardAs
        }
    }

    public var entries: [Entry] = []

    public var terms: [String] { entries.map(\.term) }
    public var replacements: [(from: String, to: String)] {
        entries.compactMap { entry in entry.heardAs.map { ($0, entry.term) } }
    }

    public init() {}

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(parsing text: String) {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let arrow = line.range(of: "->") {
                let from = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                if !from.isEmpty && !to.isEmpty {
                    entries.append(Entry(term: to, heardAs: from))
                }
            } else {
                entries.append(Entry(term: line))
            }
        }
    }

    /// The file format read by `init(parsing:)`.
    public var serialized: String {
        let lines = entries.map { entry in
            entry.heardAs.map { "\($0) -> \(entry.term)" } ?? entry.term
        }
        return (["# Softspoke dictionary. One entry per line: Word, or: misheard -> Word"] + lines)
            .joined(separator: "\n") + "\n"
    }

    /// Text passed to Whisper as context, which nudges it toward these spellings.
    public var prompt: String { terms.joined(separator: ", ") }
}

/// Rule-based cleanup that runs entirely on this Mac. It is deliberately
/// conservative: when a phrase is ambiguous, the speaker's words are kept.
public enum TextCleaner {
    private static let keptRepeats: Set<String> = [
        "that", "had", "is", "very", "really", "so", "no", "yes", "yeah",
        "bye", "ha", "now", "there", "well", "okay", "ok",
    ]

    public static func clean(
        _ raw: String,
        dictionary: PersonalDictionary = PersonalDictionary(),
        removeFillers: Bool = true
    ) -> String {
        var text = stripNonSpeechTags(raw)
        text = collapseWhitespace(text)
        if removeFillers {
            text = applyScratchThat(text)
            text = applyCorrections(text)
            text = stripFillers(text)
            text = stripRepeatedWords(text)
        }
        text = applyDictionary(text, dictionary)
        text = applySpokenBreaks(text)
        return normalize(text)
    }

    // Whisper labels non-speech as "[BLANK_AUDIO]", "(wind blowing)" or "*music*".
    static func stripNonSpeechTags(_ text: String) -> String {
        replace(text, #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#, with: " ")
    }

    static func collapseWhitespace(_ text: String) -> String {
        replace(text, #"\s+"#, with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func stripFillers(_ text: String) -> String {
        var out = replace(
            text, #"(?i)\b(?:um+|uhm+|uh+|erm+|er|ah+|hmm+|mhm+|mm+)\b,?\s*"#, with: "")
        // These carry meaning unless set off by commas ("I like it" must survive).
        out = replace(out, #"(?i),\s*(?:you know|like|i mean)\s*,\s*"#, with: " ")
        out = replace(out, #"(?i)(^|(?<=[.!?]\s))(?:you know|like|i mean),\s*"#, with: "")
        return out
    }

    static func stripRepeatedWords(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b([a-z']+)(?:,?\s+\1\b)+"#) else {
            return text
        }
        var out = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: match.range(at: 1))
            if keptRepeats.contains(word.lowercased()) { continue }
            if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: word) }
        }
        return out
    }

    /// "Buy eggs, scratch that. Buy bread." drops the sentence before the cue.
    static func applyScratchThat(_ text: String) -> String {
        let cue = #"(?i)[,.;:!?]*\s*\bscratch that\b(?=[,.;:!?]|\s*$)[,.;:!?]*\s*"#
        var out = text
        while let range = out.range(of: cue, options: .regularExpression) {
            let before = String(out[..<range.lowerBound])
            let after = String(out[range.upperBound...])
            var kept = ""
            if let end = before.range(of: #".*[.!?]\s"#, options: .regularExpression) {
                kept = String(before[end])
            }
            out = kept + after
        }
        return out
    }

    /// "Meet at 3, no wait, 4." becomes "Meet at 4." The cue must follow
    /// punctuation so that "there's no wait at the door" is left alone.
    static func applyCorrections(_ text: String) -> String {
        let cue = #"(?i)[,.;:!?—-]+\s*(?:no,? wait|wait,? no|actually,? no|no,? actually)\b[,.;:!?—-]*\s*"#
        var out = text
        while let range = out.range(of: cue, options: .regularExpression) {
            let before = String(out[..<range.lowerBound])
            let after = String(out[range.upperBound...])
            out = spliceCorrection(before: before, after: after)
        }
        return out
    }

    private static func spliceCorrection(before: String, after: String) -> String {
        guard let first = words(in: after).first else { return before }

        // Only look back within the sentence being corrected.
        var head = ""
        var sentence = before
        if let end = before.range(of: #".*[.!?]\s"#, options: .regularExpression) {
            head = String(before[end])
            sentence = String(before[end.upperBound...])
        }

        var parts = sentence.split(separator: " ").map(String.init)
        if let index = parts.lastIndex(where: { bare($0) == bare(first) }) {
            // "the red car, no wait, the blue car" restarts from the repeated word.
            parts.removeSubrange(index...)
        } else if !parts.isEmpty {
            // "coffee, no wait, tea" swaps only the last word.
            parts.removeLast()
        }
        let rebuilt = parts.isEmpty ? after : parts.joined(separator: " ") + " " + after
        return head + rebuilt
    }

    static func applyDictionary(_ text: String, _ dictionary: PersonalDictionary) -> String {
        var out = text
        for fix in dictionary.replacements {
            out = replaceWord(out, word: fix.from, with: fix.to)
        }
        for term in dictionary.terms {
            out = replaceWord(out, word: term, with: term)
        }
        return out
    }

    private static func replaceWord(_ text: String, word: String, with replacement: String) -> String {
        let pattern = "(?i)(?<![\\w])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\w])"
        return replace(text, pattern, with: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// "New line" and "new paragraph" count only as whole phrases between
    /// punctuation, so "a new line of products" is kept as spoken.
    static func applySpokenBreaks(_ text: String) -> String {
        let edge = #"(?:^|[,.;:!?]\s*)"#
        let tail = #"(?:[,.;:!?]+\s*|\s*$)"#
        var out = replace(text, "(?i)" + edge + "new paragraph" + tail, with: ".\n\n")
        out = replace(out, "(?i)" + edge + "new line" + tail, with: ".\n")
        return out
    }

    static func normalize(_ text: String) -> String {
        var out = replace(text, #"[ \t]+"#, with: " ")
        out = replace(out, #" +([,.;:!?])"#, with: "$1")
        out = replace(out, #"[,;:]+\s*([.!?])"#, with: "$1")
        out = replace(out, #"([!?])\.+"#, with: "$1")
        out = replace(out, #"(?<![.])\.\.(?![.])"#, with: ".")
        out = replace(out, #"^[\s,.;:!?]+"#, with: "")
        out = replace(out, #"[ \t]*\n[ \t]*"#, with: "\n")
        out = replace(out, #"\bi\b(?!\.)"#, with: "I")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return capitalizeSentences(out)
    }

    private static func capitalizeSentences(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[.!?]\s+|\n\s*)([a-z])"#) else {
            return text
        }
        var out = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            if let range = Range(match.range(at: 1), in: out) {
                out.replaceSubrange(range, with: out[range].uppercased())
            }
        }
        return out
    }

    private static func words(in text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    private static func bare(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
