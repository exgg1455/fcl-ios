import Foundation

enum SettingsKey {
    static let memoryAllocation = "memoryAllocation"
    static let jvmArguments = "jvmArguments"
    static let gameArguments = "gameArguments"
    static let downloadSource = "downloadSource"
    static let downloadConcurrency = "downloadConcurrency"
    static let showSnapshots = "showSnapshots"
    static let showHistoricalVersions = "showHistoricalVersions"
    static let resolutionScale = "resolutionScale"
    static let selectedAccount = "selectedAccount"
    static let selectedVersion = "selectedVersion"
    static let accounts = "accounts"
    static let automaticJavaDownload = "automaticJavaDownload"
}

struct LauncherSettings {
    var memoryAllocation: Int
    var jvmArguments: String
    var gameArguments: String
    var downloadSource: DownloadSource
    var downloadConcurrency: Int
    var resolutionScale: Double

    static var current: LauncherSettings {
        let defaults = UserDefaults.standard
        let memory = defaults.integer(forKey: SettingsKey.memoryAllocation)
        let concurrency = defaults.integer(forKey: SettingsKey.downloadConcurrency)
        let scale = defaults.double(forKey: SettingsKey.resolutionScale)
        return LauncherSettings(
            memoryAllocation: memory > 0 ? memory : DeviceInformation.recommendedMemory,
            jvmArguments: defaults.string(forKey: SettingsKey.jvmArguments) ?? "",
            gameArguments: defaults.string(forKey: SettingsKey.gameArguments) ?? "",
            downloadSource: DownloadSource(rawValue: defaults.string(forKey: SettingsKey.downloadSource) ?? "") ?? .official,
            downloadConcurrency: concurrency > 0 ? concurrency : 16,
            resolutionScale: scale > 0 ? scale : 1.0
        )
    }
}

extension LauncherSettings {
    static var isAutomaticJavaDownloadEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.automaticJavaDownload) as? Bool ?? true
    }
}

enum DeviceInformation {
    static var physicalMemory: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    }

    static var recommendedMemory: Int {
        let half = physicalMemory / 2
        let rounded = (half / 256) * 256
        return max(1024, min(rounded, 4096))
    }

    static var maximumMemory: Int {
        max(1024, (physicalMemory * 3 / 4 / 256) * 256)
    }

    static var operatingSystemDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
