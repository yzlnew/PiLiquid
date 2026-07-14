import SwiftUI

/// A flat, WebView-free rendering of a whole conversation, sized for
/// `ImageRenderer` to rasterize into one long shareable image. It deliberately
/// mirrors the transcript's *reading* layer (user prompts + replies, compact
/// tool lines) rather than the live UI chrome, and forces a light, opaque
/// surface so the exported image reads the same everywhere.
struct ConversationExportView: View {
    let items: [TranscriptItem]
    let title: String
    let subtitle: String

    /// The reading width of the exported column (matches the transcript cap).
    static let width: CGFloat = 720

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            ForEach(items) { item in
                row(for: item)
            }
            footer
        }
        .padding(28)
        .frame(width: Self.width, alignment: .leading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.black)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Exported from Pi Liquid")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func row(for item: TranscriptItem) -> some View {
        switch item {
        case .user(let e):
            if !e.text.isEmpty { userBlock(e.text) }
        case .assistant(let e):
            assistantBlock(e)
        case .tool(let e):
            toolLine(e)
        case .notice(let e):
            noticeLine(e)
        }
    }

    private func userBlock(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.black)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.06), in: .rect(cornerRadius: 14))
                .frame(alignment: .trailing)
        }
    }

    @ViewBuilder
    private func assistantBlock(_ entry: AssistantEntry) -> some View {
        let texts = entry.segments.compactMap { seg -> String? in
            if case .text(let t) = seg, !t.isEmpty { return t }   // thinking is dropped
            return nil
        }
        if !texts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(texts.enumerated()), id: \.offset) { _, t in
                    ExportMarkdown(t)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toolLine(_ entry: ToolEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            if !entry.argsSummary.isEmpty {
                Text(entry.argsSummary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let diff = entry.diff {
                if diff.addedCount > 0 { Text("+\(diff.addedCount)").foregroundStyle(.green) }
                if diff.removedCount > 0 { Text("−\(diff.removedCount)").foregroundStyle(.red) }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeLine(_ entry: NoticeEntry) -> some View {
        Text(entry.text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lightweight Markdown for the export image: fenced code blocks render as a
/// monospace card, prose between them uses SwiftUI's inline Markdown (bold,
/// italic, code spans, links) with newlines preserved. Not a full renderer —
/// good enough for a faithful, self-contained snapshot without a WebView.
private struct ExportMarkdown: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let s):
                    Text(inline(s))
                        .font(.system(size: 14))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let s):
                    Text(s)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.05), in: .rect(cornerRadius: 8))
                }
            }
        }
    }

    private enum Block { case prose(String), code(String) }

    /// Split on ``` fences; even chunks are prose, odd chunks are code (with an
    /// optional leading language tag stripped).
    private var blocks: [Block] {
        let parts = text.components(separatedBy: "```")
        var result: [Block] = []
        for (i, part) in parts.enumerated() {
            if i % 2 == 0 {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(.prose(trimmed)) }
            } else {
                // Drop a leading "swift\n"-style language line.
                var body = part
                if let nl = part.firstIndex(of: "\n") {
                    let firstLine = part[..<nl].trimmingCharacters(in: .whitespaces)
                    if !firstLine.isEmpty && !firstLine.contains(" ") {
                        body = String(part[part.index(after: nl)...])
                    }
                }
                let code = body.trimmingCharacters(in: .newlines)
                if !code.isEmpty { result.append(.code(code)) }
            }
        }
        return result.isEmpty ? [.prose(text)] : result
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}
