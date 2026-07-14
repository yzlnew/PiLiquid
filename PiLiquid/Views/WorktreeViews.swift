import SwiftUI

/// Chip shown above the composer while the session runs in an isolated git
/// worktree. The menu offers merging the work back into the main repository
/// (squash-staged, user commits) or discarding the worktree outright.
struct WorktreeChip: View {
    @Environment(ChatModel.self) private var model
    @Environment(SessionManager.self) private var manager

    private enum PendingAction: String, Identifiable {
        case merge, discard
        var id: String { rawValue }
    }

    @State private var pending: PendingAction?
    @State private var resultMessage: String?
    @State private var resultWasSuccess = false
    @State private var working = false

    var body: some View {
        if let info = model.worktree {
            Menu {
                Button {
                    pending = .merge
                } label: {
                    Label(String(localized: "Merge Back into \(info.repoName)…"),
                          systemImage: "arrow.triangle.merge")
                }
                Button(role: .destructive) {
                    pending = .discard
                } label: {
                    Label("Discard Worktree…", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.on.square.dashed")
                        .font(.system(size: 11))
                    Text("Isolated")
                        .font(.system(size: 12, weight: .medium))
                    Text(info.branch)
                        .font(.mono(11))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.sm)
                .padding(.vertical, 4)
                .background(DS.chipFill, in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(working)
            .help("This session works in an isolated copy — the project stays untouched until you merge")
            .confirmationDialog(
                pending == .merge
                    ? Text("Merge this session's changes back into \(info.repoName)?")
                    : Text("Discard this worktree?"),
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                presenting: pending
            ) { action in
                switch action {
                case .merge:
                    Button("Merge") { perform(merge: true) }
                case .discard:
                    Button("Discard", role: .destructive) { perform(merge: false) }
                }
            } message: { action in
                switch action {
                case .merge:
                    Text("The changes are staged (not committed) in the main repository, then this worktree is removed.")
                case .discard:
                    Text("All changes made in this session's worktree are permanently lost.")
                }
            }
            .alert(
                resultWasSuccess ? Text("Worktree closed") : Text("Couldn't finish the worktree"),
                isPresented: Binding(
                    get: { resultMessage != nil },
                    set: { if !$0 { dismissResult() } }
                )
            ) {
                Button("OK") { dismissResult() }
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }

    private func perform(merge: Bool) {
        working = true
        let agent = model
        Task {
            let result = await manager.finishWorktree(for: agent, merge: merge)
            working = false
            resultWasSuccess = result.ok
            resultMessage = result.message
        }
    }

    /// On success the worktree directory is gone — the session's process has no
    /// home anymore, so close it once the user has read the outcome.
    private func dismissResult() {
        let succeeded = resultWasSuccess
        resultMessage = nil
        if succeeded {
            let agent = model
            Task { manager.closeAgent(agent) }
        }
    }
}
