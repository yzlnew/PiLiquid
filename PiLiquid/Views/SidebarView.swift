import SwiftUI
import AppKit

/// Shared geometry so action rows, project headers, and session rows line their
/// icons and text up on the same two columns.
private enum SB {
    static let sidebarLeading: CGFloat = 16
    static let sidebarTrailing: CGFloat = 14
    static let contentLeading: CGFloat = 0
    static let trailingPad: CGFloat = 8
    static let iconWidth: CGFloat = 20      // fixed icon column → text always aligns
    static let iconGap: CGFloat = 8         // icon → text
    static let vPad: CGFloat = 6
    static let font: CGFloat = 14
}

/// Single source of truth for which session row is hovered. Per-row `@State`
/// can't be trusted here: across List sections Cocoa drops `mouseExited`, so
/// rows get stuck "hovered" and several light up at once. Centralizing it means
/// entering any row overrides the previous — no reliance on the exit event.
@MainActor @Observable final class SidebarHoverState {
    var hoveredPath: String?
}

/// A leading icon pinned to the shared column so every row's text starts at the
/// same x. `hidden` reserves the column without drawing (session rows).
private func sidebarIcon(_ name: String, color: Color = .secondary,
                         size: CGFloat = 15, hidden: Bool = false) -> some View {
    Image(systemName: name)
        .font(.system(size: size, weight: .regular))
        .foregroundStyle(color)
        .frame(width: SB.iconWidth, alignment: .leading)
        .opacity(hidden ? 0 : 1)
}

/// Per-session status light for the tree's icon column: a spinner while working,
/// a green/red dot for success/failure, a blinking blue dot when a background
/// session is waiting on a permission dialog, and nothing otherwise. Color is
/// used only because it carries meaning here (the run state).
private struct SessionStatusLight: View {
    let light: ChatModel.SessionLight?
    @State private var blinkOn = true

    var body: some View {
        switch light {
        case .working:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
        case .succeeded:
            dot(.green)
        case .failed:
            dot(.red)
        case .permission:
            dot(.blue)
                .opacity(blinkOn ? 1 : 0.2)
                .onAppear {
                    blinkOn = true
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        blinkOn = false
                    }
                }
        case nil:
            Color.clear.frame(width: 7, height: 7)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

/// Compact search field used at the top of the window-level session palette.
private struct SidebarSearchBar: View {
    @Binding var text: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
            SearchTextField(
                text: $text,
                placeholder: String(localized: "Search"),
                fontSize: SB.font,
                automaticallyFocus: true,
                onCancel: onCancel
            )
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusMedium))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusMedium, style: .continuous)
                .strokeBorder(DS.hairline.opacity(0.42), lineWidth: 0.5)
        }
    }
}

/// A flattened, cross-project session result for the search palette.
private struct SidebarSessionSearchResult: Identifiable {
    let session: SessionInfo
    let projectPath: String
    let name: String

    var id: String { session.path }
    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
}

/// Window-level command palette for recently used sessions. It is owned by
/// RootView rather than SidebarView so its center is the center of the entire
/// app window, independent of the current sidebar width.
struct SessionSearchOverlay: View {
    @Environment(SessionManager.self) private var manager
    @Environment(AppSettings.self) private var settings

    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var allResults: [SidebarSessionSearchResult] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                SidebarSearchBar(text: $searchText, onCancel: onDismiss)
                    .padding(14)

                Divider()

                HStack {
                    Text(searchText.isEmpty ? String(localized: "Recent Sessions") : String(localized: "Sessions"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 11)
                .padding(.bottom, 6)

                if results.isEmpty {
                    VStack(spacing: 8) {
                        if isLoading { ProgressView().controlSize(.small) }
                        Text(searchText.isEmpty ? String(localized: "No sessions yet") : String(localized: "No matches"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(results) { result in
                                SidebarSearchResultRow(result: result) { open(result) }
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.bottom, 7)
                    }
                }
            }
            .frame(width: 620, height: 440)
            .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: DS.radiusLarge, style: .continuous)
                    .strokeBorder(DS.hairline.opacity(0.55), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.24), radius: 32, y: 14)
        }
        .task { await loadSessions() }
        .transaction { $0.animation = nil }
    }

    /// Empty search shows global recents; typing filters both session and
    /// project names while preserving recency order.
    private var results: [SidebarSessionSearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? allResults : allResults.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.projectName.localizedCaseInsensitiveContains(query)
        }
        return Array(filtered.prefix(40))
    }

    private var projectPaths: [String] {
        var paths = settings.recentDirectories
        if let current = manager.active?.homeProjectURL?.path, !paths.contains(current) {
            paths.append(current)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private func displayName(_ session: SessionInfo) -> String {
        if let custom = settings.customName(session.path) { return custom }
        if session.path == manager.active?.sessionFile,
           let liveName = manager.active?.sessionName, !liveName.isEmpty {
            return liveName
        }
        return session.title
    }

    private func loadSessions() async {
        isLoading = true
        let paths = projectPaths
        let liveFile = manager.active?.sessionFile
        let liveDirectory = liveFile.map { ($0 as NSString).deletingLastPathComponent }
        let scanned = await Task.detached {
            Dictionary(uniqueKeysWithValues: paths.map { path in
                let directory = SessionIndex.directory(forProjectPath: path).path
                let current = directory == liveDirectory ? liveFile : nil
                return (path, SessionIndex.list(forProjectPath: path, currentSessionFile: current))
            })
        }.value
        guard !Task.isCancelled else { return }

        let stubs = manager.agents.filter { !$0.isWarm && $0.firstUserPrompt != nil }.map { agent in
            LiveSessionStub(
                sessionFile: agent.sessionFile,
                sessionName: agent.sessionName ?? agent.firstUserPrompt,
                lastActivated: agent.lastActivated,
                isActive: agent === manager.active,
                homeSessionsDirectory: agent.worktree.map {
                    SessionIndex.directory(forProjectPath: $0.repoPath).path
                },
                isWorktree: agent.worktree != nil
            )
        }

        allResults = paths.flatMap { path in
            let directory = SessionIndex.directory(forProjectPath: path).path
            return (scanned[path] ?? [])
                .mergingLive(stubs, inDirectory: directory)
                .filter { !settings.isArchived($0.path) }
                .map {
                    SidebarSessionSearchResult(
                        session: $0,
                        projectPath: path,
                        name: displayName($0)
                    )
                }
        }
        .sorted { $0.session.modified > $1.session.modified }
        isLoading = false
    }

    private func open(_ result: SidebarSessionSearchResult) {
        manager.resume(result.session, in: URL(fileURLWithPath: result.projectPath))
        onDismiss()
    }
}

private struct SidebarSearchResultRow: View {
    let result: SidebarSessionSearchResult
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(result.projectName)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                Text(result.session.relativeAge)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMedium)
                    .fill(hovering ? DS.chipFill : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Left rail: top actions, then a Projects list where each project folder
/// expands to its saved sessions (title + relative age). Usage moved to the
/// chat view; this rail is just navigation.
struct SidebarView: View {
    @Environment(SessionManager.self) private var manager
    @Environment(AppSettings.self) private var settings

    @State private var expanded: Set<String> = []
    /// Lazily-loaded session lists for non-active projects, keyed by path.
    @State private var otherSessions: [String: [SessionInfo]] = [:]
    @State private var hover = SidebarHoverState()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SidebarActionRow(title: String(localized: "New Session"), symbol: "square.and.pencil") {
                    if let dir = manager.active?.homeProjectURL { manager.newSession(in: dir) }
                }
                SidebarActionRow(title: String(localized: "Open Project…"), symbol: "folder.badge.plus") {
                    NotificationCenter.default.post(name: .openProject, object: nil)
                }

                Text("Projects")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                ForEach(projectPaths, id: \.self) { path in
                    projectHeader(path)
                        .task(id: "\(expanded.contains(path))-\(isLiveProject(path))") {
                            await loadSessionsIfNeeded(path)
                        }
                    if expanded.contains(path) {
                        sessionList(path)
                    }
                }
            }
            .padding(.horizontal, SB.sidebarLeading)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(hover)
        .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .font(.system(size: SB.font, weight: .regular))
        .foregroundStyle(Color.primary.opacity(0.84))
        .focusEffectDisabled()   // suppress the accent focus ring on right-clicked cells
        .onAppear {
            if let current = manager.active?.workingDirectory?.path { expanded.insert(current) }
        }
    }

    /// Codex-style fixed title row. Search stays a standalone action until the
    /// user asks for it, so the project list gets the full sidebar width.
    private var sidebarHeader: some View {
        HStack(spacing: SB.iconGap) {
            Image("PiLogo")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 30, height: 22, alignment: .leading)
                .foregroundStyle(.primary)
                .accessibilityLabel("Pi")
            Spacer(minLength: 0)
            Button {
                NotificationCenter.default.post(name: .showSessionSearch, object: nil)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary.opacity(0.82))
            .focusEffectDisabled()
            .keyboardShortcut("f", modifiers: .command)
            .help(String(localized: "Search"))
        }
        .padding(.leading, SB.sidebarLeading)
        .padding(.trailing, SB.sidebarTrailing)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .transaction { $0.animation = nil }
    }

    // MARK: - Projects

    /// Known projects in a stable, predictable order (folder name, A→Z) so that
    /// opening or expanding one never reshuffles the list.
    private var projectPaths: [String] {
        var paths = settings.recentDirectories
        // Home project, not the raw cwd — an isolated session's worktree path
        // must not surface as a phantom project of its own.
        if let current = manager.active?.homeProjectURL?.path, !paths.contains(current) {
            paths.append(current)
        }
        return paths.sorted {
            URL(fileURLWithPath: $0).lastPathComponent
                .localizedCaseInsensitiveCompare(URL(fileURLWithPath: $1).lastPathComponent) == .orderedAscending
        }
    }

    /// Directory of the currently-live session file. The only listing we can
    /// trust straight from the running agent; every other project is read from
    /// its own on-disk directory, so sessions stay attributed to one project.
    private var liveSessionDirectory: String? {
        guard let file = manager.active?.sessionFile, !file.isEmpty else { return nil }
        return (file as NSString).deletingLastPathComponent
    }

    /// Whether `path` owns the live session (compared by actual directory, not by
    /// which project merely happens to be the working directory).
    private func isLiveProject(_ path: String) -> Bool {
        liveSessionDirectory == SessionIndex.directory(forProjectPath: path).path
    }

    private func sessions(for path: String) -> [SessionInfo] {
        let scanned = isLiveProject(path) ? (manager.active?.sessions ?? []) : (otherSessions[path] ?? [])
        // pi doesn't write a session's .jsonl until its first turn completes, so
        // a freshly-created session has no on-disk row yet — synthesize one for
        // every live agent of this project that the scan didn't find. Warm
        // pool agents stay invisible until the user actually enters them, and a
        // brand-new session (nothing sent yet) gets no row at all — it only
        // materializes with its first request, titled by that request.
        let stubs = manager.agents.filter { !$0.isWarm && $0.firstUserPrompt != nil }.map { agent in
            LiveSessionStub(
                sessionFile: agent.sessionFile, sessionName: agent.sessionName ?? agent.firstUserPrompt,
                lastActivated: agent.lastActivated, isActive: agent === manager.active,
                // A worktree session's .jsonl lives under the *worktree's*
                // encoded dir — file its row under the home project instead.
                homeSessionsDirectory: agent.worktree.map {
                    SessionIndex.directory(forProjectPath: $0.repoPath).path
                },
                isWorktree: agent.worktree != nil
            )
        }
        let raw = scanned.mergingLive(stubs, inDirectory: SessionIndex.directory(forProjectPath: path).path)
        let visible = raw.filter { !settings.isArchived($0.path) }
        // Pinned sessions float to the top; recency order is preserved within each group.
        return visible.sorted { a, b in
            let pa = settings.isPinned(a.path), pb = settings.isPinned(b.path)
            if pa != pb { return pa }
            return a.modified > b.modified
        }
    }

    /// Project row. No disclosure chevron — the folder icon itself signals state
    /// (closed `folder` → open `folder.fill`); tapping toggles expansion.
    /// Deliberately does NOT switch/spawn anything: a pi process only starts when
    /// the user opens a session (or the hover "new session" action) — browsing
    /// projects must never litter the fleet with empty agents.
    private func projectHeader(_ path: String) -> some View {
        let isOpen = expanded.contains(path)
        let hovering = hover.hoveredPath == path
        return HStack(spacing: SB.iconGap) {
            sidebarIcon(isOpen ? "folder.fill" : "folder")
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                Button {
                    expanded.insert(path)
                    manager.newSession(in: URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Session")
            }
        }
        .padding(.leading, SB.contentLeading)
        .padding(.trailing, SB.trailingPad)
        .padding(.vertical, SB.vPad)
        .contentShape(Rectangle())
        // Same AppKit interaction layer as session rows: single click toggles
        // expansion, right-click gets an NSMenu without the List's blue flash.
        .overlay(
            RowInteraction(
                renaming: false,
                onOpen: { expansionBinding(path).wrappedValue.toggle() },
                onRename: {},
                onHover: { entered in
                    if entered { hover.hoveredPath = path }
                    else if hover.hoveredPath == path { hover.hoveredPath = nil }
                },
                menu: buildProjectMenu(path)
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buildProjectMenu(_ path: String) -> NSMenu {
        let url = URL(fileURLWithPath: path)
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: String(localized: "New Session")) { [weak manager] in
            manager?.newSession(in: url)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "New Session in Worktree")) { [weak manager] in
            manager?.newIsolatedSession(in: url)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Show in Finder")) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        })
        // Only removable when it won't bounce right back: the active session's
        // home project is re-appended to the tree regardless of recents.
        if manager.active?.homeProjectURL?.path != path {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: String(localized: "Remove from Sidebar")) { [weak settings] in
                settings?.forgetDirectory(path)
            })
        }
        return menu
    }

    @ViewBuilder
    private func sessionList(_ path: String) -> some View {
        let list = sessions(for: path)
        if list.isEmpty {
            Text(String(localized: "No sessions yet"))
                .captionStyle()
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        } else {
            ForEach(list) { session in
                SessionRow(session: session, projectPath: path) { open(session, in: path) }
            }
        }
    }


    // MARK: - Actions


    private func open(_ session: SessionInfo, in projectPath: String) {
        // Same call for same- or cross-project: the manager foregrounds the agent
        // if it's already live in the background, otherwise spawns one for it.
        manager.resume(session, in: URL(fileURLWithPath: projectPath))
    }

    /// Load (or refresh) the on-disk session list for any project that doesn't
    /// own the live session. The live project is served from `model.sessions`.
    private func loadSessionsIfNeeded(_ path: String) async {
        guard expanded.contains(path), !isLiveProject(path) else { return }
        let list = await Task.detached {
            SessionIndex.list(forProjectPath: path, currentSessionFile: nil)
        }.value
        otherSessions[path] = list
    }

    private func expansionBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(path) },
            set: { isOpen in
                if isOpen { expanded.insert(path) } else { expanded.remove(path) }
            }
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        // No divider or `.bar` fill — it inherits the sidebar material so the
        // status strip reads as part of the rail rather than a bolted-on bar.
        HStack(spacing: DS.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .captionStyle()
                .foregroundStyle(.secondary)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, DS.sm)
        .padding(.vertical, DS.xs + 1)
    }

    private var statusColor: Color {
        guard let active = manager.active, active.isConnected else { return .red }
        return active.isStreaming ? .orange : .green
    }

    private var statusText: String {
        guard let active = manager.active, active.isConnected else { return String(localized: "Disconnected") }
        return active.isStreaming ? String(localized: "Working…") : String(localized: "Ready")
    }
}

/// One session in the project tree. Title on the left; on the right either the
/// fork badge + relative time, or — on hover — quick pin/archive icons that
/// cover that trailing info. Right-click exposes the full action set.
private struct SessionRow: View {
    let session: SessionInfo
    let projectPath: String
    let onOpen: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(SessionManager.self) private var manager
    @Environment(SidebarHoverState.self) private var hover
    @State private var renaming = false
    @State private var renameText = ""

    /// Derived from the shared hover state so only one row is ever hovered.
    private var hovering: Bool { hover.hoveredPath == session.path }

    /// A local override wins; otherwise, for the live session, pi's authoritative
    /// `sessionName` (from `get_state`, set via `set_session_name`) — the on-disk
    /// summary can't cheaply read that late-appended entry. Falls back to title.
    private var displayName: String {
        if let custom = settings.customName(session.path) { return custom }
        if isCurrent, let name = manager.active?.sessionName, !name.isEmpty { return name }
        return session.title
    }
    private var isPinned: Bool { settings.isPinned(session.path) }
    /// Reactive (not the baked `session.isCurrent`) so an optimistic switch
    /// highlights the row instantly, before the transcript finishes loading.
    private var isCurrent: Bool { session.path == manager.active?.sessionFile }

    var body: some View {
        HStack(spacing: SB.iconGap) {
            // The status light lives in the reserved icon column, so it aligns
            // under the project's folder glyph and never collides with the
            // trailing hover actions. Empty (but still reserved) when there's
            // nothing to report — titles stay aligned under the project name.
            SessionStatusLight(light: manager.light(forSessionPath: session.path))
                .frame(width: SB.iconWidth, alignment: .leading)
            HStack(spacing: DS.xs) {
                if renaming {
                    RenameField(text: $renameText, onCommit: commitRename) { renaming = false }
                } else {
                    Text(displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: DS.xs)
                if !renaming { trailing }
            }
        }
        .padding(.leading, SB.contentLeading)
        .padding(.trailing, SB.trailingPad)
        .padding(.vertical, SB.vPad)
        .contentShape(Rectangle())
        // All interaction goes through AppKit: single-click opens, double-click
        // renames, right-click shows an NSMenu. Driving the menu from AppKit
        // (instead of SwiftUI's .contextMenu) avoids the List's blue right-click
        // emphasis entirely.
        .overlay(
            RowInteraction(
                renaming: renaming,
                onOpen: onOpen,
                onRename: startRename,
                onHover: { entered in
                    if entered { hover.hoveredPath = session.path }
                    // Clear only if we're still the hovered row — a late, possibly
                    // dropped exit must never wipe a newer row's hover.
                    else if hover.hoveredPath == session.path { hover.hoveredPath = nil }
                },
                menu: buildMenu()
            )
        )
        .selectionDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { rowBackground }
    }

    /// Selected row gets a strong fill; merely hovering gets a lighter gray —
    /// the same hover-vs-press convention as the top action rows.
    @ViewBuilder private var rowBackground: some View {
        let fill: Color? = isCurrent ? DS.chipFillStrong : (hovering ? DS.chipFill : nil)
        if let fill {
            RoundedRectangle(cornerRadius: DS.radiusMedium)
                .fill(fill)
                .padding(.vertical, 1)
        }
    }

    /// Hover → pin/archive quick actions; otherwise fork badge + relative time.
    @ViewBuilder private var trailing: some View {
        if hovering {
            HStack(spacing: 1) {
                quickIcon(isPinned ? "pin.slash" : "pin",
                          help: isPinned ? String(localized: "Unpin") : String(localized: "Pin")) { settings.togglePin(session.path) }
                quickIcon("archivebox", help: String(localized: "Archive")) { settings.setArchived(session.path, true) }
            }
        } else {
            HStack(spacing: 5) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                if session.isFork {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                        .help("Forked session")
                }
                if session.isWorktree {
                    Image(systemName: "square.on.square.dashed")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                        .help("Runs in an isolated worktree")
                }
                Text(session.relativeAge)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func quickIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: isPinned ? String(localized: "Unpin") : String(localized: "Pin to Top")) { settings.togglePin(session.path) })
        menu.addItem(ClosureMenuItem(title: String(localized: "Rename")) { startRename() })
        menu.addItem(ClosureMenuItem(title: String(localized: "Archive")) { settings.setArchived(session.path, true) })
        // Only offer "Close" when this session is actually running as a background
        // agent (there's a process to stop). The session file stays on disk.
        if let agent = manager.agent(forSessionPath: session.path), !agent.isForeground {
            menu.addItem(ClosureMenuItem(title: String(localized: "Close Session")) { manager.closeAgent(agent) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Show in Finder")) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectPath)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "Copy Working Directory")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(projectPath, forType: .string)
        })
        return menu
    }

    private func startRename() {
        renameText = displayName
        renaming = true
    }

    private func commitRename() {
        // The live session renames authoritatively through pi (persists to the
        // session file + `get_state`); others get a local display override, since
        // `set_session_name` only names the currently-active session.
        if isCurrent {
            manager.active?.renameActiveSession(to: renameText)
        } else {
            settings.rename(session.path, to: renameText)
        }
        renaming = false
    }
}

/// Borderless, transparent inline editor (no white NSTextField background or
/// focus ring). Auto-focuses and selects all; Return commits, Esc cancels.
private struct RenameField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: SB.font, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            // The shared field editor draws its own (white) background while
            // editing — clear it so the inline rename blends with the row.
            if let editor = field.currentEditor() as? NSTextView {
                editor.drawsBackground = false
                editor.backgroundColor = .clear
                editor.selectAll(nil)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: RenameField
        private var cancelled = false
        init(_ parent: RenameField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { parent.text = field.stringValue }
        }

        /// Focus lost (clicked another session or elsewhere) — commit, unless the
        /// edit was just cancelled with Esc.
        func controlTextDidEndEditing(_ obj: Notification) {
            if !cancelled { parent.onCommit() }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onCommit(); return true
            case #selector(NSResponder.cancelOperation(_:)): cancelled = true; parent.onCancel(); return true
            default: return false
            }
        }
    }
}

/// Top action row (New Session / Open Project) with hover + press feedback.
private struct SidebarActionRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SB.iconGap) {
                sidebarIcon(symbol)
                Text(title)
                    .font(.system(size: SB.font, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.leading, SB.contentLeading)
            .padding(.trailing, SB.trailingPad)
            .padding(.vertical, SB.vPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMedium)
                    .fill(hovering ? DS.chipFill : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// NSMenuItem that runs a closure when chosen.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Transparent interaction layer over a session row: single-click opens,
/// double-click renames, right-click shows an NSMenu. It lets clicks fall
/// through to the SwiftUI content while renaming (so the field is editable) and
/// over the trailing quick-action buttons while hovering.
private struct RowInteraction: NSViewRepresentable {
    let renaming: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onHover: (Bool) -> Void
    let menu: NSMenu

    func makeNSView(context: Context) -> InteractionView { InteractionView() }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.renaming = renaming
        view.onOpen = onOpen
        view.onRename = onRename
        view.onHover = onHover
        view.rowMenu = menu
    }

    final class InteractionView: NSView {
        var renaming = false
        var onOpen: () -> Void = {}
        var onRename: () -> Void = {}
        var onHover: (Bool) -> Void = { _ in }
        var rowMenu: NSMenu?

        private var isHovering = false
        private var pendingOpen: DispatchWorkItem?
        private let quickZoneWidth: CGFloat = 60

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            if renaming { return nil }                                   // let the text field edit
            if isHovering && local.x >= bounds.maxX - quickZoneWidth { return nil } // quick-action buttons
            return self
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { isHovering = true; onHover(true) }
        override func mouseExited(with event: NSEvent) { isHovering = false; onHover(false) }

        override func mouseDown(with event: NSEvent) {
            // Clicking a row doesn't move first responder off another row's inline
            // rename field (plain NSViews don't take focus), so end any active
            // field editing first — that commits the in-progress rename.
            if window?.firstResponder is NSText {
                window?.makeFirstResponder(nil)
            }
            if event.clickCount >= 2 {
                pendingOpen?.cancel(); pendingOpen = nil
                onRename()
            } else {
                // Defer the open just enough to detect a double-click (which
                // renames instead), but keep it short so selection feels instant.
                let work = DispatchWorkItem { [weak self] in self?.onOpen(); self?.pendingOpen = nil }
                pendingOpen = work
                let delay = min(NSEvent.doubleClickInterval, 0.25)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? { rowMenu }
    }
}
