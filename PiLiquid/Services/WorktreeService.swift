import Foundation

/// A session's isolated git worktree: where it lives, which repo it came from,
/// and the branch that carries its work. Codable so `AppSettings` can persist
/// the registry across relaunches.
struct WorktreeInfo: Equatable, Codable, Sendable {
    var repoPath: String
    var path: String
    var branch: String

    var repoURL: URL { URL(fileURLWithPath: repoPath) }
    var url: URL { URL(fileURLWithPath: path) }
    var repoName: String { repoURL.lastPathComponent }
}

/// git-worktree lifecycle for isolated sessions. All calls are synchronous —
/// run them off the main actor.
enum WorktreeService {
    /// Worktrees live outside the repo (Application Support) so they never
    /// pollute the project folder or its git status.
    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PiLiquid/Worktrees", isDirectory: true)
    }

    /// `git worktree add -b pi/<slug>` off the repo's current HEAD. Nil when the
    /// directory isn't a repo or has no commit yet (a worktree needs a HEAD).
    static func create(for repo: URL, slug: String, root: URL? = nil) -> WorktreeInfo? {
        guard GitService.run(["rev-parse", "--verify", "HEAD"], in: repo).ok else { return nil }
        let rootDir = root ?? defaultRoot
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let dir = rootDir.appendingPathComponent("\(repo.lastPathComponent)-\(slug)", isDirectory: true)
        let branch = "pi/\(slug)"
        guard GitService.run(["worktree", "add", "-b", branch, dir.path], in: repo).ok else { return nil }
        return WorktreeInfo(repoPath: repo.path, path: dir.path, branch: branch)
    }

    /// Commit everything in the worktree. The identity is supplied inline so it
    /// works on machines with no git user configured. No-op when clean.
    @discardableResult
    static func commitAll(in info: WorktreeInfo, message: String) -> Bool {
        let dir = info.url
        guard !GitService.run(["status", "--porcelain"], in: dir).out.isEmpty else { return true }
        guard GitService.run(["add", "-A"], in: dir).ok else { return false }
        return GitService.run(["-c", "user.name=Pi Liquid", "-c", "user.email=pi-liquid@localhost",
                               "commit", "-m", message], in: dir).ok
    }

    /// Squash-stage the worktree's work into the main repo — nothing is
    /// committed there; the user reviews and commits. On success the worktree
    /// and its branch are removed. On failure everything stays for manual
    /// resolution and the message says why.
    static func mergeBack(_ info: WorktreeInfo) -> (ok: Bool, message: String) {
        guard commitAll(in: info, message: "pi session changes") else {
            return (false, String(localized: "Couldn't commit the worktree's changes."))
        }
        let repo = info.repoURL
        if GitService.run(["rev-list", "--count", "HEAD..\(info.branch)"], in: repo).out == "0" {
            remove(info)
            return (true, String(localized: "No changes to merge — worktree removed."))
        }
        // A dirty main tree makes a failed squash merge impossible to unwind
        // safely (reset --merge could eat the user's own edits) — refuse.
        guard GitService.run(["status", "--porcelain"], in: repo).out.isEmpty else {
            return (false, String(localized: "The main repository has uncommitted changes — commit or stash them first."))
        }
        guard GitService.run(["merge", "--squash", info.branch], in: repo).ok else {
            _ = GitService.run(["reset", "--merge"], in: repo)   // clean tree above makes this safe
            return (false, String(localized: "Merge conflict — merge branch \(info.branch) manually."))
        }
        remove(info)
        return (true, String(localized: "Changes staged in \(info.repoName) — review and commit them."))
    }

    /// Remove the worktree directory and its branch. Safe to call repeatedly.
    @discardableResult
    static func remove(_ info: WorktreeInfo, deleteBranch: Bool = true) -> Bool {
        let repo = info.repoURL
        let removed = GitService.run(["worktree", "remove", "--force", info.path], in: repo).ok
        if !removed {
            // Fall back to plain deletion (e.g. the repo lost track of it).
            try? FileManager.default.removeItem(at: info.url)
            _ = GitService.run(["worktree", "prune"], in: repo)
        }
        if deleteBranch { _ = GitService.run(["branch", "-D", info.branch], in: repo) }
        return removed || !FileManager.default.fileExists(atPath: info.path)
    }
}
