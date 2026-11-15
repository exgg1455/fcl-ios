import Foundation

struct JavaDownloadOption: Identifiable, Hashable {
    let majorVersion: Int
    let address: URL
    let downloadSize: Int64
    let usage: String

    var id: Int { majorVersion }

    var title: String { "Java \(majorVersion)" }

    var directoryName: String { "java-\(majorVersion)" }
}

enum JavaCatalog {
    static let options: [JavaDownloadOption] = [
        JavaDownloadOption(
            majorVersion: 8,
            address: URL(string: "https://assets.angelauramc.dev/openjdk/ios-arm64/jre8-ios-aarch64.zip")!,
            downloadSize: 27_539_002,
            usage: "Minecraft 1.16.5 and older"
        ),
        JavaDownloadOption(
            majorVersion: 17,
            address: URL(string: "https://assets.angelauramc.dev/openjdk/ios-arm64/jre17-ios-aarch64.zip")!,
            downloadSize: 21_928_331,
            usage: "Minecraft 1.17 to 1.20.4"
        ),
        JavaDownloadOption(
            majorVersion: 21,
            address: URL(string: "https://assets.angelauramc.dev/openjdk/ios-arm64/jre21-ios-aarch64.zip")!,
            downloadSize: 24_069_623,
            usage: "Minecraft 1.20.5 to 1.21.x"
        ),
        JavaDownloadOption(
            majorVersion: 25,
            address: URL(string: "https://assets.angelauramc.dev/openjdk/ios-arm64/jre25-ios-aarch64.zip")!,
            downloadSize: 24_427_867,
            usage: "Minecraft 26.1 and newer"
        )
    ]

    static func option(for requiredMajorVersion: Int) -> JavaDownloadOption? {
        options.first { $0.majorVersion >= requiredMajorVersion }
    }
}
