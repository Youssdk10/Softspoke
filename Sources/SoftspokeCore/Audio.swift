import Foundation

/// Confirms a spoken command in hands-free. Recent audio is checked several
/// times a second, and a command counts only once it has stayed the last thing
/// heard for a moment. So "send it to the team" doesn't fire, even in a noisy room.
public struct CommandConfirmer {
    public static let holdSeconds = 0.5

    private var firstHeard: Date?

    public init() {}

    /// Returns true when the command should fire.
    public mutating func observe(heardCommand: Bool, at time: Date) -> Bool {
        guard heardCommand else {
            firstHeard = nil
            return false
        }
        guard let firstHeard else {
            self.firstHeard = time
            return false
        }
        return time.timeIntervalSince(firstHeard) >= Self.holdSeconds
    }
}

public enum AudioFormat {
    public static let sampleRate = 16_000
    /// How much recent audio is checked for a spoken command.
    public static let commandTailSeconds = 3.0
    public static let commandCheckInterval = 0.3

    /// Wraps 16-bit mono samples in the WAV container Whisper expects.
    public static func wav(samples: [Int16], sampleRate: Int = AudioFormat.sampleRate) -> Data {
        var data = Data()
        let byteCount = samples.count * 2

        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: Int) {
            withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: Int) {
            withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) }
        }

        append("RIFF")
        append32(36 + byteCount)
        append("WAVEfmt ")
        append32(16)
        append16(1)  // PCM
        append16(1)  // mono
        append32(sampleRate)
        append32(sampleRate * 2)
        append16(2)
        append16(16)
        append("data")
        append32(byteCount)
        samples.withUnsafeBytes { raw in
            data.append(contentsOf: raw.bindMemory(to: Int16.self).map { $0.littleEndian }.withUnsafeBytes { Array($0) })
        }
        return data
    }

    /// True when a recording has no real signal. Whisper tends to invent
    /// phrases from silence, so these never reach it.
    public static func isSilent(_ samples: [Int16], threshold: Double = 120) -> Bool {
        guard !samples.isEmpty else { return true }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot() < threshold
    }
}
