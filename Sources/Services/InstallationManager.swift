import Foundation

@MainActor
final class InstallationManager: ObservableObject {
    @Published private(set) var activeVersion: String?
    @Published private(set) var stage: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressDetail: String = ""
    @Published var errorMessage: String?

    private var currentTask: Task<Void, Never>?

    var isInstalling: Bool { activeVersion != nil }

    func install(_ version: ManifestVersion, completion: @escaping () -> Void) {
        guard activeVersion == nil else { return }
        activeVersion = version.identifier
        stage = "Preparing"
        progress = 0
        progressDetail = ""
        let settings = LauncherSettings.current
        currentTask = Task {
            do {
                try await performInstallation(version, settings: settings)
                stage = "Completed"
                progress = 1
            } catch {
                if Task.isCancelled {
                    stage = "Cancelled"
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            activeVersion = nil
            currentTask = nil
            completion()
        }
    }

    func repair(_ identifier: String, completion: @escaping () -> Void) {
        guard activeVersion == nil else { return }
        activeVersion = identifier
        stage = "Verifying"
        progress = 0
        progressDetail = ""
        let settings = LauncherSettings.current
        currentTask = Task {
            do {
                let versionDetail = try GameDirectory.loadVersionDetail(identifier)
                try await downloadContents(of: versionDetail, settings: settings)
                stage = "Completed"
                progress = 1
            } catch {
                if Task.isCancelled {
                    stage = "Cancelled"
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            activeVersion = nil
            currentTask = nil
            completion()
        }
    }

    func cancel() {
        currentTask?.cancel()
    }

    private func performInstallation(_ version: ManifestVersion, settings: LauncherSettings) async throws {
        try GameDirectory.prepare()
        let downloader = FileDownloader(concurrency: settings.downloadConcurrency)
        stage = "Downloading version descriptor"
        let descriptorData = try await downloader.data(from: settings.downloadSource.translate(version.address))
        let detail = try JSONDecoder().decode(VersionDetail.self, from: descriptorData)
        try FileManager.default.createDirectory(at: GameDirectory.versionDirectory(version.identifier), withIntermediateDirectories: true)
        try descriptorData.write(to: GameDirectory.versionDescriptor(version.identifier), options: .atomic)
        try await downloadContents(of: detail, settings: settings)
    }

    private func downloadContents(of detail: VersionDetail, settings: LauncherSettings) async throws {
        let source = settings.downloadSource
        let downloader = FileDownloader(concurrency: settings.downloadConcurrency)

        if let client = detail.downloads?.client {
            stage = "Downloading game client"
            progress = 0
            let item = DownloadItem(
                source: source.translate(client.address),
                destination: GameDirectory.versionArchive(detail.identifier),
                sha1: client.sha1,
                size: client.size
            )
            try await downloader.download(item)
            progress = 1
        }

        try Task.checkCancellation()
        stage = "Downloading libraries"
        let libraryItems = detail.libraries.compactMap { library -> DownloadItem? in
            guard library.isAllowed, !library.isNativeOnly,
                  let path = library.relativePath,
                  let address = library.remoteAddress else { return nil }
            return DownloadItem(
                source: source.translate(address),
                destination: GameDirectory.libraries.appendingPathComponent(path),
                sha1: library.downloads?.artifact?.sha1,
                size: library.downloads?.artifact?.size
            )
        }
        try await downloader.downloadAll(libraryItems, concurrency: settings.downloadConcurrency) { completed, total in
            Task { @MainActor in
                self.updateProgress(completed: completed, total: total)
            }
        }

        try Task.checkCancellation()
        guard let indexReference = detail.assetIndex else { return }
        stage = "Downloading asset index"
        let indexDestination = GameDirectory.assetIndexes.appendingPathComponent("\(indexReference.identifier).json")
        try await downloader.download(DownloadItem(
            source: source.translate(indexReference.address),
            destination: indexDestination,
            sha1: indexReference.sha1,
            size: indexReference.size
        ))
        let indexData = try Data(contentsOf: indexDestination)
        let index = try JSONDecoder().decode(AssetIndexFile.self, from: indexData)

        try Task.checkCancellation()
        stage = "Downloading assets"
        var seenHashes = Set<String>()
        var assetItems: [DownloadItem] = []
        for object in index.objects.values where !seenHashes.contains(object.hash) {
            seenHashes.insert(object.hash)
            assetItems.append(DownloadItem(
                source: source.assetObjectAddress(hash: object.hash),
                destination: GameDirectory.assetObjects
                    .appendingPathComponent(String(object.hash.prefix(2)), isDirectory: true)
                    .appendingPathComponent(object.hash),
                sha1: object.hash,
                size: object.size
            ))
        }
        try await downloader.downloadAll(assetItems, concurrency: settings.downloadConcurrency) { completed, total in
            Task { @MainActor in
                self.updateProgress(completed: completed, total: total)
            }
        }
    }

    private func updateProgress(completed: Int, total: Int) {
        guard total > 0 else { return }
        progress = Double(completed) / Double(total)
        progressDetail = "\(completed) / \(total)"
    }
}
