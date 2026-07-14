import Testing
import Foundation
@testable import PiLiquid

/// Turn-diff plumbing against a real git repo: the temp-index snapshot must see
/// exactly the working tree (untracked included, ignored excluded), the tree
/// diff must parse into the right per-file changes, and revert must restore.
struct GitWorkingTreeTests {

    @Test func snapshotIsStableWhenNothingChanges() throws {
        let repo = try TempRepo(prefix: "snap")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        repo.commitAll()

        let first = GitService.snapshotTree(in: repo.url)
        let second = GitService.snapshotTree(in: repo.url)
        #expect(first != nil)
        #expect(first == second)
    }

    @Test func snapshotDiffSeesModifiedUntrackedAndDeleted() throws {
        let repo = try TempRepo(prefix: "diff")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        try repo.write("gone.txt", "bye\n")
        repo.commitAll()

        let base = try #require(GitService.snapshotTree(in: repo.url))
        try repo.write("a.txt", "one\ntwo\n")     // modified
        try repo.write("b.txt", "new file\n")     // untracked — must still show
        repo.delete("gone.txt")                   // deleted
        let end = try #require(GitService.snapshotTree(in: repo.url))
        #expect(base != end)

        let text = try #require(GitService.diffText(from: base, to: end, in: repo.url))
        let files = GitDiffParser.parse(text).sorted { $0.path < $1.path }
        #expect(files.map(\.path) == ["a.txt", "b.txt", "gone.txt"])
        #expect(files[0].change == .modified)
        #expect(files[0].added == 1)
        #expect(files[1].change == .added)
        #expect(files[2].change == .deleted)
    }

    @Test func ignoredFilesStayOutOfSnapshots() throws {
        let repo = try TempRepo(prefix: "ignore")
        defer { repo.destroy() }
        try repo.write(".gitignore", "secret.txt\n")
        repo.commitAll()

        let base = try #require(GitService.snapshotTree(in: repo.url))
        try repo.write("secret.txt", "hidden\n")
        let end = try #require(GitService.snapshotTree(in: repo.url))
        #expect(base == end)
    }

    @Test func restoreBringsBackPreTurnContent() throws {
        let repo = try TempRepo(prefix: "restore")
        defer { repo.destroy() }
        try repo.write("a.txt", "original\n")
        repo.commitAll()

        let base = try #require(GitService.snapshotTree(in: repo.url))
        try repo.write("a.txt", "mangled\n")
        #expect(GitService.restoreFile("a.txt", toTree: base, in: repo.url))
        #expect(repo.read("a.txt") == "original\n")
    }

    /// A file the turn *created* isn't in the base tree — revert must delete it.
    @Test func restoreDeletesFileMissingFromBaseTree() throws {
        let repo = try TempRepo(prefix: "restore-new")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        repo.commitAll()

        let base = try #require(GitService.snapshotTree(in: repo.url))
        try repo.write("created.txt", "agent made this\n")
        #expect(GitService.restoreFile("created.txt", toTree: base, in: repo.url))
        #expect(repo.read("created.txt") == nil)
    }

    @Test func restoreResurrectsDeletedFile() throws {
        let repo = try TempRepo(prefix: "restore-del")
        defer { repo.destroy() }
        try repo.write("a.txt", "keep me\n")
        repo.commitAll()

        let base = try #require(GitService.snapshotTree(in: repo.url))
        repo.delete("a.txt")
        #expect(GitService.restoreFile("a.txt", toTree: base, in: repo.url))
        #expect(repo.read("a.txt") == "keep me\n")
    }

    /// The snapshot must never touch the real index — staged state stays put.
    @Test func snapshotLeavesRealIndexUntouched() throws {
        let repo = try TempRepo(prefix: "index")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        repo.commitAll()
        try repo.write("staged.txt", "staged\n")
        repo.git(["add", "staged.txt"])

        _ = GitService.snapshotTree(in: repo.url)
        let status = repo.git(["status", "--porcelain"]).out
        #expect(status.contains("A  staged.txt"))   // still staged, nothing else changed
    }

    @Test func nonRepoDirectoryYieldsNoSnapshot() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PiLiquidTests-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GitService.isRepo(in: dir) == false)
        #expect(GitService.snapshotTree(in: dir) == nil)
    }
}
