import AppKit
import Carbon.HIToolbox

/// Puts text at the cursor by pasting, then puts the clipboard back as it was.
enum Paster {
    enum Outcome { case pasted, copiedOnly }

    /// False without permission, or while a password field has focus.
    static var canType: Bool { AXIsProcessTrusted() && !IsSecureEventInputEnabled() }

    static func deliver(_ text: String, thenPressReturn: Bool = false) -> Outcome {
        guard canType else {
            copy(text)
            return .copiedOnly
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Asks clipboard managers not to record this temporary paste.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pasteboard.changeCount

        press(kVK_ANSI_V, flags: .maskCommand)

        if thenPressReturn {
            // Give the app a moment to take the paste, or Return can arrive first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pressReturn() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // If something else has used the clipboard since, leave it alone.
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return .pasted
    }

    static func pressReturn() {
        if canType { press(kVK_Return) }
    }

    static func pressUndo() {
        if canType { press(kVK_ANSI_Z, flags: .maskCommand) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func press(_ keyCode: Int, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(keyCode)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
