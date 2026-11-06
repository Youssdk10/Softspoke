import Foundation
import SoftspokeCore

// Runs without a microphone or any permissions:
//   softspoke-selftest                 cleanup and audio checks
//   softspoke-selftest --e2e FILE.wav MODEL [DICTIONARY_TERMS]   real transcription

var failures = 0

func check(_ input: String, _ expected: String, dictionary: PersonalDictionary = PersonalDictionary()) {
    let actual = TextCleaner.clean(input, dictionary: dictionary)
    if actual == expected {
        print("  ok    \(input.debugDescription)")
    } else {
        failures += 1
        print("  FAIL  \(input.debugDescription)\n        got      \(actual.debugDescription)\n        expected \(expected.debugDescription)")
    }
}

func checkTrue(_ name: String, _ condition: Bool) {
    if condition {
        print("  ok    \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name)")
    }
}

// Holds a two-turn conversation with a server, to check streaming and history.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--chat" {
    let client = ClaudeClient(apiKey: "test-key", baseURL: URL(string: CommandLine.arguments[2])!)
    var messages: [[String: Any]] = []
    for question in ["First question", "Second question"] {
        messages.append(["role": "user", "content": question])
        var splitter = SentenceSplitter()
        do {
            let reply = try await client.send(messages: messages) { text in
                for sentence in splitter.feed(text) { print("  speak: \(sentence)") }
            }
            if let rest = splitter.finish() { print("  speak: \(rest)") }
            print("  stop=\(reply.stopReason ?? "none") blocks=\(reply.content.count)")
            messages.append(["role": "assistant", "content": reply.content])
        } catch {
            print("  error: \(error.localizedDescription)")
            exit(0)
        }
    }
    exit(0)
}

// Plays a recording through the same pause and command checks hands-free uses.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--live" {
    let file = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    guard let chunk = file.range(of: Data("data".utf8)) else { fatalError("no audio data") }
    var samples = file[(chunk.upperBound + 4)...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    // An optional level adds random room noise on top of the speech.
    let noise = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) ?? 0 : 0
    if noise > 0 {
        samples = samples.map { Int16(clamping: Int($0) + Int.random(in: -noise...noise)) }
    }
    let engine = WhisperEngine(modelPath: CommandLine.arguments[3])
    try await engine.start()

    var confirmer = CommandConfirmer()
    let step = Int(AudioFormat.commandCheckInterval * Double(AudioFormat.sampleRate))
    let tailCount = Int(AudioFormat.commandTailSeconds * Double(AudioFormat.sampleRate))
    var position = step
    var fired = false
    while position <= samples.count, !fired {
        let tail = Array(samples[max(0, position - tailCount)..<position])
        if !AudioFormat.isSilent(tail) {
            let clock = Date()
            let heard = try await engine.transcribe(wav: AudioFormat.wav(samples: tail), quick: true)
            let command = VoiceCommands.parse(heard, handsFree: true).action == .pressReturn
            let time = Double(position) / Double(AudioFormat.sampleRate)
            fired = confirmer.observe(heardCommand: command, at: Date(timeIntervalSinceReferenceDate: time))
            print(String(format: "  %.1fs (%.2fs) command=%d fired=%d: %@", time, Date().timeIntervalSince(clock), command ? 1 : 0, fired ? 1 : 0, heard.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")))
        }
        position += step
    }
    engine.stop()
    print(fired ? "RESULT: SENT" : "RESULT: not sent")
    exit(0)
}

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--e2e" {
    let wav = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let engine = WhisperEngine(modelPath: CommandLine.arguments[3])
    let prompt = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : ""

    var clock = Date()
    try await engine.start()
    print(String(format: "engine ready in %.2fs", Date().timeIntervalSince(clock)))

    for attempt in 1...2 {
        clock = Date()
        let raw = try await engine.transcribe(wav: wav, prompt: prompt)
        print(String(format: "run %d took %.2fs", attempt, Date().timeIntervalSince(clock)))
        print("raw:     \(raw.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("cleaned: \(TextCleaner.clean(raw, dictionary: PersonalDictionary(parsing: prompt)))")
    }
    engine.stop()
    exit(0)
}

print("Fillers")
check("Um, hello there.", "Hello there.")
check("So, uh, I think we should go.", "So, I think we should go.")
check("Hello, um.", "Hello.")
check("It was, like, really good.", "It was really good.")
check("Like, I went home.", "I went home.")
check("I like it a lot.", "I like it a lot.")
check("You know what I want.", "You know what I want.")
check("The summer was warm.", "The summer was warm.")

print("Repeated words")
check("I I think the the plan works.", "I think the plan works.")
check("I think that that is fine.", "I think that that is fine.")
check("It is very very good.", "It is very very good.")

print("Self-corrections")
check("Meet at 3, no wait, 4.", "Meet at 4.")
check("Meet at 3. No wait, 4.", "Meet at 4.")
check("I want coffee, no wait, tea.", "I want tea.")
check("Take the red car, no wait, the blue car.", "Take the blue car.")
check("Hi Sam. Let's meet Tuesday, actually no, Friday.", "Hi Sam. Let's meet Friday.")
check("There's no wait at the door.", "There's no wait at the door.")
check("Buy milk. Buy eggs, scratch that. Buy bread.", "Buy milk. Buy bread.")
check("Buy milk. Scratch that.", "")
check("I'll scratch that off the list.", "I'll scratch that off the list.")

print("Spoken breaks")
check("Hello there. New line. How are you?", "Hello there.\nHow are you?")
check("First point. New paragraph. Second point.", "First point.\n\nSecond point.")
check("We launched a new line of products.", "We launched a new line of products.")

print("Non-speech and tidying")
check("[BLANK_AUDIO]", "")
check(" (wind blowing) ", "")
check("hello world. how are you?", "Hello world. How are you?")
check("and i said yes", "And I said yes")
check("Wait... really?", "Wait... Really?")
check("It costs 3.50 today.", "It costs 3.50 today.")

print("Personal dictionary")
let dictionary = PersonalDictionary(parsing: """
    # comments are ignored
    Kubernetes
    cooper netties -> Kubernetes
    y c -> YC
    """)
checkTrue("parses terms", dictionary.terms == ["Kubernetes", "Kubernetes", "YC"])
checkTrue("parses fixes", dictionary.replacements.count == 2)
check("We use cooper netties at work.", "We use Kubernetes at work.", dictionary: dictionary)
check("we use KUBERNETES here.", "We use Kubernetes here.", dictionary: dictionary)
check("I applied to Y C last year.", "I applied to YC last year.", dictionary: dictionary)
check("The bicycle is fine.", "The bicycle is fine.", dictionary: dictionary)

let reparsed = PersonalDictionary(parsing: dictionary.serialized)
checkTrue("saving and reloading keeps every entry", reparsed.entries == dictionary.entries)

print("Voice commands")
func checkCommand(_ input: String, _ text: String, _ action: VoiceCommands.Action) {
    let parsed = VoiceCommands.parse(input)
    checkTrue("\(input.debugDescription) gives \(text.debugDescription), \(action)", parsed.text == text && parsed.action == action)
}
checkCommand(" Looks good. Send it.", "Looks good.", .pressReturn)
checkCommand("Thanks for that, send it!", "Thanks for that", .pressReturn)
checkCommand("Okay. Press enter.", "Okay.", .pressReturn)
checkCommand("Send it.", "", .pressReturn)
checkCommand("I'm testing the feature. Please send.", "I'm testing the feature.", .pressReturn)
checkCommand("Please send.", "", .pressReturn)
checkCommand("What time is it? Send it. Send it.", "What time is it?", .pressReturn)
checkCommand("Send it. Please send.", "", .pressReturn)
checkCommand("Could you please send", "Could you please send", .none)
checkCommand("Please send the file.", "Please send the file.", .none)
checkCommand("Please send it.", "Please send it.", .none)
checkCommand("We should send it", "We should send it", .none)
checkCommand("Send it to the team.", "Send it to the team.", .none)
checkCommand("Undo that.", "", .undo)
checkCommand("Scratch that.", "", .undo)
checkCommand("Buy milk. Scratch that.", "Buy milk. Scratch that.", .none)

func checkHandsFree(_ input: String, _ text: String, _ action: VoiceCommands.Action) {
    let parsed = VoiceCommands.parse(input, handsFree: true)
    checkTrue("hands-free \(input.debugDescription) gives \(text.debugDescription), \(action)", parsed.text == text && parsed.action == action)
}
checkHandsFree("I finished the report and send it", "I finished the report and", .pressReturn)
checkHandsFree("Let me know what you think send it.", "Let me know what you think", .pressReturn)
checkHandsFree("Looks good. Send it.", "Looks good.", .pressReturn)
checkHandsFree("Please resend it", "Please resend it", .none)
checkHandsFree("Send it to the team tomorrow.", "Send it to the team tomorrow.", .none)
checkCommand("Looks good\n Send it.", "Looks good", .pressReturn)
checkCommand("Let me know what you think send it", "Let me know what you think send it", .none)

checkCommand("Send it. [BLANK_AUDIO]", "", .pressReturn)
checkCommand("Sounds good. Send it. (keyboard clicking)", "Sounds good.", .pressReturn)
checkHandsFree("What do you think send it [BLANK_AUDIO]", "What do you think", .pressReturn)

print("Command confirmation")
let base = Date()
func later(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }
var confirmer = CommandConfirmer()
checkTrue("first sighting waits", !confirmer.observe(heardCommand: true, at: later(0)))
checkTrue("too soon still waits", !confirmer.observe(heardCommand: true, at: later(0.3)))
checkTrue("fires after the hold time", confirmer.observe(heardCommand: true, at: later(0.6)))
var interrupted = CommandConfirmer()
_ = interrupted.observe(heardCommand: true, at: later(0))
checkTrue("more speech resets it", !interrupted.observe(heardCommand: false, at: later(0.3)))
checkTrue("a later sighting waits again", !interrupted.observe(heardCommand: true, at: later(0.6)))
checkTrue("and needs its own hold time", !interrupted.observe(heardCommand: true, at: later(0.9)))

print("Hotkey gesture")
let start = Date()
func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

var hold = HotkeyGesture()
checkTrue("hold: press starts", hold.press(at: at(0)) == .startRecording)
checkTrue("hold: release finishes", hold.release(at: at(1)) == .finish)

var doubleTap = HotkeyGesture()
checkTrue("tap: press starts", doubleTap.press(at: at(0)) == .startRecording)
checkTrue("tap: quick release discards", doubleTap.release(at: at(0.1)) == .discard)
checkTrue("double-tap: second press starts", doubleTap.press(at: at(0.25)) == .startRecording)
checkTrue("double-tap: is hands-free", doubleTap.isHandsFree)
checkTrue("hands-free: release keeps going", doubleTap.release(at: at(0.3)) == .none)
checkTrue("hands-free: typing doesn't cancel", doubleTap.otherKey(isEscape: false) == .none)
checkTrue("hands-free: next press finishes", doubleTap.press(at: at(9)) == .finish)
checkTrue("hands-free: its release does nothing", doubleTap.release(at: at(9.1)) == .none)
checkTrue("after hands-free: back to holding", doubleTap.press(at: at(20)) == .startRecording && !doubleTap.isHandsFree)

var slowTaps = HotkeyGesture()
_ = slowTaps.press(at: at(0))
_ = slowTaps.release(at: at(0.1))
_ = slowTaps.press(at: at(2))
checkTrue("slow taps aren't a double-tap", !slowTaps.isHandsFree)

var shortcut = HotkeyGesture()
_ = shortcut.press(at: at(0))
checkTrue("key during hold discards", shortcut.otherKey(isEscape: false) == .discard)
checkTrue("release after a shortcut does nothing", shortcut.release(at: at(0.1)) == .none)

var escape = HotkeyGesture()
_ = escape.press(at: at(0))
_ = escape.release(at: at(0.1))
_ = escape.press(at: at(0.2))
checkTrue("Escape cancels hands-free", escape.otherKey(isEscape: true) == .discard && !escape.isHandsFree)

print("Claude stream")
var stream = ClaudeStreamParser()
var streamed = ""
for line in [
    "event: content_block_start",
    #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
    #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
    #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello "}}"#,
    #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"there."}}"#,
    #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
    "not json at all",
] {
    if let text = stream.feed(line: line) { streamed += text }
}
checkTrue("collects the spoken text", streamed == "Hello there." && stream.text == "Hello there.")
checkTrue("keeps the thinking signature", stream.contentBlocks.first?["signature"] as? String == "abc")
checkTrue("keeps blocks in order", stream.contentBlocks.last?["type"] as? String == "text")
checkTrue("reads the stop reason", stream.stopReason == "end_turn")

print("Sentence splitting")
var splitter = SentenceSplitter()
checkTrue("waits for a whole sentence", splitter.feed("Hello the").isEmpty)
checkTrue("splits at the end of one", splitter.feed("re. How are") == ["Hello there."])
checkTrue("keeps decimals together", splitter.feed(" you at 3.5 miles? Fine") == ["How are you at 3.5 miles?"])
checkTrue("returns the rest at the end", splitter.finish() == "Fine")
checkTrue("then has nothing left", splitter.finish() == nil)

print("Speech text")
checkTrue("drops emphasis marks", SpeechText.clean("This is **really** good") == "This is really good")
checkTrue("drops list markers", SpeechText.clean("- First item") == "First item")
checkTrue("keeps link text only", SpeechText.clean("See [the docs](https://x.com) now") == "See the docs now")
checkTrue("doesn't read web addresses", SpeechText.clean("Go to https://x.com/a now") == "Go to link now")
checkTrue("skips code blocks", SpeechText.clean("Try ```let a = 1``` this") == "Try   this")

print("Cleanup off")
let untouched = TextCleaner.clean("Um, the the plan.", removeFillers: false)
checkTrue("keeps the speaker's words", untouched == "Um, the the plan.")

print("Audio")
let samples: [Int16] = [0, 1000, -1000, 32767]
let wav = AudioFormat.wav(samples: samples)
checkTrue("WAV has a 44-byte header plus samples", wav.count == 44 + samples.count * 2)
checkTrue("WAV starts with RIFF", String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
checkTrue("WAV stores the sample rate", wav[24] == 0x80 && wav[25] == 0x3E)
checkTrue("WAV stores samples little-endian", wav[46] == 0xE8 && wav[47] == 0x03)
checkTrue("silence is detected", AudioFormat.isSilent([Int16](repeating: 5, count: 16000)))
checkTrue("empty audio counts as silence", AudioFormat.isSilent([]))
checkTrue("speech-level audio passes", !AudioFormat.isSilent([Int16](repeating: 3000, count: 16000)))

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
