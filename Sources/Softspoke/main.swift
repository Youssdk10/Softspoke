import AVFoundation
import AppKit
import Combine
import SoftspokeCore
import ServiceManagement

private let escapeKeyCode: UInt16 = 53
/// Quick taps and shortcuts shouldn't flash the pill, so it waits this long.
private let revealDelay: TimeInterval = 0.18

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let supportFolder: URL
    private let dictionaryURL: URL
    private let engine: WhisperEngine
    private let recorder = Recorder()
    private lazy var talk = TalkSession(model: model)

    private var overlay: OverlayController!
    private var home: HomeWindowController!
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private var localMonitors: [Any] = []
    private var globalMonitors: [Any] = []
    private var permissionTimer: Timer?
    private var terminationSource: DispatchSourceSignal?
    private var pendingHide: DispatchWorkItem?
    private var pendingReveal: DispatchWorkItem?
    private var hotkeyWatcher: AnyCancellable?
    private var launchedAtLogin = false
    private var gesture = HotkeyGesture()
    private var isRecording = false
    private var recordingIsHandsFree = false
    private var keyIsDown = false
    private var commandTimer: Timer?
    private var commandConfirmer = CommandConfirmer()
    private var commandCheckRunning = false
    private var recordingID = 0
    private var sendWhenFinished = false
    private var queue: Task<Void, Never>?

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportFolder = support.appendingPathComponent("Softspoke")
        dictionaryURL = supportFolder.appendingPathComponent("dictionary.txt")
        engine = WhisperEngine(
            modelPath: supportFolder.appendingPathComponent("models/ggml-base.en.bin").path)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The launch event is only available this early.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin =
            event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched: accessibility=\(AXIsProcessTrusted()) microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        createDictionaryIfNeeded()
        reloadDictionary()
        buildMenu()

        overlay = OverlayController(model: model)
        home = HomeWindowController(
            model: model,
            actions: HomeActions(
                allowMicrophone: { [weak self] in self?.allowMicrophone() },
                allowTyping: { [weak self] in self?.allowTyping() },
                setOpenAtLogin: { [weak self] in self?.setOpenAtLogin($0) },
                addDictionaryEntry: { [weak self] in self?.addDictionaryEntry(term: $0, heardAs: $1) },
                removeDictionaryEntry: { [weak self] in self?.removeDictionaryEntry($0) },
                copy: { Paster.copy($0) },
                quit: { NSApp.terminate(nil) },
                saveAPIKey: { [weak self] in self?.saveAPIKey($0) },
                removeAPIKey: { [weak self] in self?.removeAPIKey() },
                previewVoice: { [weak self] in self?.talk.preview(voiceID: self?.model.voiceID) },
                newConversation: { [weak self] in self?.talk.reset() }))

        model.hasAPIKey = APIKeyStore.load() != nil
        if !model.hasAPIKey { model.talkMode = false }
        loadVoices()
        talk.showPhase = { [weak self] phase in self?.showTalkPhase(phase) }

        recorder.onLevel = { [weak self] level in self?.model.push(level: level) }

        // A recording in progress mustn't outlive a change of key.
        hotkeyWatcher = model.$hotkey.dropFirst().sink { [weak self] _ in self?.discardRecording() }

        installLocalHotkey()
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        startEngine()
        stopCleanlyOnTerminationSignal()
        configureOpenAtLoginOnFirstRun()

        // Stay out of the way at login, unless something still needs setting up.
        if !launchedAtLogin || !AXIsProcessTrusted()
            || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
        {
            home.show()
        }

        // Ask right away, so the system prompt appears on first launch.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { allowMicrophone() }
    }

    // MARK: Talk

    private func loadVoices() {
        model.voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") || $0.language.hasPrefix("fr") }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { VoiceOption(id: $0.identifier, label: "\($0.name) (\($0.language))") }
    }

    private func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.hasAPIKey = APIKeyStore.save(trimmed)
        if model.hasAPIKey {
            model.talkMode = true
        } else {
            flash(.message("Couldn't save to your Keychain"))
        }
    }

    private func removeAPIKey() {
        talk.reset()
        APIKeyStore.remove()
        model.hasAPIKey = false
        model.talkMode = false
    }

    private func showTalkPhase(_ phase: AppModel.Phase) {
        guard !isRecording else { return }
        if case .message = phase {
            flash(phase)
            return
        }
        pendingHide?.cancel()
        model.phase = phase
    }

    // MARK: Open at login

    /// Turned on once, because you asked for it. After that, the switch decides.
    private func configureOpenAtLoginOnFirstRun() {
        let key = "openAtLoginConfigured"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            setOpenAtLogin(true)
        }
        refreshOpenAtLogin()
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("open at login change failed: \(error.localizedDescription)")
            flash(.message("Couldn't change Open at Login"))
        }
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshOpenAtLogin()
    }

    private func refreshOpenAtLogin() {
        let status = SMAppService.mainApp.status
        Log.write("open at login status: \(status.rawValue)")
        model.openAtLogin = status == .enabled
    }

    /// Opening the app while it's already running lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        home.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    /// Without this, a plain `kill` would leave the speech engine running.
    private func stopCleanlyOnTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source
    }

    // MARK: Setup

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon("mic")
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        statusLine.title = model.status
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Softspoke", action: #selector(openHome), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func setIcon(_ symbol: String, tint: NSColor? = nil) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Softspoke")
        statusItem.button?.contentTintColor = tint
    }

    private func setStatus(_ text: String) {
        model.status = text
        statusLine.title = text
    }

    private func startEngine() {
        model.engineReady = false
        setStatus("Loading speech model…")
        Task { @MainActor in
            do {
                try await engine.start()
                model.engineReady = true
                setStatus("Ready to dictate")
                Log.write("engine ready")
            } catch {
                setStatus(error.localizedDescription)
                setIcon("exclamationmark.triangle")
                Log.write("engine failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Dictionary

    private func createDictionaryIfNeeded() {
        guard !FileManager.default.fileExists(atPath: dictionaryURL.path) else { return }
        saveDictionary(PersonalDictionary())
    }

    private func loadDictionary() -> PersonalDictionary {
        let text = (try? String(contentsOf: dictionaryURL, encoding: .utf8)) ?? ""
        return PersonalDictionary(parsing: text)
    }

    private func reloadDictionary() {
        model.dictionaryEntries = loadDictionary().entries
    }

    private func saveDictionary(_ dictionary: PersonalDictionary) {
        try? FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
        try? dictionary.serialized.write(to: dictionaryURL, atomically: true, encoding: .utf8)
    }

    private func addDictionaryEntry(term: String, heardAs: String) {
        let term = term.trimmingCharacters(in: .whitespaces)
        let heard = heardAs.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        var dictionary = loadDictionary()
        let entry = PersonalDictionary.Entry(term: term, heardAs: heard.isEmpty ? nil : heard)
        guard !dictionary.entries.contains(entry) else { return }
        dictionary.entries.append(entry)
        saveDictionary(dictionary)
        reloadDictionary()
    }

    private func removeDictionaryEntry(_ entry: PersonalDictionary.Entry) {
        var dictionary = loadDictionary()
        dictionary.entries.removeAll { $0 == entry }
        saveDictionary(dictionary)
        reloadDictionary()
    }

    // MARK: Permissions

    /// macOS gives no callback when these change, so they're checked each second.
    private func refreshPermissions() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let typing = AXIsProcessTrusted()
        if microphone != model.microphoneAllowed { Log.write("microphone allowed: \(microphone)") }
        if typing != model.typingAllowed { Log.write("accessibility allowed: \(typing)") }
        model.microphoneAllowed = microphone
        model.typingAllowed = typing
        if typing { installGlobalHotkey() }
    }

    private func allowMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.write("microphone prompt answered: \(granted)")
            }
        } else {
            openPrivacySettings("Privacy_Microphone")
        }
    }

    private func allowTyping() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        openPrivacySettings("Privacy_Accessibility")
    }

    private func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Hotkey

    /// Handles the key while Softspoke itself is in front, as in the try-it box.
    private func installLocalHotkey() {
        if let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleModifier(event)
            return event
        }) {
            localMonitors.append(flags)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleOtherKey(event)
            return event
        }) {
            localMonitors.append(keys)
        }
    }

    /// Handles the key in every other app. This needs Accessibility.
    private func installGlobalHotkey() {
        guard globalMonitors.isEmpty else { return }
        Log.write("global hotkey installed")
        if let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleModifier(event)
        }) {
            globalMonitors.append(flags)
        }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleOtherKey(event)
        }) {
            globalMonitors.append(keys)
        }
    }

    private func handleModifier(_ event: NSEvent) {
        let hotkey = model.hotkey
        guard event.keyCode == hotkey.keyCode else { return }
        let isDown = event.modifierFlags.rawValue & hotkey.deviceMask != 0
        guard isDown != keyIsDown else { return }
        keyIsDown = isDown
        perform(isDown ? gesture.press(at: Date()) : gesture.release(at: Date()))
    }

    private func handleOtherKey(_ event: NSEvent) {
        if event.keyCode == escapeKeyCode, talk.isActive {
            talk.stop()
            model.phase = .hidden
        }
        perform(gesture.otherKey(isEscape: event.keyCode == escapeKeyCode))
    }

    private func perform(_ action: HotkeyGesture.Action) {
        switch action {
        case .none: break
        case .startRecording: startRecording()
        case .finish: finishRecording()
        case .discard: discardRecording()
        }
    }

    // MARK: Dictation

    private func startRecording() {
        guard model.engineReady else {
            gesture.reset()
            Log.write("recording refused: engine not ready")
            flash(.message("Speech model is still loading"))
            return
        }
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        guard microphone == .authorized else {
            gesture.reset()
            Log.write("recording refused: microphone status \(microphone.rawValue)")
            flash(.message("Allow the microphone first"))
            home.show()
            return
        }
        // Talking over Claude stops its voice, just as in a real conversation.
        talk.stop()
        do {
            model.resetLevels()
            try recorder.start()
            isRecording = true
            recordingIsHandsFree = gesture.isHandsFree
            recordingID += 1
            sendWhenFinished = false
            Log.write("recording started, hands-free=\(gesture.isHandsFree)")
            if gesture.isHandsFree {
                revealRecording()
                if model.commandsEnabled { startListeningForCommand() }
            } else {
                let reveal = DispatchWorkItem { [weak self] in self?.revealRecording() }
                pendingReveal = reveal
                DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay, execute: reveal)
            }
        } catch {
            gesture.reset()
            Log.write("recording failed: \(error.localizedDescription)")
            flash(.message("Couldn't start the microphone"))
        }
    }

    /// Keeps checking hands-free speech for "send it", so no tap is needed.
    private func startListeningForCommand() {
        commandConfirmer = CommandConfirmer()
        commandTimer = Timer.scheduledTimer(withTimeInterval: AudioFormat.commandCheckInterval, repeats: true) { [weak self] _ in
            self?.checkForCommand()
        }
    }

    private func checkForCommand() {
        guard !commandCheckRunning else { return }
        let tail = recorder.tail(seconds: AudioFormat.commandTailSeconds)
        guard tail.count >= AudioFormat.sampleRate, !AudioFormat.isSilent(tail) else { return }
        commandCheckRunning = true
        let id = recordingID
        Task { @MainActor in
            defer { commandCheckRunning = false }
            do {
                let started = Date()
                let heard = try await engine.transcribe(wav: AudioFormat.wav(samples: tail), quick: true)
                guard isRecording, recordingID == id else { return }
                let command = VoiceCommands.parse(heard, handsFree: true).action == .pressReturn
                let fires = commandConfirmer.observe(heardCommand: command, at: Date())
                // Quiet stretches only matter around a command, so skip logging the rest.
                if command {
                    Log.write(String(format: "command check took %.2fs, fires=%d", Date().timeIntervalSince(started), fires ? 1 : 0))
                }
                guard fires else { return }
                gesture.reset()
                sendWhenFinished = true
                finishRecording()
            } catch {
                Log.write("command check failed: \(error.localizedDescription)")
            }
        }
    }

    private func revealRecording() {
        guard isRecording else { return }
        pendingHide?.cancel()
        model.phase = gesture.isHandsFree ? .handsFree : .listening
        setIcon("mic.fill", tint: .systemRed)
        play("Tink")
    }

    /// Drops the recording. Used for quick taps, shortcuts and Escape.
    private func discardRecording() {
        pendingReveal?.cancel()
        commandTimer?.invalidate()
        guard isRecording else { return }
        isRecording = false
        _ = recorder.stop()
        gesture = gesture.isHandsFree ? HotkeyGesture() : gesture
        Log.write("recording discarded")
        setIcon("mic")
        model.phase = queue == nil ? .hidden : .transcribing
    }

    private func finishRecording() {
        pendingReveal?.cancel()
        commandTimer?.invalidate()
        guard isRecording else { return }
        isRecording = false
        let samples = recorder.stop()
        setIcon("mic")
        let silent = AudioFormat.isSilent(samples)
        Log.write("recording stopped: \(samples.count) samples, silent=\(silent)")
        if silent {
            flash(.message("Didn't hear anything"))
            return
        }
        play("Pop")
        model.phase = .transcribing

        // Finish dictations in order, even if you start the next one early.
        let previous = queue
        let handsFree = recordingIsHandsFree
        let forceSend = sendWhenFinished
        queue = Task { @MainActor [weak self] in
            await previous?.value
            await self?.process(samples, handsFree: handsFree, forceSend: forceSend)
            if let self, !self.isRecording { self.queue = nil }
        }
    }

    @MainActor
    private func process(_ samples: [Int16], handsFree: Bool, forceSend: Bool) async {
        let dictionary = loadDictionary()
        let wav = AudioFormat.wav(samples: samples)
        do {
            let raw = try await transcribeRestartingIfNeeded(wav: wav, prompt: dictionary.prompt)
            let command = model.commandsEnabled
                ? VoiceCommands.parse(raw, handsFree: handsFree) : (text: raw, action: VoiceCommands.Action.none)
            let text = TextCleaner.clean(command.text, dictionary: dictionary, removeFillers: model.cleanupEnabled)
            Log.write("transcribed: \(raw.count) characters raw, \(text.count) after cleanup, command=\(command.action)")
            if model.talkMode {
                if text.isEmpty {
                    flash(.message("Didn't catch that"))
                } else {
                    talk.send(text)
                }
                return
            }
            deliver(text, command: forceSend ? .pressReturn : command.action)
        } catch {
            Log.write("transcription failed: \(error.localizedDescription)")
            flash(.message("Couldn't transcribe that"))
        }
    }

    private func deliver(_ text: String, command: VoiceCommands.Action) {
        if text.isEmpty {
            switch command {
            case .none:
                flash(.message("Didn't catch that"))
            case .pressReturn where Paster.canType:
                Paster.pressReturn()
                flash(.done)
            case .undo where Paster.canType:
                Paster.pressUndo()
                flash(.done)
            default:
                flash(.message("Can't type here"))
            }
            return
        }

        model.addToHistory(text)
        let sending = command == .pressReturn
        // The trailing space keeps consecutive dictations from running together.
        let outcome = Paster.deliver(sending ? text : text + " ", thenPressReturn: sending)
        Log.write("delivered: \(outcome), sent=\(sending)")
        flash(outcome == .pasted ? .done : .message("Copied. Press ⌘V to paste"))
    }

    private func transcribeRestartingIfNeeded(wav: Data, prompt: String) async throws -> String {
        do {
            return try await engine.transcribe(wav: wav, prompt: prompt)
        } catch {
            try await engine.start()
            return try await engine.transcribe(wav: wav, prompt: prompt)
        }
    }

    /// Shows a result briefly, without interrupting a recording in progress.
    private func flash(_ phase: AppModel.Phase) {
        guard !isRecording else { return }
        pendingHide?.cancel()
        model.phase = phase
        let duration: TimeInterval = phase == .done ? 0.9 : 2.4
        let hide = DispatchWorkItem { [weak self] in
            guard let self, !self.isRecording else { return }
            self.model.phase = self.queue == nil ? .hidden : .transcribing
        }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: hide)
    }

    private func play(_ name: String) {
        if model.soundsEnabled { NSSound(named: name)?.play() }
    }

    // MARK: Menu actions

    @objc private func openHome() {
        reloadDictionary()
        home.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let snapshotFlag = CommandLine.arguments.firstIndex(of: "--snapshot")
if let snapshotFlag, CommandLine.arguments.count > snapshotFlag + 1 {
    app.setActivationPolicy(.accessory)
    Snapshots.render(to: CommandLine.arguments[snapshotFlag + 1])
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
