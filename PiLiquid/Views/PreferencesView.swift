import SwiftUI
import AppKit

/// App preferences, split into pages: agent/defaults, and archived conversations.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ArchivedSettings()
                .tabItem { Label("Archived", systemImage: "archivebox") }
        }
        .frame(width: 520, height: 400)
    }
}

/// Where `pi` lives and which provider/model to launch with.
private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("Executable") {
                    HStack(spacing: DS.xs) {
                        TextField("pi executable", text: $settings.piExecutablePath)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                        Button("Choose…") { choosePi() }
                    }
                }
                LabeledContent("Status") {
                    HStack(spacing: DS.xs) {
                        Circle()
                            .fill(executableOK ? Color.green : .orange)
                            .frame(width: 7, height: 7)
                        Text(executableOK ? "pi agent detected" : "pi agent not found")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Agent")
            } footer: {
                if !executableOK {
                    InstallPiCard()
                        .padding(.top, DS.xs)
                }
            }

            Section {
                LabeledContent("Provider") {
                    TextField("Optional", text: $settings.defaultProvider)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent("Model") {
                    TextField("Optional pattern", text: $settings.defaultModel)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("Leave blank to use pi's configured default. Changes apply to the next session you open.")
            }

            Section {
                Toggle("Pre-warm recent projects", isOn: $settings.prewarmProjects)
            } footer: {
                Text("Keeps an idle pi process ready for your most recent projects so switching to them is instant. Each warmed project holds about 150 MB of memory.")
            }
        }
        .formStyle(.grouped)
    }

    private var executableOK: Bool {
        FileManager.default.isExecutableFile(atPath: settings.piExecutablePath)
    }

    private func choosePi() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Select pi")
        if panel.runModal() == .OK, let url = panel.url {
            settings.piExecutablePath = url.path
        }
    }
}

/// Manage archived conversations: restore them to the sidebar, or delete the
/// underlying session file permanently.
private struct ArchivedSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var pendingDelete: ArchivedItem?

    private struct ArchivedItem: Identifiable, Hashable {
        let path: String
        let title: String
        var id: String { path }
        var exists: Bool { FileManager.default.fileExists(atPath: path) }
    }

    private var items: [ArchivedItem] {
        settings.archivedSessions
            .map { ArchivedItem(path: $0, title: SessionIndex.title(forSessionFile: $0)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Archived Conversations") {
                if items.isEmpty {
                    Text("No archived conversations.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        HStack(spacing: DS.sm) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .lineLimit(1)
                                Text(item.path)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Restore") { settings.setArchived(item.path, false) }
                                .buttonStyle(.bordered)
                            Button(role: .destructive) { pendingDelete = item } label: {
                                Image(systemName: "trash")
                            }
                            .help("Delete permanently")
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete this conversation permanently?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text("“\(item.title)” and its session file will be removed. This can't be undone.")
        }
    }

    private func delete(_ item: ArchivedItem) {
        try? FileManager.default.removeItem(atPath: item.path)
        settings.forgetSession(item.path)
        pendingDelete = nil
    }
}
