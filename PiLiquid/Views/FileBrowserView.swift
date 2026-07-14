import SwiftUI
import AppKit

/// Lazy file tree of the project for the inspector's Files tab. Each folder is
/// read on expand (fresh every time) — no upfront indexing. Clicking a file
/// opens it with its default app; right-click offers Finder/path actions.
struct FileBrowserView: View {
    let root: URL
    @State private var entries: [FileNode] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { FileNodeRow(node: $0, depth: 0) }
            }
            .padding(.vertical, DS.xs)
        }
        .task(id: root) { entries = FileNode.list(root) }
    }
}

/// One entry in the tree. Value type; children live in the row's local state so
/// collapsing and re-expanding re-reads the directory.
private struct FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }

    /// Heavy build/dependency dirs that would make the tree useless noise.
    private static let skipped: Set<String> = ["node_modules", ".git", ".build", "DerivedData", "__pycache__", ".venv"]

    static func list(_ dir: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { !skipped.contains($0.lastPathComponent) }
            .map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileNode(url: url, isDirectory: isDir)
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}

private struct FileNodeRow: View {
    let node: FileNode
    let depth: Int
    @State private var expanded = false
    @State private var children: [FileNode] = []
    @State private var hovering = false

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(node.isDirectory ? 1 : 0)
                    .frame(width: 10)
                // Quiet outline glyphs (no colorful Finder icons) — the same
                // icon language as the sidebar's folder rows.
                Image(systemName: node.isDirectory ? (expanded ? "folder.fill" : "folder") : "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .leading)
                Text(node.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, DS.xs + CGFloat(depth) * 14)
            .padding(.trailing, DS.xs)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusMedium))
            .background(
                hovering ? DS.chipFill : .clear,
                in: RoundedRectangle(cornerRadius: DS.radiusMedium)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.xs)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "")
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
        }

        if expanded {
            ForEach(children) { FileNodeRow(node: $0, depth: depth + 1) }
        }
    }

    private func activate() {
        if node.isDirectory {
            if !expanded { children = FileNode.list(node.url) }   // fresh on every expand
            expanded.toggle()
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }
}
