import Foundation
import Observation

/// Owns the fleet of `ChatModel` agents — one live `pi` process per session — and
/// designates exactly one as `active` (shown in the detail pane). Every other
/// agent keeps running in the background, folding its own RPC event stream into
/// a `runStatus` the sidebar surfaces as a status light.
///
/// This is the app-level environment object. The chat subtree still reads the
/// *active* `ChatModel` from the environment, so only the sidebar and a little
/// wiring need to know the manager exists.
@MainActor
@Observable
final class SessionManager {
    private(set) var agents: [ChatModel] = []
    private(set) var active: ChatModel?

    // MARK: - View history (browser-style back/forward)
    //
    // A visit stack of the sessions the user has foregrounded, so the toolbar's
    // back/forward buttons can walk through them. `historyIndex` points at the
    // current view; moving back/forward re-foregrounds without recording a new
    // visit, while any *fresh* activation truncates the forward entries (exactly
    // like a web browser).

    private var history: [ChatModel] = []
    private var historyIndex = -1
    /// Set while `goBack`/`goForward` drive `setActive`, so the visit isn't
    /// recorded as a new history entry.
    private var navigatingHistory = false

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    /// Re-foreground the previously viewed session.
    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        navigateHistory(to: history[historyIndex])
    }

    /// Re-foreground the session we came back from.
    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        navigateHistory(to: history[historyIndex])
    }

    private func navigateHistory(to agent: ChatModel) {
        navigatingHistory = true
        setActive(agent)
        navigatingHistory = false
    }

    /// Record a freshly-foregrounded session as the newest visit, dropping any
    /// forward entries. Consecutive duplicates are collapsed.
    private func recordVisit(_ agent: ChatModel) {
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        if history.last === agent {
            historyIndex = history.count - 1
            return
        }
        history.append(agent)
        historyIndex = history.count - 1
    }

    /// Drop every occurrence of a closed agent from the visit stack, keeping the
    /// current index pointing at the same remaining entry.
    private func forgetVisits(of agent: ChatModel) {
        let kept = history.filter { $0 !== agent }
        // Shift the cursor left by however many removed entries sat at/before it.
        let removedBeforeCursor = history.prefix(historyIndex + 1).filter { $0 === agent }.count
        history = kept
        historyIndex = kept.isEmpty ? -1 : min(max(historyIndex - removedBeforeCursor, 0), kept.count - 1)
    }

    /// Surfaced on the welcome screen when a launch fails outright (e.g. a bad
    /// pi path) — the failed agent is dropped rather than left as a broken pane.
    private(set) var lastLaunchError: String?

    private let settings: AppSettings
    /// Soft cap on concurrent pi processes; past this we stop the
    /// least-recently-active idle background agent before spawning another.
    private let maxAgents = 6

    init(settings: AppSettings) {
        self.settings = settings

        // Notification interactions route back through the fleet: action
        // buttons answer the pending approval dialog of the agent that posted
        // it; clicking the body foregrounds that session. Guarded by request id
        // so a stale notification can't answer a newer dialog.
        NotificationService.shared.onApprovalReply = { [weak self] agentID, requestID, reply in
            guard let agent = self?.agents.first(where: { $0.agentID == agentID }),
                  agent.pendingUIRequest?.id == requestID else { return }
            switch reply {
            case .confirm(let ok): agent.resolveUI(confirmed: ok)
            case .select(let value): agent.resolveUI(value: value)
            }
        }
        NotificationService.shared.onFocusSession = { [weak self] agentID in
            guard let self, let agent = self.agents.first(where: { $0.agentID == agentID }) else { return }
            self.setActive(agent)
        }
    }

    // MARK: - Opening / switching

    /// Open a project, optionally resuming a specific session file. Foregrounds an
    /// already-running agent when possible; otherwise spawns a new process.
    func open(_ url: URL, sessionPath: String? = nil) {
        settings.rememberDirectory(url)
        if let sessionPath, let existing = agent(forSessionPath: sessionPath) {
            setActive(existing)
            return
        }
        // Plain "open project" (no session): reuse this project's most-recently
        // used running agent instead of spawning a duplicate.
        if sessionPath == nil,
           let existing = agents
               .filter({ $0.workingDirectory?.path == url.path })
               .max(by: { $0.lastActivated < $1.lastActivated }) {
            setActive(existing)
            return
        }
        spawn(workingDirectory: url, resumeSessionFile: sessionPath)
    }

    /// Sidebar: resume a saved session in a project. Foregrounds it if it's
    /// already live in the background, else spawns a process attached to it.
    func resume(_ session: SessionInfo, in projectURL: URL) {
        settings.rememberDirectory(projectURL)
        if let existing = agent(forSessionPath: session.path) {
            setActive(existing)
            return
        }
        spawn(workingDirectory: projectURL, resumeSessionFile: session.path)
    }

    /// Start a brand-new session in `url`; the previous one keeps running.
    /// A warm pre-spawned agent for this project is consumed first — it IS a
    /// fresh session, already connected.
    func newSession(in url: URL) {
        settings.rememberDirectory(url)
        if let warm = agents.first(where: { $0.isWarm && $0.workingDirectory?.path == url.path }) {
            setActive(warm)
            return
        }
        spawn(workingDirectory: url, resumeSessionFile: nil)
    }

    /// Start a brand-new session isolated in its own git worktree, so parallel
    /// agents can't trample each other's files. The worktree lives under
    /// Application Support; the chat header chip offers merge back / discard.
    func newIsolatedSession(in url: URL) {
        settings.rememberDirectory(url)
        lastLaunchError = nil
        Task {
            let slug = Self.sessionSlug()
            let info = await Task.detached { WorktreeService.create(for: url, slug: slug) }.value
            guard let info else {
                lastLaunchError = String(localized: "Couldn't create a worktree — the project must be a git repository with at least one commit.")
                return
            }
            settings.registerWorktree(info)
            spawn(workingDirectory: info.url, resumeSessionFile: nil, worktree: info)
        }
    }

    /// Merge an isolated session's work back into the main repo (squash-staged,
    /// not committed) or discard it. On success the worktree is gone and the
    /// agent's chip clears; the caller decides when to close the session.
    func finishWorktree(for agent: ChatModel, merge: Bool) async -> (ok: Bool, message: String) {
        guard let info = agent.worktree else { return (false, "") }
        let result = await Task.detached { () -> (Bool, String) in
            if merge { return WorktreeService.mergeBack(info) }
            let ok = WorktreeService.remove(info)
            return (ok, ok ? String(localized: "Worktree discarded.")
                           : String(localized: "Couldn't remove the worktree."))
        }.value
        if result.0 {
            settings.forgetWorktree(info.path)
            agent.worktree = nil
        }
        return result
    }

    private static func sessionSlug() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Carry out a plan produced in plan mode: spawn a *fresh* session (normal
    /// mode, write tools enabled) in the same project and seed it with the plan
    /// as its first prompt. A clean session keeps the executing context free of
    /// the (potentially large) planning exploration. The plan session keeps
    /// running in the background, untouched.
    func executePlan(_ prompt: String, in url: URL) {
        spawn(workingDirectory: url, resumeSessionFile: nil, initialPrompt: prompt)
    }

    /// Stop and drop an agent (its session file stays on disk). If it was active,
    /// promote the next most-recently-used agent.
    func closeAgent(_ agent: ChatModel) {
        agent.stop()
        agents.removeAll { $0 === agent }
        forgetVisits(of: agent)
        if active === agent {
            active = nil   // clear so the promotion re-foregrounds and records a visit
            // Never promote a warm pool agent — closing your last real session
            // shouldn't teleport you into a blank session of another project.
            if let next = agents.filter({ !$0.isWarm }).max(by: { $0.lastActivated < $1.lastActivated }) {
                setActive(next)
            }
        }
    }

    // MARK: - Sidebar lookups

    func agent(forSessionPath path: String) -> ChatModel? {
        agents.first { $0.sessionFile == path }
    }

    /// The light to draw for a session row, or `nil` for none.
    func light(forSessionPath path: String) -> ChatModel.SessionLight? {
        agent(forSessionPath: path)?.sidebarLight
    }

    // MARK: - Internals

    private func spawn(workingDirectory url: URL, resumeSessionFile: String?,
                       initialPrompt: String? = nil, worktree: WorktreeInfo? = nil) {
        lastLaunchError = nil
        evictIfNeeded()
        let agent = ChatModel()
        // Attach worktree metadata — passed in for a fresh isolated session, or
        // rehydrated from the registry when a relaunch reopens a worktree cwd.
        agent.worktree = worktree ?? settings.worktreeInfo(forDirectory: url.path)
        agents.append(agent)
        setActive(agent)   // foreground synchronously so the pane swaps at once
        let config = launchConfig(url: url, resumeSessionFile: resumeSessionFile)
        Task {
            await agent.launch(config: config)
            // A launch that never connected and produced no transcript is a hard
            // failure (bad pi path, etc.) — drop it and surface the error rather
            // than leaving a dead pane behind.
            if !agent.isConnected, agent.launchError != nil, agent.transcript.isEmpty {
                lastLaunchError = agent.launchError
                closeAgent(agent)
            } else {
                if agent === active {
                    // The session file is known now (pi assigns it on start) —
                    // record it so a relaunch can restore this conversation.
                    rememberLastSession()
                }
                // Seed the first prompt (e.g. a plan to execute) once connected.
                if let initialPrompt, agent.isConnected {
                    agent.sendPrompt(initialPrompt)
                }
            }
        }
    }

    private func setActive(_ agent: ChatModel) {
        guard active !== agent else { agent.lastActivated = Date(); return }
        active?.setForeground(false)
        active = agent
        agent.setForeground(true)
        agent.lastActivated = Date()
        if agent.isWarm {
            // A warm agent just got consumed — it's a real session now; refill
            // the pool for the next project switch.
            agent.isWarm = false
            prewarmRecentProjects()
        }
        if !navigatingHistory { recordVisit(agent) }
        rememberLastSession()
    }

    /// Persist the foreground project + session so a relaunch can resume it.
    /// A brand-new session with no file yet simply isn't remembered until it has
    /// one (see the post-launch hook in `spawn`).
    private func rememberLastSession() {
        settings.lastProjectPath = active?.workingDirectory?.path
        settings.lastSessionFile = active?.sessionFile
    }

    /// Internal (not private) so tests can assert the exact pi invocation —
    /// e.g. that new sessions are never spawned with `--name` (which pi would
    /// persist as the session's title, shadowing the first-message title).
    func launchConfig(url: URL, resumeSessionFile: String?) -> PiLaunchConfig {
        var extra: [String] = []
        if let resumeSessionFile, !resumeSessionFile.isEmpty {
            extra = ["--session", resumeSessionFile]
        }
        return PiLaunchConfig(
            executablePath: settings.piExecutablePath,
            workingDirectory: url,
            provider: settings.defaultProvider.isEmpty ? nil : settings.defaultProvider,
            model: settings.defaultModel.isEmpty ? nil : settings.defaultModel,
            extraArguments: extra,
            resumeSessionFile: resumeSessionFile
        )
    }

    /// Keep the process count bounded: at the cap, stop the least-recently-active
    /// background agent that isn't working or waiting on a permission dialog.
    /// Warm pool agents go first — they hold no conversation.
    private func evictIfNeeded() {
        guard agents.count >= maxAgents else { return }
        let victim = agents.first(where: { $0.isWarm })
            ?? agents
                .filter { $0 !== active && $0.runStatus != .working && $0.runStatus != .needsPermission }
                .min(by: { $0.lastActivated < $1.lastActivated })
        if let victim {
            victim.stop()
            agents.removeAll { $0 === victim }
            forgetVisits(of: victim)   // don't let back/forward land on a stopped agent
        }
    }

    // MARK: - Warm pool
    //
    // Opening a project with no live agent costs a full pi spawn (seconds of
    // "Connecting…"). Keep up to `warmLimit` pre-spawned, never-foregrounded
    // agents for the most recent other projects, so the first open / new
    // session there swaps in an already-connected process instantly. Warm
    // agents are hidden from the sidebar, first in line for eviction, and
    // never crowd out real sessions (they only fill genuinely spare slots).

    private let warmLimit = 2

    /// Top up the warm pool from the recents list. Safe to call repeatedly.
    func prewarmRecentProjects() {
        guard settings.prewarmProjects, settings.isPiInstalled else { return }
        let liveDirs = Set(agents.compactMap { $0.workingDirectory?.path })
        let warmCount = agents.filter(\.isWarm).count
        let room = min(warmLimit - warmCount, maxAgents - 1 - agents.count)
        guard room > 0 else { return }
        let candidates = settings.recentDirectories
            .filter { !liveDirs.contains($0) && Self.directoryExists($0) }
            .prefix(room)
        for path in candidates {
            spawnWarm(URL(fileURLWithPath: path))
        }
    }

    private func spawnWarm(_ url: URL) {
        let agent = ChatModel()
        agent.isWarm = true
        agents.append(agent)
        let config = launchConfig(url: url, resumeSessionFile: nil)
        Task {
            await agent.launch(config: config)
            // A warm spawn that failed is silently dropped — the normal open
            // path will retry (and surface the error) when the user gets there.
            if !agent.isConnected, agent.isWarm {
                agents.removeAll { $0 === agent }
            }
        }
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
