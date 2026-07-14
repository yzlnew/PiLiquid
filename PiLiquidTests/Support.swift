import Foundation
@testable import PiLiquid

/// Decode a raw JSON string into the app's `JSONValue` — the same path real
/// RPC lines take (`JSONDecoder` over the wire bytes).
func jsonValue(_ raw: String) -> JSONValue {
    guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else {
        fatalError("test fixture is not valid JSON: \(raw)")
    }
    return v
}

/// Demultiplex a captured RPC line exactly like `PiClient` does.
func inbound(_ raw: String) -> RPCInbound {
    RPCInbound(json: jsonValue(raw))
}

/// Replay captured RPC lines through a `ChatModel`'s real folding logic.
@MainActor
func replay(_ lines: [String], into model: ChatModel) {
    for line in lines { model.handle(inbound(line)) }
}

// MARK: - Captured pi 0.80.2 traffic
//
// These fixtures are (lightly trimmed) real lines captured from
// `pi --mode rpc` on 2026-07-02. If pi changes its wire format, update these
// AND make PiContractTests pass against the new binary first.

enum Fixture {
    static let agentStart = #"{"type":"agent_start"}"#
    static let turnStart = #"{"type":"turn_start"}"#
    static let turnEnd = #"{"type":"turn_end","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#
    static let agentEnd = #"{"type":"agent_end","messages":[]}"#

    static let userMessageStart =
        #"{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"say hi"}],"timestamp":1782980824525}}"#

    /// Plan mode injects a `custom`-role context message whose `content` is a
    /// plain string (not a block array) before the assistant reply.
    static let planContextMessageStart =
        #"{"type":"message_start","message":{"role":"custom","customType":"plan-mode-context","content":"[PLAN MODE ACTIVE]\nYou are in plan mode."}}"#

    static let assistantMessageStart =
        #"{"type":"message_start","message":{"role":"assistant","content":[],"api":"openai-completions","provider":"deepseek","model":"deepseek-v4-flash","stopReason":"stop"}}"#

    /// A streaming delta carrying BOTH the top-level `message` and the
    /// `assistantMessageEvent.partial` copy (pi 0.80.x behavior).
    static let assistantUpdateBothKeys =
        #"{"type":"message_update","message":{"role":"assistant","content":[{"type":"text","text":"hel"}]},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"l","partial":{"role":"assistant","content":[{"type":"text","text":"hel"}]}}}"#

    /// The same delta with the top-level `message` dropped — the shape pi's
    /// rpc.md examples suggest could exist; the decoder must fall back to
    /// `assistantMessageEvent.partial` instead of silently dropping the event.
    static let assistantUpdatePartialOnly =
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"lo","partial":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}}"#

    static let assistantMessageEnd =
        #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"the user wants a greeting"},{"type":"text","text":"hello"}],"stopReason":"stop"}}"#

    /// A failed turn: `stopReason:"error"`, empty content, detail in `errorMessage`.
    static let assistantMessageEndError =
        #"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"429 rate limited"}}"#

    /// Extension footer status with ANSI SGR color codes (theme.fg emits them).
    static let planStatusOn =
        #"{"type":"extension_ui_request","id":"a1","method":"setStatus","statusKey":"plan-mode","statusText":"\u001b[38;2;154;115;38m⏸ plan\u001b[39m"}"#

    /// Toggling off posts the key with no text — that clears the entry.
    static let planStatusOff =
        #"{"type":"extension_ui_request","id":"a2","method":"setStatus","statusKey":"plan-mode"}"#
}

// MARK: - Throwaway git repositories (service-level tests)

private struct TempRepoGitError: Error, CustomStringConvertible {
    let arguments: [String]
    let output: String
    let error: String

    var description: String {
        let command = (["/usr/bin/git"] + arguments).joined(separator: " ")
        return "\(command) failed; stdout: \(output.debugDescription); stderr: \(error.debugDescription)"
    }
}

/// A disposable git repo under the temp directory, with the identity configured
/// so commits work on any machine. Call `destroy()` when done.
struct TempRepo {
    let url: URL

    init(prefix: String = "repo") throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PiLiquidTests-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try requireGit(["init", "-q", "-b", "main"])
        try requireGit(["config", "user.name", "Tests"])
        try requireGit(["config", "user.email", "tests@localhost"])
    }

    @discardableResult
    func git(_ args: [String]) -> (out: String, err: String, ok: Bool) {
        GitService.run(args, in: url)
    }

    private func requireGit(_ args: [String]) throws {
        let result = git(args)
        guard result.ok else {
            throw TempRepoGitError(arguments: args, output: result.out, error: result.err)
        }
    }

    func write(_ name: String, _ content: String) throws {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url.appendingPathComponent(name))
    }

    func commitAll(_ message: String = "commit") {
        git(["add", "-A"])
        git(["commit", "-q", "-m", message])
    }

    func destroy() {
        try? FileManager.default.removeItem(at: url)
    }
}
