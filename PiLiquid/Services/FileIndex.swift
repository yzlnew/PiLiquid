import Foundation

/// One candidate in the `@`-mention picker: a project file or an inferred folder.
struct FileEntry: Identifiable, Hashable, Sendable {
    /// Project-relative path. Folders end with no slash (e.g. `PiLiquid/Views`).
    let path: String
    /// The last path component — what the row shows prominently.
    let name: String
    /// Parent directory (dimmed context in the row); empty at the root.
    let parent: String
    let isDirectory: Bool

    var id: String { (isDirectory ? "d:" : "f:") + path }
}

/// A flat, in-memory index of a project's files, and the single source of truth
/// for the composer's `@`-mention picker. Browse listings and fuzzy search both
/// derive from `paths` — the picker never hits the filesystem live, so it stays
/// fast and consistently respects `.gitignore`.
actor FileIndex {
    /// Sorted project-relative file paths (no directories — those are inferred).
    private var paths: [String] = []
    /// `paths` pre-lowercased as character arrays, kept in lockstep. Built once per
    /// (re)build so per-keystroke fuzzy scoring skips the `lowercased()` + array
    /// allocation that otherwise dominated its cost on large repos.
    private var lower: [[Character]] = []
    private var root: URL?
    /// Wall-clock of the last successful build; `nil` means "stale — rebuild on next
    /// use." Drives the picker's lazy freshness check.
    private var lastBuilt: Date?
    /// Guards against overlapping background refreshes.
    private var isRebuilding = false

    /// Directories that never carry useful mentions; skipped by the FS fallback.
    private static let ignoredDirs: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData",
        ".venv", "venv", "Pods", ".next", "dist", "target", ".mypy_cache",
        "__pycache__", ".pytest_cache", ".gradle", ".idea", ".xcodeproj",
    ]

    /// Cap the FS-fallback walk so a pathological tree can't hang or bloat memory.
    private static let fallbackCap = 20_000

    /// (Re)build the index for `root`. Prefers `git ls-files` (fast, honours
    /// `.gitignore`); falls back to a bounded filesystem walk for non-git dirs.
    func rebuild(root: URL?) async {
        self.root = root
        guard let root else { setPaths([]); lastBuilt = nil; return }
        setPaths(Self.listFiles(root: root))
        lastBuilt = Date()
    }

    /// Mark the index stale so the next `refreshIfStale` rebuilds it. Cheap — called
    /// when the working tree likely changed (e.g. an agent turn just finished), so
    /// files the agent created/removed show up the next time the picker opens.
    func markStale() { lastBuilt = nil }

    /// Rebuild in the background if the index is stale (older than `maxAge`, or
    /// invalidated by `markStale`). Returns immediately: the heavy `git`/FS work
    /// runs off the actor and fresh paths are swapped in when ready, so the picker
    /// never blocks — at worst the current keystroke sees the previous snapshot.
    func refreshIfStale(maxAge: TimeInterval = 4) {
        guard let root, !isRebuilding else { return }
        if let lastBuilt, Date().timeIntervalSince(lastBuilt) < maxAge { return }
        isRebuilding = true
        Task.detached(priority: .utility) { [weak self] in
            let fresh = Self.listFiles(root: root)
            await self?.applyRefresh(fresh)
        }
    }

    private func applyRefresh(_ fresh: [String]) {
        setPaths(fresh)
        lastBuilt = Date()
        isRebuilding = false
    }

    /// Swap in a new path set and rebuild the parallel lowercased-char cache.
    private func setPaths(_ newPaths: [String]) {
        paths = newPaths
        lower = newPaths.map { Array($0.lowercased()) }
    }

    // MARK: - Query

    /// Candidates for the active `@`-token (the text after `@`, sans the `@`):
    /// - empty leaf (`` or `src/`)     → browse the directory's immediate children
    /// - leaf with a `/` in the token  → fuzzy-match under that directory
    /// - leaf, no `/` in the token     → fuzzy-match across the whole index
    /// Returns folders-first for browse, score-ranked for fuzzy; capped at 50.
    func candidates(for token: String, limit: Int = 50) -> [FileEntry] {
        let slash = token.lastIndex(of: "/")
        let dirPrefix = slash.map { String(token[token.startIndex...$0]) } ?? ""   // "src/" or ""
        let leaf = slash.map { String(token[token.index(after: $0)...]) } ?? token

        if leaf.isEmpty {
            return browse(dirPrefix: dirPrefix, limit: limit)
        }
        if dirPrefix.isEmpty {
            return fuzzy(leaf: leaf, under: "", limit: limit)
        }
        return fuzzy(leaf: leaf, under: dirPrefix, limit: limit)
    }

    /// Immediate children of `dirPrefix` (e.g. `"PiLiquid/"`), folders first then
    /// files, each alphabetical. Derived purely from `paths`.
    private func browse(dirPrefix: String, limit: Int) -> [FileEntry] {
        var folders: Set<String> = []
        var files: [String] = []
        for p in paths where p.hasPrefix(dirPrefix) {
            let rest = p.dropFirst(dirPrefix.count)
            guard !rest.isEmpty else { continue }
            if let slash = rest.firstIndex(of: "/") {
                folders.insert(String(rest[..<slash]))     // immediate subfolder name
            } else {
                files.append(String(rest))                  // immediate file name
            }
        }
        let folderEntries = folders.sorted().map {
            entry(path: dirPrefix + $0, isDirectory: true)
        }
        let fileEntries = files.sorted().prefix(max(0, limit - folderEntries.count)).map {
            entry(path: dirPrefix + $0, isDirectory: false)
        }
        return Array((folderEntries + fileEntries).prefix(limit))
    }

    /// Fuzzy-rank files whose path starts with `under` against `leaf`, matching on
    /// the portion after the prefix (so `src/fo` scores `foo.ts`, not `src`).
    private func fuzzy(leaf: String, under prefix: String, limit: Int) -> [FileEntry] {
        let q = Array(leaf.lowercased())                 // lowercased once per query
        let dropN = prefix.count
        var scored: [(score: Int, path: String)] = []
        scored.reserveCapacity(paths.count)
        for i in paths.indices {
            let p = paths[i]
            if !prefix.isEmpty && !p.hasPrefix(prefix) { continue }
            // Score the portion after the (already-matched) directory prefix. The
            // global case (empty prefix) reuses the cached array as-is — no alloc.
            let c = prefix.isEmpty ? lower[i] : Array(lower[i].dropFirst(dropN))
            let baseStart = c.lastIndex(of: "/").map { $0 + 1 } ?? 0
            if let s = FuzzyScore.score(queryLower: q, candidateLower: c, baseStart: baseStart) {
                scored.append((s, p))
            }
        }
        scored.sort { a, b in
            a.score != b.score ? a.score > b.score : a.path.count < b.path.count
        }
        return scored.prefix(limit).map { entry(path: $0.path, isDirectory: false) }
    }

    private func entry(path: String, isDirectory: Bool) -> FileEntry {
        let name: String
        let parent: String
        if let slash = path.lastIndex(of: "/") {
            name = String(path[path.index(after: slash)...])
            parent = String(path[..<slash])
        } else {
            name = path
            parent = ""
        }
        return FileEntry(path: path, name: name, parent: parent, isDirectory: isDirectory)
    }

    // MARK: - Build sources

    /// The project's candidate files: `git ls-files` when available, else a bounded
    /// FS walk. Sorted and capped at `fallbackCap` so a pathological monorepo (the
    /// git path is otherwise unbounded) can't bloat memory or stall per-keystroke
    /// scoring. Runs off the actor — pure/static so `refreshIfStale` can detach it.
    private static func listFiles(root: URL) -> [String] {
        let all = (gitListFiles(root: root) ?? walk(root: root)).sorted()
        return all.count > fallbackCap ? Array(all.prefix(fallbackCap)) : all
    }

    /// Tracked + untracked (non-ignored) files via git, or `nil` if `root` isn't a
    /// git work tree (or git is unavailable) so the caller can fall back.
    private static func gitListFiles(root: URL) -> [String]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", root.path, "ls-files", "--cached", "--others", "--exclude-standard"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // Read the pipe before waitUntilExit to avoid deadlocking on a full buffer.
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return lines
    }

    /// Bounded recursive walk skipping `ignoredDirs`, capped at `fallbackCap`.
    private static func walk(root: URL) -> [String] {
        var result: [String] = []
        let rootPath = root.standardizedFileURL.path
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in en {
            if result.count >= fallbackCap { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if ignoredDirs.contains(url.lastPathComponent) {
                    en.skipDescendants()
                }
                continue
            }
            // Relative path from the root.
            let full = url.standardizedFileURL.path
            if full.hasPrefix(rootPath + "/") {
                result.append(String(full.dropFirst(rootPath.count + 1)))
            }
        }
        return result
    }
}

/// Case-insensitive subsequence fuzzy scorer. Higher is better; `nil` = no match.
/// Rewards contiguous runs, matches at path-segment/word boundaries, and matches
/// in the basename; longer paths are broken by the caller (shorter wins on ties).
enum FuzzyScore {
    /// Core scorer over pre-lowercased character arrays (the picker's hot path passes
    /// cached arrays so it never re-lowercases). `baseStart` is the index in `c` where
    /// the basename begins, for the basename bonus.
    static func score(queryLower q: [Character], candidateLower c: [Character], baseStart: Int) -> Int? {
        guard !q.isEmpty else { return 0 }
        guard q.count <= c.count else { return nil }

        var qi = 0
        var score = 0
        var prevMatch = -2
        for ci in 0..<c.count {
            guard qi < q.count else { break }
            if c[ci] == q[qi] {
                score += 1
                if ci == prevMatch + 1 { score += 5 }                    // contiguous run
                if ci == 0 || c[ci - 1] == "/" || c[ci - 1] == "_" || c[ci - 1] == "-" || c[ci - 1] == "." {
                    score += 8                                            // boundary start
                }
                if ci >= baseStart { score += 3 }                        // in basename
                prevMatch = ci
                qi += 1
            }
        }
        guard qi == q.count else { return nil }
        // Prefer matches that don't strand the query far into a long candidate.
        return score - c.count / 40
    }

    /// String convenience for callers without precomputed arrays (tests, ad-hoc use).
    static func score(query: String, candidate: String) -> Int? {
        let c = Array(candidate.lowercased())
        let baseStart = c.lastIndex(of: "/").map { $0 + 1 } ?? 0
        return score(queryLower: Array(query.lowercased()), candidateLower: c, baseStart: baseStart)
    }

    /// The character offsets in `text` that a left-greedy subsequence match of
    /// `query` lands on — for bolding matched letters in the picker. Matching
    /// against just the shown text (the basename) means query characters that only
    /// occur in the parent directory simply don't light up, which quietly exposes
    /// weak, scattered matches (e.g. `proj` highlights nothing in `Contents.json`).
    /// Returns whatever matched, even a partial run, so those hits still highlight.
    static func matchedOffsets(query: String, in text: String) -> [Int] {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return [] }
        let c = Array(text.lowercased())
        var qi = 0
        var offsets: [Int] = []
        for ci in 0..<c.count where qi < q.count {
            if c[ci] == q[qi] { offsets.append(ci); qi += 1 }
        }
        return offsets
    }
}
