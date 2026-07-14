import SwiftUI
import AppKit

/// "14:32" for today, "Jun 30, 14:32"-style (locale-aware) otherwise — the
/// quiet stamp trailing every message action bar.
func messageTimeLabel(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.month().day().hour().minute())
}

/// User prompt — a right-aligned neutral glass bubble.
struct UserRow: View {
    let entry: UserEntry
    @Environment(ChatModel.self) private var model
    @State private var showRaw = false
    @State private var hovering = false
    /// In-place edit state: the bubble becomes an editor with confirm/cancel;
    /// confirming rewinds this turn and regenerates right here.
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: DS.xs) {
                if !entry.attachments.isEmpty {
                    attachmentGrid
                }
                if editing {
                    editor
                        .transition(.scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity))
                } else if let inv = invocation {
                    invocationBubble(inv)
                } else if !entry.text.isEmpty {
                    bubbleText
                        .font(.system(size: DS.chatSize))
                        .tracking(DS.bodyTracking)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(.horizontal, DS.md - 2)
                        .padding(.vertical, DS.sm - 2)
                        .background(DS.chipFillStrong, in: .rect(cornerRadius: DS.radiusLarge))
                }

                if !editing {
                    actionBar
                        .opacity(hovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: hovering)
                }
            }
            // AppKit tracking area over the whole message block (bubble + bar,
            // including the spacing gap between them) — plain .onHover drops
            // out while the pointer crosses the gap, hiding the bar right
            // before it can be clicked.
            .background(HoverReporter { hovering = $0 })
        }
    }

    /// The bubble turned editable in place. Deliberately looks like the bubble
    /// it replaces — same fill, same padding, content-hugging width (an
    /// invisible Text twin does the sizing; a bare vertical TextField would
    /// greedily span the row) — with two quiet text actions underneath. The
    /// caret is what says "editing"; no colored border, no heavy buttons.
    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // Full row width and a few lines of breathing room — editing wants
            // space, unlike the display bubble it replaces. Still quiet: same
            // fill, no border, the caret is the editing signal.
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: DS.chatSize))
                .tracking(DS.bodyTracking)
                .lineSpacing(3)
                .lineLimit(3...16)
                .focused($editFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    confirmEdit()
                    return .handled
                }
                .onKeyPress(.escape) { setEditing(false); return .handled }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, DS.md - 2)
                .padding(.vertical, DS.sm)
                .background(DS.chipFillStrong, in: .rect(cornerRadius: DS.radiusLarge))

            HStack(spacing: DS.md) {
                Button(action: { setEditing(false) }) {
                    Text("Cancel")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Button(action: confirmEdit) {
                    Text("Resend")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(canResend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .disabled(!canResend)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
        }
        .onAppear { editFocused = true }
    }

    private var canResend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Expand/collapse the in-place editor with the app's standard spring.
    private func setEditing(_ on: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { editing = on }
    }

    private func confirmEdit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        setEditing(false)
        model.resendEdited(entry.id, newText: text, attachments: entry.attachments)
    }

    /// Copy + edit under the bubble, revealed on hover — mirrors the assistant
    /// bar. Editing turns the bubble into an in-place editor; confirming
    /// rewinds this turn and regenerates in the same pane.
    private var actionBar: some View {
        HStack(spacing: 2) {
            if let ts = entry.timestamp {
                Text(messageTimeLabel(ts))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 4)
            }
            IconButton(symbol: "square.on.square", help: String(localized: "Copy message"), action: copyMessage)
            IconButton(symbol: "pencil", help: String(localized: "Edit and resend from here")) {
                draft = entry.text
                setEditing(true)
            }
            .disabled(model.isStreaming)
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    /// A slash command pi expanded into the turn — e.g.
    /// `<skill name="x" …>…injected instructions…</skill>\n\n<the text I typed>`.
    /// We keep the message as-is *except* the injected block, which collapses to
    /// a chip. Returns the category, the command name, the user's own trailing
    /// text, and the raw injected block (for the disclosure).
    private var invocation: (source: String, name: String, userText: String, body: String)? {
        let t = entry.text
        guard t.hasPrefix("<"),
              let tagEnd = t[t.index(after: t.startIndex)...].firstIndex(where: { $0 == " " || $0 == ">" })
        else { return nil }
        let tag = String(t[t.index(after: t.startIndex)..<tagEnd])
        guard ["skill", "prompt", "command", "extension"].contains(tag),
              let open = t.range(of: "name=\""),
              let close = t[open.upperBound...].firstIndex(of: "\"")
        else { return nil }
        let name = String(t[open.upperBound..<close])
        guard !name.isEmpty else { return nil }

        // Split the injected block off from the user's own text at the close tag.
        let closeTag = "</\(tag)>"
        let body: String, userText: String
        if let end = t.range(of: closeTag) {
            body = String(t[..<end.upperBound])
            userText = String(t[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = t
            userText = ""
        }
        let source = (tag == "command") ? "extension" : tag
        return (source, name, userText, body)
    }

    /// The normal user bubble, but with the injected block shown as a chip and
    /// the user's own text kept intact beside it. The chip toggles a disclosure
    /// of the raw injected instructions below.
    @ViewBuilder
    private func invocationBubble(_ inv: (source: String, name: String, userText: String, body: String)) -> some View {
        VStack(alignment: .trailing, spacing: DS.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showRaw.toggle() }
                } label: {
                    InvocationPill(source: inv.source, name: inv.name, expanded: showRaw)
                }
                .buttonStyle(.plain)
                .help(showRaw ? "Hide injected text" : "Show injected text")

                if !inv.userText.isEmpty {
                    Text(inv.userText)
                        .font(.system(size: DS.chatSize))
                        .tracking(DS.bodyTracking)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, DS.md - 2)
            .padding(.vertical, DS.sm - 2)
            .background(DS.chipFillStrong, in: .rect(cornerRadius: DS.radiusLarge))

            if showRaw {
                Text(inv.body)
                    .font(.system(size: DS.chatSize))
                    .tracking(DS.bodyTracking)
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.horizontal, DS.md - 2)
                    .padding(.vertical, DS.sm - 2)
                    .background(DS.chipFill, in: .rect(cornerRadius: DS.radiusLarge))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// If the prompt opens with a known slash command, tint that leading token
    /// in its `CommandKind` color so it echoes the composer's pill; otherwise
    /// render the text plainly. The token flows inline and wraps with the rest.
    private var bubbleText: Text {
        guard entry.text.hasPrefix("/") else { return Text(entry.text) }
        let name = String(entry.text.dropFirst().prefix { !$0.isWhitespace })
        guard let cmd = model.commands.first(where: { $0.name == name }) else {
            return Text(entry.text)
        }
        let token = "/\(cmd.name)"
        return Text(token)
            .foregroundStyle(CommandKind.tint(for: cmd.source))
            .fontWeight(.semibold)
            + Text(entry.text.dropFirst(token.count))
    }

    /// Up to a few attached images, shown as rounded thumbnails above the text.
    private var attachmentGrid: some View {
        HStack(spacing: DS.xs) {
            ForEach(entry.attachments) { att in
                Image(nsImage: att.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusMedium))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusMedium)
                            .strokeBorder(DS.hairline.opacity(0.5), lineWidth: 1)
                    )
            }
        }
    }
}

/// History echo of the composer chip: the injected slash command rendered
/// inline as category glyph + name colored by `CommandKind` (no frame), with a
/// chevron that flips when the raw injected text is revealed.
private struct InvocationPill: View {
    let source: String
    let name: String
    let expanded: Bool

    var body: some View {
        let tint = CommandKind.tint(for: source)
        // One Text (inline SF Symbols) so it sits on the exact same baseline as
        // the user's own text beside it.
        return (
            Text(Image(systemName: CommandKind.symbol(for: source)))
            + Text(" ") + Text(name)
            + Text("  ")
            + Text(Image(systemName: expanded ? "chevron.down" : "chevron.right"))
                .font(.system(size: 9, weight: .semibold))   // smaller than the label
                .foregroundColor(tint.opacity(0.55))
        )
        .font(.system(size: DS.chatSize, weight: .medium))
        .foregroundColor(tint)
        .lineLimit(1)
        .fixedSize()
    }
}

/// Assistant turn — plain editorial text plus collapsible thinking blocks.
/// This is the reading layer, deliberately without glass.
struct AssistantRow: View {
    let entry: AssistantEntry
    /// This message is a turn's final (summarizing) output, so it carries actions.
    var showActions: Bool = false
    /// The very last assistant message of the conversation — actions stay pinned.
    var pinActions: Bool = false
    @Environment(ChatModel.self) private var model
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            ForEach(Array(entry.segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let t):
                    MarkdownView(markdown: t)
                case .thinking(let t):
                    ThinkingBlock(text: t)
                }
            }
            if entry.isStreaming && !entry.hasContent {
                TypingIndicator()
            }
            if showActions && !entry.isStreaming {
                actionBar
                    .opacity(pinActions || hovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
        }
        // AppKit tracking area (as a non-interfering background) so hover is
        // detected over the whole message — SwiftUI's .onHover is unreliable
        // above a WKWebView.
        .background(HoverReporter { hovering = $0 })
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "square.on.square", help: String(localized: "Copy message"), action: copyMessage)
            IconButton(symbol: "arrow.triangle.branch", help: String(localized: "Fork a new session from here")) {
                model.fork(fromAssistant: entry.id)
            }
            if let ts = entry.timestamp {
                Text(messageTimeLabel(ts))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
        .padding(.top, 2)
    }

    private func copyMessage() {
        let text = entry.segments.compactMap { seg -> String? in
            if case .text(let t) = seg { return t }
            return nil
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Small icon button with a rounded highlight that fills in on hover.
private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(hover ? DS.chipFill : .clear, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
                .contentShape(RoundedRectangle(cornerRadius: DS.radiusSmall))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Reports pointer enter/exit over its bounds via an AppKit tracking area, with
/// click-through `hitTest` so it never steals interaction from the content.
private struct HoverReporter: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { TrackingView(onChange: onChange) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void
        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self
            ))
        }
        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }
}

/// Collapsible "thinking" disclosure, dim and secondary.
private struct ThinkingBlock: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                // No withAnimation: animating this disclosure repositions the
                // sibling message webview frame-by-frame, and WKWebView repaints
                // (flashes) during that animated move. Snap instead.
                expanded.toggle()
            } label: {
                Label("Thinking", systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Tool execution — a quiet, single-line entry that expands to reveal output.
/// Collapsed it reads as plain text (tool-type icon + name + args); the gray
/// block and border are gone so it stays subordinate to the conversation.
struct ToolRow: View {
    let entry: ToolEntry
    @State private var expanded = false
    @State private var hovering = false

    private var hasOutput: Bool { !entry.output.isEmpty }
    private var isRunning: Bool { entry.status == .running }
    private var isError: Bool { if case .error = entry.status { return true }; return false }
    /// An edit/write diff to render in place of the raw result text.
    private var diff: ToolDiff? { entry.diff }
    private var isExpandable: Bool { diff != nil || hasOutput }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard isExpandable else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: DS.xs) {
                    glyph
                        .frame(width: 16, height: 16)
                    if entry.isManual {
                        // Console entry (user-typed `!command`): a `$ command`
                        // line instead of the tool-name + dimmed-args look.
                        Text("$")
                            .font(.mono(13))
                            .foregroundStyle(isError ? Color.red : Color.green)
                        Text(entry.argsSummary)
                            .font(.mono(13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(entry.name)
                            .font(.mono(13))
                            .foregroundStyle(isError ? Color.red : Color.secondary)
                        if !entry.argsSummary.isEmpty {
                            Text(entry.argsSummary)
                                .font(.mono(13))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if let diff { diffStat(diff) }
                    Spacer(minLength: 4)
                    if isExpandable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .opacity(hovering || expanded ? 1 : 0)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Detail lives behind the disclosure; collapsed stays a single line.
            // edit/write show a diff; every other tool shows its raw output.
            if expanded {
                if let diff {
                    DiffView(diff: diff)
                } else if hasOutput {
                    ScrollView {
                        // While the tool is still streaming, lay out only the
                        // tail — re-flowing megabytes of Text per update chokes
                        // the main thread. The full output lands on toolEnd.
                        Text(isRunning ? String(entry.output.suffix(4000)) : entry.output)
                            .font(.mono(12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DS.sm)
                    }
                    .frame(maxHeight: 280)
                    .background(DS.chipFill, in: .rect(cornerRadius: DS.radiusMedium))
                }
            } else if isRunning, !tailLines.isEmpty {
                // Live tail while the tool runs, so long calls stream instead
                // of sitting silently behind a spinner until they finish.
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(tailLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.mono(11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.leading, 16 + DS.xs)
            }
        }
        .padding(.horizontal, entry.isManual ? DS.sm : 0)
        .padding(.vertical, entry.isManual ? 6 : 1)
        // The quiet fill is what reads "console entry" at a glance — model
        // tool rows stay backgroundless.
        .background(entry.isManual ? AnyShapeStyle(DS.chipFill) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: DS.radiusMedium))
        .onHover { hovering = $0 }
    }

    /// The last few non-empty output lines, scanned from a bounded suffix so a
    /// multi-megabyte stream never costs more than a few hundred characters.
    private var tailLines: [String] {
        let tail = entry.output.suffix(600)
        let lines = tail.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return Array(lines.suffix(3))
    }

    /// Compact `+adds −dels` change summary shown inline on the collapsed row.
    @ViewBuilder private func diffStat(_ diff: ToolDiff) -> some View {
        HStack(spacing: 5) {
            if diff.addedCount > 0 {
                Text("+\(diff.addedCount)")
                    .foregroundStyle(.green)
                    .contentTransition(.numericText())
            }
            if diff.removedCount > 0 {
                Text("−\(diff.removedCount)")
                    .foregroundStyle(.red)
                    .contentTransition(.numericText())
            }
        }
        .font(.mono(12))
        .animation(.easeOut(duration: 0.25), value: diff.addedCount + diff.removedCount)
    }

    /// Running → spinner; otherwise an outline icon chosen by tool type (tinted
    /// red on error). The icon — not a status check — is what tells tools apart.
    /// Manual `!` shell entries get a green terminal to match the composer pill.
    /// The finished icon pops in over the spinner — the "done" moment reads.
    @ViewBuilder private var glyph: some View {
        ZStack {
            switch entry.status {
            case .running:
                ProgressView().controlSize(.small).scaleEffect(0.6)
                    .transition(.opacity)
            default:
                Image(systemName: entry.isManual ? "terminal" : toolSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(isError ? Color.red : (entry.isManual ? Color.green : Color.secondary))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: entry.status)
    }

    private var toolSymbol: String {
        let name = entry.name.lowercased()
        switch true {
        case name.contains("bash"), name.contains("shell"), name.contains("exec"),
             name.contains("terminal"), name == "sh", name == "zsh", name.contains("run"):
            return "terminal"
        case name.contains("write"), name.contains("create"):
            return "square.and.pencil"
        case name.contains("edit"), name.contains("replace"), name.contains("patch"):
            return "pencil"
        case name.contains("read"), name.contains("cat"), name.contains("view"), name.contains("open"):
            return "doc.text"
        case name.contains("grep"), name.contains("search"), name.contains("find"), name.contains("glob"):
            return "magnifyingglass"
        case name == "ls", name.contains("list"), name.contains("tree"), name.contains("dir"):
            return "folder"
        case name.contains("web"), name.contains("fetch"), name.contains("http"),
             name.contains("curl"), name.contains("browse"):
            return "globe"
        case name.contains("todo"), name.contains("task"), name.contains("plan"):
            return "checklist"
        default:
            return "wrench.and.screwdriver"
        }
    }
}

/// System notices (compaction, retries, errors, extension notifications).
struct NoticeRow: View {
    let entry: NoticeEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(color)
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.sm)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }

    private var shape: RoundedRectangle { .rect(cornerRadius: DS.radiusSmall) }

    private var icon: String {
        switch entry.kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "exclamationmark.circle"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Three-dot pulse shown before the assistant's first token arrives.
struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(0.3 + 0.7 * pulse(i))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func pulse(_ i: Int) -> Double {
        let shifted = (phase + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
        return shifted
    }
}
