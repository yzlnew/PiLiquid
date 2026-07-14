import SwiftUI

/// Right-side inspector, toggled from the toolbar: a segmented header over the
/// session's utility views — turn-diff review and a project file browser.
struct SessionInspector: View {
    @Environment(ChatModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            // Quiet chip tabs (gray fill for the active one) — deliberately not
            // a segmented Picker, whose accent-colored selection fights the
            // app's neutral look.
            HStack(spacing: DS.xs) {
                InspectorTabChip(tab: .review, icon: "plus.forwardslash.minus",
                                 label: String(localized: "Review"))
                InspectorTabChip(tab: .files, icon: "folder",
                                 label: String(localized: "Files"))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.sm)
            .padding(.vertical, DS.xs + 2)

            Divider()

            switch model.inspectorTab {
            case .review:
                reviewTab
            case .files:
                if let dir = model.workingDirectory {
                    FileBrowserView(root: dir)
                } else {
                    emptyState(String(localized: "No project open"))
                }
            }
        }
    }

    @ViewBuilder private var reviewTab: some View {
        // A clicked chip pins its turn; otherwise show the latest turn's changes.
        if let diff = model.reviewingTurnDiff ?? model.latestTurnDiff {
            TurnDiffPanel(diff: diff)
        } else {
            emptyState(String(localized: "No changes to review yet"))
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// One inspector tab: an icon + label pill, gray-filled when active, faint on
/// hover — the same hover-vs-selected language as the sidebar rows.
private struct InspectorTabChip: View {
    let tab: ChatModel.InspectorTab
    let icon: String
    let label: String

    @Environment(ChatModel.self) private var model
    @State private var hovering = false

    private var isActive: Bool { model.inspectorTab == tab }

    var body: some View {
        Button {
            model.inspectorTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
            }
            .foregroundStyle(isActive ? Color.primary.opacity(0.85) : .secondary)
            .padding(.horizontal, DS.sm)
            .padding(.vertical, 5)
            .background(
                isActive ? DS.chipFillStrong : (hovering ? DS.chipFill : .clear),
                in: RoundedRectangle(cornerRadius: DS.radiusMedium)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusMedium))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
