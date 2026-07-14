import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// How the composer wants the drafted message delivered.
enum ComposerDelivery {
    /// Normal prompt — steers immediately when the agent is already running.
    case send
    /// Queue for after the agent finishes (`follow_up`).
    case followUp
}

/// Floating glass input bar. Return sends; Shift+Return inserts a newline.
struct ComposerView: View {
    @Binding var text: String
    @Binding var attachments: [ImageAttachment]
    let onSend: (ComposerDelivery) -> Void

    @Environment(ChatModel.self) private var model
    @Environment(SessionManager.self) private var manager
    @FocusState private var focused: Bool
    @State private var importing = false
    @State private var dropTargeted = false
    /// Gate for the "execute plan in a new session" confirmation.
    @State private var confirmingExecute = false
    /// While the agent runs, whether the draft queues as a follow-up (delivered
    /// after the run) instead of steering (delivered after the current turn).
    @State private var queueAsFollowUp = false
    /// Shell mode: typing a leading `!` lifts it into a terminal pill (like the
    /// slash-command pill) and the field holds the bash command to run via pi.
    @State private var shellMode = false

    // Slash-command palette state.
    @State private var paletteSelection = 0
    @State private var paletteDismissed = false
    @State private var paletteHeight: CGFloat = 0

    // `@`-mention file-picker state. Results are fetched async from the project
    // file index (see ChatModel.mentionCandidates) so a large repo can't stall
    // typing; the search Task is cancelled and re-issued on each keystroke.
    @State private var mentionEntries: [FileEntry] = []
    @State private var mentionSelection = 0
    @State private var mentionDismissed = false
    @State private var mentionHeight: CGFloat = 0
    private let mentionColumns = 2

    /// Completed `@file` mentions, lifted out of the text into inline pills (like
    /// the command chip) so a reference reads as a token rather than raw path
    /// text. Folded back as `@path` on send.
    @State private var mentions: [FileEntry] = []
    /// Hovering a mention pill slides its full path out from behind the bar.
    @State private var hoveredMention: FileEntry?
    @State private var mentionInfoHeight: CGFloat = 0

    /// A completed slash command, lifted out of the text as a glass pill so the
    /// text field holds only its arguments. Folded back to `/name …` on send.
    @State private var command: PiCommand?
    /// Hovering the command chip slides its description out from behind the bar.
    @State private var showCommandInfo = false
    @State private var commandInfoHeight: CGFloat = 0
    /// Local key monitor so Backspace can peel the pill even when the field is
    /// empty (an empty SwiftUI TextField swallows the key, so `.onKeyPress`
    /// never sees it).
    @State private var deleteMonitor: Any?

    /// Image attachment is only meaningful when the active model is multimodal.
    private var imagesEnabled: Bool { model.modelSupportsImages }

    /// The in-progress `/command` token: a leading slash with no whitespace yet.
    /// `nil` once the user types a space (they're now writing arguments).
    private var slashQuery: String? {
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        if rest.contains(where: \.isWhitespace) { return nil }
        return String(rest)
    }

    /// Commands matching the current `/query`, in grouped (source, name) order.
    private var paletteCommands: [PiCommand] {
        guard let q = slashQuery else { return [] }
        guard !q.isEmpty else { return model.commands }
        let lower = q.lowercased()
        return model.commands.filter { $0.name.lowercased().contains(lower) }
    }

    private var paletteVisible: Bool {
        !shellMode && !paletteDismissed && slashQuery != nil && !paletteCommands.isEmpty
    }

    /// The in-progress `@mention` token: the text after a trailing `@` that sits
    /// at the start of the message or just after whitespace, with no whitespace
    /// between it and the end. Returns the token *without* the `@`. `nil` when no
    /// mention is being typed. Tracking only the trailing token means we never
    /// need the text field's cursor position (which SwiftUI doesn't expose).
    private var mentionQuery: String? {
        guard let atIdx = text.lastIndex(of: "@") else { return nil }
        if atIdx > text.startIndex, !text[text.index(before: atIdx)].isWhitespace {
            return nil   // e.g. an email address — not a mention
        }
        let after = text[text.index(after: atIdx)...]
        if after.contains(where: \.isWhitespace) { return nil }
        return String(after)
    }

    private var mentionVisible: Bool {
        !shellMode && !mentionDismissed && mentionQuery != nil && !mentionEntries.isEmpty
    }

    /// The directory the current token points into (everything before its last
    /// `/`), or "" at the root. Drives the palette's floating breadcrumb chip and
    /// lets its rows drop the now-redundant per-file directory label.
    private var mentionScope: String {
        guard let q = mentionQuery, let slash = q.lastIndex(of: "/") else { return "" }
        return String(q[..<slash])
    }

    /// The token's final path segment (after the last `/`) — what the fuzzy matcher
    /// scored against, and what each palette row highlights in its filename.
    private var mentionLeaf: String {
        guard let q = mentionQuery else { return "" }
        guard let slash = q.lastIndex(of: "/") else { return q }
        return String(q[q.index(after: slash)...])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            queueBanner

            if !attachments.isEmpty {
                attachmentStrip
            }

            // Command pill and file-mention pills sit inline, to the left of the
            // first line of text, so they read as part of the message.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if shellMode {
                    ShellPill { shellMode = false }
                        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                }
                if let command {
                    CommandPill(command: command) { self.command = nil }
                        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                        .onHover { inside in
                            let hasDesc = !(command.description ?? "").isEmpty
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                showCommandInfo = inside && hasDesc
                            }
                        }
                }

                ForEach(mentions) { m in
                    MentionPill(entry: m) {
                        withAnimation(.easeOut(duration: 0.16)) { mentions.removeAll { $0.path == m.path } }
                    } onHover: { inside in
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                            hoveredMention = inside ? m : (hoveredMention?.path == m.path ? nil : hoveredMention)
                        }
                    }
                    .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                }

                TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                // Shell mode reads as a terminal: the command is typed in mono,
                // matching the transcript's console entry it will become.
                .font(shellMode ? .mono(13.5) : .system(size: 14))
                .tracking(-0.2)
                .lineLimit(2...10)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    if paletteVisible { completeSelectedCommand(); return .handled }
                    if mentionVisible { insertSelectedMention(); return .handled }
                    submit()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    if paletteVisible { movePaletteSelection(-1); return .handled }
                    if mentionVisible { moveMentionSelection(by: -mentionColumns); return .handled }
                    return .ignored
                }
                .onKeyPress(.downArrow) {
                    if paletteVisible { movePaletteSelection(1); return .handled }
                    if mentionVisible { moveMentionSelection(by: mentionColumns); return .handled }
                    return .ignored
                }
                // Left/right walk the mention grid within a row. Only hijacked
                // while the picker is open, so ordinary cursor movement is intact.
                .onKeyPress(.leftArrow) {
                    guard mentionVisible else { return .ignored }
                    moveMentionSelection(by: -1); return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard mentionVisible else { return .ignored }
                    moveMentionSelection(by: 1); return .handled
                }
                .onKeyPress(.tab) {
                    if paletteVisible { completeSelectedCommand(); return .handled }
                    if mentionVisible { insertSelectedMention(); return .handled }
                    return .ignored
                }
                .onKeyPress(.escape) {
                    if paletteVisible { paletteDismissed = true; return .handled }
                    if mentionVisible { mentionDismissed = true; return .handled }
                    return .ignored
                }
                .onChange(of: slashQuery) { _, _ in
                    paletteDismissed = false
                    paletteSelection = 0
                }
                // A leading `!` lifts into the shell pill immediately; the rest
                // of the draft (if any) stays in the field as the command.
                .onChange(of: text) { _, new in
                    if !shellMode, command == nil, mentions.isEmpty, new.hasPrefix("!") {
                        withAnimation(.easeOut(duration: 0.16)) { shellMode = true }
                        text = String(new.dropFirst())
                    }
                }
                .onChange(of: mentionQuery) { _, _ in
                    // Cheap state reset only; the actual fetch is driven by
                    // `.task(id:)` below so it survives programmatic text writes.
                    mentionDismissed = false
                    mentionSelection = 0
                }
                // Single source of truth for the picker's results: SwiftUI cancels
                // and restarts this whenever `mentionQuery` changes — including the
                // programmatic writes from `pick()` — so there are no racing tasks.
                .task(id: mentionQuery) {
                    guard let q = mentionQuery else { mentionEntries = []; return }
                    try? await Task.sleep(for: .milliseconds(40))
                    if Task.isCancelled { return }
                    let results = await model.mentionCandidates(for: q)
                    if Task.isCancelled { return }
                    mentionEntries = results
                }
                .padding(.top, 2)
                .frame(minHeight: 48, alignment: .topLeading)
            }
            .padding(.leading, 4)

            // Bottom control row: the "+" actions menu (and, when on, the plan
            // chip) on the left; model + reasoning + send on the right.
            HStack(spacing: DS.xs) {
                plusMenu
                if model.isPlanActive {
                    PlanChip { model.togglePlanMode() }
                        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                }
                Spacer(minLength: DS.xs)
                if model.isStreaming {
                    deliveryMenu
                }
                ModelReasoningMenu()
                if let stats = model.stats, (stats.contextPercent ?? 0) > 0 || stats.totalTokens > 0 {
                    ContextRing(stats: stats)
                }
                sendOrStopButton
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.isPlanActive)
        }
        .padding(.horizontal, DS.sm)
        .padding(.vertical, DS.sm)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DS.radiusLarge))
        // Sits behind the bar and slides up on command hover to show its blurb.
        .background(alignment: .top) { commandInfoCard }
        // Same slide-up behind the bar, showing a hovered mention's full path.
        .background(alignment: .top) { mentionInfoCard }
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusLarge)
                .strokeBorder(dropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(DS.hairline.opacity(0.4)),
                              lineWidth: dropTargeted ? 2 : 1)
        )
        // Slash-command palette floats above the composer without disturbing its
        // layout. Offset up by its measured height so its bottom meets the top edge.
        .overlay(alignment: .top) {
            if paletteVisible {
                CommandPalette(
                    commands: paletteCommands,
                    selection: $paletteSelection,
                    onPick: complete
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paletteHeight = $0 }
                .offset(y: -(paletteHeight + DS.xs))
                .opacity(paletteHeight > 0 ? 1 : 0)
            }
        }
        // `@`-mention picker, floated above the composer the same way.
        .overlay(alignment: .top) {
            if mentionVisible {
                MentionPalette(
                    entries: mentionEntries,
                    columns: mentionColumns,
                    scope: mentionScope,
                    query: mentionLeaf,
                    selection: $mentionSelection,
                    onPick: pick,
                    onScopeUp: mentionScopeUp
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mentionHeight = $0 }
                .offset(y: -(mentionHeight + DS.xs))
                .opacity(mentionHeight > 0 ? 1 : 0)
            }
        }
        .frame(maxWidth: 760)
        .onAppear {
            focused = true
            if deleteMonitor == nil {
                deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // keyCode 51 = Delete (Backspace). Only intercept it when we
                    // own focus and the field is empty but a pill is present. Peel
                    // the nearest pill: the last mention first, then the command.
                    guard event.keyCode == 51, focused, text.isEmpty else { return event }
                    if shellMode {
                        withAnimation(.easeOut(duration: 0.16)) { shellMode = false }
                        return nil
                    }
                    if !mentions.isEmpty {
                        withAnimation(.easeOut(duration: 0.16)) { _ = mentions.popLast() }
                        return nil
                    }
                    if command != nil {
                        withAnimation(.easeOut(duration: 0.16)) { command = nil }
                        return nil
                    }
                    return event
                }
            }
        }
        .onDisappear {
            if let deleteMonitor { NSEvent.removeMonitor(deleteMonitor) }
            deleteMonitor = nil
        }
        .onDrop(of: imagesEnabled ? [.image, .fileURL] : [], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { addAttachment(fromFile: url) }
            }
        }
        .confirmationDialog("Execute this plan in a new session?",
                            isPresented: $confirmingExecute, titleVisibility: .visible) {
            Button("Execute") { executePlan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A fresh session will carry out the plan with full write access. This planning session stays open.")
        }
    }

    /// Horizontal row of thumbnails for the staged images, each removable.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.xs) {
                ForEach(attachments) { att in
                    Image(nsImage: att.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.radiusSmall)
                                .strokeBorder(DS.hairline.opacity(0.5), lineWidth: 1)
                        )
                        .overlay(alignment: .topTrailing) {
                            Button {
                                attachments.removeAll { $0.id == att.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .padding(2)
                            .help("Remove image")
                        }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .frame(height: 60)
    }

    /// Leftmost "+" actions menu (Codex-style): plan mode toggle, the deliberate
    /// "execute plan" action while planning, plus (for multimodal models) the
    /// image-attachment actions.
    private var plusMenu: some View {
        Menu {
            if model.supportsPlanMode {
                Button {
                    model.togglePlanMode()
                } label: {
                    Label(model.isPlanActive ? "Exit Plan Mode" : "Plan Mode",
                          systemImage: "list.bullet.clipboard")
                }
                // Execute is user-timed (like opencode's manual Plan→Build switch):
                // offered only while planning, and only once there's something to
                // act on. We never try to auto-detect "the plan is ready."
                if model.isPlanActive {
                    Button {
                        confirmingExecute = true
                    } label: {
                        Label("Execute Plan in New Session", systemImage: "play.fill")
                    }
                    .disabled(model.latestPlanText == nil)
                }
            }
            if imagesEnabled {
                if model.supportsPlanMode { Divider() }
                Button {
                    importing = true
                } label: {
                    Label("Choose Image…", systemImage: "photo")
                }
                Button {
                    let pasted = ImageAttachment.fromPasteboard()
                    if !pasted.isEmpty { attachments.append(contentsOf: pasted) }
                } label: {
                    Label("Paste Image", systemImage: "doc.on.clipboard")
                }
                .disabled(!ImageAttachment.pasteboardHasImage())
            }
            Divider()
            Button {
                model.cloneSession()
            } label: {
                Label("Clone Session", systemImage: "doc.on.doc")
            }
            .disabled(model.transcript.isEmpty)
            if model.retryPending {
                Button {
                    model.abortRetry()
                } label: {
                    Label("Cancel Auto-Retry", systemImage: "xmark.circle")
                }
            }
            sessionOptionsMenu
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(DS.chipFill, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.isConnected)
        .help("Actions")
    }

    /// Session-scoped pi toggles: auto-compaction/retry and how queued
    /// steering / follow-up messages are delivered.
    private var sessionOptionsMenu: some View {
        Menu {
            Toggle("Auto-Compaction", isOn: Binding(
                get: { model.autoCompaction }, set: { model.setAutoCompaction($0) }))
            Toggle("Auto-Retry", isOn: Binding(
                get: { model.autoRetry }, set: { model.setAutoRetry($0) }))
            Divider()
            Picker("Steering Delivery", selection: Binding(
                get: { model.steeringMode }, set: { model.setSteeringMode($0) })) {
                Text("One at a Time").tag("one-at-a-time")
                Text("All at Once").tag("all")
            }
            Picker("Follow-Up Delivery", selection: Binding(
                get: { model.followUpMode }, set: { model.setFollowUpMode($0) })) {
                Text("One at a Time").tag("one-at-a-time")
                Text("All at Once").tag("all")
            }
        } label: {
            Label("Session Options", systemImage: "slider.horizontal.3")
        }
    }

    /// One button wearing four hats (send / run shell / stop agent / stop
    /// bash), so its glyph can morph via the SF Symbols replace effect instead
    /// of the view snapping between separate buttons.
    private var sendOrStopButton: some View {
        let stopping = model.bashRunning || model.isStreaming
        // Shell mode flips the glyph to a terminal: this draft runs as a
        // command, not a prompt.
        let symbol = stopping ? "stop.fill" : (shellMode ? "terminal" : "arrow.up")
        let symbolSize: CGFloat = stopping ? 12 : (shellMode ? 13 : 15)
        let active = stopping || canSend
        let fill: AnyShapeStyle = stopping ? AnyShapeStyle(Color.red)
            : canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(DS.chipFillStrong)
        let help = model.bashRunning ? String(localized: "Stop shell command")
            : model.isStreaming ? String(localized: "Stop (⌘.)")
            : shellMode ? String(localized: "Run shell command (↩)")
            : String(localized: "Send (↩)")

        return Button {
            if model.bashRunning { model.abortBash() }
            else if model.isStreaming { model.abort() }
            else { submit() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .bold))
                .foregroundStyle(active ? .white : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .help(help)
        .animation(.easeOut(duration: 0.18), value: symbol)
        .animation(.easeOut(duration: 0.15), value: canSend)
        .animation(.easeOut(duration: 0.18), value: stopping)
    }

    private var canSend: Bool {
        guard model.isConnected else { return false }
        if shellMode { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if command != nil { return true }   // a bare `/command` (no args) is valid
        if !mentions.isEmpty { return true }  // bare `@file` reference(s) are valid
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var placeholder: String {
        if !model.isConnected { return String(localized: "Connecting…") }
        if shellMode { return String(localized: "Run a shell command…") }
        if let command { return Self.argumentHint(for: command) }
        if model.isStreaming {
            return queueAsFollowUp ? String(localized: "Queue a follow-up…")
                                   : String(localized: "Steer the agent…")
        }
        return String(localized: "Message pi…")
    }

    /// What goes after the lifted command pill — a hint that means something
    /// for the commands we know, the command's own description otherwise.
    static func argumentHint(for command: PiCommand) -> String {
        switch command.name {
        case "compact": return String(localized: "Optional focus for the summary…")
        case "plan": return String(localized: "Optionally start planning with a prompt…")
        default:
            if let desc = command.description, !desc.isEmpty { return desc }
            return String(localized: "Add arguments…")
        }
    }

    /// Steer vs. follow-up choice for messages typed while the agent runs —
    /// steering lands after the current turn, a follow-up waits for the whole
    /// run to finish. Same quiet capsule as the model menu.
    private var deliveryMenu: some View {
        Menu {
            Button {
                queueAsFollowUp = false
            } label: {
                if queueAsFollowUp { Text("Steer") } else { Label("Steer", systemImage: "checkmark") }
            }
            Button {
                queueAsFollowUp = true
            } label: {
                if queueAsFollowUp { Label("Follow-up", systemImage: "checkmark") } else { Text("Follow-up") }
            }
        } label: {
            HStack(spacing: 5) {
                Text(queueAsFollowUp ? String(localized: "Follow-up") : String(localized: "Steer"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .padding(.horizontal, DS.sm)
            .padding(.vertical, 6)
            .background(DS.chipFill, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Steering lands after the current turn; a follow-up waits until the run finishes")
    }

    /// The hovered command's description on a tinted glass card that slides up
    /// from behind the composer's top edge. Rendered as a `.background` so it
    /// truly sits behind the bar; offset up so most of it peeks above, with a
    /// sliver tucked behind. Quick spring in `showCommandInfo`.
    @ViewBuilder
    private var commandInfoCard: some View {
        if showCommandInfo, let command, let desc = command.description, !desc.isEmpty {
            let tint = CommandKind.tint(for: command.source)
            Text(desc)
                .font(.system(size: 13))
                .lineSpacing(2)
                // Not pure black — the ink leans into the command's color while
                // staying readable (adapts in dark mode via `.primary`).
                .foregroundStyle(tint.mix(with: .primary, by: 0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.md)
                .padding(.top, DS.sm)
                .padding(.bottom, DS.sm + 20)   // keep text clear of the tucked-behind sliver
                // Mostly clear glass with just a whisper of the command's color —
                // the material supplies the uneven translucency, no hard border.
                .glassEffect(.regular.tint(tint.opacity(0.06)), in: .rect(cornerRadius: DS.radiusLarge))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { commandInfoHeight = $0 }
                .offset(y: -(commandInfoHeight - 18))
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The hovered mention's full path, sliding up from behind the bar — same
    /// treatment as `commandInfoCard`, tinted to match the mention pill.
    @ViewBuilder
    private var mentionInfoCard: some View {
        if let hoveredMention {
            let tint = Color.indigo
            Text(hoveredMention.path)
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(tint.mix(with: .primary, by: 0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.md)
                .padding(.top, DS.sm)
                .padding(.bottom, DS.sm + 20)
                .glassEffect(.regular.tint(tint.opacity(0.06)), in: .rect(cornerRadius: DS.radiusLarge))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mentionInfoHeight = $0 }
                .offset(y: -(mentionInfoHeight - 18))
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func submit() {
        // Gate the Return key too (the button uses `canSend`). Until the agent
        // connects, sendPrompt would silently drop the text *and* the draft would
        // be cleared by the caller — so refuse to submit and keep what's typed.
        guard model.isConnected else { return }
        // Shell mode: run the command directly, no prompt involved. The pill
        // stays on so consecutive commands don't need retyping the `!`.
        if shellMode {
            let cmd = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return }
            model.runBash(cmd)
            text = ""
            return
        }
        var args = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Builtin palette commands are the app's own — intercept instead of
        // prompting pi (which wouldn't recognize them).
        if let cmd = command, cmd.source == "builtin" {
            if cmd.name == "compact" {
                model.compact(customInstructions: args.isEmpty ? nil : args)
            }
            text = ""
            command = nil
            mentions.removeAll()
            return
        }
        // Fold the file-mention pills back in as `@path` tokens (path-only; pi's
        // Read tool fetches them) so the sent prompt carries the references.
        if !mentions.isEmpty {
            let refs = mentions.map { "@\($0.path)" }.joined(separator: " ")
            args = args.isEmpty ? refs : "\(args) \(refs)"
        }
        // Fold the pill's command back in front of its arguments so the sent
        // prompt is the full `/name …` the agent expects.
        let composed = command.map { args.isEmpty ? "/\($0.name)" : "/\($0.name) \(args)" } ?? args
        guard !composed.isEmpty || !attachments.isEmpty else { return }
        text = composed          // ChatScreen.send() reads this binding synchronously
        command = nil
        mentions.removeAll()
        onSend(model.isStreaming && queueAsFollowUp ? .followUp : .send)
    }

    /// Hand the plan produced in this session to a fresh session to carry out.
    private func executePlan() {
        guard let plan = model.latestPlanText, let dir = model.workingDirectory else { return }
        let lead = String(localized: "Execute the following implementation plan step by step:")
        manager.executePlan("\(lead)\n\n\(plan)", in: dir)
    }

    // MARK: - Slash-command palette

    private func movePaletteSelection(_ delta: Int) {
        let n = paletteCommands.count
        guard n > 0 else { return }
        paletteSelection = ((paletteSelection + delta) % n + n) % n
    }

    private func completeSelectedCommand() {
        guard paletteCommands.indices.contains(paletteSelection) else { return }
        complete(paletteCommands[paletteSelection])
    }

    /// Lift the chosen command into the glass pill and clear the field for its
    /// arguments. Emptying the text also disqualifies `slashQuery`, closing the
    /// palette.
    private func complete(_ cmd: PiCommand) {
        withAnimation(.easeOut(duration: 0.16)) { command = cmd }
        text = ""
        paletteDismissed = true
        focused = true   // clicking a row can steal focus; return it for arguments
    }

    // MARK: - `@`-mention picker

    private func moveMentionSelection(by delta: Int) {
        let n = mentionEntries.count
        guard n > 0 else { return }
        mentionSelection = ((mentionSelection + delta) % n + n) % n
    }

    private func insertSelectedMention() {
        guard mentionEntries.indices.contains(mentionSelection) else { return }
        pick(mentionEntries[mentionSelection])
    }

    /// Act on a picked entry. A folder *descends* — the token grows to `@dir/` and
    /// the picker re-browses that folder. A file *completes* the mention as
    /// `@path ` (path-only; pi's Read tool fetches it) and closes the picker.
    private func pick(_ entry: FileEntry) {
        guard let atIdx = text.lastIndex(of: "@") else { return }
        if entry.isDirectory {
            // Descend: grow the token to `@dir/`. The `.task(id: mentionQuery)`
            // re-browses the folder when the text (hence the query) changes.
            let head = String(text[..<text.index(after: atIdx)])   // through the '@'
            text = head + entry.path + "/"
        } else {
            // Complete: lift the file into a pill and strip its `@token` from the
            // text (path-only; folded back as `@path` on send).
            if !mentions.contains(where: { $0.path == entry.path }) {
                withAnimation(.easeOut(duration: 0.16)) { mentions.append(entry) }
            }
            text = String(text[..<atIdx])   // drop from '@' to end
            mentionDismissed = true
            mentionEntries = []
        }
        focused = true   // a click can steal focus; return it for further typing
    }

    /// Pop one directory level off the active token (the palette's breadcrumb).
    private func mentionScopeUp() {
        guard let atIdx = text.lastIndex(of: "@") else { return }
        let head = String(text[..<text.index(after: atIdx)])   // through the '@'
        var token = String(text[text.index(after: atIdx)...])
        if token.hasSuffix("/") { token.removeLast() }
        if let slash = token.lastIndex(of: "/") {
            token = String(token[...slash])                    // keep parent + its slash
        } else {
            token = ""                                         // back to the root listing
        }
        text = head + token
    }

    // MARK: - Attachment intake

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard imagesEnabled else { return false }
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    appendOnMain(data)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    appendOnMain(data)
                }
            }
        }
        return handled
    }

    private func addAttachment(fromFile url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        appendOnMain(data)
    }

    /// Decode and append off the main actor's hot path. Completion handlers fire
    /// on arbitrary queues, so hop back to the main actor to touch the binding.
    private func appendOnMain(_ data: Data) {
        Task { @MainActor in
            guard let att = ImageAttachment(data: data) else { return }
            attachments.append(att)
        }
    }

    @ViewBuilder
    private var queueBanner: some View {
        if !model.steeringQueue.isEmpty || !model.followUpQueue.isEmpty {
            HStack(spacing: DS.xs) {
                Image(systemName: "tray.full")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(queueText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.sm)
            .padding(.top, 4)
        }
    }

    private var queueText: String {
        var parts: [String] = []
        if !model.steeringQueue.isEmpty {
            parts.append(String(localized: "\(model.steeringQueue.count) queued steering"))
        }
        if !model.followUpQueue.isEmpty {
            parts.append(String(localized: "\(model.followUpQueue.count) follow-up"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Circular context-usage gauge. Tints green→orange→red as the window fills;
/// hovering reveals the token count and cost.
private struct ContextRing: View {
    let stats: SessionStats
    @State private var hovering = false
    @State private var cardHeight: CGFloat = 0

    private var percent: Int { stats.contextPercent ?? 0 }
    private var ringColor: Color { percent < 60 ? .green : percent < 85 ? .orange : .red }

    var body: some View {
        ZStack {
            Circle().stroke(DS.chipFillStrong, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(1, max(0.03, Double(percent) / 100)))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        // The ring grows (and shifts hue) smoothly as each turn lands, instead
        // of snapping to the new fill level.
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: percent)
        .frame(width: 15, height: 15)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A plain overlay instead of `.popover` so it appears instantly — NSPopover
        // always animates its grow/scale and SwiftUI can't disable it. Offset up by
        // its measured height to sit above the ring, and right to line its trailing
        // edge up with the composer border: send button (30) + spacing (DS.xs) +
        // composer padding (DS.sm).
        .overlay(alignment: .topTrailing) {
            if hovering {
                statsCard
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .offset(x: 30 + DS.xs + DS.sm, y: -(cardHeight + 14))
                    .opacity(cardHeight > 0 ? 1 : 0)
            }
        }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailRow("gauge.with.dots.needle.bottom.50percent", String(localized: "Context"), "\(percent)%")
            detailRow("number", String(localized: "Tokens"), stats.totalTokens.formatted())
            detailRow("dollarsign.circle", String(localized: "Cost"), String(format: "$%.4f", stats.cost))
        }
        .padding(14)
        .frame(width: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusMedium)
                .strokeBorder(DS.hairline.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .fixedSize()
    }

    private func detailRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: DS.xs) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 15)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: value)
        }
        .font(.system(size: 12))
    }
}

/// Compact in-composer control: provider glyph + model + reasoning level.
/// Tapping opens a popover with a segmented reasoning slider (shade deepens
/// with effort) and the model as a submenu underneath. A popover — not a Menu —
/// because AppKit menus can't host a draggable custom view.
private struct ModelReasoningMenu: View {
    @Environment(ChatModel.self) private var model
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(model.currentModel?.displayLabel ?? String(localized: "Model"))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // Reserve the widest level's width so the chip (and the popover
                // anchored to it) doesn't shift while dragging the slider.
                ZStack(alignment: .leading) {
                    ForEach(model.thinkingLevels, id: \.self) { level in
                        Text(thinkingDisplayName(level)).hidden()
                    }
                    Text(thinkingDisplayName(model.thinkingLevel))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .padding(.horizontal, DS.sm)
            .padding(.vertical, 6)
            .background(DS.chipFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.xs) {
                HStack {
                    Text("Thinking")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(thinkingDisplayName(model.thinkingLevel))
                        .font(.system(size: 12))
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.15), value: model.thinkingLevel)
                }
                ReasoningSlider(
                    levels: model.thinkingLevels,
                    selection: model.thinkingLevel
                ) { model.setThinking($0) }

                Divider().padding(.vertical, DS.xxs)

                Menu {
                    if model.availableModels.isEmpty {
                        Text("No models configured")
                    }
                    ForEach(groupedModels, id: \.provider) { group in
                        Section(providerName(group.provider)) {
                            ForEach(group.models) { m in
                                Button {
                                    model.setModel(m)
                                } label: {
                                    if m.id == model.currentModel?.id {
                                        Label(m.displayLabel, systemImage: "checkmark")
                                    } else {
                                        Text(m.displayLabel)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(model.currentModel?.displayLabel ?? String(localized: "Model"))
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, DS.xs)
                    .padding(.vertical, 5)
                    .background(DS.chipFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
                    .contentShape(RoundedRectangle(cornerRadius: DS.radiusSmall))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .padding(DS.sm)
            .frame(width: 248)
        }
    }

    /// Available models clustered by provider, with the well-known vendors
    /// pinned to a preferred order and the rest sorted alphabetically. Model
    /// order within each provider is preserved as the agent reported it.
    private var groupedModels: [(provider: String, models: [PiModel])] {
        let order = ["anthropic", "openai", "openai-codex", "google", "deepseek"]
        return Dictionary(grouping: model.availableModels, by: \.provider)
            .sorted { a, b in
                let ai = order.firstIndex(of: a.key.lowercased()) ?? Int.max
                let bi = order.firstIndex(of: b.key.lowercased()) ?? Int.max
                if ai != bi { return ai < bi }
                return a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending
            }
            .map { (provider: $0.key, models: $0.value) }
    }

    private func providerName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "openai-codex": return "OpenAI Codex"
        case "google", "google-gemini": return "Google"
        case "deepseek": return "DeepSeek"
        case "": return "Other"
        default: return raw.capitalized
        }
    }
}

/// Localized display name for a pi reasoning-effort level. Dynamic strings
/// don't auto-localize through `Text`, so each known level maps to a literal
/// `String(localized:)` key; unknown levels fall back to capitalized raw.
private func thinkingDisplayName(_ level: String) -> String {
    switch level {
    case "off": return String(localized: "Off")
    case "minimal": return String(localized: "Minimal")
    case "low": return String(localized: "Low")
    case "medium": return String(localized: "Medium")
    case "high": return String(localized: "High")
    case "xhigh": return String(localized: "Xhigh")
    default: return level.capitalized
    }
}

/// Level-meter slider for the reasoning effort: one segment per level, filled
/// left-to-right up to the selection with a shade that deepens as effort rises
/// ("off" stays neutral gray). Tap or drag anywhere on the bar to pick a level.
private struct ReasoningSlider: View {
    let levels: [String]
    let selection: String
    let onChange: (String) -> Void

    private var selectedIndex: Int { levels.firstIndex(of: selection) ?? 0 }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(levels.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fill(for: i))
                        .help(thinkingDisplayName(levels[i]))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let level = levels[index(at: drag.location.x, width: geo.size.width)]
                        if level != selection { onChange(level) }
                    }
            )
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.15), value: selection)
        .accessibilityElement()
        .accessibilityLabel(Text("Thinking"))
        .accessibilityValue(Text(selection.capitalized))
        .accessibilityAdjustableAction { direction in
            let next = selectedIndex + (direction == .increment ? 1 : -1)
            if levels.indices.contains(next) { onChange(levels[next]) }
        }
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, !levels.isEmpty else { return 0 }
        let fraction = min(max(x / width, 0), 1)
        return min(levels.count - 1, Int(fraction * CGFloat(levels.count)))
    }

    private func fill(for i: Int) -> Color {
        guard i <= selectedIndex else { return DS.chipFill }
        if selectedIndex == 0 { return Color.primary.opacity(0.22) }   // "off": no tint
        let t = levels.count > 1 ? Double(i) / Double(levels.count - 1) : 1
        return Color.accentColor.opacity(0.3 + 0.7 * t)
    }
}

/// Floating `/command` completion list above the composer. Grouped by source
/// (extensions · prompts · skills); driven by keyboard from the text field and
/// clickable directly. Selection is owned by the composer so both stay in sync.
private struct CommandPalette: View {
    let commands: [PiCommand]
    @Binding var selection: Int
    let onPick: (PiCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { idx, cmd in
                        if idx == 0 || commands[idx - 1].source != cmd.source {
                            Text(sectionLabel(cmd.source))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.top, idx == 0 ? 2 : 8)
                                .padding(.bottom, 2)
                        }
                        CommandRow(command: cmd, selected: idx == selection)
                            .id(idx)
                            .contentShape(Rectangle())
                            .onHover { if $0 { selection = idx } }
                            .onTapGesture { onPick(cmd) }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 260)
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusLarge)
                .strokeBorder(DS.hairline.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }

    private func sectionLabel(_ source: String) -> String {
        switch source {
        case "extension": return String(localized: "Commands")
        case "prompt": return String(localized: "Prompts")
        case "skill": return String(localized: "Skills")
        case "builtin": return String(localized: "App")
        default: return String(localized: "Other")
        }
    }
}

/// One row in the command palette: source glyph, name, description, scope tag.
private struct CommandRow: View {
    let command: PiCommand
    let selected: Bool

    var body: some View {
        HStack(spacing: DS.xs) {
            Image(systemName: CommandKind.symbol(for: command.source))
                .font(.system(size: 12))
                .foregroundStyle(CommandKind.tint(for: command.source))
                .frame(width: 16)
            Text(command.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let desc = command.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DS.xs)
            if let loc = command.location, loc != "path" {
                Text(loc)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(DS.chipFill, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(selected ? DS.chipFillStrong : .clear)
        )
    }
}

/// Shell mode's inline marker — same anatomy as `CommandPill`, in the console
/// green that also tints the transcript's `$` entries, so "this line is a
/// command" reads consistently end to end.
private struct ShellPill: View {
    let onRemove: () -> Void

    var body: some View {
        let tint = Color.green
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            (Text(Image(systemName: "terminal")) + Text(" ") + Text(verbatim: "shell"))
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Text(Image(systemName: "xmark"))
                    .font(.system(size: 10, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tint.opacity(0.6))
            .help("Exit shell mode")
        }
        .foregroundStyle(tint)
        .fixedSize()
    }
}

/// The active slash command, rendered inline as category glyph + name colored
/// by `CommandKind` (no frame — it reads as part of the message text), with a
/// trailing ✕ to peel it back off.
private struct CommandPill: View {
    let command: PiCommand
    let onRemove: () -> Void

    var body: some View {
        let tint = CommandKind.tint(for: command.source)
        // Icon + name as one Text (inline SF Symbol) so its baseline matches the
        // field text exactly; the removable ✕ rides alongside on the same baseline.
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            (Text(Image(systemName: CommandKind.symbol(for: command.source))) + Text(" ") + Text(command.name))
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Text(Image(systemName: "xmark"))
                    .font(.system(size: 10, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tint.opacity(0.6))
            .help("Remove command")
        }
        .foregroundStyle(tint)
        .fixedSize()
    }
}

/// Floating `@`-mention file picker above the composer. A multi-column grid so a
/// glance shows more of the tree; keyboard-driven (arrows walk the grid, Tab
/// descends folders) and clickable. Neutral palette — files aren't a command
/// "category," so no colored tint, only the selection highlight.
private struct MentionPalette: View {
    let entries: [FileEntry]
    let columns: Int
    /// Directory being browsed ("" at root). When set, a floating breadcrumb chip
    /// shows it and the rows drop their now-redundant per-file directory label.
    let scope: String
    /// The active fuzzy query (the token's last path segment); each row bolds the
    /// characters it matches. Empty while browsing a folder.
    let query: String
    @Binding var selection: Int
    let onPick: (FileEntry) -> Void
    let onScopeUp: () -> Void

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .leading), count: columns)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 2) {
                    // Row identity is the entry id (from ForEach). NO `.id(idx)`:
                    // pinning identity to the row index makes SwiftUI keep old rows'
                    // content when the whole set swaps (e.g. descending into a
                    // folder), leaving the grid showing stale items.
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        MentionCell(entry: entry, selected: idx == selection, showParent: scope.isEmpty, query: query)
                            .contentShape(Rectangle())
                            .onHover { if $0 { selection = idx } }
                            .onTapGesture { onPick(entry) }
                    }
                }
                .padding(6)
                // Leave room for the floating breadcrumb chip so it never covers
                // the first row.
                .padding(.top, scope.isEmpty ? 0 : 16)
            }
            .frame(maxHeight: 240)
            .onChange(of: selection) { _, new in
                guard entries.indices.contains(new) else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(entries[new].id, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusLarge)
                .strokeBorder(DS.hairline.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        // Floating breadcrumb: the folder we're inside, tap to go up a level.
        .overlay(alignment: .topLeading) {
            if !scope.isEmpty {
                scopeChip.offset(x: DS.sm, y: -13)
            }
        }
    }

    private var scopeChip: some View {
        Button(action: onScopeUp) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                Image(systemName: "folder").font(.system(size: 11))
                Text(scope).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.sm)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.hairline.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("Go up a folder")
    }
}

/// One cell in the mention grid: outline file/folder glyph, name, dimmed parent
/// dir (only in global search), and a chevron on folders hinting Tab-to-enter.
private struct MentionCell: View {
    let entry: FileEntry
    let selected: Bool
    let showParent: Bool
    let query: String

    /// The filename with matched query characters at full strength and the rest
    /// dimmed, so the match stands out by recession — no bold, no tint (matches the
    /// palette's restrained, blend-not-float feel). Folders / empty query render
    /// plain. Characters that only matched in the parent dir don't light up here.
    private var displayName: AttributedString {
        var attr = AttributedString(entry.name)
        guard !query.isEmpty, !entry.isDirectory else { return attr }
        let hits = Set(FuzzyScore.matchedOffsets(query: query, in: entry.name))
        guard !hits.isEmpty else { return attr }
        attr.foregroundColor = .secondary
        var idx = attr.startIndex
        var offset = 0
        while idx < attr.endIndex {
            let next = attr.index(afterCharacter: idx)
            if hits.contains(offset) { attr[idx..<next].foregroundColor = .primary }
            idx = next
            offset += 1
        }
        return attr
    }

    var body: some View {
        HStack(spacing: DS.xs) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showParent, !entry.parent.isEmpty {
                    Text(entry.parent)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(selected ? DS.chipFillStrong : .clear)
        )
    }
}

/// A completed `@file` reference, rendered inline exactly like the command pill:
/// colored glyph + name (no frame — it reads as part of the message text), with a
/// trailing ✕ to peel it off. Hovering slides its full path up from behind the bar.
private struct MentionPill: View {
    let entry: FileEntry
    let onRemove: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        let tint = Color.indigo
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            (Text(Image(systemName: "doc")) + Text(" ") + Text(entry.name))
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Text(Image(systemName: "xmark"))
                    .font(.system(size: 10, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tint.opacity(0.6))
            .help("Remove reference")
        }
        .foregroundStyle(tint)
        .fixedSize()
        .onHover(perform: onHover)
    }
}
