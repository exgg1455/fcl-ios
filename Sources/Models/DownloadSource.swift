import Foundation

enum DownloadSource: String, CaseIterable, Identifiable {
    case official
    case bmclapi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .official: return "Official (Mojang)"
        case .bmclapi: return "BMCLAPI Mirror"
        }
    }

    var manifestAddress: URL {
        switch self {
        case .official:
            return URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!
        case .bmclapi:
            return URL(string: "https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json")!
        }
    }

    func assetObjectAddress(hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        switch self {
        case .official:
            return URL(string: "https://resources.download.minecraft.net/\(prefix)/\(hash)")!
        case .bmclapi:
            return URL(string: "https://bmclapi2.bangbang93.com/assets/\(prefix)/\(hash)")!
        }
    }

    func translate(_ address: URL) -> URL {
        guard self == .bmclapi else { return address }
        let replacements = [
            ("https://piston-meta.mojang.com", "https://bmclapi2.bangbang93.com"),
            ("https://piston-data.mojang.com", "https://bmclapi2.bangbang93.com"),
            ("https://launchermeta.mojang.com", "https://bmclapi2.bangbang93.com"),
            ("https://launcher.mojang.com", "https://bmclapi2.bangbang93.com"),
            ("https://libraries.minecraft.net", "https://bmclapi2.bangbang93.com/maven"),
            ("https://resources.download.minecraft.net", "https://bmclapi2.bangbang93.com/assets")
        ]
        var text = address.absoluteString
        for (original, mirror) in replacements where text.hasPrefix(original) {
            text = mirror + String(text.dropFirst(original.count))
            break
        }
        return URL(string: text) ?? address
    }
}
