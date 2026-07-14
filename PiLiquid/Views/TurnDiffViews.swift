import SwiftUI

/// Quiet capsule under a finished turn: file count plus +/− totals of what the
/// turn *actually* changed on disk. Opens the review inspector.
struct TurnDiffChip: View {
    let diff: TurnDiff
    @Environment(ChatModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            // Toggle: clicking the chip of the turn already showing closes the
            // inspector; anything else pins this turn in the review tab.
            if model.inspectorShown, model.inspectorTab == .review,
               (model.reviewingTurnDiff ?? model.latestTurnDiff)?.id == diff.id {
                model.inspectorShown = false
            } else {
                model.reviewingTurnDiff = diff
                model.inspectorTab = .review
                model.inspectorShown = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 10))
                Text(String(localized: "\(diff.files.count) files changed"))
                Text(verbatim: "+\(diff.totalAdded)")
                    .foregroundStyle(.green)
                Text(verbatim: "−\(diff.totalRemoved)")
                    .foregroundStyle(.red)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.sm)
            .padding(.vertical, 4)
            .background(hovering ? DS.chipFill : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Review the files this turn actually changed")
    }
}

/// Inspector panel: the turn's working-tree changes, file by file, each with the
/// shared diff renderer and a per-file revert.
struct TurnDiffPanel: View {
    let diff: TurnDiff
    @Environment(ChatModel.self) private var model
    @State private var confirmRevert: FileDiff?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.lg) {
                header
                ForEach(diff.files) { file in
                    FileDiffSection(file: file) { confirmRevert = file }
                }
            }
            .padding(DS.md)
        }
        .confirmationDialog(
            Text("Revert “\(confirmRevert.map(Self.displayName) ?? "")”?"),
            isPresented: Binding(
                get: { confirmRevert != nil },
                set: { if !$0 { confirmRevert = nil } }
            ),
            presenting: confirmRevert
        ) { file in
            Button(role: .destructive) {
                model.revertTurnFile(file, turnID: diff.id)
            } label: {
                Text("Revert")
            }
        } message: { file in
            Text(revertMessage(for: file))
        }
    }

    private var header: some View {
        HStack(spacing: DS.xs) {
            Text("Changes this turn")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            Text(verbatim: "+\(diff.totalAdded)")
                .foregroundStyle(.green)
            Text(verbatim: "−\(diff.totalRemoved)")
                .foregroundStyle(.red)
        }
        .font(.system(size: 13))
    }

    private static func displayName(_ file: FileDiff) -> String {
        (file.path as NSString).lastPathComponent
    }

    private func revertMessage(for file: FileDiff) -> String {
        switch file.change {
        case .added:
            return String(localized: "The turn created this file — reverting deletes it.")
        case .deleted:
            return String(localized: "The turn deleted this file — reverting restores it.")
        default:
            return String(localized: "The file returns to its state from before this turn.")
        }
    }
}

/// One file within the panel: a header row (change badge, path, counts, revert)
/// over the rendered hunks.
private struct FileDiffSection: View {
    let file: FileDiff
    let onRevert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: DS.xs) {
                Text(file.path)
                    .font(.mono(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
                changeBadge
                Spacer(minLength: DS.xs)
                if !file.isBinary {
                    Text(verbatim: "+\(file.added)")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text(verbatim: "−\(file.removed)")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Button(action: onRevert) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9))
                        Text("Revert")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(DS.hairline, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Revert this file to its pre-turn state")
            }

            if file.isBinary {
                placeholder(String(localized: "Binary file changed"))
            } else if case .renamed(let old) = file.change, file.hunks.isEmpty {
                placeholder(String(localized: "Renamed from \(old)"))
            } else if !file.hunks.isEmpty {
                DiffView(diff: file.toolDiff)
            }
        }
    }

    @ViewBuilder private var changeBadge: some View {
        if let label = badgeText {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(DS.chipFill, in: Capsule())
        }
    }

    private var badgeText: String? {
        switch file.change {
        case .added: return String(localized: "new")
        case .deleted: return String(localized: "deleted")
        case .renamed: return String(localized: "renamed")
        case .modified: return nil
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
    }
}
