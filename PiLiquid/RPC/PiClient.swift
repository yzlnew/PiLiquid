import Foundation

/// Configuration for launching a `pi --mode rpc` subprocess.
struct PiLaunchConfig: Sendable {
    var executablePath: String
    var workingDirectory: URL
    var provider: String?
    var model: String?
    var extraArguments: [String]
    /// The .jsonl path being resumed, if any — used only for optimistic UI
    /// (highlighting the session before the agent restarts).
    var resumeSessionFile: String?

    init(
        executablePath: String,
        workingDirectory: URL,
        provider: String? = nil,
        model: String? = nil,
        extraArguments: [String] = [],
        resumeSessionFile: String? = nil
    ) {
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.provider = provider
        self.model = model
        self.extraArguments = extraArguments
        self.resumeSessionFile = resumeSessionFile
    }
}

enum PiClientError: Error, LocalizedError {
    case notRunning
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return String(localized: "The pi agent is not running.")
        case .launchFailed(let m): return String(localized: "Failed to launch pi: \(m)")
        }
    }
}

/// Owns a `pi --mode rpc` child process and speaks its JSONL stdio protocol.
///
/// Inbound lines are demultiplexed: command **responses** (which carry the
/// `id` we attached on send) resolve the awaiting caller; everything else —
/// lifecycle **events** and **extension UI requests** — flows out through the
/// public `events` stream for the UI to consume.
actor PiClient {
    private var process: Process?
    private var stdinHandle: FileHandle?

    /// Lines decoded off the read queue, fed into the actor's routing loop.
    private let inboundStream: AsyncStream<RPCInbound>
    private let inboundContinuation: AsyncStream<RPCInbound>.Continuation

    /// Public stream the UI subscribes to (events + UI requests + diagnostics).
    let events: AsyncStream<RPCInbound>
    private let eventsContinuation: AsyncStream<RPCInbound>.Continuation

    /// stderr text, surfaced for diagnostics when launch/auth fails.
    let diagnostics: AsyncStream<String>
    private let diagnosticsContinuation: AsyncStream<String>.Continuation

    private var pending: [String: CheckedContinuation<RPCResponse, Never>] = [:]
    private var requestCounter = 0
    private var running = false

    init() {
        (inboundStream, inboundContinuation) = AsyncStream.makeStream()
        (events, eventsContinuation) = AsyncStream.makeStream()
        (diagnostics, diagnosticsContinuation) = AsyncStream.makeStream()
    }

    var isRunning: Bool { running }

    // MARK: - Lifecycle

    func start(_ config: PiLaunchConfig) throws {
        guard !running else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.executablePath)
        proc.currentDirectoryURL = config.workingDirectory

        var args = ["--mode", "rpc"]
        if let provider = config.provider, !provider.isEmpty { args += ["--provider", provider] }
        if let model = config.model, !model.isEmpty { args += ["--model", model] }
        // NOTE: never pass `--name` here — pi persists it as the session's name
        // (a `session_info` entry), which then shadows the first-message title
        // in every session list.
        // Load the bundled plan-mode extension (read-only planning + progress
        // widget). Absent on the headless raw-binary path (no bundle) — skipped
        // silently there; pi still runs, just without `/plan`.
        if let planDir = Self.bundledExtensionDirectory("plan-mode") {
            args += ["-e", planDir.path]
        }
        args += config.extraArguments
        proc.arguments = args

        // Inherit the user environment but guarantee Homebrew/Node are on PATH,
        // since apps launched from Finder start with a minimal PATH.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + existing.split(separator: ":").map(String.init))
            .reduced()
            .joined(separator: ":")
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let reader = LineReader(continuation: inboundContinuation)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            reader.feed(data)
        }

        let diag = diagnosticsContinuation
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) { diag.yield(s) }
        }

        let onExit = inboundContinuation
        proc.terminationHandler = { _ in
            reader.flush()
            onExit.yield(.unknown(type: "__process_exit__", raw: .null))
        }

        do {
            try proc.run()
        } catch {
            throw PiClientError.launchFailed(error.localizedDescription)
        }

        process = proc
        stdinHandle = stdin.fileHandleForWriting
        running = true

        // Routing loop: responses → awaiting callers, everything else → UI.
        Task { [inboundStream] in
            for await item in inboundStream {
                self.route(item)
            }
        }
    }

    /// Locate a vendored extension folder inside the app bundle's Resources
    /// (a blue folder reference, so the `subdirectory:` structure is preserved).
    /// Returns nil when running without a bundle (the headless verify path).
    private static func bundledExtensionDirectory(_ name: String) -> URL? {
        Bundle.main.url(forResource: "index", withExtension: "ts", subdirectory: "Extensions/\(name)")?
            .deletingLastPathComponent()
    }

    func stop() {
        guard running else { return }
        running = false
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        for (_, cont) in pending {
            cont.resume(returning: RPCResponse(json: .object([
                "type": .string("response"), "command": .string("__cancelled__"),
                "success": .bool(false), "error": .string("Agent stopped"),
            ])))
        }
        pending.removeAll()

        // Finish the streams so this instance's routing loop and stream pumps
        // exit; ChatModel discards the client on each (re)launch, and a lingering
        // loop would retain it (and its dead process handlers) forever.
        inboundContinuation.finish()
        eventsContinuation.finish()
        diagnosticsContinuation.finish()
    }

    private func route(_ item: RPCInbound) {
        switch item {
        case .response(let r):
            if let id = r.id, let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: r)
            } else {
                eventsContinuation.yield(item)
            }
        case .unknown(let type, _) where type == "__process_exit__":
            running = false
            eventsContinuation.yield(item)
        default:
            eventsContinuation.yield(item)
        }
    }

    // MARK: - Sending

    /// Send a command and await its correlated response.
    @discardableResult
    func send(_ type: String, _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        guard running, let handle = stdinHandle else {
            return RPCResponse(json: .object([
                "command": .string(type), "success": .bool(false),
                "error": .string("not running"),
            ]))
        }
        requestCounter += 1
        let id = "req-\(requestCounter)"

        var dict = params
        dict["type"] = .string(type)
        dict["id"] = .string(id)

        return await withCheckedContinuation { (cont: CheckedContinuation<RPCResponse, Never>) in
            pending[id] = cont
            do {
                let data = try JSONEncoder().encode(JSONValue.object(dict))
                handle.write(data)
                handle.write(Data([0x0A]))
            } catch {
                pending.removeValue(forKey: id)?.resume(returning: RPCResponse(json: .object([
                    "command": .string(type), "success": .bool(false),
                    "error": .string("encode failed: \(error.localizedDescription)"),
                ])))
            }
        }
    }

    /// Send an extension UI response (no correlated reply expected).
    func sendRaw(_ dict: [String: JSONValue]) {
        guard running, let handle = stdinHandle else { return }
        if let data = try? JSONEncoder().encode(JSONValue.object(dict)) {
            handle.write(data)
            handle.write(Data([0x0A]))
        }
    }
}

// MARK: - JSONL line framing

/// Accumulates stdout bytes and emits one `RPCInbound` per LF-delimited line,
/// per pi's strict JSONL framing. `@unchecked Sendable` because all access is
/// serialized by `FileHandle`'s private read queue.
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let continuation: AsyncStream<RPCInbound>.Continuation

    init(continuation: AsyncStream<RPCInbound>.Continuation) {
        self.continuation = continuation
    }

    func feed(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.last == 0x0D { line = line.dropLast() }   // tolerate CRLF
            emit(Data(line))
        }
    }

    func flush() {
        if !buffer.isEmpty {
            var line = buffer
            if line.last == 0x0D { line = line.dropLast() }
            emit(Data(line))
            buffer.removeAll()
        }
    }

    private func emit(_ data: Data) {
        guard !data.isEmpty,
              let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return }
        continuation.yield(RPCInbound(json: json))
    }
}

private extension Array where Element == String {
    /// Order-preserving de-duplication.
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
