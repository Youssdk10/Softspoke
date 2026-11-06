import Foundation

/// Turns presses of the dictation key into actions:
/// hold to talk, or double-tap to talk hands-free until the next tap.
public struct HotkeyGesture {
    public enum Action: Equatable {
        case none, startRecording, finish, discard
    }

    private enum State {
        case idle
        case holding(since: Date)
        case handsFree
        case finishingHandsFree
    }

    public static let minimumHold: TimeInterval = 0.25
    public static let doubleTapWindow: TimeInterval = 0.4

    private var state: State = .idle
    private var lastTap: Date?

    public init() {}

    public var isHandsFree: Bool {
        if case .handsFree = state { return true }
        return false
    }

    public mutating func press(at time: Date) -> Action {
        switch state {
        case .idle:
            if let lastTap, time.timeIntervalSince(lastTap) <= Self.doubleTapWindow {
                self.lastTap = nil
                state = .handsFree
            } else {
                state = .holding(since: time)
            }
            return .startRecording
        case .handsFree:
            state = .finishingHandsFree
            return .finish
        case .holding, .finishingHandsFree:
            return .none
        }
    }

    public mutating func release(at time: Date) -> Action {
        switch state {
        case .holding(let start):
            state = .idle
            if time.timeIntervalSince(start) < Self.minimumHold {
                lastTap = time
                return .discard
            }
            return .finish
        case .finishingHandsFree:
            state = .idle
            return .none
        case .idle, .handsFree:
            return .none
        }
    }

    /// Another key during a hold means a shortcut or accent, not dictation.
    /// In hands-free mode you may be typing, so only Escape cancels.
    public mutating func otherKey(isEscape: Bool) -> Action {
        switch state {
        case .holding:
            reset()
            return .discard
        case .handsFree where isEscape:
            reset()
            return .discard
        default:
            return .none
        }
    }

    public mutating func reset() {
        state = .idle
        lastTap = nil
    }
}
