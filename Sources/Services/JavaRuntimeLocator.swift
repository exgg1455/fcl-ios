import Foundation

struct JavaRuntime: Identifiable, Hashable {
    let name: String
    let location: URL
    let majorVersion: Int?
    let fullVersion: String?
    let platform: BinaryPlatform
    let isBundled: Bool

    var id: String { location.path }
}

enum JavaRuntimeLocator {
    static let libraryCandidates = [
        "lib/libjli.dylib",
        "lib/jli/libjli.dylib",
        "jre/lib/libjli.dylib",
        "jre/lib/jli/libjli.dylib",
        "lib/server/libjvm.dylib",
        "jre/lib/server/libjvm.dylib",
        "lib/libjli.so",
        "lib/aarch64/jli/libjli.so",
        "jre/lib/aarch64/jli/libjli.so",
        "lib/jli/libjli.so"
    ]

    static var bundledRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("java_runtimes", isDirectory: true)
    }

    static func installedRuntimes() -> [JavaRuntime] {
        let manager = FileManager.default
        var searchRoots: [(URL, Bool)] = [(GameDirectory.javaRuntimes, false)]
        if let bundled = bundledRoot {
            searchRoots.append((bundled, true))
        }
        var runtimes: [JavaRuntime] = []
        for (root, isBundled) in searchRoots {
            guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for entry in entries {
                if let runtime = describe(entry, isBundled: isBundled) {
                    runtimes.append(runtime)
                }
            }
        }
        return runtimes.sorted { ($0.majorVersion ?? 0) < ($1.majorVersion ?? 0) }
    }

    static func bestRuntime(for requiredMajorVersion: Int) -> JavaRuntime? {
        let usable = installedRuntimes().filter { $0.platform.isUsableOnDevice }
        let compatible = usable.filter { ($0.majorVersion ?? 0) >= requiredMajorVersion }
        return compatible.min { ($0.majorVersion ?? 0) < ($1.majorVersion ?? 0) }
    }

    static func describe(_ directory: URL, isBundled: Bool) -> JavaRuntime? {
        guard let library = launcherLibrary(in: directory) else { return nil }
        let version = releaseVersion(of: directory)
        return JavaRuntime(
            name: directory.lastPathComponent,
            location: directory,
            majorVersion: version.flatMap(majorVersion(from:)),
            fullVersion: version,
            platform: BinaryInspector.platform(of: library),
            isBundled: isBundled
        )
    }

    static func launcherLibrary(in directory: URL) -> URL? {
        let manager = FileManager.default
        for candidate in libraryCandidates {
            let file = directory.appendingPathComponent(candidate)
            if manager.fileExists(atPath: file.path) {
                return file
            }
        }
        return nil
    }

    static func findRuntimeRoot(in directory: URL, depth: Int = 3) -> URL? {
        if launcherLibrary(in: directory) != nil {
            return directory
        }
        guard depth > 0,
              let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let found = findRuntimeRoot(in: entry, depth: depth - 1) {
                return found
            }
        }
        return nil
    }

    static func releaseVersion(of directory: URL) -> String? {
        for name in ["release", "jre/release"] {
            let file = directory.appendingPathComponent(name)
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") where line.hasPrefix("JAVA_VERSION=") {
                return line.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"\r "))
            }
        }
        return nil
    }

    static func majorVersion(from version: String) -> Int? {
        let parts = version.split(separator: ".")
        guard let first = parts.first, let number = Int(first) else { return nil }
        if number == 1, parts.count > 1 {
            return Int(parts[1])
        }
        return number
    }
}
