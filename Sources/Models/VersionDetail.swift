import Foundation

struct VersionDetail: Decodable {
    let identifier: String
    let type: String?
    let mainClass: String?
    let minecraftArguments: String?
    let arguments: VersionArguments?
    let assetIndex: AssetIndexReference?
    let assets: String?
    let downloads: VersionDownloads?
    let libraries: [Library]
    let javaVersion: JavaVersionRequirement?
    let inheritsFrom: String?

    enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case type
        case mainClass
        case minecraftArguments
        case arguments
        case assetIndex
        case assets
        case downloads
        case libraries
        case javaVersion
        case inheritsFrom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        mainClass = try container.decodeIfPresent(String.self, forKey: .mainClass)
        minecraftArguments = try container.decodeIfPresent(String.self, forKey: .minecraftArguments)
        arguments = try container.decodeIfPresent(VersionArguments.self, forKey: .arguments)
        assetIndex = try container.decodeIfPresent(AssetIndexReference.self, forKey: .assetIndex)
        assets = try container.decodeIfPresent(String.self, forKey: .assets)
        downloads = try container.decodeIfPresent(VersionDownloads.self, forKey: .downloads)
        libraries = try container.decodeIfPresent([Library].self, forKey: .libraries) ?? []
        javaVersion = try container.decodeIfPresent(JavaVersionRequirement.self, forKey: .javaVersion)
        inheritsFrom = try container.decodeIfPresent(String.self, forKey: .inheritsFrom)
    }

    var requiredJavaMajorVersion: Int {
        javaVersion?.majorVersion ?? 8
    }
}

struct VersionArguments: Decodable {
    let game: [ArgumentValue]?
    let jvm: [ArgumentValue]?
}

enum ArgumentValue: Decodable {
    case plain(String)
    case conditional(rules: [Rule], values: [String])

    enum CodingKeys: String, CodingKey {
        case rules
        case value
    }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self) {
            self = .plain(text)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        if let text = try? container.decode(String.self, forKey: .value) {
            self = .conditional(rules: rules, values: [text])
        } else {
            let values = try container.decode([String].self, forKey: .value)
            self = .conditional(rules: rules, values: values)
        }
    }

    func resolvedValues(features: [String: Bool]) -> [String] {
        switch self {
        case .plain(let text):
            return [text]
        case .conditional(let rules, let values):
            return RuleEvaluator.isAllowed(rules, features: features) ? values : []
        }
    }
}

struct Rule: Decodable {
    let action: String
    let operatingSystem: OperatingSystemCondition?
    let features: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case action
        case operatingSystem = "os"
        case features
    }
}

struct OperatingSystemCondition: Decodable {
    let name: String?
    let architecture: String?

    enum CodingKeys: String, CodingKey {
        case name
        case architecture = "arch"
    }
}

enum RuleEvaluator {
    static let operatingSystemName = "osx"

    static func isAllowed(_ rules: [Rule]?, features: [String: Bool] = [:]) -> Bool {
        guard let rules = rules, !rules.isEmpty else { return true }
        var allowed = false
        for rule in rules where matches(rule, features: features) {
            allowed = rule.action == "allow"
        }
        return allowed
    }

    private static func matches(_ rule: Rule, features: [String: Bool]) -> Bool {
        if let system = rule.operatingSystem {
            if let name = system.name, name != operatingSystemName {
                return false
            }
            if let architecture = system.architecture, architecture == "x86" {
                return false
            }
        }
        if let required = rule.features {
            for (key, value) in required where (features[key] ?? false) != value {
                return false
            }
        }
        return true
    }
}

struct AssetIndexReference: Decodable {
    let identifier: String
    let sha1: String?
    let size: Int?
    let totalSize: Int?
    let address: URL

    enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case sha1
        case size
        case totalSize
        case address = "url"
    }
}

struct VersionDownloads: Decodable {
    let client: DownloadableFile?
}

struct DownloadableFile: Decodable {
    let sha1: String?
    let size: Int?
    let address: URL

    enum CodingKeys: String, CodingKey {
        case sha1
        case size
        case address = "url"
    }
}

struct JavaVersionRequirement: Decodable {
    let component: String?
    let majorVersion: Int
}

struct Library: Decodable {
    let name: String
    let downloads: LibraryDownloads?
    let rules: [Rule]?
    let natives: [String: String]?
    let repositoryAddress: String?

    enum CodingKeys: String, CodingKey {
        case name
        case downloads
        case rules
        case natives
        case repositoryAddress = "url"
    }

    var isAllowed: Bool {
        RuleEvaluator.isAllowed(rules)
    }

    var isNativeOnly: Bool {
        natives != nil && downloads?.artifact == nil
    }

    var mavenPath: String? {
        let parts = name.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return nil }
        let group = parts[0].replacingOccurrences(of: ".", with: "/")
        let artifactName = parts[1]
        var version = parts[2]
        var fileExtension = "jar"
        if let atIndex = version.firstIndex(of: "@") {
            fileExtension = String(version[version.index(after: atIndex)...])
            version = String(version[..<atIndex])
        }
        var fileName = "\(artifactName)-\(version)"
        if parts.count >= 4 {
            var classifier = parts[3]
            if let atIndex = classifier.firstIndex(of: "@") {
                fileExtension = String(classifier[classifier.index(after: atIndex)...])
                classifier = String(classifier[..<atIndex])
            }
            fileName += "-\(classifier)"
        }
        return "\(group)/\(artifactName)/\(version)/\(fileName).\(fileExtension)"
    }

    var relativePath: String? {
        if let path = downloads?.artifact?.path, !path.isEmpty {
            return path
        }
        return mavenPath
    }

    var remoteAddress: URL? {
        if let text = downloads?.artifact?.address, !text.isEmpty {
            return URL(string: text)
        }
        guard let path = mavenPath else { return nil }
        let base = repositoryAddress ?? "https://libraries.minecraft.net/"
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        return URL(string: normalizedBase + path)
    }
}

struct LibraryDownloads: Decodable {
    let artifact: LibraryArtifact?
    let classifiers: [String: LibraryArtifact]?
}

struct LibraryArtifact: Decodable {
    let path: String?
    let sha1: String?
    let size: Int?
    let address: String

    enum CodingKeys: String, CodingKey {
        case path
        case sha1
        case size
        case address = "url"
    }
}

struct AssetIndexFile: Decodable {
    let objects: [String: AssetObject]
}

struct AssetObject: Decodable {
    let hash: String
    let size: Int
}
