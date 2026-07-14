import Testing
import Foundation
@testable import PiLiquid

/// Isolated-session worktree lifecycle against real git: create off HEAD, merge
/// back squash-staged (never committed), discard without a trace.
struct WorktreeServiceTests {

    /// Worktrees rooted in the temp dir so tests never touch Application Support.
    private func tempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PiLiquidTests-wt-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func createMakesWorktreeOnFreshBranch() throws {
        let repo = try TempRepo(prefix: "wt-create")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        repo.commitAll()

        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try #require(WorktreeService.create(for: repo.url, slug: "t1", root: root))

        #expect(info.branch == "pi/t1")
        #expect(info.repoPath == repo.url.path)
        #expect(FileManager.default.fileExists(atPath: info.path))
        // The worktree starts from HEAD: the committed file is there.
        #expect((try? String(contentsOf: info.url.appendingPathComponent("a.txt"), encoding: .utf8)) == "one\n")
        #expect(repo.git(["branch", "--list", "pi/t1"]).out.contains("pi/t1"))
    }

    @Test func createRefusesNonRepoAndUnbornHead() throws {
        let plain = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PiLiquidTests-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(WorktreeService.create(for: plain, slug: "x", root: tempRoot()) == nil)

        let empty = try TempRepo(prefix: "wt-empty")   // repo with no commits
        defer { empty.destroy() }
        #expect(WorktreeService.create(for: empty.url, slug: "x", root: tempRoot()) == nil)
    }

    @Test func mergeBackStagesChangesAndCleansUp() throws {
        let repo = try TempRepo(prefix: "wt-merge")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        repo.commitAll()

        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try #require(WorktreeService.create(for: repo.url, slug: "m1", root: root))

        // The "session" writes a new file and edits an existing one.
        try "from session\n".write(to: info.url.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "one\nedited\n".write(to: info.url.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let result = WorktreeService.mergeBack(info)
        #expect(result.ok, "\(result.message)")

        // Staged in the main repo, NOT committed.
        let status = repo.git(["status", "--porcelain"]).out
        #expect(status.contains("A  b.txt"))
        #expect(status.contains("M  a.txt"))
        #expect(repo.git(["log", "--oneline"]).out.split(separator: "\n").count == 1)

        // Worktree and branch are gone.
        #expect(!FileManager.default.fileExists(atPath: info.path))
        #expect(repo.git(["branch", "--list", "pi/m1"]).out.isEmpty)
    }

    @Test func mergeBackWithNoChangesJustRemoves() throws {
        let repo = try TempRepo(prefix: "wt-noop")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        repo.commitAll()

        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try #require(WorktreeService.create(for: repo.url, slug: "n1", root: root))

        let result = WorktreeService.mergeBack(info)
        #expect(result.ok)
        #expect(!FileManager.default.fileExists(atPath: info.path))
        #expect(repo.git(["status", "--porcelain"]).out.isEmpty)   // main repo untouched
    }

    /// A dirty main tree makes a failed squash merge impossible to unwind
    /// safely — merge must refuse and leave both sides intact.
    @Test func mergeBackRefusesWhenMainRepoDirty() throws {
        let repo = try TempRepo(prefix: "wt-dirty")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        repo.commitAll()

        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try #require(WorktreeService.create(for: repo.url, slug: "d1", root: root))
        try "session work\n".write(to: info.url.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try repo.write("a.txt", "user's own uncommitted edit\n")

        let result = WorktreeService.mergeBack(info)
        #expect(!result.ok)
        #expect(FileManager.default.fileExists(atPath: info.path))          // worktree kept
        #expect(repo.read("a.txt") == "user's own uncommitted edit\n")     // user's edit kept
    }

    @Test func removeDiscardsWorktreeAndBranch() throws {
        let repo = try TempRepo(prefix: "wt-discard")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        repo.commitAll()

        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try #require(WorktreeService.create(for: repo.url, slug: "x1", root: root))
        try "doomed\n".write(to: info.url.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)

        #expect(WorktreeService.remove(info))
        #expect(!FileManager.default.fileExists(atPath: info.path))
        #expect(repo.git(["branch", "--list", "pi/x1"]).out.isEmpty)
        #expect(!repo.git(["worktree", "list"]).out.contains(info.path))
        // Main repo never saw any of it.
        #expect(repo.git(["status", "--porcelain"]).out.isEmpty)
    }
}
