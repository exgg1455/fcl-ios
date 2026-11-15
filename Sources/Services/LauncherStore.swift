import Foundation
import SwiftUI

@MainActor
final class LauncherStore: ObservableObject {
    @Published private(set) var accounts: [GameAccount] = []
    @Published private(set) var installedVersions: [String] = []
    @Published var selectedAccountIdentifier: UUID? {
        didSet { UserDefaults.standard.set(selectedAccountIdentifier?.uuidString, forKey: SettingsKey.selectedAccount) }
    }
    @Published var selectedVersion: String? {
        didSet { UserDefaults.standard.set(selectedVersion, forKey: SettingsKey.selectedVersion) }
    }
    @Published private(set) var isJitEnabled: Bool = false

    init() {
        loadAccounts()
        if let stored = UserDefaults.standard.string(forKey: SettingsKey.selectedAccount) {
            selectedAccountIdentifier = UUID(uuidString: stored)
        }
        selectedVersion = UserDefaults.standard.string(forKey: SettingsKey.selectedVersion)
        try? GameDirectory.prepare()
        refreshInstalledVersions()
        refreshJitStatus()
    }

    var selectedAccount: GameAccount? {
        accounts.first { $0.id == selectedAccountIdentifier } ?? accounts.first
    }

    func refreshJitStatus() {
        isJitEnabled = JitService.isJitEnabled
    }

    func refreshInstalledVersions() {
        installedVersions = GameDirectory.installedVersionIdentifiers()
        if let selected = selectedVersion, !installedVersions.contains(selected) {
            selectedVersion = installedVersions.first
        } else if selectedVersion == nil {
            selectedVersion = installedVersions.first
        }
    }

    func addOfflineAccount(playerName: String) {
        let account = GameAccount.offline(playerName: playerName)
        accounts.append(account)
        selectedAccountIdentifier = account.id
        saveAccounts()
    }

    func removeAccounts(at offsets: IndexSet) {
        let removed = offsets.map { accounts[$0].id }
        accounts.remove(atOffsets: offsets)
        if let selected = selectedAccountIdentifier, removed.contains(selected) {
            selectedAccountIdentifier = accounts.first?.id
        }
        saveAccounts()
    }

    func removeVersion(_ identifier: String) {
        try? GameDirectory.removeVersion(identifier)
        refreshInstalledVersions()
    }

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: SettingsKey.accounts),
              let decoded = try? JSONDecoder().decode([GameAccount].self, from: data) else { return }
        accounts = decoded
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: SettingsKey.accounts)
        }
    }
}

@MainActor
final class VersionListModel: ObservableObject {
    @Published private(set) var versions: [ManifestVersion] = []
    @Published private(set) var latestRelease: String?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    func load(force: Bool = false) async {
        if isLoading || (!force && !versions.isEmpty) { return }
        isLoading = true
        errorMessage = nil
        let source = LauncherSettings.current.downloadSource
        do {
            let data = try await FileDownloader().data(from: source.manifestAddress)
            let manifest = try JSONDecoder().decode(VersionManifest.self, from: data)
            versions = manifest.versions
            latestRelease = manifest.latest.release
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
