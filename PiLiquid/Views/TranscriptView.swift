import SwiftUI
import WebKit

/// Scrollable conversation. Auto-scrolls to the latest item while streaming.
struct TranscriptView: View {
    @Environment(ChatModel.self) private var model

    /// Bottom breathing room so the last line clears the floating composer.
    var bottomInset: CGFloat = 96

    var body: some View {
        ScrollViewReader { proxy in
            // One pass over the transcript per render — this body re-evaluates
            // on every streaming flush (~12/s), so the turn grouping, terminal
            // ids and last-assistant id are all derived together instead of
            // each re-scanning the whole conversation.
            let layout = TranscriptLayout(model.transcript)
            let groups = layout.groups
            let terminals = layout.terminals
            let lastAssistant = layout.lastAssistant
            let liveGroupID = model.isStreaming ? groups.last?.id : nil
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.md) {
                    ForEach(groups) { group in
                        turnView(group, isLive: group.id == liveGroupID,
                                 terminals: terminals, lastAssistant: lastAssistant)
                    }
                    // The agent is running but no assistant bubble is streaming
                    // yet — the model call is still in flight (it can stall for
                    // a long time; pi has no request timeout). Without this the
                    // conversation looks dead until the first token arrives.
                    if model.awaitingModelOutput {
                        HStack(spacing: DS.sm) {
                            TypingIndicator()
                            if model.modelStalled {
                                Text("No response from the model yet — you can keep waiting, or stop and retry.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.leading, DS.xs)
                        .animation(.easeOut(duration: 0.2), value: model.modelStalled)
                    }
                    // Spacer so the floating composer never covers the last line.
                    Color.clear.frame(height: bottomInset).id(Self.bottomAnchor)
                }
                .padding(.horizontal, DS.lg)
                .padding(.top, DS.lg)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                // Hidden behind the loader while webviews lay out, then revealed
                // as a whole so messages don't pop in.
                .opacity(model.isLoadingSession ? 0 : 1)
                .animation(.easeOut(duration: 0.22), value: model.isLoadingSession)
            }
            .scrollContentBackground(.hidden)
            // A single loader spanning the agent restart and the webview-settle
            // hold — so a switch never shows two animations.
            .overlay {
                if model.isLoadingSession { LoadingPlaceholder() }
            }
            .onChange(of: model.transcript.count) {
                if !model.isLoadingSession {
                    // The new row can contain a WKWebView that is loading and
                    // reporting its first height. Moving it frame-by-frame here
                    // can leave WebKit's surface blank until the view is rebuilt.
                    snapToBottom(proxy)
                }
            }
            .onChange(of: lastItemSignature) {
                if !model.isLoadingSession { snapToBottom(proxy) }
            }
            // Loading finished → content revealed; pin to the bottom (heights have
            // settled during the hold).
            .onChange(of: model.isLoadingSession) { _, loading in
                if !loading { settleToBottom(proxy) }
            }
            .onAppear { settleToBottom(proxy) }
        }
    }

    private func settleToBottom(_ proxy: ScrollViewProxy) {
        guard !model.transcript.isEmpty else { return }
        for delay in [0.0, 0.06, 0.18] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                snapToBottom(proxy)
            }
        }
    }

    /// Auto-follow is deliberately a snap. Transcript rows host WKWebViews;
    /// animated scrolling or layout moves them every frame while they render,
    /// which can strand their backing surface blank until navigation rebuilds it.
    private func snapToBottom(_ proxy: ScrollViewProxy) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private static let bottomAnchor = "transcript-bottom"

    /// Changes whenever the streaming tail grows, so we keep scrolling along.
    /// `utf8.count` (O(1) on native strings), not `count` — a tool can stream
    /// megabytes and this runs on every flush.
    private var lastItemSignature: Int {
        guard let last = model.transcript.last else { return 0 }
        switch last {
        case .assistant(let e):
            return e.segments.reduce(0) { acc, seg in
                switch seg { case .text(let t), .thinking(let t): return acc + t.utf8.count }
            }
        case .tool(let e):
            return e.output.utf8.count
        default:
            return 0
        }
    }

    /// Renders one turn: the user prompt (if any), the intermediate tool/agent
    /// steps, and the final reply. A completed turn folds its steps behind a
    /// "已处理 · 12s" disclosure so only the reply shows by default; the live turn
    /// stays fully expanded so its progress is visible.
    @ViewBuilder
    private func turnView(_ group: TurnGroup, isLive: Bool,
                          terminals: Set<String>, lastAssistant: String?) -> some View {
        if let user = group.user {
            TranscriptRow(item: .user(user), terminals: terminals, lastAssistant: lastAssistant)
                .id(user.id)
        }
        if !isLive && !group.intermediate.isEmpty {
            CollapsedTurn(
                items: group.intermediate,
                duration: group.finalAssistantID.flatMap { model.turnDurations[$0] },
                terminals: terminals, lastAssistant: lastAssistant
            )
        } else {
            ForEach(group.intermediate) { item in
                TranscriptRow(item: item, terminals: terminals, lastAssistant: lastAssistant)
                    .id(item.id)
            }
        }
        ForEach(group.tail) { item in
            TranscriptRow(item: item, terminals: terminals, lastAssistant: lastAssistant)
                .id(item.id)
        }
        // What the turn actually changed on disk (git snapshot diff) — shown
        // once the turn has settled, opening the review inspector.
        if !isLive, let key = group.finalAssistantID, let turnDiff = model.turnDiffs[key] {
            TurnDiffChip(diff: turnDiff)
        }
    }

}

/// Everything the transcript body needs, derived in a single pass: the turn
/// groups (split at each user prompt), the set of turn-terminal assistant ids
/// (the reply that carries each turn's actions), and the conversation's final
/// assistant id. Built fresh per body evaluation — one O(n) traversal instead
/// of several, with each group's parts stored rather than re-sliced on access.
private struct TranscriptLayout {
    var groups: [TurnGroup] = []
    var terminals: Set<String> = []
    var lastAssistant: String?

    init(_ transcript: [TranscriptItem]) {
        var user: UserEntry?
        var items: [TranscriptItem] = []
        var finalAssistantIndex: Int?   // within `items`

        func flush() {
            guard user != nil || !items.isEmpty else { return }
            var group = TurnGroup(user: user)
            if let i = finalAssistantIndex {
                if case .assistant(let e) = items[i] {
                    group.finalAssistantID = e.id
                    terminals.insert(e.id)
                }
                group.intermediate = Array(items[..<i])
                group.tail = Array(items[i...])
            } else {
                group.tail = items
            }
            groups.append(group)
            user = nil
            items = []
            finalAssistantIndex = nil
        }

        for item in transcript {
            if case .user(let e) = item {
                flush()
                user = e
            } else {
                if case .assistant(let e) = item {
                    finalAssistantIndex = items.count
                    lastAssistant = e.id
                }
                items.append(item)
            }
        }
        flush()
    }
}

/// One conversational turn: the opening user prompt plus everything the agent
/// emitted in response, split so the final reply can stay visible while the
/// intermediate steps collapse. Parts are precomputed by `TranscriptLayout`.
private struct TurnGroup: Identifiable {
    var user: UserEntry?
    /// Tool calls and agent-loop output emitted before the final reply — the
    /// part that folds away. Empty when the turn had no reply to sit under.
    var intermediate: [TranscriptItem] = []
    /// The final reply and anything after it (trailing notices) — always shown.
    var tail: [TranscriptItem] = []
    /// The turn's final assistant message — the reply we keep visible.
    var finalAssistantID: String?

    var id: String { user?.id ?? intermediate.first?.id ?? tail.first?.id ?? "turn-empty" }
}

/// Renders a single transcript item. Shared by the transcript and the collapsed
/// turn disclosure so both draw rows identically.
private struct TranscriptRow: View {
    let item: TranscriptItem
    let terminals: Set<String>
    let lastAssistant: String?

    var body: some View {
        switch item {
        case .user(let e): UserRow(entry: e)
        case .assistant(let e):
            AssistantRow(
                entry: e,
                showActions: terminals.contains(e.id),
                pinActions: e.id == lastAssistant
            )
        case .tool(let e): ToolRow(entry: e)
        case .notice(let e): NoticeRow(entry: e)
        }
    }
}

/// The folded middle of a finished turn: a quiet "已处理 · 12s" line that expands
/// to reveal the tool calls and agent-loop output it stands in for.
private struct CollapsedTurn: View {
    let items: [TranscriptItem]
    let duration: TimeInterval?
    let terminals: Set<String>
    let lastAssistant: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Button {
                // Snap, don't animate: the intermediate rows include Markdown
                // webviews that flash if repositioned frame-by-frame (see
                // ThinkingBlock).
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? String(localized: "Hide steps") : String(localized: "Show steps"))

            if expanded {
                ForEach(items) { item in
                    TranscriptRow(item: item, terminals: terminals, lastAssistant: lastAssistant)
                        .id(item.id)
                }
            }
        }
    }

    /// "已处理 · 12s" when we timed the turn, else a step count for turns loaded
    /// from history (no live timing).
    private var summary: String {
        if let duration {
            let elapsed = Duration.seconds(duration)
                .formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
            return String(localized: "Worked for \(elapsed)")
        }
        let steps = items.reduce(0) { if case .tool = $1 { return $0 + 1 }; return $0 }
        return String(localized: "Worked · \(steps) steps")
    }
}

private struct LoadingPlaceholder: View {
    var body: some View {
        MathCurveLoader()
            .frame(width: 76, height: 76)
            .frame(maxWidth: .infinity)
    }
}

/// A randomly-chosen math-curve loader (Paidax01/math-curve-loaders), rendered
/// in a transparent web view. A fresh curve is picked each time it appears.
private struct MathCurveLoader: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        if let url = Bundle.main.url(forResource: "loader", withExtension: "html", subdirectory: "Web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct EmptyConversation: View {
    @Environment(ChatModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Ask pi to do something")
                .font(.system(size: 24, weight: .regular))
                .tracking(0.2)
                .foregroundStyle(.secondary)
            Text("It can read, edit, and run code in \(model.workingDirectory?.lastPathComponent ?? "your project").")
                .bodyStyle()
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
