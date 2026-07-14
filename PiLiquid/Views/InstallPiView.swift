import SwiftUI
import AppKit

/// Shown when the `pi` agent can't be found on disk. Explains the dependency,
/// offers a copyable install command, a link to the docs, and a re-check that
/// re-scans the common install locations once pi is present.
struct InstallPiCard: View {
    @Environment(AppSettings.self) private var settings
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.xs) {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                Text("pi agent not found")
                    .font(.callout.weight(.semibold))
            }

            Text("Pi Liquid drives the pi command-line agent. Install it with npm, then sign in to a provider.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            commandRow

            HStack(spacing: DS.md) {
                Link(destination: AppSettings.websiteURL) {
                    HStack(spacing: 3) {
                        Text("Documentation")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button("Re-check") { settings.rediscoverPi() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    /// Monospace command in a translucent chip with a copy affordance.
    private var commandRow: some View {
        HStack(spacing: DS.xs) {
            Text(AppSettings.installCommand)
                .font(.mono(12.5))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.xs)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help("Copy install command")
        }
        .padding(.horizontal, DS.sm)
        .padding(.vertical, DS.xs)
        .background(DS.chipFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppSettings.installCommand, forType: .string)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }
}
