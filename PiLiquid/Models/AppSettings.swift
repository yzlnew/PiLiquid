import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`. The app is unsandboxed, so
/// plain filesystem paths are stored directly (no security-scoped bookmarks).
@MainActor
@Observable
final class AppSettings {
    var piExecutablePath: String {
        didSet { defaults.set(piExecutablePath, forKey: Keys.piPath) }
    }
    var defaultProvider: String {
        didSet { defaults.set(defaultProvider, forKey: Keys.provider) }
    }
    var defaultModel: String {
        didSet { defaults.set(defaultModel, forKey: Keys.model) }
    }
    var recentDirectories: [String] {
        didSet { defaults.set(recentDirectories, forKey: Keys.recents) }
    }

    /// Pre-spawn pi for recent projects so switching to them is instant
    /// (costs one idle pi process ≈150 MB per warmed project).
    var prewarmProjects: Bool {
        didSet { defaults.set(prewarmProjects, forKey: Keys.prewarm) }
    }

    /// The project + session (its `.jsonl` path) that was foreground when the app
    /// last quit, so a relaunch can drop the user back into that conversation
    /// instead of a fresh empty session.
    var lastProjectPath: String? {
        didSet { persist(lastProjectPath, Keys.lastProject) }
    }
    var lastSessionFile: String? {
        didSet { persist(lastSessionFile, Keys.lastSession) }
    }

    // Per-session, app-local state keyed by the session's .jsonl path.
    private(set) var pinnedSessions: Set<String> {
        didSet { defaults.set(Array(pinnedSessions), forKey: Keys.pinned) }
    }
    private(set) var archivedSessions: Set<String> {
        didSet { defaults.set(Array(archivedSessions), forKey: Keys.archived) }
    }
    private(set) var sessionNames: [String: String] {
        didSet { defaults.set(sessionNames, forKey: Keys.names) }
    }

    /// Isolated-session worktrees keyed by worktree path, so a relaunch that
    /// reopens a session whose working directory is a registered worktree can
    /// re-attach the merge/discard chip.
    private(set) var sessionWorktrees: [String: WorktreeInfo] {
        didSet {
            defaults.set(try? JSONEncoder().encode(sessionWorktrees), forKey: Keys.worktrees)
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let piPath = "piExecutablePath"
        static let provider = "defaultProvider"
        static let model = "defaultModel"
        static let recents = "recentDirectories"
        static let pinned = "pinnedSessions"
        static let archived = "archivedSessions"
        static let names = "sessionNames"
        static let lastProject = "lastProjectPath"
        static let lastSession = "lastSessionFile"
        static let worktrees = "sessionWorktrees"
        static let prewarm = "prewarmProjects"
    }

    init() {
        piExecutablePath = defaults.string(forKey: Keys.piPath) ?? Self.discoverPiPath()
        defaultProvider = defaults.string(forKey: Keys.provider) ?? ""
        defaultModel = defaults.string(forKey: Keys.model) ?? ""
        recentDirectories = defaults.stringArray(forKey: Keys.recents) ?? []
        prewarmProjects = (defaults.object(forKey: Keys.prewarm) as? Bool) ?? true
        pinnedSessions = Set(defaults.stringArray(forKey: Keys.pinned) ?? [])
        archivedSessions = Set(defaults.stringArray(forKey: Keys.archived) ?? [])
        sessionNames = (defaults.dictionary(forKey: Keys.names) as? [String: String]) ?? [:]
        lastProjectPath = defaults.string(forKey: Keys.lastProject)
        lastSessionFile = defaults.string(forKey: Keys.lastSession)
        sessionWorktrees = (defaults.data(forKey: Keys.worktrees))
            .flatMap { try? JSONDecoder().decode([String: WorktreeInfo].self, from: $0) } ?? [:]
    }

    /// Store a `String?` in `UserDefaults`, removing the key when nil.
    private func persist(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    // MARK: - Session state

    func isPinned(_ path: String) -> Bool { pinnedSessions.contains(path) }
    func isArchived(_ path: String) -> Bool { archivedSessions.contains(path) }

    func togglePin(_ path: String) {
        if pinnedSessions.contains(path) { pinnedSessions.remove(path) }
        else { pinnedSessions.insert(path) }
    }

    func setArchived(_ path: String, _ archived: Bool) {
        if archived { archivedSessions.insert(path) } else { archivedSessions.remove(path) }
    }

    /// App-local display name override, or nil to fall back to the pi title.
    func customName(_ path: String) -> String? {
        guard let raw = sessionNames[path]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw
    }

    func rename(_ path: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { sessionNames[path] = nil } else { sessionNames[path] = trimmed }
    }

    /// Drop all app-local state for a session (e.g. after deleting its file).
    func forgetSession(_ path: String) {
        pinnedSessions.remove(path)
        archivedSessions.remove(path)
        sessionNames[path] = nil
    }

    // MARK: - Worktree registry

    func registerWorktree(_ info: WorktreeInfo) {
        sessionWorktrees[info.path] = info
    }

    func forgetWorktree(_ path: String) {
        sessionWorktrees[path] = nil
    }

    func worktreeInfo(forDirectory path: String) -> WorktreeInfo? {
        sessionWorktrees[path]
    }

    func rememberDirectory(_ url: URL) {
        let path = url.path
        var list = recentDirectories.filter { $0 != path }
        list.insert(path, at: 0)
        recentDirectories = Array(list.prefix(8))
    }

    /// Drop a project from the sidebar. Only the recents entry goes away —
    /// nothing on disk (sessions included) is touched.
    func forgetDirectory(_ path: String) {
        recentDirectories.removeAll { $0 == path }
    }

    // MARK: - pi installation

    /// Whether the configured `pi` path points at a runnable binary.
    var isPiInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: piExecutablePath)
    }

    /// Re-scan the common install locations and adopt the first hit. Lets the
    /// "not found" state clear itself after the user installs pi, without a relaunch.
    func rediscoverPi() {
        piExecutablePath = Self.discoverPiPath()
    }

    /// One-line npm install for the pi coding agent.
    static let installCommand = "npm i -g @earendil-works/pi-coding-agent"

    /// Project homepage / install docs.
    static let websiteURL = URL(string: "https://github.com/earendil-works/pi")!

    /// Best-effort discovery of the `pi` binary across common install locations.
    static func discoverPiPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            "\(NSHomeDirectory())/.local/bin/pi",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to asking a login shell where `pi` resolves.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v pi"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
                return out
            }
        } catch { /* ignore */ }
        return "/opt/homebrew/bin/pi"
    }
}
