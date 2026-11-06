import AppKit
import Combine
import SoftspokeCore

/// The keys offered for dictation. All are modifiers, because holding one
/// types nothing by itself.
enum HotkeyChoice: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, rightShift, fn

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .rightShift: return 60
        case .fn: return 63
        }
    }

    /// Separates the right-hand key from its left-hand twin.
    var deviceMask: UInt {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        case .rightShift: return 0x4
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        case .rightShift: return "Right ⇧"
        case .fn: return "fn"
        }
    }
}

struct TalkMessage: Identifiable {
    let id = UUID()
    let fromClaude: Bool
    var text: String
}

struct VoiceOption: Identifiable, Hashable {
    let id: String
    let label: String
}

enum HomeTab: String, CaseIterable, Identifiable {
    case dictate = "Dictate"
    case talk = "Talk"
    case dictionary = "Dictionary"
    case settings = "Settings"

    var id: String { rawValue }
}

/// Everything the pill and the home window display.
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case hidden, listening, handsFree, transcribing, done, thinking, speaking
        case message(String)
    }

    static let barCount = 9

    @Published var phase: Phase = .hidden
    @Published var levels = [CGFloat](repeating: 0, count: AppModel.barCount)
    @Published var status = "Loading speech model…"
    @Published var engineReady = false
    @Published var microphoneAllowed = false
    @Published var typingAllowed = false
    /// Recent dictations, kept in memory only and gone when the app quits.
    @Published var history: [String] = []
    @Published var tryItText = ""
    @Published var openAtLogin = false
    @Published var tab: HomeTab = .dictate
    @Published var dictionaryEntries: [PersonalDictionary.Entry] = []
    @Published var talkMessages: [TalkMessage] = []
    @Published var voices: [VoiceOption] = []
    @Published var hasAPIKey = false

    @Published var talkMode: Bool {
        didSet { UserDefaults.standard.set(talkMode, forKey: "talkMode") }
    }
    @Published var voiceID: String? {
        didSet { UserDefaults.standard.set(voiceID, forKey: "voiceID") }
    }

    @Published var hotkey: HotkeyChoice {
        didSet { UserDefaults.standard.set(hotkey.rawValue, forKey: "hotkey") }
    }
    @Published var cleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(cleanupEnabled, forKey: "cleanup") }
    }
    @Published var commandsEnabled: Bool {
        didSet { UserDefaults.standard.set(commandsEnabled, forKey: "commands") }
    }
    @Published var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "sounds") }
    }

    init() {
        let defaults = UserDefaults.standard
        hotkey = HotkeyChoice(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption
        cleanupEnabled = defaults.object(forKey: "cleanup") as? Bool ?? true
        commandsEnabled = defaults.object(forKey: "commands") as? Bool ?? true
        soundsEnabled = defaults.object(forKey: "sounds") as? Bool ?? true
        talkMode = defaults.bool(forKey: "talkMode")
        voiceID = defaults.string(forKey: "voiceID")
    }

    /// Newest loudness enters at the centre of the waveform and moves outward.
    func push(level: CGFloat) {
        levels.removeLast()
        levels.insert(level, at: 0)
    }

    func resetLevels() {
        levels = [CGFloat](repeating: 0, count: AppModel.barCount)
    }

    func addToHistory(_ text: String) {
        history.insert(text, at: 0)
        if history.count > 10 { history.removeLast() }
    }

    var isReady: Bool { engineReady && microphoneAllowed && typingAllowed }
}
