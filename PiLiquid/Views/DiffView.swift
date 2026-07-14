import SwiftUI

/// Renders a reconstructed `edit`/`write` diff as tinted gutter lines — removed
/// in red, added in green, context muted — inside a scrollable monospaced card.
struct DiffView: View {
    let diff: ToolDiff
    /// The card's visible width, so each line's tint fills it edge-to-edge even
    /// when the code is narrower than the card (short lines would otherwise leave
    /// the gray backing showing on the right); long lines still scroll past it.
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { idx, hunk in
                    if idx > 0 {
                        Divider().padding(.vertical, 2)
                    }
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line, minWidth: width)
                    }
                }
            }
        }
        .frame(maxHeight: 320)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // No gray backing: the tinted rows fill the card, and the rounded clip
        // lets the corners fall back to the page — so no gray peeks through.
        .clipShape(.rect(cornerRadius: DS.radiusMedium))
    }
}

/// A single diff line: a sign gutter plus the code, both tinted by change kind.
private struct DiffLineRow: View {
    let line: ToolDiff.Line
    /// Floor width so the tint fills the card; longer lines exceed it and scroll.
    var minWidth: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(sign)
                .font(.mono(12))
                .foregroundStyle(signColor)
                .frame(width: 18, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.mono(12))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.trailing, DS.xs)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(rowBackground)
    }

    private var sign: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }

    private var textColor: Color {
        line.kind == .context ? .secondary : .primary
    }

    private var rowBackground: Color {
        switch line.kind {
        case .added: return .green.opacity(0.12)
        case .removed: return .red.opacity(0.12)
        case .context: return .clear
        }
    }
}
