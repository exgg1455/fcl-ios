import Foundation

struct VersionManifest: Decodable {
    let latest: LatestVersions
    let versions: [ManifestVersion]
}

struct LatestVersions: Decodable {
    let release: String
    let snapshot: String
}

enum VersionKind: String, CaseIterable, Identifiable {
    case release
    case snapshot
    case oldBeta = "old_beta"
    case oldAlpha = "old_alpha"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .release: return "Release"
        case .snapshot: return "Snapshot"
        case .oldBeta: return "Beta"
        case .oldAlpha: return "Alpha"
        }
    }
}

struct ManifestVersion: Decodable, Identifiable, Hashable {
    let identifier: String
    let type: String
    let address: URL
    let releaseTime: String
    let sha1: String?

    var id: String { identifier }

    var kind: VersionKind? { VersionKind(rawValue: type) }

    var releaseDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: releaseTime)
    }

    enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case type
        case address = "url"
        case releaseTime
        case sha1
    }
}
