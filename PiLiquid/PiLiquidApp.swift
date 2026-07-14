import SwiftUI

@main
struct PiLiquidApp: App {
    @State private var settings: AppSettings
    @State private var manager: SessionManager

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _manager = State(initialValue: SessionManager(settings: settings))
    }

    var body: some Scene {
        Window("Pi Liquid", id: "main") {
            RootView()
                .environment(manager)
                .environment(settings)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Project…") {
                    NotificationCenter.default.post(name: .openProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("New Session") {
                    if let dir = manager.active?.homeProjectURL { manager.newSession(in: dir) }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(manager.active?.workingDirectory == nil)
                Button("New Session in Worktree") {
                    if let dir = manager.active?.homeProjectURL { manager.newIsolatedSession(in: dir) }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(manager.active?.workingDirectory == nil)
                Button("Clone Session") { manager.active?.cloneSession() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!(manager.active?.isConnected ?? false))
            }
            CommandGroup(after: .toolbar) {
                Button("Stop Agent") { manager.active?.abort() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!(manager.active?.isStreaming ?? false))
                Divider()
                Button("Cycle Model") { manager.active?.cycleModel() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!(manager.active?.isConnected ?? false))
                Button("Cycle Thinking Level") { manager.active?.cycleThinkingLevel() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!(manager.active?.isConnected ?? false))
                Button("Compact Context") { manager.active?.compact() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!(manager.active?.isConnected ?? false))
            }
        }

        Settings {
            PreferencesView()
                .environment(settings)
        }
    }
}

extension Notification.Name {
    static let openProject = Notification.Name("PiLiquid.openProject")
    /// Posted with `object: URL` to switch to a specific project directory.
    static let openProjectAt = Notification.Name("PiLiquid.openProjectAt")
    /// Opens the window-centered, cross-project session search palette.
    static let showSessionSearch = Notification.Name("PiLiquid.showSessionSearch")
}
