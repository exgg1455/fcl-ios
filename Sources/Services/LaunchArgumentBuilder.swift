import Foundation
import UIKit

struct LaunchConfiguration {
    let versionIdentifier: String
    let detail: VersionDetail
    let account: GameAccount
    let settings: LauncherSettings
    let screenWidth: Int
    let screenHeight: Int
}

enum LaunchArgumentBuilder {
    static func build(_ configuration: LaunchConfiguration) -> [String] {
        let detail = configuration.detail
        let settings = configuration.settings
        let features: [String: Bool] = [
            "is_demo_user": false,
            "has_custom_resolution": true,
            "has_quick_plays_support": false,
            "is_quick_play_singleplayer": false,
            "is_quick_play_multiplayer": false,
            "is_quick_play_realms": false
        ]
        let substitutions = substitutionTable(configuration)

        var arguments: [String] = [
            "-Xms\(min(512, settings.memoryAllocation))M",
            "-Xmx\(settings.memoryAllocation)M",
            "-Djava.awt.headless=true",
            "-Dorg.lwjgl.util.DebugLoader=true",
            "-Dfml.earlyprogresswindow=false",
            "-Duser.language=\(Locale.current.languageCode ?? "en")"
        ]
        arguments.append(contentsOf: splitArguments(settings.jvmArguments))

        if let jvm = detail.arguments?.jvm {
            arguments.append(contentsOf: jvm.flatMap { $0.resolvedValues(features: features) })
        } else {
            arguments.append(contentsOf: [
                "-Djava.library.path=${natives_directory}",
                "-cp",
                "${classpath}"
            ])
        }

        arguments.append(detail.mainClass ?? "net.minecraft.client.main.Main")

        if let game = detail.arguments?.game {
            arguments.append(contentsOf: game.flatMap { $0.resolvedValues(features: features) })
        } else if let legacy = detail.minecraftArguments {
            arguments.append(contentsOf: splitArguments(legacy))
        }

        if detail.arguments?.game == nil {
            arguments.append(contentsOf: ["--width", "${resolution_width}", "--height", "${resolution_height}"])
        }
        arguments.append(contentsOf: splitArguments(settings.gameArguments))

        return arguments.map { substitute($0, table: substitutions) }
    }

    static func classpath(for detail: VersionDetail, identifier: String) -> [String] {
        var entries: [String] = []
        var seen = Set<String>()
        for library in detail.libraries where library.isAllowed && !library.isNativeOnly {
            guard let path = library.relativePath else { continue }
            let fullPath = GameDirectory.libraries.appendingPathComponent(path).path
            if seen.insert(fullPath).inserted {
                entries.append(fullPath)
            }
        }
        entries.append(GameDirectory.versionArchive(identifier).path)
        return entries
    }

    private static func substitutionTable(_ configuration: LaunchConfiguration) -> [String: String] {
        let detail = configuration.detail
        let identifier = configuration.versionIdentifier
        let assetsName = detail.assetIndex?.identifier ?? detail.assets ?? "legacy"
        let scale = configuration.settings.resolutionScale
        return [
            "auth_player_name": configuration.account.playerName,
            "version_name": identifier,
            "game_directory": GameDirectory.root.path,
            "assets_root": GameDirectory.assets.path,
            "game_assets": GameDirectory.assets.path,
            "assets_index_name": assetsName,
            "auth_uuid": configuration.account.playerIdentifier,
            "auth_access_token": configuration.account.accessToken,
            "auth_session": configuration.account.accessToken,
            "auth_xuid": "0",
            "clientid": "0",
            "user_type": configuration.account.kind == .offline ? "legacy" : "msa",
            "user_properties": "{}",
            "version_type": detail.type ?? "release",
            "natives_directory": GameDirectory.nativesDirectory(identifier).path,
            "launcher_name": "FoldCraftLauncher",
            "launcher_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            "classpath": classpath(for: detail, identifier: identifier).joined(separator: ":"),
            "classpath_separator": ":",
            "library_directory": GameDirectory.libraries.path,
            "resolution_width": String(Int(Double(configuration.screenWidth) * scale)),
            "resolution_height": String(Int(Double(configuration.screenHeight) * scale))
        ]
    }

    private static func substitute(_ argument: String, table: [String: String]) -> String {
        var result = argument
        for (key, value) in table {
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return result
    }

    private static func splitArguments(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}
