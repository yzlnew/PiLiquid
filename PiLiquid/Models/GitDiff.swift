import Foundation

/// One file's change within a working-tree diff, parsed from `git diff` output.
/// Reuses `ToolDiff.Hunk/Line` so the existing `DiffView` renders it unchanged.
struct FileDiff: Equatable, Identifiable {
    enum Change: Equatable {
        case added, deleted, modified
        case renamed(from: String)
    }

    var path: String
    var change: Change = .modified
    var isBinary = false
    var hunks: [ToolDiff.Hunk] = []

    var id: String { path }

    var added: Int {
        hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .added }) }
    }
    var removed: Int {
        hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .removed }) }
    }

    /// Adapter for the existing `DiffView` renderer.
    var toolDiff: ToolDiff { ToolDiff(filePath: path, hunks: hunks, isNewFile: change == .added) }
}

/// The working-tree changes one agent turn actually produced, bracketed by two
/// tree snapshots so any file can later be reverted to its pre-turn content.
struct TurnDiff: Equatable, Identifiable {
    /// The turn's final assistant message id (same keying as `turnDurations`).
    var id: String
    /// Snapshot tree of the working tree when the turn started — revert target.
    var baseTree: String
    var files: [FileDiff]

    var totalAdded: Int { files.reduce(0) { $0 + $1.added } }
    var totalRemoved: Int { files.reduce(0) { $0 + $1.removed } }
}

/// Parses `git diff` unified output into per-file structures. Pure string
/// logic, unit-tested — no git involved.
enum GitDiffParser {
    static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunks: [ToolDiff.Hunk] = []
        var lines: [ToolDiff.Line] = []
        var inHunk = false

        func flushHunk() {
            if !lines.isEmpty { hunks.append(ToolDiff.Hunk(lines: lines)); lines = [] }
        }
        func flushFile() {
            flushHunk()
            if var file = current {
                file.hunks = hunks
                files.append(file)
            }
            current = nil
            hunks = []
            inHunk = false
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flushFile()
                current = FileDiff(path: headerPath(line))
                continue
            }
            guard current != nil else { continue }

            if inHunk {
                if line.hasPrefix("@@") {
                    flushHunk()
                } else if line.hasPrefix("+") {
                    lines.append(.init(kind: .added, text: String(line.dropFirst())))
                } else if line.hasPrefix("-") {
                    lines.append(.init(kind: .removed, text: String(line.dropFirst())))
                } else if line.hasPrefix("\\") {
                    // "\ No newline at end of file" — presentation only.
                } else {
                    // Context lines start with a space; an empty context line can
                    // arrive fully empty at the end of input.
                    lines.append(.init(kind: .context, text: String(line.dropFirst(line.isEmpty ? 0 : 1))))
                }
                continue
            }

            if line.hasPrefix("@@") {
                inHunk = true
            } else if line.hasPrefix("new file") {
                current?.change = .added
            } else if line.hasPrefix("deleted file") {
                current?.change = .deleted
            } else if line.hasPrefix("rename from ") {
                let old = unquote(String(line.dropFirst("rename from ".count)))
                current?.change = .renamed(from: old)
            } else if line.hasPrefix("rename to ") {
                current?.path = unquote(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("Binary files ") {
                current?.isBinary = true
            } else if line.hasPrefix("+++ ") {
                // More reliable than the `diff --git` header (paths with spaces).
                if let p = fileLinePath(line) { current?.path = p }
            } else if line.hasPrefix("--- ") {
                // Deleted files have `+++ /dev/null`; take the old side.
                if current?.change == .deleted, let p = fileLinePath(line) { current?.path = p }
            }
        }
        flushFile()
        return files
    }

    /// Best-effort path from `diff --git a/<old> b/<new>` — refined later by the
    /// `+++`/`---`/`rename to` lines when they carry one.
    private static func headerPath(_ line: String) -> String {
        if let range = line.range(of: " b/", options: .backwards) {
            return unquote(String(line[range.upperBound...]))
        }
        return line
    }

    /// Path from a `+++ b/<path>` / `--- a/<path>` line, nil for `/dev/null`.
    private static func fileLinePath(_ line: String) -> String? {
        var s = unquote(String(line.dropFirst(4)))
        // git appends a tab when the path contains spaces (unquoted mode).
        if s.hasSuffix("\t") { s = String(s.dropLast()) }
        if s == "/dev/null" { return nil }
        if s.hasPrefix("a/") || s.hasPrefix("b/") { s = String(s.dropFirst(2)) }
        return s
    }

    /// Undo git's quoting of paths with special characters (minimal: quotes and
    /// backslashes; octal escapes are left as-is).
    private static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        return String(s.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
