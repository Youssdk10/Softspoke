import Foundation

/// Spoken commands. "Send it" counts only at the very end, set off by
/// punctuation, so "please send it" stays ordinary text.
public enum VoiceCommands {
    public enum Action: Equatable {
        case none, pressReturn, undo
    }

    /// `handsFree` drops the punctuation requirement. Whisper often leaves none
    /// in longer speech, and in that mode ending on a command is deliberate.
    public static func parse(_ raw: String, handsFree: Bool = false) -> (text: String, action: Action) {
        // Whisper can add labels like "[BLANK_AUDIO]" after the last spoken word.
        let text = TextCleaner.stripNonSpeechTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)

        if text.range(of: #"(?i)^(undo that|delete that|scratch that)[.,!?]*$"#, options: .regularExpression) != nil {
            return ("", .undo)
        }

        let boundary = handsFree ? #"^|\s+|[.,;:!?]\s*"# : #"^|\s*\n\s*|[.,;:!?]\s*"#
        let send = "(?i)(" + boundary + #")(send it|send that|please send|press enter|press return)[.,!?]*$"#
        var kept = text
        var action = Action.none
        // Repeated commands all come off, so "Send it. Send it." can't leave one behind.
        while let range = kept.range(of: send, options: .regularExpression) {
            action = .pressReturn
            // Keep a sentence's final punctuation, and drop a comma left dangling.
            let ending = kept[range].first.flatMap { ".!?".contains($0) ? $0 : nil }
            kept = String(kept[..<range.lowerBound])
            if let ending { kept.append(ending) }
            kept = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (kept, action)
    }
}
