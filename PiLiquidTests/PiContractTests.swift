import Testing
import Foundation
@testable import PiLiquid

/// Contract tests against the *installed* pi binary — the drift detector. Every
/// GUI bug rooted in "pi behaves differently than we assumed" (lazy session
/// files, event shapes, extension loading) should get a check here. No model
/// API is ever called, so these are free and deterministic; they are skipped
/// entirely when pi isn't installed.
///
/// Serialized: each test spawns its own pi process (node startup ~1-2s).
@Suite(.serialized, .enabled(if: PiBinary.path != nil))
struct PiContractTests {

    @Test func getStateReturnsSessionFileBeforeAnythingIsOnDisk() throws {
        let pi = try PiProcess(arguments: ["--mode", "rpc"])
        defer { pi.stop() }
        let resp = try pi.request(#"{"id":"1","type":"get_state"}"#)

        #expect(resp["success"]?.boolValue == true)
        let file = resp["data"]?["sessionFile"]?.stringValue ?? ""
        #expect(file.hasSuffix(".jsonl"))
        // The app relies on both halves of this: the path is known immediately
        // (sidebar can synthesize a row), but the file does NOT exist until the
        // first turn completes (disk scans can't see new sessions).
        #expect(!FileManager.default.fileExists(atPath: file))
        // And a fresh session must carry no name — titles come from the first
        // user message. (`--name` poisoning regression.)
        let name = resp["data"]?["sessionName"]?.stringValue ?? ""
        #expect(name.isEmpty)
    }

    @Test func bundledPlanModeExtensionRegistersPlanCommand() throws {
        let pi = try PiProcess(arguments: ["--mode", "rpc", "--no-session", "-e", Self.planModeSourceDir])
        defer { pi.stop() }
        // Cold TS-extension compile took ~16s on this machine; leave headroom.
        let resp = try pi.request(#"{"id":"1","type":"get_commands"}"#, timeout: 60)

        let names = resp["data"]?["commands"]?.arrayValue?
            .compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("plan"), "vendored plan-mode extension failed to register /plan")
    }

    @Test func planToggleEmitsStatusAndClearsOnExit() throws {
        let pi = try PiProcess(arguments: ["--mode", "rpc", "--no-session", "-e", Self.planModeSourceDir])
        defer { pi.stop() }

        _ = try pi.send(#"{"id":"1","type":"prompt","message":"/plan"}"#)
        let on = try pi.waitForLine(timeout: 30) {
            $0["type"]?.stringValue == "extension_ui_request"
                && $0["method"]?.stringValue == "setStatus"
                && $0["statusKey"]?.stringValue == "plan-mode"
                && !($0["statusText"]?.stringValue ?? "").isEmpty
        }
        // This is what drives the app's plan chip (after ANSI stripping).
        #expect(on["statusText"]?.stringValue?.contains("plan") == true)

        _ = try pi.send(#"{"id":"2","type":"prompt","message":"/plan"}"#)
        _ = try pi.waitForLine(timeout: 15) {
            $0["type"]?.stringValue == "extension_ui_request"
                && $0["method"]?.stringValue == "setStatus"
                && $0["statusKey"]?.stringValue == "plan-mode"
                && ($0["statusText"]?.stringValue ?? "").isEmpty
        }
    }

    /// `/plan <prompt>` must enable plan mode AND submit the prompt — the args
    /// used to be silently dropped, which read as "sent and nothing happened".
    /// Asserted only up to the user-message event (emitted before any model
    /// call); the process is killed right after, so no tokens are generated.
    @Test func planCommandWithArgsSubmitsPrompt() throws {
        let pi = try PiProcess(arguments: ["--mode", "rpc", "--no-session", "-e", Self.planModeSourceDir])
        defer { pi.stop() }

        _ = try pi.send(#"{"id":"1","type":"prompt","message":"/plan hello there"}"#)
        let userMsg = try pi.waitForLine(timeout: 60) {
            $0["type"]?.stringValue == "message_start"
                && $0["message"]?["role"]?.stringValue == "user"
        }
        let text = userMsg["message"]?["content"]?.arrayValue?
            .compactMap { $0["text"]?.stringValue }.joined() ?? ""
        #expect(text == "hello there")   // args became the prompt, `/plan` stripped
    }

    /// The vendored extension is loaded from the repo source (what gets bundled).
    private static var planModeSourceDir: String {
        URL(fileURLWithPath: #filePath)                       // …/PiLiquidTests/PiContractTests.swift
            .deletingLastPathComponent()                      // …/PiLiquidTests
            .deletingLastPathComponent()                      // repo root
            .appendingPathComponent("PiLiquid/Extensions/plan-mode").path
    }
}

// MARK: - Minimal RPC driver

enum PiBinary {
    /// Locate pi the way a user launch would; xcodebuild strips the shell PATH.
    static let path: String? = {
        let candidates = ["/opt/homebrew/bin/pi", "/usr/local/bin/pi",
                          NSHomeDirectory() + "/.local/bin/pi"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
}

/// A tiny synchronous JSONL driver for contract tests. Runs pi in a throwaway
/// temp working directory so tests never touch real project session folders…
/// except get_state's future path, which lands in a temp-keyed folder.
// @unchecked: mutable state (`buffer`) is guarded by `lock`; everything else
// is set once in init. The readability handler runs on a background queue.
final class PiProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    /// Filled by the readability handlers on a background queue; drained under
    /// the lock by `waitForLine`, so a silent pi can't block the deadline check.
    private let lock = NSLock()
    private var buffer = Data()
    private var errBuffer = Data()
    /// Non-matching lines consumed by waitForLine — kept for timeout diagnostics.
    private var consumed: [String] = []

    struct TimeoutError: Error, CustomStringConvertible {
        let waited: TimeInterval
        let alive: Bool
        let stderrTail: String
        let seenLines: [String]
        var description: String {
            "no matching line after \(Int(waited))s (pi alive: \(alive)) "
                + "seen: \(seenLines.map { String($0.prefix(120)) }.joined(separator: " | ")) "
                + "stderr: \(stderrTail.suffix(300))"
        }
    }

    init(arguments: [String]) throws {
        let cwd = NSTemporaryDirectory() + "PiLiquidContractTests"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: PiBinary.path!)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Keep the child env clean of any Claude-session proxy leakage (no model
        // is ever called here, but hygiene beats surprises).
        var env = ProcessInfo.processInfo.environment
        for key in ["http_proxy", "https_proxy", "all_proxy"] { env.removeValue(forKey: key) }
        // xcodebuild strips the user PATH; pi's `#!/usr/bin/env node` shebang
        // needs to find node or the process dies before its first byte.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(chunk)
            self.lock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self.errBuffer.append(chunk)
            self.lock.unlock()
        }
        try process.run()
    }

    func stop() {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    @discardableResult
    func send(_ line: String) throws -> Bool {
        try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        return true
    }

    /// Send a command and wait for the response echoing its `id`.
    func request(_ line: String, timeout: TimeInterval = 20) throws -> JSONValue {
        let id = (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?["id"]?.stringValue
        try send(line)
        return try waitForLine(timeout: timeout) {
            $0["type"]?.stringValue == "response" && $0["id"]?.stringValue == id
        }
    }

    /// Poll the buffered stdout for a complete line matching `match`, up to a
    /// deadline. Non-matching lines are consumed and discarded.
    func waitForLine(timeout: TimeInterval, match: (JSONValue) -> Bool) throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            while let line = nextLine() {
                if let v = try? JSONDecoder().decode(JSONValue.self, from: line), match(v) {
                    return v
                }
                if let s = String(data: line, encoding: .utf8) { consumed.append(s) }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock()
        let tail = String(data: errBuffer, encoding: .utf8) ?? ""
        lock.unlock()
        throw TimeoutError(waited: timeout, alive: process.isRunning,
                           stderrTail: tail, seenLines: consumed.suffix(6))
    }

    private func nextLine() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let range = buffer.firstRange(of: Data("\n".utf8)) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return line
    }
}
