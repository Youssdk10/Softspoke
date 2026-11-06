import Foundation

public enum WhisperError: LocalizedError {
    case engineMissing
    case modelMissing(String)
    case startupFailed
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .engineMissing: return "Whisper isn't installed. Run: brew install whisper-cpp"
        case .modelMissing(let path): return "Speech model not found at \(path)"
        case .startupFailed: return "The speech engine didn't start"
        case .badResponse(let detail): return "Unexpected engine response: \(detail)"
        }
    }
}

/// Runs whisper-server as a child process so the model stays loaded between
/// dictations. It listens only on 127.0.0.1, and audio never leaves this Mac.
public final class WhisperEngine {
    private static let serverPaths = [
        "/opt/homebrew/opt/whisper.cpp/bin/whisper-server",
        "/opt/homebrew/bin/whisper-server",
        "/usr/local/opt/whisper.cpp/bin/whisper-server",
        "/usr/local/bin/whisper-server",
    ]

    private let modelPath: String
    private var process: Process?
    private var port: Int = 0
    private let session: URLSession

    public init(modelPath: String) {
        self.modelPath = modelPath
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 180
        session = URLSession(configuration: config)
    }

    deinit { stop() }

    public func start() async throws {
        stop()
        guard let server = Self.serverPaths.first(where: FileManager.default.isExecutableFile) else {
            throw WhisperError.engineMissing
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelMissing(modelPath)
        }

        port = try Self.freePort()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: server)
        child.arguments = ["-m", modelPath, "--host", "127.0.0.1", "--port", String(port), "-l", "en"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child

        // Loading the model takes a moment, so wait until the server answers.
        for _ in 0..<120 {
            guard child.isRunning else { break }
            if await isResponding() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        stop()
        throw WhisperError.startupFailed
    }

    public func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    /// `quick` skips Whisper's retries on uncertain audio, like the silence after
    /// a command. It suits command checks, not the text you'll actually keep.
    public func transcribe(wav: Data, prompt: String = "", quick: Bool = false) async throws -> String {
        let boundary = "softspoke-\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "json")
        field("temperature", "0.0")
        if quick { field("temperature_inc", "0.0") }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw WhisperError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return text
    }

    private func isResponding() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Asks the OS for an unused port, so a leftover server can never collide.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WhisperError.startupFailed }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { throw WhisperError.startupFailed }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw WhisperError.startupFailed }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
