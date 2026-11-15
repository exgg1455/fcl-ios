import Foundation

struct JavaRuntime: Identifiable, Hashable {
    let name: String
    let location: URL
    let majorVersion: Int?

    var id: String { location.path }
}

enum JavaRuntimeLocator {
    static func installedRuntimes() -> [JavaRuntime] {
        let manager = FileManager.default
        var searchRoots = [GameDirectory.javaRuntimes]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("java", isDirectory: true) {
            searchRoots.append(bundled)
        }
        var runtimes: [JavaRuntime] = []
        for root in searchRoots {
            guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for entry in entries where isRuntime(entry) {
                runtimes.append(JavaRuntime(name: entry.lastPathComponent, location: entry, majorVersion: majorVersion(of: entry)))
            }
        }
        return runtimes
    }

    static func bestRuntime(for requiredMajorVersion: Int) -> JavaRuntime? {
        let runtimes = installedRuntimes()
        let compatible = runtimes.filter { ($0.majorVersion ?? 0) >= requiredMajorVersion }
        return compatible.min { ($0.majorVersion ?? 0) < ($1.majorVersion ?? 0) } ?? runtimes.first
    }

    private static func isRuntime(_ directory: URL) -> Bool {
        let manager = FileManager.default
        let candidates = [
            "lib/libjli.dylib",
            "lib/jli/libjli.dylib",
            "lib/server/libjvm.dylib",
            "jre/lib/libjli.dylib"
        ]
        return candidates.contains { manager.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    private static func majorVersion(of directory: URL) -> Int? {
        let releaseFile = directory.appendingPathComponent("release")
        guard let contents = try? String(contentsOf: releaseFile, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") where line.hasPrefix("JAVA_VERSION=") {
            let value = line.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let parts = value.split(separator: ".")
            guard let first = parts.first, let number = Int(first) else { return nil }
            if number == 1, parts.count > 1 {
                return Int(parts[1])
            }
            return number
        }
        return nil
    }
}
