import AVFoundation
import AppKit
import SoftspokeCore
import Security

/// Keeps the API key in your login Keychain, never in a plain file or the log.
enum APIKeyStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.softspoke.app",
        kSecAttrAccount as String: "anthropic-api-key",
    ]

    static func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Reads sentences aloud, one after another, with a built-in Mac voice.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending = 0
    var onIdle: (() -> Void)?
    var isSpeaking: Bool { pending > 0 }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voiceID: String?) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        pending += 1
        synthesizer.speak(utterance)
    }

    func stop() {
        pending = 0
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishedOne()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // `stop()` has already reset the count.
    }

    private func finishedOne() {
        pending = max(0, pending - 1)
        if pending == 0 { onIdle?() }
    }
}

/// One spoken conversation with Claude. It's kept in memory only.
final class TalkSession {
    private let model: AppModel
    private let speaker = Speaker()
    private var history: [[String: Any]] = []
    private var task: Task<Void, Never>?
    private var streamFinished = true
    /// Sets the pill, unless a recording currently owns it.
    var showPhase: (AppModel.Phase) -> Void = { _ in }

    init(model: AppModel) {
        self.model = model
        speaker.onIdle = { [weak self] in self?.finishIfDone() }
    }

    var isActive: Bool { task != nil || speaker.isSpeaking }

    func preview(voiceID: String?) {
        stop()
        speaker.speak("Hello. This is how I'd sound in a conversation.", voiceID: voiceID)
    }

    /// Stops the voice and any reply in progress, as when you start talking again.
    func stop() {
        task?.cancel()
        task = nil
        streamFinished = true
        speaker.stop()
    }

    func reset() {
        stop()
        history = []
        model.talkMessages = []
    }

    func send(_ text: String) {
        guard let key = APIKeyStore.load() else {
            showPhase(.message("Add your API key in the Talk tab"))
            return
        }
        stop()
        history.append(["role": "user", "content": text])
        model.talkMessages.append(.init(fromClaude: false, text: text))
        model.talkMessages.append(.init(fromClaude: true, text: ""))
        showPhase(.thinking)
        streamFinished = false

        let messages = history
        task = Task { @MainActor [weak self] in
            await self?.stream(messages: messages, key: key)
        }
    }

    @MainActor
    private func stream(messages: [[String: Any]], key: String) async {
        var splitter = SentenceSplitter()
        var spoken = ""
        let client = ClaudeClient(apiKey: key)
        do {
            let reply = try await client.send(messages: messages) { [weak self] text in
                guard let self else { return }
                spoken += text
                self.updateLastMessage(spoken)
                for sentence in splitter.feed(text) { self.say(sentence) }
            }
            if let rest = splitter.finish() { say(rest) }

            if reply.stopReason == "refusal" {
                // A declined turn leaves no reply to continue from.
                Log.write("claude reply declined")
                history.removeLast()
                updateLastMessage("Claude declined to answer that.")
                say("I can't help with that one.")
            } else {
                history.append(["role": "assistant", "content": reply.content])
                Log.write("claude reply: \(reply.text.count) characters, stop=\(reply.stopReason ?? "none")")
            }
        } catch is CancellationError {
            keepPartialReply(spoken)
            return
        } catch let error as URLError where error.code == .cancelled {
            keepPartialReply(spoken)
            return
        } catch {
            Log.write("claude request failed: \(error.localizedDescription)")
            history.removeLast()
            model.talkMessages.removeLast()
            task = nil
            streamFinished = true
            speaker.stop()
            showPhase(.message(error.localizedDescription))
            return
        }
        task = nil
        streamFinished = true
        finishIfDone()
    }

    /// If you interrupted, Claude should remember only what it got to say.
    private func keepPartialReply(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            history.removeLast()
            model.talkMessages.removeLast()
        } else {
            history.append(["role": "assistant", "content": [["type": "text", "text": trimmed]]])
        }
    }

    private func updateLastMessage(_ text: String) {
        guard !model.talkMessages.isEmpty else { return }
        model.talkMessages[model.talkMessages.count - 1].text = text
    }

    private func say(_ sentence: String) {
        let clean = SpeechText.clean(sentence)
        guard !clean.isEmpty else { return }
        showPhase(.speaking)
        speaker.speak(clean, voiceID: model.voiceID)
    }

    private func finishIfDone() {
        if streamFinished, !speaker.isSpeaking { showPhase(.hidden) }
    }
}
