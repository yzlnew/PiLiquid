import Foundation

/// Enumerates pi session files for a project directory and summarizes each.
///
/// pi stores sessions at `~/.pi/agent/sessions/<encoded-cwd>/<ts>_<uuid>.jsonl`.
/// Rather than reconstruct that encoded folder name, callers pass the *current*
/// session file path (from `get_state`) and we read its parent directory — the
/// per-project sessions folder.
enum SessionIndex {
    /// List sessions in the directory that contains `currentSessionFile`
    /// (authoritative for the active project). File IO only.
    static func list(currentSessionFile: String?) -> [SessionInfo] {
        guard let current = currentSessionFile, !current.isEmpty else { return [] }
        let dirURL = URL(fileURLWithPath: (current as NSString).deletingLastPathComponent)
        return list(in: dirURL, currentSessionFile: current)
    }

    /// The per-project sessions directory pi uses for `path`, reconstructing its
    /// encoded folder name (`/`→`-`, wrapped in `-…--`; dots are preserved).
    static func directory(forProjectPath path: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let encoded = "-" + path.replacingOccurrences(of: "/", with: "-") + "--"
        return home.appendingPathComponent(".pi/agent/sessions/\(encoded)", isDirectory: true)
    }

    /// List sessions for an arbitrary project path.
    static func list(forProjectPath path: String, currentSessionFile: String?) -> [SessionInfo] {
        list(in: directory(forProjectPath: path), currentSessionFile: currentSessionFile)
    }

    /// Human title for a single session file (falls back to its filename if the
    /// file is gone). Used by the archived-conversations manager.
    static func title(forSessionFile path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return url.lastPathComponent }
        return summarize(url).title
    }

    private static func list(in dirURL: URL, currentSessionFile: String?) -> [SessionInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let sessions: [SessionInfo] = entries
            .filter { $0.pathExtension == "jsonl" }
            .map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let summary = summarize(url)
                return SessionInfo(
                    id: url.path,
                    title: summary.title,
                    modified: modified,
                    isCurrent: url.path == currentSessionFile,
                    isFork: summary.isFork
                )
            }
            .sorted { $0.modified > $1.modified }

        return sessions
    }

    /// Derive a human title (session `name`, else first user message, else a
    /// placeholder) and whether this is a fork (header carries `parentSession`).
    /// Reads only a prefix of the file.
    private static func summarize(_ url: URL) -> (title: String, isFork: Bool) {
        var name: String?
        var firstUser: String?
        var isFork = false

        for line in readPrefixLines(url) {
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
            switch v["type"]?.stringValue {
            case "session":
                name = v["name"]?.stringValue
                if let parent = v["parentSession"]?.stringValue, !parent.isEmpty { isFork = true }
            case "message":
                let msg = v["message"]
                if msg?["role"]?.stringValue == "user", firstUser == nil {
                    firstUser = extractText(msg?["content"])
                }
            default:
                break
            }
            if firstUser != nil { break }   // header (with name) precedes messages
        }

        let title = (name?.isEmpty == false ? name : firstUser) ?? "New session"
        return (title.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces), isFork)
    }

    /// Read the first `maxBytes` of a file and split into complete lines.
    private static func readPrefixLines(_ url: URL, maxBytes: Int = 16_384) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        // Drop a possibly-truncated final line when we hit the byte cap.
        if data.count == maxBytes, let nl = text.lastIndex(of: "\n") {
            text = String(text[..<nl])
        }
        return text.split(separator: "\n").map(String.init)
    }

    /// Flatten a message `content` (string or `[{type:text,text}]`) to plain text.
    private static func extractText(_ content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let s = content.stringValue { return s }
        if let arr = content.arrayValue {
            let texts = arr.compactMap { $0["text"]?.stringValue }
            return texts.isEmpty ? nil : texts.joined(separator: " ")
        }
        return nil
    }
}
