import SwiftUI
import AppKit

/// Footer control: shows the current branch and opens a picker on tap. Renders
/// nothing when the working directory isn't a git repo.
struct BranchButton: View {
    let dir: URL
    @State private var current: String?
    @State private var showPicker = false

    var body: some View {
        Group {
            if let current {
                Button { showPicker = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(current).lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                    BranchPicker(dir: dir, current: current) {
                        Task { await refresh() }
                    }
                }
            }
        }
        .task(id: dir) { await refresh() }
    }

    private func refresh() async {
        let d = dir
        current = await Task.detached { GitService.currentBranch(in: d) }.value
    }
}

/// Popover: searchable list of local branches (current marked + uncommitted
/// count), plus an inline "create & checkout new branch" affordance.
private struct BranchPicker: View {
    let dir: URL
    let current: String
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var branches: [String] = []
    @State private var uncommitted = 0
    @State private var creating = false
    @State private var newName = ""
    @State private var error: String?

    private var filtered: [String] {
        search.isEmpty ? branches : branches.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(text: $search, placeholder: String(localized: "Search branches"))
                .padding(.horizontal, DS.sm)
                .padding(.vertical, DS.xs)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Branches")
                        .captionStyle(weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, DS.sm)
                        .padding(.top, DS.xs)
                        .padding(.bottom, 2)

                    if filtered.isEmpty {
                        Text(search.isEmpty ? String(localized: "No branches") : String(localized: "No matches"))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, DS.sm)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(filtered, id: \.self) { branch in
                            branchRow(branch)
                        }
                    }
                }
                .padding(.bottom, DS.xs)
            }
            .frame(maxHeight: 260)

            Divider()
            createRow

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, DS.sm)
                    .padding(.bottom, DS.xs)
            }
        }
        .frame(width: 300)
        .task { await load() }
    }

    private func branchRow(_ branch: String) -> some View {
        IconRowButton {
            select(branch)
        } content: {
            HStack(spacing: DS.xs) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(branch)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if branch == current && uncommitted > 0 {
                        Text("Uncommitted changes: \(uncommitted)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DS.xs)
                if branch == current {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var createRow: some View {
        if creating {
            HStack(spacing: DS.xs) {
                Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 18)
                TextField("New branch name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { create() }
                    .onExitCommand { creating = false; newName = "" }
            }
            .padding(.horizontal, DS.sm)
            .padding(.vertical, DS.xs + 2)
        } else {
            IconRowButton {
                creating = true
            } content: {
                HStack(spacing: DS.xs) {
                    Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 18)
                    Text("Create and checkout new branch…")
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func load() async {
        let d = dir
        branches = await Task.detached { GitService.branches(in: d) }.value
        uncommitted = await Task.detached { GitService.uncommittedCount(in: d) }.value
    }

    private func select(_ branch: String) {
        guard branch != current else { dismiss(); return }
        let d = dir
        Task {
            let ok = await Task.detached { GitService.checkout(branch, in: d) }.value
            if ok { onChange(); dismiss() }
            else { error = String(localized: "Couldn't switch to “\(branch)” — commit or stash changes first.") }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let d = dir
        Task {
            let ok = await Task.detached { GitService.createBranch(name, in: d) }.value
            if ok { onChange(); dismiss() }
            else { error = String(localized: "Couldn't create “\(name)”.") }
        }
    }
}

/// A full-width popover row that highlights on hover.
private struct IconRowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, DS.sm)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? DS.chipFill : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
