import SwiftUI

/// Dismissible "Plan" chip shown in the composer while plan mode is active.
/// The ✕ exits plan mode (sends `/plan`). Mirrors the composer's command pill,
/// but with a tinted capsule so it reads as a live mode toggle.
struct PlanChip: View {
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            (Text(Image(systemName: "list.bullet.clipboard")) + Text(" ") + Text("Plan"))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Text(Image(systemName: "xmark"))
                    .font(.system(size: 9, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint.opacity(0.6))
            .help("Exit plan mode")
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, DS.xs)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}
