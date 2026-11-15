import Foundation

enum GameDirectory {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var root: URL {
        documents.appendingPathComponent("minecraft", isDirectory: true)
    }

    static var versions: URL {
        root.appendingPathComponent("versions", isDirectory: true)
    }

    static var libraries: URL {
        root.appendingPathComponent("libraries", isDirectory: true)
    }

    static var assets: URL {
        root.appendingPathComponent("assets", isDirectory: true)
    }

    static var assetIndexes: URL {
        assets.appendingPathComponent("indexes", isDirectory: true)
    }

    static var assetObjects: URL {
        assets.appendingPathComponent("objects", isDirectory: true)
    }

    static var javaRuntimes: URL {
        documents.appendingPathComponent("java", isDirectory: true)
    }

    static func versionDirectory(_ identifier: String) -> URL {
        versions.appendingPathComponent(identifier, isDirectory: true)
    }

    static func versionDescriptor(_ identifier: String) -> URL {
        versionDirectory(identifier).appendingPathComponent("\(identifier).json")
    }

    static func versionArchive(_ identifier: String) -> URL {
        versionDirectory(identifier).appendingPathComponent("\(identifier).jar")
    }

    static func nativesDirectory(_ identifier: String) -> URL {
        versionDirectory(identifier).appendingPathComponent("natives", isDirectory: true)
    }

    static func prepare() throws {
        let manager = FileManager.default
        for directory in [root, versions, libraries, assetIndexes, assetObjects, javaRuntimes] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func installedVersionIdentifiers() -> [String] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: versions, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { manager.fileExists(atPath: versionDescriptor($0.lastPathComponent).path) }
            .sorted { first, second in
                let firstDate = (try? first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let secondDate = (try? second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return firstDate > secondDate
            }
            .map { $0.lastPathComponent }
    }

    static func loadVersionDetail(_ identifier: String) throws -> VersionDetail {
        let data = try Data(contentsOf: versionDescriptor(identifier))
        return try JSONDecoder().decode(VersionDetail.self, from: data)
    }

    static func removeVersion(_ identifier: String) throws {
        try FileManager.default.removeItem(at: versionDirectory(identifier))
    }

    static func directorySize(_ directory: URL) -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
