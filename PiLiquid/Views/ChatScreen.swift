import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The detail pane: scrolling transcript topped by a glass toolbar and capped
/// by the floating composer.
struct ChatScreen: View {
    @Environment(ChatModel.self) private var model
    @State private var draft = ""
    @State private var attachments: [ImageAttachment] = []
    @State private var composerHeight: CGFloat = 0
    @State private var newProjectFromTitle = false
    @State private var newProjectFromFooter = false

    private var isNewSession: Bool { model.transcript.isEmpty && !model.isLoadingSession }

    var body: some View {
        // The inspector is a plain trailing pane (NOT `.inspector`): attached to
        // the split view's detail, `.inspector` re-balances ALL columns and
        // visibly squeezes the left sidebar — here only the chat compresses.
        HStack(spacing: 0) {
            Group {
                if isNewSession {
                    newSession
                } else {
                    chat
                }
            }
            // Keep both conditional branches pinned to the detail pane's full
            // bounds. The first prompt swaps `newSession` for `chat`; without a
            // vertical constraint AppKit can retain the outgoing branch's
            // intrinsic height until another navigation change forces layout.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.inspectorShown {
                Divider()
                SessionInspector()
                    .frame(width: 380)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: model.inspectorShown)
        .navigationTitle(model.workingDirectory?.lastPathComponent ?? "Pi Liquid")
        .navigationSubtitle(model.currentModel?.displayLabel ?? "")
        // Share / export in the header bar, once there's a conversation, plus
        // the inspector toggle. (Plan mode is toggled from the composer's "+"
        // menu, not the toolbar.)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.transcript.isEmpty {
                    TimelineButton()
                    ShareButton()
                }
                Button {
                    model.inspectorShown.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the inspector (⌥⌘I)")
            }
        }
        .onChange(of: model.composerPrefill) { _, new in
            if let new { draft = new; model.composerPrefill = nil }
        }
        // Drop staged images if the user switches to a text-only model.
        .onChange(of: model.modelSupportsImages) { _, supports in
            if !supports { attachments.removeAll() }
        }
    }

    /// Active conversation: scrolling transcript with the composer docked low.
    private var chat: some View {
        ZStack(alignment: .bottom) {
            // Reserve exactly the floating composer's height at the bottom so
            // the last lines can always be scrolled clear of it.
            TranscriptView(bottomInset: composerHeight + DS.sm)

            VStack(alignment: .leading, spacing: DS.xs) {
                if model.worktree != nil {
                    WorktreeChip()
                }
                ComposerView(text: $draft, attachments: $attachments, onSend: send)
            }
            .padding(.horizontal, DS.lg)
            .padding(.bottom, DS.md)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// First screen of a session: a centered greeting, the composer wrapped in a
    /// flowing liquid-glass glow, and a project · mode · branch footer.
    private var newSession: some View {
        VStack(spacing: DS.xl) {
            Spacer()
            greeting

            VStack(spacing: DS.sm) {
                if model.worktree != nil {
                    HStack {
                        WorktreeChip()
                        Spacer(minLength: 0)
                    }
                }
                // Just the composer's own Liquid Glass — no halo. The restrained,
                // native look leans on the material rather than a colored glow.
                ComposerView(text: $draft, attachments: $attachments, onSend: send)
                contextFooter
                    .padding(.horizontal, DS.xs)
            }
            .frame(maxWidth: 680)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Greeting with the project name as a quiet drop-down (name + chevron) that
    /// opens the new-project popover — anchored on the name itself, so the arrow
    /// points at it. The localized sentence is split on %@ to keep word order
    /// correct in every language.
    @ViewBuilder private var greeting: some View {
        Group {
            if let project = model.workingDirectory?.lastPathComponent {
                let parts = String(localized: "What's next in %@?")
                    .components(separatedBy: "%@")
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let head = parts.first, !head.isEmpty { greetingText(head) }
                    Button {
                        newProjectFromTitle = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            greetingText(project)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Start a new project")
                    .popover(isPresented: $newProjectFromTitle, arrowEdge: .bottom) {
                        NewProjectForm()
                    }
                    if parts.count > 1, !parts[1].isEmpty { greetingText(parts[1]) }
                }
            } else {
                greetingText(String(localized: "What's next today?"))
            }
        }
        .foregroundStyle(Color.primary.opacity(0.85))
    }

    private func greetingText(_ string: String) -> Text {
        Text(string)
            .font(.system(size: 30, weight: .regular))
            .tracking(-0.4)
    }

    /// Project and git branch of the working directory.
    private var contextFooter: some View {
        HStack(spacing: DS.md) {
            if let project = model.workingDirectory?.lastPathComponent {
                Button {
                    newProjectFromFooter = true
                } label: {
                    footerItem("folder", project)
                }
                .buttonStyle(.plain)
                .help("Start a new project")
                .popover(isPresented: $newProjectFromFooter, arrowEdge: .bottom) {
                    NewProjectForm()
                }
            }
            if let dir = model.workingDirectory {
                BranchButton(dir: dir)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    private func footerItem(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text).lineLimit(1)
        }
    }

    private func send(_ delivery: ComposerDelivery) {
        switch delivery {
        case .followUp: model.sendFollowUp(draft, images: attachments)
        case .send: model.sendPrompt(draft, images: attachments)
        }
        draft = ""
        attachments.removeAll()
    }
}

/// Popover for spinning up a brand-new project: name it, and a folder is created
/// under ~/Documents/Pi with a fresh session opened inside. An existing folder of
/// the same name is simply opened.
private struct NewProjectForm: View {
    @Environment(SessionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?

    private static let baseDirectory = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pi", isDirectory: true)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("New Project")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Project name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(create)
            Text(verbatim: "~/Documents/Pi/\(trimmedName.isEmpty ? "…" : trimmedName)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(String(localized: "Create"), action: create)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(DS.md)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        let folder = trimmedName
        guard !folder.isEmpty else { return }
        guard !folder.contains("/"), folder != "." , folder != ".." else {
            error = String(localized: "That name can't be used as a folder.")
            return
        }
        let dir = Self.baseDirectory.appendingPathComponent(folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            self.error = String(localized: "Couldn't create the folder.")
            return
        }
        dismiss()
        manager.newSession(in: dir)
    }
}

/// Toolbar timeline: the active branch's prompts, newest first. Picking one
/// forks the session from that point — an undo/branch affordance built on pi's
/// `get_fork_messages` + `fork` (there is no true in-place rewind over RPC).
private struct TimelineButton: View {
    @Environment(ChatModel.self) private var model
    @State private var showing = false
    @State private var points: [ChatModel.ForkPoint] = []

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .help("Timeline — jump back to an earlier prompt")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            timeline
                .frame(width: 340)
                .frame(minHeight: 60, maxHeight: 420)
        }
    }

    private var timeline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                Text("Jump back to a prompt — the session forks from there.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                if points.isEmpty {
                    Text("No prompts yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                ForEach(Array(points.enumerated().reversed()), id: \.element.id) { idx, point in
                    TimelineRow(ordinal: idx + 1, text: point.text,
                                isLatest: idx == points.count - 1) {
                        showing = false
                        model.fork(fromEntry: point.id)
                    }
                }
            }
            .padding(6)
        }
        .task { points = await model.forkMessages() }
    }
}

/// One prompt in the timeline popover.
private struct TimelineRow: View {
    let ordinal: Int
    let text: String
    let isLatest: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                Text("\(ordinal)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, alignment: .trailing)
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if hovering {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSmall)
                    .fill(hovering ? DS.chipFillStrong : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isLatest ? String(localized: "Fork from the latest prompt (undo the last turn)")
                       : String(localized: "Fork from this prompt"))
    }
}

/// Header-bar share/export button: a menu offering the conversation as a long
/// image (rendered through the same Markdown + KaTeX pipeline as the transcript)
/// or the raw pi session file, both routed through the macOS share sheet (which
/// also covers "Save to Files").
private struct ShareButton: View {
    @Environment(ChatModel.self) private var model
    @State private var anchor: NSView?
    @State private var rendering = false

    var body: some View {
        Menu {
            Button {
                shareImage()
            } label: {
                Label("Share as Image", systemImage: "photo")
            }
            Button {
                shareSession()
            } label: {
                Label("Share Session File", systemImage: "doc.text")
            }
            .disabled(model.sessionFile == nil)
            Button {
                exportHTML()
            } label: {
                Label("Export as HTML…", systemImage: "safari")
            }
            .disabled(!model.isConnected)
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(rendering)
        .help("Share or export this conversation")
        .background(ViewAnchor { anchor = $0 })
    }

    /// pi renders the session to a standalone HTML file at a user-chosen path.
    private func exportHTML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        let base = model.sessionName ?? model.workingDirectory?.lastPathComponent ?? "session"
        panel.nameFieldStringValue = "\(base).html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let path = await model.exportHTML(to: url) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }

    private func shareImage() {
        guard let anchor else { return }
        rendering = true
        let title = model.workingDirectory?.lastPathComponent ?? String(localized: "Conversation")
        let subtitle = model.currentModel?.displayLabel ?? ""
        let items = model.transcript
        Task {
            let url = await ConversationExporter.imageFile(items: items, title: title, subtitle: subtitle)
            rendering = false
            if let url { ConversationExporter.share([url], from: anchor) }
        }
    }

    private func shareSession() {
        guard let anchor, let path = model.sessionFile else { return }
        ConversationExporter.share([URL(fileURLWithPath: path)], from: anchor)
    }
}

/// The active model's provider brand glyph (template-tinted), falling back to
/// a generic chip symbol when the provider isn't recognized.
struct ProviderIcon: View {
    let model: PiModel?

    var body: some View {
        Group {
            if let asset = model?.logoAssetName {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "cpu")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 14, height: 14)
    }
}
