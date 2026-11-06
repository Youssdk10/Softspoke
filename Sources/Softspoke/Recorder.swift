import AVFoundation
import SoftspokeCore

/// Captures the microphone only while the hotkey is held, converting to the
/// 16 kHz mono audio Whisper expects. Audio is kept in memory, never on disk.
final class Recorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Int16] = []
    private let lock = NSLock()
    var onLevel: ((CGFloat) -> Void)?

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioFormat.sampleRate),
        channels: 1,
        interleaved: true)!

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }

        // A fresh engine picks up whichever input device is currently selected.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw NSError(
                domain: "Softspoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone is available"])
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, using: converter)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.converter = converter
    }

    /// The most recent audio, without interrupting the recording.
    func tail(seconds: Double) -> [Int16] {
        let count = Int(seconds * Double(AudioFormat.sampleRate))
        return lock.withLock { Array(samples.suffix(count)) }
    }

    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> [Int16] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        return lock.withLock { samples }
    }

    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.int16ChannelData?[0] else { return }
        let converted = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        lock.withLock { samples.append(contentsOf: converted) }
        reportLevel(converted)
    }

    /// Loudness from 0 to 1, curved so normal speech fills most of the waveform.
    private func reportLevel(_ samples: UnsafeBufferPointer<Int16>) {
        guard let onLevel, !samples.isEmpty else { return }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (sum / Double(samples.count)).squareRoot()
        let level = CGFloat(min(1, (rms / 4000).squareRoot()))
        DispatchQueue.main.async { onLevel(level) }
    }
}
