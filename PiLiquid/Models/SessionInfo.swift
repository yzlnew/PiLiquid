import Foundation

/// A pi session on disk, summarized for the sidebar list.
struct SessionInfo: Identifiable, Hashable {
    let id: String          // absolute .jsonl path
    var path: String { id }
    let title: String
    let modified: Date
    var isCurrent: Bool
    /// True when this session was forked/branched from another (its on-disk
    /// header carries a `parentSession` path).
    var isFork: Bool = false
    /// True when the session runs isolated in its own git worktree.
    var isWorktree: Bool = false

    /// Short relative age, e.g. "just now", "5m", "3h", "2d", "4w".
    var relativeAge: String {
        let seconds = Date().timeIntervalSince(modified)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 604_800))w"
        }
    }
}

/// The bits of a running agent the sidebar needs to synthesize a row for a
/// session pi hasn't written to disk yet (the .jsonl only appears once the
/// first turn completes).
struct LiveSessionStub {
    let sessionFile: String?
    let sessionName: String?
    let lastActivated: Date
    let isActive: Bool
    /// For a worktree-isolated agent: the sessions directory of its *home*
    /// project, so the row files under the main repo instead of appearing as a
    /// phantom "project" for the worktree path.
    var homeSessionsDirectory: String? = nil
    var isWorktree: Bool = false
}

extension [SessionInfo] {
    /// Append a synthesized row for every live agent that belongs to
    /// `directory` (pi's per-project sessions folder) but has no on-disk entry
    /// in this scanned list yet. Pure logic, unit-tested — a regression here is
    /// "brand-new sessions are invisible in the sidebar".
    func mergingLive(_ stubs: [LiveSessionStub], inDirectory directory: String) -> [SessionInfo] {
        var merged = self
        for stub in stubs {
            guard let file = stub.sessionFile, !file.isEmpty else { continue }
            let home = stub.homeSessionsDirectory ?? (file as NSString).deletingLastPathComponent
            guard home == directory,
                  !merged.contains(where: { $0.path == file }) else { continue }
            merged.append(SessionInfo(
                id: file,
                title: stub.sessionName ?? String(localized: "New session"),
                modified: stub.lastActivated,
                isCurrent: stub.isActive,
                isWorktree: stub.isWorktree
            ))
        }
        return merged
    }
}
