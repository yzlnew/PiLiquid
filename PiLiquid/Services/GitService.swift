import Foundation

/// Thin wrapper over the `git` CLI, scoped to a working directory. All calls are
/// synchronous (run them off the main actor).
enum GitService {
    @discardableResult
    static func run(_ args: [String], in dir: URL,
                    environment: [String: String] = [:]) -> (out: String, err: String, ok: Bool) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.currentDirectoryURL = dir
        proc.arguments = args
        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            environment.forEach { env[$0.key] = $0.value }
            proc.environment = env
        }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { return ("", "\(error)", false) }
        // Read to EOF *before* waiting, so a large diff can't fill the pipe and
        // deadlock the child against `waitUntilExit`.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (out.trimmingCharacters(in: .whitespacesAndNewlines),
                err.trimmingCharacters(in: .whitespacesAndNewlines),
                proc.terminationStatus == 0)
    }

    static func isRepo(in dir: URL) -> Bool {
        run(["rev-parse", "--is-inside-work-tree"], in: dir).out == "true"
    }

    static func currentBranch(in dir: URL) -> String? {
        let r = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)
        return (r.ok && !r.out.isEmpty && r.out != "HEAD") ? r.out : nil
    }

    static func branches(in dir: URL) -> [String] {
        let r = run(["branch", "--format=%(refname:short)"], in: dir)
        guard r.ok else { return [] }
        return r.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func uncommittedCount(in dir: URL) -> Int {
        let r = run(["status", "--porcelain"], in: dir)
        guard r.ok else { return 0 }
        return r.out.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    static func checkout(_ branch: String, in dir: URL) -> Bool {
        run(["checkout", branch], in: dir).ok
    }

    static func createBranch(_ name: String, in dir: URL) -> Bool {
        run(["checkout", "-b", name], in: dir).ok
    }

    // MARK: - Working-tree snapshots (turn diffs)

    /// Object id of a tree capturing the exact working-tree content — tracked
    /// *and* untracked files, `.gitignore` respected — without touching the real
    /// index: stage everything into a throwaway index file and write it out.
    /// The blobs land in the object database as unreferenced garbage; `git gc`
    /// reaps them eventually.
    static func snapshotTree(in dir: URL) -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-liquid-index-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let env = ["GIT_INDEX_FILE": tmp]
        guard run(["add", "-A"], in: dir, environment: env).ok else { return nil }
        let r = run(["write-tree"], in: dir, environment: env)
        return (r.ok && !r.out.isEmpty) ? r.out : nil
    }

    /// Unified diff between two snapshot trees.
    static func diffText(from base: String, to end: String, in dir: URL) -> String? {
        let r = run(["diff", "--no-color", "--no-ext-diff", "--find-renames", base, end], in: dir)
        return r.ok ? r.out : nil
    }

    /// Restore one file to its content in `tree` — or delete it when the tree
    /// doesn't contain it (i.e. the file didn't exist back then).
    static func restoreFile(_ path: String, toTree tree: String, in dir: URL) -> Bool {
        let existed = run(["cat-file", "-e", "\(tree):\(path)"], in: dir).ok
        if existed {
            return run(["restore", "--source", tree, "--worktree", "--", path], in: dir).ok
        }
        return (try? FileManager.default.removeItem(at: dir.appendingPathComponent(path))) != nil
    }
}
