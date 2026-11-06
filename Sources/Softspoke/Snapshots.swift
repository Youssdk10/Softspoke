import AppKit
import SoftspokeCore
import SwiftUI

/// `Softspoke --snapshot DIR` renders each screen to a PNG, so the design can be
/// reviewed without permissions, a microphone or screen recording.
enum Snapshots {
    static func render(to folder: String) {
        let voice: [CGFloat] = [0.9, 0.7, 0.85, 0.5, 0.65, 0.35, 0.45, 0.2, 0.15]
        let pills: [(String, AppModel.Phase)] = [
            ("pill-listening", .listening),
            ("pill-handsfree", .handsFree),
            ("pill-writing", .transcribing),
            ("pill-done", .done),
            ("pill-message", .message("Allow the microphone first")),
        ]
        for (name, phase) in pills {
            let view = PillContent(phase: phase, levels: voice)
                .padding(30)
                .background(Color(white: 0.75))
            save(view, size: NSSize(width: 400, height: 110), name: name, folder: folder)
        }

        let size = NSSize(width: 480, height: 700)

        let setup = model(ready: false)
        save(HomeView(model: setup, actions: HomeActions()), size: size, name: "home-setup", folder: folder)

        let dictate = model(ready: true)
        dictate.history = ["Let's meet at 3 o'clock on Wednesday.", "Send the notes to the team tomorrow morning."]
        save(HomeView(model: dictate, actions: HomeActions()), size: size, name: "home-dictate", folder: folder)

        let talkSetup = model(ready: true)
        talkSetup.tab = .talk
        talkSetup.voices = [.init(id: "a", label: "Samantha (en-US)")]
        talkSetup.voiceID = "a"
        save(HomeView(model: talkSetup, actions: HomeActions()), size: size, name: "home-talk-setup", folder: folder)

        let talk = model(ready: true)
        talk.tab = .talk
        talk.hasAPIKey = true
        talk.talkMode = true
        talk.voices = talkSetup.voices
        talk.voiceID = "a"
        talk.talkMessages = [
            .init(fromClaude: false, text: "What's a good name for a coffee shop?"),
            .init(fromClaude: true, text: "How about Morning Ritual? It's warm and easy to remember."),
        ]
        save(HomeView(model: talk, actions: HomeActions()), size: size, name: "home-talk", folder: folder)
        save(PillContent(phase: .speaking, levels: voice).padding(30).background(Color(white: 0.75)), size: NSSize(width: 400, height: 110), name: "pill-speaking", folder: folder)

        let dictionary = model(ready: true)
        dictionary.tab = .dictionary
        dictionary.dictionaryEntries = [
            .init(term: "Claude", heardAs: "A club"),
            .init(term: "Kubernetes"),
        ]
        save(HomeView(model: dictionary, actions: HomeActions()), size: size, name: "home-dictionary", folder: folder)

        let settings = model(ready: true)
        settings.tab = .settings
        settings.openAtLogin = true
        save(HomeView(model: settings, actions: HomeActions()), size: size, name: "home-settings", folder: folder)
    }

    private static func model(ready: Bool) -> AppModel {
        let model = AppModel()
        model.engineReady = true
        model.microphoneAllowed = ready
        model.typingAllowed = ready
        return model
    }

    private static func save<V: View>(_ view: V, size: NSSize, name: String, folder: String) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}
