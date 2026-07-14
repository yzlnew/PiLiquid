import Foundation

/// A structured old→new diff reconstructed from an `edit`/`write` tool's
/// arguments, so the tool card can render changes instead of raw result text.
/// Built from args (not the result) so it works identically for a live run and
/// a resumed session, where only the tool-call arguments are available.
struct ToolDiff: Equatable {
    var filePath: String?
    var hunks: [Hunk]
    /// A `write` of a brand-new (or fully overwritten) file — all additions.
    var isNewFile: Bool = false

    struct Hunk: Equatable {
        var lines: [Line]
    }

    struct Line: Equatable {
        enum Kind { case context, added, removed }
        var kind: Kind
        var text: String
    }

    var allLines: [Line] { hunks.flatMap(\.lines) }
    var addedCount: Int {
        var count = 0
        for line in allLines where line.kind == .added { count += 1 }
        return count
    }
    var removedCount: Int {
        var count = 0
        for line in allLines where line.kind == .removed { count += 1 }
        return count
    }

    // MARK: - Construction

    /// Build a diff for `edit`/`write` tools, or `nil` for anything else (or when
    /// the arguments don't carry the expected shape — the caller falls back to
    /// showing the raw tool output).
    static func from(toolName: String, args: JSONValue?) -> ToolDiff? {
        guard let args else { return nil }
        let name = toolName.lowercased()
        if name.contains("edit") || name.contains("replace") || name.contains("patch") {
            return fromEdit(args)
        }
        if name.contains("write") || name.contains("create") {
            return fromWrite(args)
        }
        return nil
    }

    private static func fromEdit(_ args: JSONValue) -> ToolDiff? {
        let path = parsePath(args)
        // pi's `edit` groups changes as `edits: [{oldText, newText}]`.
        if let editArr = args["edits"]?.arrayValue, !editArr.isEmpty {
            let hunks = editArr.compactMap { e -> Hunk? in
                guard let (old, new) = pair(e) else { return nil }
                return Hunk(lines: lineDiff(old: splitLines(old), new: splitLines(new)))
            }
            return hunks.isEmpty ? nil : ToolDiff(filePath: path, hunks: hunks)
        }
        // Fall back to a single top-level old/new pair (str-replace style tools).
        if let (old, new) = pair(args) {
            return ToolDiff(filePath: path, hunks: [Hunk(lines: lineDiff(old: splitLines(old), new: splitLines(new)))])
        }
        return nil
    }

    private static func fromWrite(_ args: JSONValue) -> ToolDiff? {
        guard let content = args["content"]?.stringValue else { return nil }
        let lines = splitLines(content).map { Line(kind: .added, text: $0) }
        guard !lines.isEmpty else { return nil }
        let hunk = Hunk(lines: lines)
        return ToolDiff(filePath: parsePath(args), hunks: [hunk], isNewFile: true)
    }

    private static func parsePath(_ v: JSONValue) -> String? {
        v["path"]?.stringValue ?? v["file_path"]?.stringValue ?? v["filePath"]?.stringValue
    }

    /// Tolerate the common old/new key spellings across edit-style tools.
    private static func pair(_ v: JSONValue) -> (String, String)? {
        let old = v["oldText"]?.stringValue ?? v["old_string"]?.stringValue ?? v["old"]?.stringValue
        let new = v["newText"]?.stringValue ?? v["new_string"]?.stringValue ?? v["new"]?.stringValue
        guard let old, let new else { return nil }
        return (old, new)
    }

    private static func splitLines(_ s: String) -> [String] {
        var lines = s.components(separatedBy: "\n")
        // Drop the phantom empty line a trailing newline produces.
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Classic LCS line diff: shared lines become context, the rest removed/added.
    /// Inputs are small (one edit block), so the O(n·m) table is fine.
    static func lineDiff(old: [String], new: [String]) -> [Line] {
        let n = old.count, m = new.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = old[i] == new[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var lines: [Line] = []
        var i = 0, j = 0
        while i < n, j < m {
            if old[i] == new[j] {
                lines.append(Line(kind: .context, text: old[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                lines.append(Line(kind: .removed, text: old[i])); i += 1
            } else {
                lines.append(Line(kind: .added, text: new[j])); j += 1
            }
        }
        while i < n { lines.append(Line(kind: .removed, text: old[i])); i += 1 }
        while j < m { lines.append(Line(kind: .added, text: new[j])); j += 1 }
        return lines
    }
}
