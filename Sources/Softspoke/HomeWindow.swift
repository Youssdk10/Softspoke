import AppKit
import SoftspokeCore
import SwiftUI

struct HomeActions {
    var allowMicrophone: () -> Void = {}
    var allowTyping: () -> Void = {}
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var addDictionaryEntry: (String, String) -> Void = { _, _ in }
    var removeDictionaryEntry: (PersonalDictionary.Entry) -> Void = { _ in }
    var copy: (String) -> Void = { _ in }
    var quit: () -> Void = {}
    var saveAPIKey: (String) -> Void = { _ in }
    var removeAPIKey: () -> Void = {}
    var previewVoice: () -> Void = {}
    var newConversation: () -> Void = {}
}

private let mint = Color(red: 0.36, green: 0.90, blue: 0.78)
private let amber = Color(red: 1.0, green: 0.74, blue: 0.36)

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.hairline))
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.18)))
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let allowed: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if allowed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(mint)
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.40, green: 0.62, blue: 1.0))
            }
        }
    }
}

private struct CommandRow: View {
    let phrase: String
    let effect: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(phrase)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 118, alignment: .leading)
            Text(effect)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HomeView: View {
    @ObservedObject var model: AppModel
    let actions: HomeActions

    @State private var newTerm = ""
    @State private var newHeardAs = ""
    @State private var newAPIKey = ""

    private let idleWave: [CGFloat] = [0.95, 0.8, 0.9, 0.6, 0.72, 0.42, 0.5, 0.26, 0.2]

    var body: some View {
        VStack(spacing: 14) {
            header
            Picker("", selection: $model.tab) {
                ForEach(HomeTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.tab {
                    case .dictate: dictateTab
                    case .talk: talkTab
                    case .dictionary: dictionaryTab
                    case .settings: settingsTab
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 480, height: 700)
        .background(
            ZStack {
                Brand.background
                RadialGradient(
                    colors: [Color(red: 0.32, green: 0.36, blue: 0.85).opacity(0.28), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 330)
            }
        )
        .foregroundStyle(.white)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Waveform(levels: idleWave, barWidth: 4, maxHeight: 34)
            Text("Softspoke")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            HStack(spacing: 7) {
                Text("Hold")
                KeyCap(text: model.hotkey.label)
                Text("to talk, or double-tap for hands-free")
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 6) {
                Circle().fill(model.isReady ? mint : amber).frame(width: 7, height: 7)
                Text(headerStatus)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
    }

    private var headerStatus: String {
        if !model.engineReady { return model.status }
        if !model.microphoneAllowed || !model.typingAllowed { return "Two quick permissions and you're set" }
        if model.talkMode { return "Talking to Claude. Your words go to Anthropic" }
        return "Ready. Dictation runs entirely on this Mac"
    }

    // MARK: Dictate

    @ViewBuilder private var dictateTab: some View {
        if !model.microphoneAllowed || !model.typingAllowed { setup }
        Card {
            SectionTitle(text: "Try it here")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.tryItText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14))
                    .frame(height: 76)
                if model.tryItText.isEmpty {
                    Text("Click here, hold \(model.hotkey.label), and say something…")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.25)))
        }
        Card {
            SectionTitle(text: "Say this")
            CommandRow(phrase: "“Send it.”", effect: "Pastes your words, then presses Enter. In hands-free, just say it and pause. No tap needed.")
            CommandRow(phrase: "“Please send.”", effect: "Does the same, as does “Press enter.”")
            CommandRow(phrase: "“Undo that.”", effect: "On its own, undoes the last paste. Most apps support this.")
        }
        if !model.history.isEmpty { recent }
    }

    private var setup: some View {
        Card {
            SectionTitle(text: "Finish setting up")
            PermissionRow(
                icon: "mic.fill",
                title: "Microphone",
                detail: "Only listens while you dictate.",
                allowed: model.microphoneAllowed,
                action: actions.allowMicrophone)
            Divider().overlay(Brand.hairline)
            PermissionRow(
                icon: "keyboard.fill",
                title: "Accessibility",
                detail: "Detects the key and types into other apps. Switch on Softspoke in the list that opens.",
                allowed: model.typingAllowed,
                action: actions.allowTyping)
        }
    }

    private var recent: some View {
        Card {
            SectionTitle(text: "Recent")
            ForEach(Array(model.history.prefix(4).enumerated()), id: \.offset) { _, text in
                HStack(alignment: .top, spacing: 10) {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button { actions.copy(text) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.55))
                    .help("Copy")
                }
            }
        }
    }

    // MARK: Talk

    @ViewBuilder private var talkTab: some View {
        if !model.hasAPIKey {
            Card {
                SectionTitle(text: "Connect to Claude")
                Text("Paste an API key from console.anthropic.com. It's stored in your Keychain. API use is billed by Anthropic, separately from your Claude plan.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("API key", text: $newAPIKey)
                    .textFieldStyle(.roundedBorder)
                Button("Save Key") {
                    actions.saveAPIKey(newAPIKey)
                    newAPIKey = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.40, green: 0.62, blue: 1.0))
                .disabled(newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        Card {
            Toggle("Talk to Claude instead of typing", isOn: $model.talkMode)
                .disabled(!model.hasAPIKey)
            Text("While this is on, your dictation key talks to Claude, and nothing is typed into other apps. Your words and Claude's replies go through Anthropic.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Voice", selection: $model.voiceID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.voices) { Text($0.label).tag(String?.some($0.id)) }
                }
                Button("Preview", action: actions.previewVoice)
            }
        }
        .font(.system(size: 13))
        if !model.talkMessages.isEmpty {
            Card {
                HStack {
                    SectionTitle(text: "This conversation")
                    Spacer()
                    Button("New Conversation", action: actions.newConversation)
                }
                ForEach(model.talkMessages) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.fromClaude ? "Claude" : "You")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(message.fromClaude ? mint : .white.opacity(0.55))
                        Text(message.text.isEmpty ? "…" : message.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.88))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if model.hasAPIKey {
            HStack {
                Spacer()
                Button("Remove API Key", action: actions.removeAPIKey)
            }
        }
    }

    // MARK: Dictionary

    @ViewBuilder private var dictionaryTab: some View {
        Card {
            SectionTitle(text: "Add a word")
            TextField("Correct spelling, like Kubernetes", text: $newTerm)
                .textFieldStyle(.roundedBorder)
            TextField("Optional: what it mishears, like cooper netties", text: $newHeardAs)
                .textFieldStyle(.roundedBorder)
            Button("Add", action: addEntry)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.40, green: 0.62, blue: 1.0))
                .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Card {
            SectionTitle(text: "Your words")
            if model.dictionaryEntries.isEmpty {
                Text("Add names and jargon here so they're spelled your way.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ForEach(model.dictionaryEntries) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.term).font(.system(size: 13, weight: .semibold))
                        if let heardAs = entry.heardAs {
                            Text("Fixes “\(heardAs)”")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Spacer()
                    Button { actions.removeDictionaryEntry(entry) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.45))
                    .help("Remove")
                }
            }
        }
    }

    private func addEntry() {
        actions.addDictionaryEntry(newTerm, newHeardAs)
        newTerm = ""
        newHeardAs = ""
    }

    // MARK: Settings

    @ViewBuilder private var settingsTab: some View {
        Card {
            SectionTitle(text: "Dictation key")
            Picker("Key", selection: $model.hotkey) {
                ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
            }
            if model.hotkey == .fn {
                Text("If fn also opens emoji or dictation, set “Press 🌐 key to” to “Do Nothing” in System Settings > Keyboard.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Card {
            Toggle("Clean up filler words and self-corrections", isOn: $model.cleanupEnabled)
            Toggle("Voice commands, like “send it”", isOn: $model.commandsEnabled)
            Toggle("Play sounds", isOn: $model.soundsEnabled)
            Toggle(
                "Open at login",
                isOn: Binding(get: { model.openAtLogin }, set: { actions.setOpenAtLogin($0) }))
        }
        .font(.system(size: 13))
        HStack {
            Spacer()
            Button("Quit Softspoke", action: actions.quit)
        }
    }
}

final class HomeWindowController {
    private let window: NSWindow

    init(model: AppModel, actions: HomeActions) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Softspoke"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: HomeView(model: model, actions: actions))
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
