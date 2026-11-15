import Foundation

enum JavaInstallError: LocalizedError {
    case runtimeNotFound
    case accessDenied
    case downloadFailed(Int)

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            return "No Java runtime was found. The archive or folder must contain lib/libjli.dylib."
        case .accessDenied:
            return "The selected file could not be opened."
        case .downloadFailed(let status):
            return "Download failed with status \(status)."
        }
    }
}

@MainActor
final class JavaRuntimeInstaller: ObservableObject {
    @Published private(set) var runtimes: [JavaRuntime] = []
    @Published private(set) var isWorking = false
    @Published private(set) var stage = ""
    @Published private(set) var progress: Double = 0
    @Published var errorMessage: String?
    @Published var resultMessage: String?
    @Published private(set) var installingMajorVersion: Int?
    @Published private(set) var queuedMajorVersions: [Int] = []

    private var currentTask: Task<Void, Never>?
    private var queue: [JavaDownloadOption] = []
    private var silentResult = false

    nonisolated private static var stagingRoot: URL {
        GameDirectory.javaRuntimes.appendingPathComponent(".staging", isDirectory: true)
    }

    func refresh() {
        runtimes = JavaRuntimeLocator.installedRuntimes()
    }

    func usableRuntime(for requiredMajorVersion: Int) -> JavaRuntime? {
        runtimes.filter { $0.platform.isUsableOnDevice && ($0.majorVersion ?? 0) >= requiredMajorVersion }
            .min { ($0.majorVersion ?? 0) < ($1.majorVersion ?? 0) }
    }

    func isInstalled(_ option: JavaDownloadOption) -> Bool {
        runtimes.contains { $0.platform.isUsableOnDevice && $0.majorVersion == option.majorVersion }
    }

    func isPending(_ option: JavaDownloadOption) -> Bool {
        installingMajorVersion == option.majorVersion || queuedMajorVersions.contains(option.majorVersion)
    }

    @discardableResult
    func ensureRuntime(for requiredMajorVersion: Int) -> JavaDownloadOption? {
        refresh()
        if usableRuntime(for: requiredMajorVersion) != nil {
            return nil
        }
        guard let option = JavaCatalog.option(for: requiredMajorVersion) else { return nil }
        if !isPending(option) {
            install(option, silent: true)
        }
        return option
    }

    func install(_ option: JavaDownloadOption, silent: Bool = false) {
        guard !isPending(option) else { return }
        if isWorking {
            queue.append(option)
            queuedMajorVersions = queue.map { $0.majorVersion }
            return
        }
        installingMajorVersion = option.majorVersion
        silentResult = silent
        start { report in
            report("Downloading \(option.title)", 0)
            let archive = try await JavaRuntimeInstaller.downloadArchive(from: option.address) { fraction in
                report("Downloading \(option.title)", fraction)
            }
            defer { try? FileManager.default.removeItem(at: archive) }
            return try JavaRuntimeInstaller.installArchive(archive, suggestedName: option.directoryName, fixedName: option.directoryName, report: report)
        }
    }

    func importArchive(from file: URL) {
        start { report in
            let local = try JavaRuntimeInstaller.copySecurityScoped(file, report: report)
            defer { try? FileManager.default.removeItem(at: local) }
            return try JavaRuntimeInstaller.installArchive(local, suggestedName: file.lastPathComponent, fixedName: nil, report: report)
        }
    }

    func importFolder(from folder: URL) {
        start { report in
            let local = try JavaRuntimeInstaller.copySecurityScoped(folder, report: report)
            return try JavaRuntimeInstaller.finalize(staging: local, suggestedName: folder.lastPathComponent, fixedName: nil)
        }
    }

    func download(from address: URL) {
        start { report in
            report("Downloading", 0)
            let archive = try await JavaRuntimeInstaller.downloadArchive(from: address) { fraction in
                report("Downloading", fraction)
            }
            defer { try? FileManager.default.removeItem(at: archive) }
            return try JavaRuntimeInstaller.installArchive(archive, suggestedName: address.lastPathComponent, fixedName: nil, report: report)
        }
    }

    func cancel() {
        queue.removeAll()
        queuedMajorVersions = []
        currentTask?.cancel()
    }

    func remove(_ runtime: JavaRuntime) {
        guard !runtime.isBundled else { return }
        try? FileManager.default.removeItem(at: runtime.location)
        refresh()
    }

    private func start(_ work: @escaping @Sendable (@escaping @Sendable (String, Double) -> Void) async throws -> JavaRuntime) {
        guard !isWorking else { return }
        isWorking = true
        stage = "Preparing"
        progress = 0
        let report: @Sendable (String, Double) -> Void = { [weak self] stage, fraction in
            Task { @MainActor in
                self?.stage = stage
                self?.progress = fraction
            }
        }
        currentTask = Task {
            let outcome: Result<JavaRuntime, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try GameDirectory.prepare()
                    return .success(try await work(report))
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let runtime):
                var message = "\(runtime.name) installed"
                if let version = runtime.fullVersion {
                    message += " (Java \(version))"
                }
                message += ". Platform: \(runtime.platform.title)."
                if !runtime.platform.isUsableOnDevice {
                    message += " This runtime is not built for iOS and cannot start the game."
                }
                if !silentResult || !runtime.platform.isUsableOnDevice {
                    resultMessage = message
                }
            case .failure(let error):
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            try? FileManager.default.removeItem(at: JavaRuntimeInstaller.stagingRoot)
            isWorking = false
            installingMajorVersion = nil
            silentResult = false
            currentTask = nil
            refresh()
            if !queue.isEmpty {
                let next = queue.removeFirst()
                queuedMajorVersions = queue.map { $0.majorVersion }
                install(next, silent: true)
            }
        }
    }

    nonisolated private static func copySecurityScoped(_ source: URL, report: (String, Double) -> Void) throws -> URL {
        report("Copying", 0)
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let manager = FileManager.default
        try manager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let destination = stagingRoot.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                try manager.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            throw error
        }
        guard manager.fileExists(atPath: destination.path) else {
            throw JavaInstallError.accessDenied
        }
        return destination
    }

    nonisolated private static func installArchive(_ archive: URL, suggestedName: String, fixedName: String?, report: @escaping @Sendable (String, Double) -> Void) throws -> JavaRuntime {
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let working = stagingRoot.appendingPathComponent("work-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: working) }
        try ArchiveExtractor.extract(archive, to: staging, workingDirectory: working, progress: report)
        report("Finishing", 1)
        return try finalize(staging: staging, suggestedName: suggestedName, fixedName: fixedName)
    }

    nonisolated private static func finalize(staging: URL, suggestedName: String, fixedName: String?) throws -> JavaRuntime {
        let manager = FileManager.default
        defer { try? manager.removeItem(at: staging) }
        guard let runtimeRoot = JavaRuntimeLocator.findRuntimeRoot(in: staging) else {
            throw JavaInstallError.runtimeNotFound
        }
        let version = JavaRuntimeLocator.releaseVersion(of: runtimeRoot)
        let baseName: String
        if let version = version, let major = JavaRuntimeLocator.majorVersion(from: version) {
            baseName = "java-\(major)"
        } else {
            baseName = cleanName(suggestedName)
        }
        var destination = GameDirectory.javaRuntimes.appendingPathComponent(fixedName ?? baseName, isDirectory: true)
        if fixedName != nil, manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        var suffix = 2
        while manager.fileExists(atPath: destination.path) {
            destination = GameDirectory.javaRuntimes.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try manager.moveItem(at: runtimeRoot, to: destination)
        prepareForDevice(destination)
        guard let runtime = JavaRuntimeLocator.describe(destination, isBundled: false) else {
            throw JavaInstallError.runtimeNotFound
        }
        return runtime
    }

    nonisolated private static func cleanName(_ name: String) -> String {
        var result = name
        for suffix in [".tar.xz", ".tar.gz", ".tgz", ".txz", ".tar", ".zip"] where result.lowercased().hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
            break
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        result = String(result.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return result.isEmpty ? "java" : result
    }

    nonisolated private static func prepareForDevice(_ directory: URL) {
        let manager = FileManager.default
        let unusedItems = [
            "ASSEMBLY_EXCEPTION",
            "LICENSE",
            "THIRD_PARTY_README",
            "bin",
            "include",
            "man",
            "demo",
            "sample",
            "lib/ct.sym",
            "lib/jspawnhelper",
            "lib/libjsig.dylib",
            "lib/src.zip",
            "lib/tools.jar",
            "jre/bin"
        ]
        for item in unusedItems {
            try? manager.removeItem(at: directory.appendingPathComponent(item))
        }
        if let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in enumerator where file.pathExtension == "dylib" {
                try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    nonisolated private static func downloadArchive(from address: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let destination = stagingRoot.appendingPathComponent(UUID().uuidString + "-" + address.lastPathComponent)
        return try await withCheckedThrowingContinuation { continuation in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: address) { temporary, response, error in
                observation?.invalidate()
                observation = nil
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: JavaInstallError.downloadFailed(http.statusCode))
                    return
                }
                guard let temporary = temporary else {
                    continuation.resume(throwing: JavaInstallError.downloadFailed(0))
                    return
                }
                do {
                    try manager.moveItem(at: temporary, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted, options: [.new]) { taskProgress, _ in
                progress(taskProgress.fractionCompleted)
            }
            task.resume()
        }
    }
}
