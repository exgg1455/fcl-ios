import SwiftUI

struct VersionsView: View {
    @EnvironmentObject private var store: LauncherStore
    @EnvironmentObject private var installationManager: InstallationManager
    @StateObject private var versionList = VersionListModel()
    @State private var section: VersionSection = .installed
    @State private var searchText = ""
    @State private var pendingInstallation: ManifestVersion?
    @State private var pendingRemoval: String?
    @AppStorage(SettingsKey.showSnapshots) private var showSnapshots = false
    @AppStorage(SettingsKey.showHistoricalVersions) private var showHistoricalVersions = false

    enum VersionSection: String, CaseIterable, Identifiable {
        case installed
        case available

        var id: String { rawValue }

        var title: String {
            switch self {
            case .installed: return "Installed"
            case .available: return "Download"
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(VersionSection.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
                .padding(.bottom, 8)

                if installationManager.isInstalling {
                    InstallationProgressCard()
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                switch section {
                case .installed:
                    installedList
                case .available:
                    availableList
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Versions")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if section == .available {
                        Menu {
                            Toggle("Snapshots", isOn: $showSnapshots)
                            Toggle("Beta and Alpha", isOn: $showHistoricalVersions)
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .confirmationDialog(
            "Install \(pendingInstallation?.identifier ?? "")?",
            isPresented: Binding(get: { pendingInstallation != nil }, set: { if !$0 { pendingInstallation = nil } }),
            titleVisibility: .visible
        ) {
            Button("Install") {
                if let version = pendingInstallation {
                    installationManager.install(version) {
                        store.refreshInstalledVersions()
                        store.selectedVersion = version.identifier
                    }
                }
                pendingInstallation = nil
            }
            Button("Cancel", role: .cancel) {
                pendingInstallation = nil
            }
        } message: {
            Text("The game client, libraries and assets will be downloaded to the Files app under FCL/minecraft.")
        }
        .confirmationDialog(
            "Delete \(pendingRemoval ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let identifier = pendingRemoval {
                    store.removeVersion(identifier)
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        }
    }

    private var installedList: some View {
        List {
            if store.installedVersions.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No versions installed")
                            .font(.headline)
                        Button("Browse versions") {
                            section = .available
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            } else {
                ForEach(store.installedVersions, id: \.self) { identifier in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(identifier)
                                .font(.headline)
                            if store.selectedVersion == identifier {
                                Text("Selected")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        Spacer()
                        if store.selectedVersion == identifier {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.selectedVersion = identifier
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingRemoval = identifier
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            installationManager.repair(identifier) {
                                store.refreshInstalledVersions()
                            }
                        } label: {
                            Label("Repair", systemImage: "wrench.and.screwdriver")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            store.refreshInstalledVersions()
        }
    }

    private var filteredVersions: [ManifestVersion] {
        versionList.versions.filter { version in
            guard let kind = version.kind else { return false }
            switch kind {
            case .release:
                break
            case .snapshot:
                if !showSnapshots { return false }
            case .oldBeta, .oldAlpha:
                if !showHistoricalVersions { return false }
            }
            if searchText.isEmpty { return true }
            return version.identifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var availableList: some View {
        List {
            if let message = versionList.errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Could not load the version list")
                            .font(.headline)
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            Task { await versionList.load(force: true) }
                        }
                    }
                }
            }
            if versionList.isLoading && versionList.versions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            ForEach(filteredVersions) { version in
                Button {
                    pendingInstallation = version
                } label: {
                    VersionRow(
                        version: version,
                        isLatest: version.identifier == versionList.latestRelease,
                        isInstalled: store.installedVersions.contains(version.identifier)
                    )
                }
                .disabled(installationManager.isInstalling)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search versions")
        .refreshable {
            await versionList.load(force: true)
        }
        .task {
            await versionList.load()
        }
    }
}

struct VersionRow: View {
    let version: ManifestVersion
    let isLatest: Bool
    let isInstalled: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(version.identifier)
                        .font(.headline)
                        .foregroundColor(.primary)
                    if isLatest {
                        Text("Latest")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .foregroundColor(.accentColor)
                    }
                }
                HStack(spacing: 6) {
                    Text(version.kind?.title ?? version.type)
                    if let date = version.releaseDate {
                        Text(VersionRow.dateFormatter.string(from: date))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundColor(isInstalled ? .green : .accentColor)
        }
    }
}
