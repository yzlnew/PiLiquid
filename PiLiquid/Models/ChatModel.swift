import Foundation
import Observation

/// The app's central state. Owns a `PiClient`, drives it with commands, and
/// folds the inbound RPC event stream into a rendered `transcript`.
@MainActor
@Observable
final class ChatModel {
    /// Stable identity for routing async callbacks (notification actions) back
    /// to this agent across the manager's fleet.
    let agentID = UUID().uuidString

    // Connection
    private(set) var isConnected = false
    private(set) var isStreaming = false
    private(set) var launchError: String?
    /// A session/project switch is in flight (process restart + history load).
    private(set) var isLoadingSession = false

    /// Pre-spawned for a recent project but never shown to the user yet — the
    /// manager's warm pool. Hidden from the sidebar; cleared on first foreground.
    var isWarm = false

    /// A composer `!` shell command is executing (the `bash` RPC call returns
    /// only on completion) — the stop button aborts it instead of the agent.
    private(set) var bashRunning = false

    /// pi is waiting out an auto-retry delay (between `auto_retry_start`/`_end`).
    private(set) var retryPending = false

    // Session toggles, mirrored optimistically (pi's defaults; there is no
    // RPC read-back for them).
    private(set) var autoCompaction = true
    private(set) var autoRetry = true
    private(set) var steeringMode = "one-at-a-time"
    private(set) var followUpMode = "one-at-a-time"

    // MARK: - Background run status
    //
    // Every session runs in its own process, so a backgrounded agent keeps
    // reporting state. `runStatus` is the raw lifecycle; the sidebar turns it
    // into a light via `sidebarLight`, suppressed while this agent is foreground
    // (you're already looking at it) or once its attention has been acknowledged.

    enum RunStatus { case idle, working, needsPermission, succeeded, failed }

    /// The four lights the sidebar can show for a background session.
    enum SessionLight { case working, permission, failed, succeeded }

    private(set) var runStatus: RunStatus = .idle
    /// True while this is the session shown in the detail pane. Set by SessionManager.
    private(set) var isForeground = false
    /// Cleared (true) when foregrounded/seen; a later background transition
    /// flips it back to false so the light re-appears.
    private(set) var attentionCleared = true
    /// Latches within a turn so `agentEnd` can decide succeeded vs. failed.
    private var turnHadError = false

    /// The light to draw in the sidebar tree, or `nil` for none.
    var sidebarLight: SessionLight? {
        if isForeground { return nil }              // you're looking at it
        switch runStatus {
        case .working:                                 return .working
        case .needsPermission where !attentionCleared: return .permission
        case .failed where !attentionCleared:          return .failed
        case .succeeded where !attentionCleared:       return .succeeded
        default:                                       return nil
        }
    }

    /// Called by the manager when this agent enters/leaves the foreground.
    /// Entering clears the attention light (the "点进去灯消失" behaviour).
    func setForeground(_ on: Bool) {
        isForeground = on
        if on { attentionCleared = true }
    }

    /// A backgrounded agent produced noteworthy activity — re-light its row.
    private func noteBackgroundActivity() {
        if !isForeground { attentionCleared = false }
    }

    /// Bumped by the manager for LRU eviction of idle background agents.
    var lastActivated = Date.distantPast

    // Session
    /// Set when this session runs isolated in its own git worktree (feature:
    /// parallel agents without file collisions). Owned by `SessionManager`;
    /// cleared once the worktree is merged back or discarded.
    var worktree: WorktreeInfo?

    /// The project the user thinks of this session as belonging to — the main
    /// repo for an isolated session, the working directory otherwise.
    var homeProjectURL: URL? { worktree.map(\.repoURL) ?? workingDirectory }

    private(set) var workingDirectory: URL?
    private(set) var sessionName: String?
    /// Leading part of the session's first user request, set once when it's
    /// sent (or recovered from history on resume). Stored — not derived from
    /// `transcript` — so the sidebar can read it without observing every
    /// streaming flush. A brand-new session stays `nil`, which is also the
    /// sidebar's cue to not show a row for it yet.
    private(set) var firstUserPrompt: String?
    private(set) var sessionId: String?
    private(set) var sessionFile: String?
    private(set) var sessions: [SessionInfo] = []

    // Model & thinking
    private(set) var currentModel: PiModel?
    private(set) var availableModels: [PiModel] = []
    var thinkingLevel: String = "medium"

    // Slash commands (extensions, prompt templates, skills) for the composer palette.
    private(set) var commands: [PiCommand] = []

    // MARK: - Extension UI surfaces (setStatus / setWidget)
    //
    // Fire-and-forget footer statuses and widgets an extension posts over RPC,
    // keyed by the extension's own key. ANSI color codes (theme.fg emits them)
    // are stripped on ingest so the strings render cleanly in native views.
    // The plan-mode extension drives `plan-mode` (status) and `plan-todos`
    // (widget); `planTodos`/`isPlanActive` below derive the progress UI from them.
    private(set) var extensionStatuses: [String: String] = [:]
    private(set) var extensionWidgets: [String: [String]] = [:]

    /// Whether the loaded extensions expose a `/plan` command (gates the toggle).
    var supportsPlanMode: Bool { commands.contains { $0.name == "plan" } }

    /// Plan mode is active while its extension is posting a footer status.
    var isPlanActive: Bool { !(extensionStatuses["plan-mode"] ?? "").isEmpty }

    /// The plan-mode footer text, ANSI-stripped (e.g. "⏸ plan").
    var planStatusText: String? {
        let s = extensionStatuses["plan-mode"] ?? ""
        return s.isEmpty ? nil : s
    }

    /// The latest assistant reply's text — the plan produced in plan mode, which
    /// the app hands to a fresh session to execute. `nil` before any reply.
    var latestPlanText: String? {
        for item in transcript.reversed() {
            guard case .assistant(let entry) = item else { continue }
            let text = entry.segments.compactMap { segment -> String? in
                if case .text(let t) = segment { return t }
                return nil
            }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    // Usage
    private(set) var stats: SessionStats?

    // Conversation
    private(set) var transcript: [TranscriptItem] = []
    private(set) var steeringQueue: [String] = []
    private(set) var followUpQueue: [String] = []

    /// Wall-clock duration of each completed turn, keyed by the id of that turn's
    /// final assistant message. Filled on `agentEnd`; the transcript uses it to
    /// label a turn's collapsed middle ("已处理 · 12s"). Turns loaded from history
    /// have no entry (we only ever have live timing).
    private(set) var turnDurations: [String: TimeInterval] = [:]
    /// When the in-flight turn began, captured on `agentStart`.
    private var turnStart: Date?

    // MARK: - Turn working-tree diffs
    //
    // Every turn is bracketed by a git snapshot (a temp-index `write-tree` of
    // the whole working tree, untracked included); diffing the two trees gives
    // the changes the turn *actually* made — as opposed to what the transcript
    // claims. Keyed like `turnDurations`, by the turn's final assistant message.

    private(set) var turnDiffs: [String: TurnDiff] = [:]
    /// The turn diff pinned in the inspector's review tab, if any (UI state;
    /// the panel re-reads it after a revert). When nil the tab falls back to
    /// the latest turn's diff.
    var reviewingTurnDiff: TurnDiff?
    private(set) var isGitRepo = false
    /// The pre-turn snapshot, in flight while the turn runs.
    private var turnBaseTreeTask: Task<String?, Never>?

    // MARK: - Inspector (right side panel)

    enum InspectorTab: Hashable { case review, files }
    var inspectorShown = false
    var inspectorTab: InspectorTab = .review

    /// The most recent turn's diff — the review tab's default subject when no
    /// specific turn chip was clicked.
    var latestTurnDiff: TurnDiff? {
        for item in transcript.reversed() {
            if case .assistant(let e) = item, let diff = turnDiffs[e.id] { return diff }
        }
        return nil
    }

    // Extension UI dialog awaiting a user response (tool approvals, etc.)
    var pendingUIRequest: ExtUIRequest?

    /// Text to drop into the composer (e.g. the prompt returned when forking),
    /// consumed and cleared by the chat view.
    var composerPrefill: String?

    // MARK: - Streaming coalescing
    //
    // pi streams `message_update`/`tool_execution_update` at token/chunk rate —
    // hundreds of events per second for a big tool output. Folding each one
    // straight into `transcript` re-diffs the whole conversation view (and
    // re-runs every visible webview's update) per event, saturating the main
    // thread. Instead the latest payload per entry is buffered here and applied
    // at most every `streamFlushInterval`; end events always apply immediately.

    @ObservationIgnored private var pendingAssistantSegments: [String: [TextSegment]] = [:]
    @ObservationIgnored private var pendingToolOutputs: [String: String] = [:]
    @ObservationIgnored private var streamFlushTask: Task<Void, Never>?
    /// Minimum spacing between streaming UI updates. Internal so tests can shrink it.
    @ObservationIgnored var streamFlushInterval: TimeInterval = 0.08

    private func scheduleStreamFlush() {
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.streamFlushInterval ?? 0.08))
            guard !Task.isCancelled else { return }
            self?.flushStreamingUpdates()
        }
    }

    /// Apply every buffered streaming payload in one transcript pass.
    private func flushStreamingUpdates() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        guard !pendingAssistantSegments.isEmpty || !pendingToolOutputs.isEmpty else { return }
        for (id, segments) in pendingAssistantSegments {
            updateAssistant(id) { $0.segments = segments }
        }
        pendingAssistantSegments.removeAll()
        for (id, output) in pendingToolOutputs {
            updateTool(id) { $0.output = output }
        }
        pendingToolOutputs.removeAll()
    }

    // Recreated on every (re)launch: its event/inbound streams are single-shot
    // `AsyncStream`s, so a cross-project switch (which respawns pi) needs a fresh
    // client — re-subscribing to a spent stream silently delivers nothing.
    private var client = PiClient()

    /// Project file index backing the composer's `@`-mention picker. Rebuilt on
    /// each launch for the new working directory.
    private let fileIndex = FileIndex()
    private var currentAssistantId: String?
    private var eventTask: Task<Void, Never>?
    private var diagnosticsBuffer = ""

    let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh"]

    // MARK: - Lifecycle

    func launch(config: PiLaunchConfig) async {
        // Optimistic UI first (synchronous, so it lands before the slow restart):
        // switch project, highlight the resuming session, list that project's
        // sessions from disk. Cross-project switches must respawn pi, which takes
        // seconds — but the loader is only for *reloading history*. A fresh
        // session has no transcript to settle, so show its hero screen right away
        // and just disable sending until the agent connects (see ComposerView).
        let resuming = config.resumeSessionFile != nil
        launchError = nil
        transcript.removeAll()
        extensionStatuses.removeAll()
        extensionWidgets.removeAll()
        streamFlushTask?.cancel()
        streamFlushTask = nil
        pendingAssistantSegments.removeAll()
        pendingToolOutputs.removeAll()
        currentAssistantId = nil
        workingDirectory = config.workingDirectory
        // Rebuild the `@`-mention file index off the main actor; the picker
        // tolerates an empty index until this lands.
        Task { await fileIndex.rebuild(root: config.workingDirectory) }
        // Turn diffs only make sense inside a repo — probe once per launch.
        let dir = config.workingDirectory
        isGitRepo = false
        Task { isGitRepo = await Task.detached { GitService.isRepo(in: dir) }.value }
        sessionName = nil   // authoritative name arrives via get_state after connect
        firstUserPrompt = nil
        sessionFile = config.resumeSessionFile
        isLoadingSession = resuming
        isConnected = false
        await refreshSessions()

        // Tear down any existing agent first and *await* it, so the old process
        // is fully stopped before we start the new one. Doing this inline (rather
        // than a fire-and-forget stop() at the call site) avoids a race where the
        // stray stop lands after start and kills the freshly-launched process.
        await teardown()

        // Fresh client so this launch gets live event/inbound streams (the old
        // instance's are spent once iterated). `teardown()` already stopped and
        // finished the previous one.
        client = PiClient()

        // Drain stderr for diagnostics in the background.
        let diagStream = client.diagnostics
        Task { for await chunk in diagStream { self.appendDiagnostics(chunk) } }

        do {
            try await client.start(config)
        } catch {
            launchError = error.localizedDescription
            runStatus = .failed
            noteBackgroundActivity()
            isLoadingSession = false
            return
        }
        isConnected = true
        NotificationService.shared.requestAuthorizationIfNeeded()

        let stream = client.events
        eventTask = Task { [weak self] in
            for await item in stream {
                self?.handle(item)
            }
        }

        await refreshState()
        await refreshModels()
        await refreshCommands()
        await loadMessages()   // populate history when resuming an existing session
        // Only the history path needs the loader + settle hold: hold briefly so
        // message webviews lay out behind the loader before reveal. A fresh
        // session never showed the loader, so there's nothing to reveal.
        if resuming {
            try? await Task.sleep(for: .milliseconds(450))
            isLoadingSession = false
        }
    }

    func stop() {
        Task { await teardown() }
    }

    /// Cancel the event pump and stop the child process, awaiting the actor so
    /// callers can rely on the agent being fully down when this returns.
    private func teardown() async {
        eventTask?.cancel()
        eventTask = nil
        stopStallWatchdog()
        await client.stop()
        isConnected = false
        isStreaming = false
    }

    private func appendDiagnostics(_ chunk: String) {
        diagnosticsBuffer += chunk
        if diagnosticsBuffer.count > 8000 {
            diagnosticsBuffer = String(diagnosticsBuffer.suffix(8000))
        }
    }

    var diagnostics: String { diagnosticsBuffer }

    // MARK: - Commands

    /// Whether the active model accepts image input. Gates the composer's
    /// attachment affordances.
    var modelSupportsImages: Bool { currentModel?.supportsImages ?? false }

    func sendPrompt(_ text: String, images: [ImageAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only forward images the current model can actually consume.
        let attachments = modelSupportsImages ? images : []
        guard isConnected, !trimmed.isEmpty || !attachments.isEmpty else { return }

        transcript.append(.user(UserEntry(id: UUID().uuidString, text: trimmed,
                                          attachments: attachments, timestamp: Date())))
        if firstUserPrompt == nil, !trimmed.isEmpty { firstUserPrompt = Self.promptPreview(trimmed) }

        var params: [String: JSONValue] = ["message": .string(trimmed)]
        if !attachments.isEmpty { params["images"] = .array(attachments.map(\.rpcValue)) }
        if isStreaming { params["streamingBehavior"] = .string("steer") }

        Task {
            let resp = await client.send("prompt", params)
            if !resp.success {
                self.addNotice(.error, resp.error ?? String(localized: "Prompt rejected"))
            }
        }
    }

    func abort() {
        Task { await client.send("abort") }
    }

    /// Queue a follow-up: delivered only after the agent finishes its current
    /// run (steering instead interrupts after the current turn). Mirrors
    /// `sendPrompt`'s bubble-at-send behaviour so both queue paths read alike.
    func sendFollowUp(_ text: String, images: [ImageAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = modelSupportsImages ? images : []
        guard isConnected, !trimmed.isEmpty || !attachments.isEmpty else { return }

        transcript.append(.user(UserEntry(id: UUID().uuidString, text: trimmed,
                                          attachments: attachments, timestamp: Date())))
        if firstUserPrompt == nil, !trimmed.isEmpty { firstUserPrompt = Self.promptPreview(trimmed) }

        var params: [String: JSONValue] = ["message": .string(trimmed)]
        if !attachments.isEmpty { params["images"] = .array(attachments.map(\.rpcValue)) }
        Task {
            let resp = await client.send("follow_up", params)
            if !resp.success {
                self.addNotice(.error, resp.error ?? String(localized: "Follow-up rejected"))
            }
        }
    }

    /// Duplicate the active branch into a new session at the current position.
    /// The clone becomes the active session; the original stays on disk.
    func cloneSession() {
        guard isConnected else { return }
        Task {
            let resp = await client.send("clone")
            guard resp.success else {
                addNotice(.error, resp.error ?? String(localized: "Clone failed"))
                return
            }
            if resp.data?["cancelled"]?.boolValue == true { return }
            await refreshState()
            await refreshSessions()
            addNotice(.info, String(localized: "Cloned into a new session"))
        }
    }

    /// Run a shell command via pi (the composer's leading-`!` mode). Output
    /// lands in a terminal-style tool row and pi folds it into the LLM context
    /// on the next prompt.
    func runBash(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !trimmed.isEmpty else { return }
        let entryID = "bash-\(UUID().uuidString)"
        transcript.append(.tool(ToolEntry(
            id: entryID, name: "bash", argsSummary: trimmed, output: "", status: .running,
            isManual: true
        )))
        bashRunning = true
        Task {
            let resp = await client.send("bash", ["command": .string(trimmed)])
            bashRunning = false
            let output = resp.data?["output"]?.stringValue ?? ""
            let exitCode = resp.data?["exitCode"]?.intValue ?? 0
            updateTool(entryID) {
                $0.output = output.isEmpty ? (resp.error ?? "") : output
                $0.status = (resp.success && exitCode == 0) ? .done : .error
            }
            if resp.data?["truncated"]?.boolValue == true,
               let path = resp.data?["fullOutputPath"]?.stringValue {
                addNotice(.info, String(localized: "Shell output truncated — full log: \(path)"))
            }
        }
    }

    func abortBash() {
        Task { await client.send("abort_bash") }
    }

    // MARK: - Session toggles

    func setAutoCompaction(_ enabled: Bool) {
        autoCompaction = enabled
        Task { await client.send("set_auto_compaction", ["enabled": .bool(enabled)]) }
    }

    func setAutoRetry(_ enabled: Bool) {
        autoRetry = enabled
        Task { await client.send("set_auto_retry", ["enabled": .bool(enabled)]) }
    }

    /// `"all"` or `"one-at-a-time"`.
    func setSteeringMode(_ mode: String) {
        steeringMode = mode
        Task { await client.send("set_steering_mode", ["mode": .string(mode)]) }
    }

    func setFollowUpMode(_ mode: String) {
        followUpMode = mode
        Task { await client.send("set_follow_up_mode", ["mode": .string(mode)]) }
    }

    /// Cancel an in-flight auto-retry wait (the turn then fails immediately).
    func abortRetry() {
        retryPending = false
        Task { await client.send("abort_retry") }
    }

    // MARK: - Cycling

    /// Step to the next available model (menu shortcut). pi picks the order.
    func cycleModel() {
        guard isConnected else { return }
        Task {
            let resp = await client.send("cycle_model")
            guard resp.success, let data = resp.data, data.objectValue != nil else { return }
            if let m = PiModel(data["model"]) { currentModel = m }
            if let level = data["thinkingLevel"]?.stringValue { thinkingLevel = level }
            await refreshStats()
        }
    }

    /// Step through thinking levels; no-op when the model doesn't think.
    func cycleThinkingLevel() {
        guard isConnected else { return }
        Task {
            let resp = await client.send("cycle_thinking_level")
            guard resp.success, let level = resp.data?["level"]?.stringValue else { return }
            thinkingLevel = level
        }
    }

    /// Export the session to a standalone HTML file (pi renders it). Returns
    /// the written path, or nil on failure (a notice is posted either way).
    @discardableResult
    func exportHTML(to url: URL) async -> String? {
        guard isConnected else { return nil }
        let resp = await client.send("export_html", ["outputPath": .string(url.path)])
        guard resp.success, let path = resp.data?["path"]?.stringValue else {
            addNotice(.error, resp.error ?? String(localized: "Export failed"))
            return nil
        }
        addNotice(.info, String(localized: "Exported to \(path)"))
        return path
    }

    /// Toggle plan mode by invoking the extension's `/plan` command.
    func togglePlanMode() { runCommand("plan") }

    /// Invoke a slash command (extension command, prompt template, or skill)
    /// directly, without adding a user bubble — extension commands like `/plan`
    /// manage their own output. Runs even while streaming (pi executes extension
    /// commands immediately).
    func runCommand(_ name: String) {
        guard isConnected else { return }
        Task {
            let resp = await client.send("prompt", ["message": .string("/\(name)")])
            if !resp.success {
                addNotice(.error, resp.error ?? String(localized: "Command failed"))
            }
        }
    }

    /// Fork a new session from the user prompt that produced the given assistant
    /// message. `fork` is keyed by the prompt's `entryId` (only exposed via
    /// `get_fork_messages`), so we map the assistant row → its preceding user
    /// prompt's ordinal → entryId. The fork becomes the active session and its
    /// original prompt text is dropped into the composer to edit and resend.
    func fork(fromAssistant assistantId: String) {
        guard isConnected else { return }
        guard let idx = transcript.firstIndex(where: { $0.id == assistantId }) else { return }
        let priorUserCount = transcript[..<idx].reduce(0) {
            if case .user = $1 { return $0 + 1 } else { return $0 }
        }
        let ordinal = priorUserCount - 1
        guard ordinal >= 0 else { return }

        Task {
            let points = await forkMessages()
            guard ordinal < points.count else {
                addNotice(.error, String(localized: "Couldn't fork from this message"))
                return
            }
            await performFork(entryId: points[ordinal].id)
        }
    }

    /// Confirmed in-place edit of a sent prompt: rewind to just before it
    /// (fork under the hood — pi's only rewind primitive) and immediately
    /// resend the revised text, so the same pane regenerates from there. No
    /// composer round-trip, no fork announcement.
    func resendEdited(_ userId: String, newText: String, attachments: [ImageAttachment] = []) {
        guard isConnected else { return }
        guard let idx = transcript.firstIndex(where: { $0.id == userId }) else { return }
        // This prompt's ordinal among user messages = how many precede it.
        let ordinal = transcript[..<idx].reduce(0) {
            if case .user = $1 { return $0 + 1 } else { return $0 }
        }
        Task {
            let points = await forkMessages()
            guard ordinal < points.count else {
                addNotice(.error, String(localized: "Couldn't fork from this message"))
                return
            }
            guard await performFork(entryId: points[ordinal].id, quiet: true) else { return }
            sendPrompt(newText, images: attachments)
        }
    }

    /// A user prompt the session can be forked (rewound) from — the timeline's
    /// unit. `id` is pi's entry id, only obtainable via `get_fork_messages`.
    struct ForkPoint: Identifiable, Sendable, Equatable {
        let id: String
        let text: String
    }

    /// The active branch's user prompts, oldest first (pi's order).
    func forkMessages() async -> [ForkPoint] {
        let resp = await client.send("get_fork_messages")
        guard resp.success, let arr = resp.data?["messages"]?.arrayValue else { return [] }
        return arr.compactMap { msg in
            guard let id = msg["entryId"]?.stringValue else { return nil }
            return ForkPoint(id: id, text: msg["text"]?.stringValue ?? "")
        }
    }

    /// Timeline: rewind/branch from the given prompt entry.
    func fork(fromEntry entryId: String) {
        guard isConnected else { return }
        Task { await performFork(entryId: entryId) }
    }

    /// Shared fork tail: branch the session before `entryId` and rebuild the
    /// transcript from the fork. Normally the original prompt text drops into
    /// the composer to edit and a notice announces the fork; `quiet` skips
    /// both (the in-place edit flow resends immediately instead).
    @discardableResult
    private func performFork(entryId: String, quiet: Bool = false) async -> Bool {
        let forkResp = await client.send("fork", ["entryId": .string(entryId)])
        guard forkResp.success else {
            addNotice(.error, forkResp.error ?? String(localized: "Fork failed"))
            return false
        }
        if forkResp.data?["cancelled"]?.boolValue == true { return false }

        // The fork is now the active session — rebuild from it.
        await loadMessages()
        await refreshState()
        await refreshStats()
        await refreshSessions()
        if !quiet {
            if let text = forkResp.data?["text"]?.stringValue, !text.isEmpty {
                composerPrefill = text
            }
            addNotice(.info, String(localized: "Forked into a new session"))
        }
        return true
    }

    /// Pull the full message history and rebuild the rendered transcript.
    private func loadMessages() async {
        let resp = await client.send("get_messages")
        guard resp.success, let messages = resp.data?["messages"]?.arrayValue else { return }
        rebuildTranscript(from: messages)
    }

    private func rebuildTranscript(from messages: [JSONValue]) {
        var items: [TranscriptItem] = []
        var toolIndexByCallId: [String: Int] = [:]
        currentAssistantId = nil

        for msg in messages {
            let timestamp = msg["timestamp"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
            switch msg["role"]?.stringValue {
            case "user":
                let text = Self.flattenContent(msg["content"]) ?? ""
                let images = Self.extractImages(msg["content"])
                if !text.isEmpty || !images.isEmpty {
                    items.append(.user(UserEntry(id: UUID().uuidString, text: text,
                                                 attachments: images, timestamp: timestamp)))
                }
            case "assistant":
                let blocks = msg["content"]?.arrayValue ?? []
                var segments: [TextSegment] = []
                for block in blocks {
                    switch block["type"]?.stringValue {
                    case "text":
                        if let t = block["text"]?.stringValue, !t.isEmpty { segments.append(.text(t)) }
                    case "thinking":
                        if let t = block["thinking"]?.stringValue, !t.isEmpty { segments.append(.thinking(t)) }
                    default:
                        break
                    }
                }
                if !segments.isEmpty {
                    items.append(.assistant(AssistantEntry(id: UUID().uuidString, segments: segments,
                                                           isStreaming: false, timestamp: timestamp)))
                }
                // Tool calls become their own rows, filled in by tool results below.
                for block in blocks where block["type"]?.stringValue == "toolCall" {
                    let callId = block["id"]?.stringValue ?? UUID().uuidString
                    let entry = ToolEntry(
                        id: callId,
                        name: block["name"]?.stringValue ?? "tool",
                        argsSummary: Self.summarizeArgs(block["arguments"]),
                        output: "",
                        status: .done,
                        diff: ToolDiff.from(toolName: block["name"]?.stringValue ?? "", args: block["arguments"])
                    )
                    toolIndexByCallId[callId] = items.count
                    items.append(.tool(entry))
                }
            case "toolResult":
                let callId = msg["toolCallId"]?.stringValue ?? ""
                if let idx = toolIndexByCallId[callId], case .tool(var entry) = items[idx] {
                    entry.output = RPCEvent.extractContentText(msg) ?? entry.output
                    entry.status = (msg["isError"]?.boolValue == true) ? .error : .done
                    items[idx] = .tool(entry)
                }
            default:
                break
            }
        }
        transcript = items
        // Resumed/forked sessions carry their history — recover the first
        // request so the sidebar row keeps its prompt-derived title.
        if firstUserPrompt == nil {
            for item in items {
                if case .user(let entry) = item, !entry.text.isEmpty {
                    firstUserPrompt = Self.promptPreview(entry.text)
                    break
                }
            }
        }
    }

    /// First line of a request, capped, for use as a session title.
    private static func promptPreview(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1,
                                   omittingEmptySubsequences: true).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }

    /// Decode any `ImageContent` blocks from a stored user message so attachments
    /// reappear when a session is resumed. Tolerates both `data` (ImageContent)
    /// and `content` (Attachment) base64 keys.
    private static func extractImages(_ content: JSONValue?) -> [ImageAttachment] {
        guard let arr = content?.arrayValue else { return [] }
        return arr.compactMap { block in
            guard block["type"]?.stringValue == "image" else { return nil }
            let b64 = block["data"]?.stringValue ?? block["content"]?.stringValue
            guard let b64 else { return nil }
            let mime = block["mimeType"]?.stringValue ?? "image/png"
            return ImageAttachment(base64: b64, mimeType: mime)
        }
    }

    private static func flattenContent(_ content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let s = content.stringValue { return s }
        if let arr = content.arrayValue {
            let texts = arr.compactMap { $0["text"]?.stringValue }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    func setModel(_ model: PiModel) {
        Task {
            let resp = await client.send("set_model", [
                "provider": .string(model.provider),
                "modelId": .string(model.id),
            ])
            if resp.success, let m = PiModel(resp.data) {
                currentModel = m
            }
            await refreshStats()
        }
    }

    func setThinking(_ level: String) {
        thinkingLevel = level
        Task { await client.send("set_thinking_level", ["level": .string(level)]) }
    }

    /// Rename the *active* session authoritatively via pi. `set_session_name`
    /// appends a `session_info` entry, so the name persists in the session file
    /// and surfaces through `get_state.sessionName` (and pi's own `/resume`).
    /// A blank name clears it, falling back to the first-message title.
    func renameActiveSession(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionName = trimmed.isEmpty ? nil : trimmed   // optimistic; sidebar reflects instantly
        Task {
            let resp = await client.send("set_session_name", ["name": .string(trimmed)])
            if !resp.success {
                addNotice(.error, resp.error ?? String(localized: "Couldn't rename session"))
            }
            await refreshSessions()
        }
    }

    func compact(customInstructions: String? = nil) {
        Task {
            addNotice(.info, String(localized: "Compacting context…"))
            var params: [String: JSONValue] = [:]
            if let instructions = customInstructions, !instructions.isEmpty {
                params["customInstructions"] = .string(instructions)
            }
            await client.send("compact", params)
            await refreshStats()
        }
    }

    // MARK: - State refresh

    func refreshState() async {
        let resp = await client.send("get_state")
        guard resp.success, let data = resp.data else { return }
        currentModel = PiModel(data["model"])
        thinkingLevel = data["thinkingLevel"]?.stringValue ?? thinkingLevel
        isStreaming = data["isStreaming"]?.boolValue ?? false
        // Session toggles pi reports back (auto-retry has no read-back).
        autoCompaction = data["autoCompactionEnabled"]?.boolValue ?? autoCompaction
        steeringMode = data["steeringMode"]?.stringValue ?? steeringMode
        followUpMode = data["followUpMode"]?.stringValue ?? followUpMode
        sessionId = data["sessionId"]?.stringValue
        sessionFile = data["sessionFile"]?.stringValue
        if let name = Self.adoptedSessionName(data["sessionName"]?.stringValue,
                                              projectFolderName: workingDirectory?.lastPathComponent) {
            sessionName = name
        }
        await refreshSessions()
    }

    /// Which fetched session name to adopt, if any. Migration shim: earlier
    /// builds spawned every new session with `--name <project folder>`,
    /// permanently naming them after the project — ignore that poisoned name so
    /// those sessions fall back to their first-message title instead of all
    /// reading "pi_liquid" etc.
    static func adoptedSessionName(_ fetched: String?, projectFolderName: String?) -> String? {
        guard let fetched, !fetched.isEmpty, fetched != projectFolderName else { return nil }
        return fetched
    }

    /// True while the agent is running but the transcript's tail has no
    /// streaming assistant bubble to signal life — i.e. the next model response
    /// hasn't started arriving (initial call, between tool turns, or a stalled
    /// request — pi has no request timeout, so a stall is otherwise invisible).
    var awaitingModelOutput: Bool {
        guard isStreaming else { return false }
        if case .assistant(let e) = transcript.last, e.isStreaming { return false }
        return true
    }

    // MARK: - Stall watchdog
    //
    // Model API requests can stall indefinitely (observed with DeepSeek: the
    // connection opens and nothing ever arrives — no error, no timeout). pi
    // only gives up after its `httpIdleTimeoutMs` (minutes), so surface the
    // silence in the UI: after `stallAfter` seconds with no inbound RPC
    // activity while we're waiting on the model, `modelStalled` flips true and
    // the transcript shows a hint next to the typing indicator. Any inbound
    // line clears it.

    /// Seconds of RPC silence (while awaiting model output) before the UI
    /// calls the request stalled. Internal so tests can shrink it.
    var stallAfter: TimeInterval = 45
    private(set) var modelStalled = false
    /// Not observed by any view (only the watchdog reads it) — and it's written
    /// on every inbound RPC line, so routing it through the observation
    /// registrar would fire observers at token rate for nothing.
    @ObservationIgnored private var lastInboundAt = Date()
    private var stallWatchdog: Task<Void, Never>?

    private func startStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = max(self.stallAfter / 4, 0.05)
                try? await Task.sleep(for: .seconds(interval))
                guard self.isStreaming else { return }
                if self.awaitingModelOutput,
                   Date().timeIntervalSince(self.lastInboundAt) > self.stallAfter {
                    self.modelStalled = true
                }
            }
        }
    }

    private func stopStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
        modelStalled = false
    }

    /// Re-scan the on-disk session list for the current project (off-main IO).
    func refreshSessions() async {
        let file = sessionFile
        let list = await Task.detached { SessionIndex.list(currentSessionFile: file) }.value
        sessions = list
    }

    func refreshModels() async {
        let resp = await client.send("get_available_models")
        guard resp.success, let arr = resp.data?["models"]?.arrayValue else { return }
        availableModels = arr.compactMap { PiModel($0) }
    }

    /// Commands the app provides itself — pi's `get_commands` only reports
    /// extensions/prompts/skills, so built-ins like `/compact` are injected
    /// client-side and intercepted by the composer instead of being sent as a
    /// prompt.
    static let builtinCommands: [PiCommand] = [
        PiCommand(name: "compact",
                  description: String(localized: "Compact the conversation to free context — optional focus instructions after the command"),
                  source: "builtin"),
    ]

    /// Fetch invocable slash commands (extensions, prompt templates, skills) for
    /// the composer palette. Project/global scope, so once per launch is enough.
    func refreshCommands() async {
        let resp = await client.send("get_commands")
        guard resp.success, let arr = resp.data?["commands"]?.arrayValue else { return }
        commands = arr.compactMap { PiCommand($0) }
            .sorted {
                if $0.sourceRank != $1.sourceRank { return $0.sourceRank < $1.sourceRank }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            + Self.builtinCommands
    }

    func refreshStats() async {
        let resp = await client.send("get_session_stats")
        guard resp.success else { return }
        stats = SessionStats(resp.data)
    }

    /// Candidates for the composer's `@`-mention picker. `token` is the text
    /// after `@` (no leading `@`); see `FileIndex.candidates(for:)`.
    func mentionCandidates(for token: String) async -> [FileEntry] {
        // Non-blocking: kicks off a background rebuild if the index has gone stale
        // (see FileIndex.refreshIfStale) so this keystroke returns instantly and a
        // following one picks up any on-disk changes.
        await fileIndex.refreshIfStale()
        return await fileIndex.candidates(for: token)
    }

    // MARK: - Extension UI replies

    func resolveUI(value: String) {
        guard let req = pendingUIRequest else { return }
        Task { await client.sendRaw(["type": .string("extension_ui_response"),
                                     "id": .string(req.id), "value": .string(value)]) }
        clearPendingUI()
    }

    func resolveUI(confirmed: Bool) {
        guard let req = pendingUIRequest else { return }
        Task { await client.sendRaw(["type": .string("extension_ui_response"),
                                     "id": .string(req.id), "confirmed": .bool(confirmed)]) }
        clearPendingUI()
    }

    func cancelUI() {
        guard let req = pendingUIRequest else { return }
        Task { await client.sendRaw(["type": .string("extension_ui_response"),
                                     "id": .string(req.id), "cancelled": .bool(true)]) }
        clearPendingUI()
    }

    /// Drop the pending dialog and step the status off `needsPermission` — back to
    /// working while the turn continues, so the blue light doesn't linger.
    private func clearPendingUI() {
        if let req = pendingUIRequest {
            // The dialog was answered — withdraw its notification so a stale
            // Approve button can't act on a request pi already resolved.
            NotificationService.shared.clearApprovalNotification(requestID: req.id)
        }
        pendingUIRequest = nil
        if runStatus == .needsPermission {
            runStatus = isStreaming ? .working : .succeeded
        }
    }

    // MARK: - Event handling

    /// Single entry point for everything pi sends us. Internal (not private) so
    /// regression tests can replay captured RPC traffic through the real folding
    /// logic without a live process.
    func handle(_ item: RPCInbound) {
        // Any inbound line is proof of life — feed the stall watchdog.
        // Guard the reset: @Observable fires on every assignment (no equality
        // short-circuit), and an unconditional write here would invalidate the
        // transcript view at event rate — hundreds of times per second during a
        // streaming tool run — bypassing the 80ms coalescing entirely.
        lastInboundAt = Date()
        if modelStalled { modelStalled = false }
        switch item {
        case .event(let event):
            handle(event)
        case .uiRequest(let req):
            handle(req)
        case .unknown(let type, _):
            if type == "__process_exit__" {
                flushStreamingUpdates()
                isConnected = false
                isStreaming = false
                runStatus = .failed
                noteBackgroundActivity()
                finalizeStreamingAssistant()
                addNotice(.warning, String(localized: "The pi agent exited."))
            }
        case .response:
            break   // routed to awaiting callers inside PiClient
        }
    }

    private func handle(_ event: RPCEvent) {
        switch event {
        case .agentStart:
            isStreaming = true
            turnHadError = false
            turnStart = Date()
            runStatus = .working
            noteBackgroundActivity()
            startStallWatchdog()
            captureTurnBase()
            // pi only writes the session .jsonl once the first prompt lands —
            // rescan so a brand-new session shows up in the sidebar with its
            // real (first-message) title.
            Task { await refreshSessions() }
        case .agentEnd:
            flushStreamingUpdates()   // land any buffered tail before finalizing
            isStreaming = false
            retryPending = false
            stopStallWatchdog()
            runStatus = turnHadError ? .failed : .succeeded
            recordTurnDuration()
            noteBackgroundActivity()
            finalizeStreamingAssistant()
            captureTurnDiff()
            Task { await refreshStats() }
            Task { await refreshSessions() }   // keep sidebar recency ordering fresh
            // The turn likely touched the working tree — invalidate the mention
            // index so the next `@` picks up files the agent created or removed.
            Task { await fileIndex.markStale() }
            NotificationService.shared.notifyAgentFinished(
                project: workingDirectory?.lastPathComponent,
                summary: lastAssistantSummary(),
                agentID: agentID
            )
        case .turnStart, .turnEnd:
            break

        case .messageStart(let msg):
            guard msg.role == "assistant" else { break }
            let id = UUID().uuidString
            currentAssistantId = id
            transcript.append(.assistant(AssistantEntry(id: id, segments: msg.textSegments,
                                                        isStreaming: true, timestamp: Date())))
        case .messageUpdate(let msg):
            guard msg.role == "assistant", let id = currentAssistantId else { break }
            pendingAssistantSegments[id] = msg.textSegments
            scheduleStreamFlush()
        case .messageEnd(let msg):
            guard msg.role == "assistant", let id = currentAssistantId else { break }
            pendingAssistantSegments[id] = nil   // the end event carries the final text
            // A failed turn (e.g. an API 4xx) ends with `stopReason: "error"` and
            // empty content. The `prompt` command still reported success, so this
            // is the only place the failure surfaces — show it instead of leaving
            // an empty bubble behind.
            if msg.isError {
                turnHadError = true
                finishAssistant(id, replacingEmptyWith: msg.errorMessage)
                break
            }
            updateAssistant(id) { $0.segments = msg.textSegments; $0.isStreaming = false }
            currentAssistantId = nil

        case .toolStart(let callId, let name, let args):
            // Guarded for the same reason as `modelStalled` above: re-assigning
            // the same value would still ping the sidebar's observers per call.
            if runStatus != .working { runStatus = .working }
            transcript.append(.tool(ToolEntry(
                id: callId.isEmpty ? UUID().uuidString : callId,
                name: name,
                argsSummary: Self.summarizeArgs(args),
                output: "",
                status: .running,
                diff: ToolDiff.from(toolName: name, args: args)
            )))
        case .toolUpdate(let callId, _, let partial):
            if let partial {
                pendingToolOutputs[callId] = partial
                scheduleStreamFlush()
            }
        case .toolEnd(let callId, _, let output, let isError):
            let buffered = pendingToolOutputs.removeValue(forKey: callId)
            updateTool(callId) {
                if !output.isEmpty { $0.output = output }
                else if let buffered, !buffered.isEmpty { $0.output = buffered }
                $0.status = isError ? .error : .done
            }

        case .queueUpdate(let steering, let followUp):
            steeringQueue = steering
            followUpQueue = followUp

        case .compactionStart:
            addNotice(.info, String(localized: "Compacting context to free up space…"))
        case .compactionEnd(let summary, let aborted, let error):
            if let error { addNotice(.error, String(localized: "Compaction failed: \(error)")) }
            else if aborted { addNotice(.warning, String(localized: "Compaction aborted.")) }
            else if summary != nil { addNotice(.info, String(localized: "Context compacted.")) }
            Task { await refreshStats() }

        case .autoRetryStart(let attempt, let maxAttempts, let delayMs, _):
            retryPending = true
            addNotice(.warning, String(localized: "Transient error — retrying (\(attempt)/\(maxAttempts)) in \(delayMs / 1000)s…"))
        case .autoRetryEnd(let success, _, let finalError):
            retryPending = false
            if !success { addNotice(.error, finalError ?? String(localized: "Retry failed.")) }

        case .extensionError(_, let message):
            addNotice(.error, String(localized: "Extension error: \(message)"))
        }
    }

    private func handle(_ req: ExtUIRequest) {
        if req.isDialog {
            pendingUIRequest = req
            runStatus = .needsPermission
            noteBackgroundActivity()
            NotificationService.shared.notifyApprovalNeeded(req, agentID: agentID)
        } else if req.method == "notify" {
            let kind: NoticeEntry.Kind = req.notifyType == "error" ? .error
                : req.notifyType == "warning" ? .warning : .info
            addNotice(kind, req.message ?? "")
        } else if req.method == "setStatus", let key = req.statusKey {
            // A nil/blank text clears the entry for that key.
            let text = req.statusText.map(Self.stripANSI)
            extensionStatuses[key] = (text?.isEmpty == false) ? text : nil
        } else if req.method == "setWidget", let key = req.widgetKey {
            // Absent/empty lines clear the widget for that key.
            if let lines = req.widgetLines, !lines.isEmpty {
                extensionWidgets[key] = lines.map(Self.stripANSI)
            } else {
                extensionWidgets[key] = nil
            }
        }
        // Remaining fire-and-forget methods (setTitle/set_editor_text) are ignored.
    }

    /// Strip ANSI SGR color codes — extension status/widget strings are themed
    /// with `theme.fg(...)`, which emits `\u{1B}[…m` sequences over RPC.
    private static let ansiSGR = try! Regex("\u{001B}\\[[0-9;]*m")
    private static func stripANSI(_ s: String) -> String {
        s.replacing(ansiSGR, with: "")
    }

    // MARK: - Transcript mutation helpers

    private func updateAssistant(_ id: String, _ mutate: (inout AssistantEntry) -> Void) {
        // Search from the back: the entry being updated is the streaming tail
        // in practice, and this runs on every flush of a long conversation.
        guard let idx = transcript.lastIndex(where: { $0.id == id }),
              case .assistant(var entry) = transcript[idx] else { return }
        mutate(&entry)
        transcript[idx] = .assistant(entry)
    }

    private func updateTool(_ id: String, _ mutate: (inout ToolEntry) -> Void) {
        guard let idx = transcript.lastIndex(where: { $0.id == id }),
              case .tool(var entry) = transcript[idx] else { return }
        mutate(&entry)
        transcript[idx] = .tool(entry)
    }

    /// The id of the current turn's final assistant message — the anchor both
    /// `turnDurations` and `turnDiffs` key on. Stops at the turn's opening user
    /// prompt (a turn with no assistant reply has no anchor).
    private var finalAssistantID: String? {
        for item in transcript.reversed() {
            switch item {
            case .assistant(let e): return e.id
            case .user: return nil
            default: break
            }
        }
        return nil
    }

    /// Stamp the just-finished turn's elapsed time onto its final assistant
    /// message, so the transcript can label the collapsed middle.
    private func recordTurnDuration() {
        guard let start = turnStart else { return }
        turnStart = nil
        guard let id = finalAssistantID else { return }
        turnDurations[id] = Date().timeIntervalSince(start)
    }

    // MARK: - Turn diff capture / revert

    /// Test hook: adopt a working directory (and probe its repo-ness) without
    /// launching pi, so the turn-diff wiring can run against a temp repo.
    func adoptWorkingDirectoryForTesting(_ url: URL) {
        workingDirectory = url
        isGitRepo = GitService.isRepo(in: url)
    }

    private func captureTurnBase() {
        guard isGitRepo, let dir = workingDirectory else { turnBaseTreeTask = nil; return }
        turnBaseTreeTask = Task.detached { GitService.snapshotTree(in: dir) }
    }

    /// Snapshot again at turn end and store the base→end diff, if any.
    private func captureTurnDiff() {
        guard let baseTask = turnBaseTreeTask, let dir = workingDirectory,
              let key = finalAssistantID else { turnBaseTreeTask = nil; return }
        turnBaseTreeTask = nil
        Task { [weak self] in
            guard let base = await baseTask.value else { return }
            let files: [FileDiff]? = await Task.detached {
                guard let end = GitService.snapshotTree(in: dir), end != base,
                      let text = GitService.diffText(from: base, to: end, in: dir) else { return nil }
                return GitDiffParser.parse(text)
            }.value
            guard let self, let files, !files.isEmpty else { return }
            self.turnDiffs[key] = TurnDiff(id: key, baseTree: base, files: files)
        }
    }

    /// Revert one file to its pre-turn content (delete it if the turn created
    /// it), then recompute the stored diff against the now-current tree so the
    /// panel reflects reality.
    func revertTurnFile(_ file: FileDiff, turnID: String) {
        guard let dir = workingDirectory, let diff = turnDiffs[turnID] else { return }
        let base = diff.baseTree
        Task {
            let files: [FileDiff]? = await Task.detached { () -> [FileDiff]? in
                switch file.change {
                case .renamed(let old):
                    _ = GitService.restoreFile(file.path, toTree: base, in: dir)  // drops the new name
                    _ = GitService.restoreFile(old, toTree: base, in: dir)        // restores the old
                default:
                    _ = GitService.restoreFile(file.path, toTree: base, in: dir)
                }
                guard let end = GitService.snapshotTree(in: dir) else { return nil }
                if end == base { return [] }
                guard let text = GitService.diffText(from: base, to: end, in: dir) else { return nil }
                return GitDiffParser.parse(text)
            }.value
            guard let files else { return }   // git failed — keep the stored diff
            if files.isEmpty {
                turnDiffs[turnID] = nil
                reviewingTurnDiff = nil
            } else {
                let updated = TurnDiff(id: turnID, baseTree: base, files: files)
                turnDiffs[turnID] = updated
                if reviewingTurnDiff?.id == turnID { reviewingTurnDiff = updated }
            }
        }
    }

    private func finalizeStreamingAssistant() {
        guard let id = currentAssistantId else { return }
        updateAssistant(id) { $0.isStreaming = false }
        currentAssistantId = nil
    }

    /// Close out an assistant turn that errored. Drops the placeholder bubble if
    /// it never received content, then surfaces the provider error as a notice.
    private func finishAssistant(_ id: String, replacingEmptyWith error: String?) {
        if let idx = transcript.firstIndex(where: { $0.id == id }),
           case .assistant(let entry) = transcript[idx], entry.segments.isEmpty {
            transcript.remove(at: idx)
        } else {
            updateAssistant(id) { $0.isStreaming = false }
        }
        currentAssistantId = nil
        let text = Self.humanizeError(error) ?? String(localized: "The model returned an error.")
        addNotice(.error, text)
    }

    /// Provider errors arrive as `"<status> <json-body>"` (e.g. the Anthropic
    /// `{"error":{"message":"…"}}` envelope). Surface the human message when we
    /// can find it, otherwise fall back to the raw string.
    private static func humanizeError(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let start = raw.firstIndex(of: "{"),
           let body = try? JSONDecoder().decode(JSONValue.self, from: Data(raw[start...].utf8)),
           let message = body["error"]?["message"]?.stringValue ?? body["message"]?.stringValue {
            return message
        }
        return raw
    }

    /// A one-line preview of the latest assistant reply for a background
    /// notification body. Prefers visible text over thinking; `nil` if empty.
    private func lastAssistantSummary() -> String? {
        guard case .assistant(let entry)? = transcript.last(where: {
            if case .assistant = $0 { return true } else { return false }
        }) else { return nil }
        let text = entry.segments.compactMap { seg -> String? in
            if case .text(let t) = seg { return t }
            return nil
        }.joined(separator: " ")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 140 ? String(oneLine.prefix(140)) + "…" : oneLine
    }

    private func addNotice(_ kind: NoticeEntry.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        transcript.append(.notice(NoticeEntry(id: UUID().uuidString, kind: kind, text: text)))
    }

    private static func summarizeArgs(_ args: JSONValue?) -> String {
        guard let obj = args?.objectValue, !obj.isEmpty else { return "" }
        // Prefer the most meaningful single field for common tools.
        for key in ["command", "path", "file_path", "filePath", "pattern", "query", "url"] {
            if let v = obj[key]?.stringValue { return v }
        }
        return obj.keys.sorted().map { "\($0): \(obj[$0]?.displayString ?? "")" }.joined(separator: ", ")
    }
}
