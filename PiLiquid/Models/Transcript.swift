import Foundation

/// A single rendered item in the conversation transcript. Assistant text and
/// tool executions are split into separate items so they read naturally in
/// the order pi emits them.
enum TranscriptItem: Identifiable {
    case user(UserEntry)
    case assistant(AssistantEntry)
    case tool(ToolEntry)
    case notice(NoticeEntry)

    var id: String {
        switch self {
        case .user(let e): return e.id
        case .assistant(let e): return e.id
        case .tool(let e): return e.id
        case .notice(let e): return e.id
        }
    }
}

struct UserEntry: Identifiable {
    let id: String
    var text: String
    var attachments: [ImageAttachment] = []
    /// When the message was sent — live sends stamp locally, history restores
    /// pi's stored epoch. `nil` only for legacy entries with no stamp.
    var timestamp: Date? = nil
}

struct AssistantEntry: Identifiable {
    let id: String
    var segments: [TextSegment]
    var isStreaming: Bool
    var timestamp: Date? = nil

    var hasContent: Bool {
        segments.contains { seg in
            switch seg {
            case .text(let t), .thinking(let t): return !t.isEmpty
            }
        }
    }
}

enum ToolStatus: Equatable {
    case running
    case done
    case error
}

struct ToolEntry: Identifiable {
    let id: String          // toolCallId
    var name: String
    var argsSummary: String
    var output: String
    var status: ToolStatus
    /// Structured old→new changes for `edit`/`write` tools, rendered in place of
    /// the raw result text. `nil` for every other tool.
    var diff: ToolDiff? = nil
    /// User-initiated (the composer's `!` shell mode) rather than a model tool
    /// call — rendered as a console entry so the two can't be confused.
    var isManual: Bool = false
}

struct NoticeEntry: Identifiable {
    enum Kind { case info, warning, error }
    let id: String
    var kind: Kind
    var text: String
}
