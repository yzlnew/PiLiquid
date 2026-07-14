import SwiftUI
import AppKit

/// Top-level layout. Shows a welcome screen until a project folder is chosen,
/// then a sidebar + chat split with the agent connected.
struct RootView: View {
    @Environment(SessionManager.self) private var manager
    @Environment(AppSettings.self) private var settings

    /// Sidebar visibility, driven by the system `.sidebarToggle`. Its native
    /// slide is smooth here because the transcript is capped at a fixed reading
    /// width, so the message webviews only translate during the slide instead of
    /// reflowing — at normal/wide windows. (Reflow, and a brief shimmer, is only
    /// possible once the detail pane is narrower than that cap.)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Persist the collapsed state across launches ourselves, the way NNW owns
    /// its sidebar-hidden state rather than leaning on AppKit autosave.
    @SceneStorage("pi.sidebarCollapsed") private var sidebarCollapsed = false
    @State private var isSessionSearchPresented = false

    var body: some View {
        Group {
            if manager.active == nil {
                WelcomeView(onOpen: openProject)
            } else {
                workspace
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProject)) { _ in
            openProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectAt)) { note in
            if let url = note.object as? URL {
                open(url, sessionPath: note.userInfo?["session"] as? String)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSessionSearch)) { _ in
            if manager.active != nil { isSessionSearchPresented = true }
        }
        .task {
            guard manager.active == nil else { return }

            // Running as a unit-test host: stay inert. Auto-opening a project
            // would spawn real pi processes underneath the test run.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil {
                return
            }

            // Allow opening a project non-interactively, e.g.
            // `PILIQUID_PROJECT=/path/to/repo open PiLiquid.app`.
            if let path = ProcessInfo.processInfo.environment["PILIQUID_PROJECT"],
               !path.isEmpty {
                open(URL(fileURLWithPath: path))
                return
            }

            // Returning users skip the welcome screen. Prefer dropping them back
            // into the exact session they last had foreground; if that session
            // file is gone (deleted/archived), fall back to reopening the most
            // recent project as a fresh session. First run — or a pi binary we
            // can't find — falls through to the welcome screen instead.
            guard settings.isPiInstalled else { return }
            if let project = settings.lastProjectPath, directoryExists(project),
               let session = settings.lastSessionFile,
               FileManager.default.fileExists(atPath: session) {
                open(URL(fileURLWithPath: project), sessionPath: session)
            } else if let recent = mostRecentExistingProject() {
                open(URL(fileURLWithPath: recent))
            }

            // Once the main launch has had a head start, pre-warm agents for
            // the other recent projects so switching to them is instant.
            try? await Task.sleep(for: .seconds(3))
            manager.prewarmRecentProjects()
        }
        .overlay {
            if isSessionSearchPresented, manager.active != nil {
                SessionSearchOverlay { isSessionSearchPresented = false }
            }
        }
        .overlay {
            if let active = manager.active, let req = active.pendingUIRequest {
                ApprovalOverlay(request: req)
                    .environment(active)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: manager.active?.pendingUIRequest?.id)
    }

    /// Sidebar + chat split, once a project is open.
    private var workspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            // The system `.sidebarToggle` stays: it anchors in the sidebar's
            // title bar (not a floating glass button), animates natively —
            // exactly what we want now — and drives `columnVisibility`, so
            // the persistence below still fires. It carries ⌃⌘S for free.
        } detail: {
            // Feed the *active* agent into the detail subtree, so the chat
            // views keep reading `@Environment(ChatModel.self)` unchanged.
            if let active = manager.active {
                ChatScreen()
                    .environment(active)
            }
        }
        // Browser-style back/forward through the sessions you've viewed.
        // `.navigation` placement seats them at the leading edge, right of
        // the system sidebar toggle and hard against the traffic lights.
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { manager.goBack() } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!manager.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")

                Button { manager.goForward() } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .disabled(!manager.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward")
            }
        }
        // `.balanced` makes revealing the sidebar *compress the detail*
        // to make room, instead of the default behavior that keeps the
        // detail width and widens the whole window (the reported bug).
        .navigationSplitViewStyle(.balanced)
        // Restore the saved collapsed state without animation (like NNW's
        // non-animated state restore), then persist every later change.
        .onAppear { columnVisibility = sidebarCollapsed ? .detailOnly : .all }
        .onChange(of: columnVisibility) { _, v in sidebarCollapsed = (v == .detailOnly) }
    }

    /// Most recently opened project whose folder still exists on disk — skipping
    /// any that were moved or deleted so auto-open never lands on a dead path.
    private func mostRecentExistingProject() -> String? {
        settings.recentDirectories.first { directoryExists($0) }
    }

    private func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open Project")
        panel.message = String(localized: "Choose the project folder the pi agent should work in.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    private func open(_ url: URL, sessionPath: String? = nil) {
        manager.open(url, sessionPath: sessionPath)
    }
}

/// First-run / no-project screen.
private struct WelcomeView: View {
    let onOpen: () -> Void
    @Environment(AppSettings.self) private var settings
    @Environment(SessionManager.self) private var manager
    @State private var appeared = false

    var body: some View {
        VStack(spacing: DS.lg) {
            // Hero mark — neutral, blends into the surface rather than floating.
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 92, height: 92)
                .background(DS.chipFill, in: RoundedRectangle(cornerRadius: DS.radiusLarge))
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: DS.xs) {
                Text("Pi Liquid")
                    .font(.system(size: 32, weight: .semibold))
                    .tracking(-0.4)
                Text("A native macOS client for the pi coding agent")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)

            if settings.isPiInstalled {
                Button(action: onOpen) {
                    Label("Open Project…", systemImage: "folder")
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                }
                .controlSize(.large)
                .buttonStyle(.glass)
                .opacity(appeared ? 1 : 0)
                .padding(.top, DS.xxs)
            } else {
                InstallPiCard()
                    .frame(maxWidth: 380)
                    .padding(DS.md)
                    .background(DS.chipFill, in: RoundedRectangle(cornerRadius: DS.radiusLarge))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusLarge)
                            .strokeBorder(DS.hairline, lineWidth: 1)
                    )
                    .opacity(appeared ? 1 : 0)
                    .padding(.top, DS.xxs)

                SettingsLink {
                    Text("Set pi path in Settings…")
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .opacity(appeared ? 1 : 0)
            }

            if let err = manager.lastLaunchError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if settings.isPiInstalled, !settings.recentDirectories.isEmpty {
                recents
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { appeared = true }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Recent")
                .captionStyle(weight: .semibold)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, DS.xs)
                .padding(.bottom, 3)
            ForEach(settings.recentDirectories.prefix(5), id: \.self) { path in
                Button {
                    openRecent(path)
                } label: {
                    Label {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, DS.xs)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 260)
        .opacity(appeared ? 0.95 : 0)
        .padding(.top, DS.xs)
    }

    private func openRecent(_ path: String) {
        manager.open(URL(fileURLWithPath: path))
    }
}
