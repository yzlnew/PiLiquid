import Testing
import Foundation
@testable import PiLiquid

/// Sidebar session-list regressions: brand-new sessions (no .jsonl on disk yet)
/// must still get a row, and on-disk titles must come from the right entry.
struct SessionListTests {

    private let dir = "/Users/example/.pi/agent/sessions/--proj--"

    private func stub(file: String?, name: String? = nil, active: Bool = false) -> LiveSessionStub {
        LiveSessionStub(sessionFile: file, sessionName: name,
                        lastActivated: Date(timeIntervalSince1970: 100), isActive: active)
    }

    @Test func liveAgentWithoutDiskFileGetsSynthesizedRow() {
        let merged = [SessionInfo]().mergingLive(
            [stub(file: dir + "/new.jsonl", active: true)], inDirectory: dir)
        #expect(merged.count == 1)
        #expect(merged[0].path == dir + "/new.jsonl")
        #expect(merged[0].isCurrent)
    }

    @Test func scannedRowIsNotDuplicated() {
        let scanned = [SessionInfo(id: dir + "/a.jsonl", title: "real title",
                                   modified: .now, isCurrent: false)]
        let merged = scanned.mergingLive([stub(file: dir + "/a.jsonl")], inDirectory: dir)
        #expect(merged.count == 1)
        #expect(merged[0].title == "real title")   // disk row wins
    }

    @Test func agentsFromOtherProjectsAndUnknownFilesAreIgnored() {
        let merged = [SessionInfo]().mergingLive([
            stub(file: "/Users/example/.pi/agent/sessions/--other--/x.jsonl"),
            stub(file: nil),      // not connected yet — no path to key a row on
            stub(file: ""),
        ], inDirectory: dir)
        #expect(merged.isEmpty)
    }

    /// A worktree-isolated agent's session file lives under the *worktree's*
    /// encoded dir; its `homeSessionsDirectory` override must file the row
    /// under the main project (and mark it as a worktree).
    @Test func worktreeAgentFilesUnderItsHomeProject() {
        let worktreeSessionsDir = "/Users/example/.pi/agent/sessions/--worktree--"
        var s = stub(file: worktreeSessionsDir + "/wt.jsonl", active: true)
        s.homeSessionsDirectory = dir
        s.isWorktree = true

        let merged = [SessionInfo]().mergingLive([s], inDirectory: dir)
        #expect(merged.count == 1)
        #expect(merged[0].path == worktreeSessionsDir + "/wt.jsonl")
        #expect(merged[0].isWorktree)

        // …and it must NOT also appear under the worktree's own directory.
        #expect([SessionInfo]().mergingLive([s], inDirectory: worktreeSessionsDir).isEmpty)
    }

    /// pi's per-project folder name: `/`→`-`, dots preserved, wrapped in `-…--`.
    /// Must match pi's real layout or every disk scan silently returns [].
    @Test func projectDirectoryEncodingMatchesPiLayout() {
        let url = SessionIndex.directory(forProjectPath: "/Users/example/Documents/projects/5.side-projects/pi_liquid")
        #expect(url.lastPathComponent == "--Users-example-Documents-projects-5.side-projects-pi_liquid--")
        #expect(url.path.hasSuffix("/.pi/agent/sessions/--Users-example-Documents-projects-5.side-projects-pi_liquid--"))
    }

    // MARK: - On-disk titles (SessionIndex.summarize via title(forSessionFile:))

    private func writeTemp(_ lines: [String]) throws -> String {
        let path = NSTemporaryDirectory() + "PiLiquidTests-\(UUID().uuidString).jsonl"
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Real pi layout: `session` header (no name), `session_info` (name), then
    /// messages. Title must be the first user message.
    @Test func titleFallsBackToFirstUserMessage() throws {
        let path = try writeTemp([
            #"{"type":"session","version":3,"id":"x","cwd":"/tmp/p"}"#,
            #"{"type":"session_info","id":"y","name":"pi_liquid"}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"修复登录 bug"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(SessionIndex.title(forSessionFile: path) == "修复登录 bug")
    }

    @Test func titleHandlesStringContentAndNewlines() throws {
        let path = try writeTemp([
            #"{"type":"session","version":3,"id":"x","cwd":"/tmp/p"}"#,
            #"{"type":"message","message":{"role":"user","content":"first\nline"}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(SessionIndex.title(forSessionFile: path) == "first line")
    }

    @Test func missingFileFallsBackToFilename() {
        #expect(SessionIndex.title(forSessionFile: "/nonexistent/dir/abc.jsonl") == "abc.jsonl")
    }
}
