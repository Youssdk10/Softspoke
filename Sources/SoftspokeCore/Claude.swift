import Foundation

public enum ClaudeError: LocalizedError, Equatable {
    case invalidKey
    case busy
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey: return "Your API key wasn't accepted"
        case .busy: return "Claude is busy. Try again in a moment"
        case .rejected(let message): return message
        }
    }
}

/// Reads the server-sent events of a streaming Messages API response. Every
/// content block is kept whole, because thinking blocks must be sent back
/// unchanged on the next turn.
public struct ClaudeStreamParser {
    private var blocks: [Int: [String: Any]] = [:]
    public private(set) var stopReason: String?
    public private(set) var errorMessage: String?

    public init() {}

    /// Takes one line of the stream, and returns any new text to read aloud.
    public mutating func feed(line: String) -> String? {
        guard line.hasPrefix("data:"),
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
            let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        switch event["type"] as? String {
        case "content_block_start":
            if let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] {
                blocks[index] = block
            }
        case "content_block_delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { return nil }
            return apply(delta, to: index)
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
        case "error":
            errorMessage = (event["error"] as? [String: Any])?["message"] as? String ?? "The response stopped early"
        default:
            break
        }
        return nil
    }

    private mutating func apply(_ delta: [String: Any], to index: Int) -> String? {
        var block = blocks[index] ?? [:]
        defer { blocks[index] = block }
        switch delta["type"] as? String {
        case "text_delta":
            let text = delta["text"] as? String ?? ""
            block["text"] = (block["text"] as? String ?? "") + text
            return text
        case "thinking_delta":
            block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
        case "signature_delta":
            block["signature"] = delta["signature"]
        default:
            break
        }
        return nil
    }

    /// The complete content, in order, ready to send back as the assistant turn.
    public var contentBlocks: [[String: Any]] {
        blocks.keys.sorted().compactMap { blocks[$0] }
    }

    public var text: String {
        contentBlocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }
}

/// Calls the Claude Messages API directly, since Swift has no official SDK.
public final class ClaudeClient {
    public static let model = "claude-opus-5-5"
    public static let systemPrompt = """
        You're talking with someone out loud. Your replies are spoken by a text-to-speech voice, \
        so answer the way you would in conversation: usually a sentence or three, in plain words, \
        with no markdown, lists, code blocks or emoji. Reply in the language they use. \
        Their words come from speech recognition, so if something looks misheard, go with the \
        likely meaning, or ask.
        """

    public struct Reply {
        public let content: [[String: Any]]
        public let text: String
        public let stopReason: String?
    }

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        session = URLSession(configuration: config)
    }

    /// Streams one reply, calling `onText` as the words arrive.
    public func send(messages: [[String: Any]], onText: (String) -> Void) async throws -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.model,
            "max_tokens": 64000,
            "stream": true,
            "fallbacks": "default",
            // A spoken chat needs a quick answer more than a deep one.
            "output_config": ["effort": "low"],
            "system": Self.systemPrompt,
            "messages": messages,
        ] as [String: Any])

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw Self.error(status: status, body: body)
        }

        var parser = ClaudeStreamParser()
        for try await line in bytes.lines {
            if let text = parser.feed(line: line) { onText(text) }
            if let message = parser.errorMessage { throw ClaudeError.rejected(message) }
        }
        return Reply(content: parser.contentBlocks, text: parser.text, stopReason: parser.stopReason)
    }

    static func error(status: Int, body: String) -> ClaudeError {
        switch status {
        case 401, 403: return .invalidKey
        case 429, 500...599: return .busy
        default:
            let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            return .rejected(message ?? "Claude returned error \(status)")
        }
    }
}

/// Cuts streaming text into whole sentences, so each can be spoken as it's ready.
public struct SentenceSplitter {
    private var buffer = ""

    public init() {}

    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        // A boundary needs following whitespace, which leaves "3.5" and "example.com" whole.
        while let range = buffer.range(of: #"[.!?…]+["')\]]*\s+|\n+"#, options: .regularExpression) {
            let sentence = buffer[..<range.upperBound].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[range.upperBound...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    /// Whatever is left once the reply has ended.
    public mutating func finish() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }
}

/// Removes formatting that a voice would otherwise read out as symbols.
public enum SpeechText {
    public static func clean(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"https?://\S+"#, with: "link", options: .regularExpression)
        out = out.replacingOccurrences(of: #"^\s*(#{1,6}|[-*•]|\d+\.)\s+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
