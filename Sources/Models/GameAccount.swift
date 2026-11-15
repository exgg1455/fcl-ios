import CryptoKit
import Foundation

enum AccountKind: String, Codable {
    case offline

    var title: String {
        switch self {
        case .offline: return "Offline"
        }
    }
}

struct GameAccount: Codable, Identifiable, Hashable {
    let id: UUID
    var playerName: String
    var playerIdentifier: String
    var kind: AccountKind
    var accessToken: String
    var createdAt: Date

    static func offline(playerName: String) -> GameAccount {
        GameAccount(
            id: UUID(),
            playerName: playerName,
            playerIdentifier: offlineIdentifier(for: playerName),
            kind: .offline,
            accessToken: "0",
            createdAt: Date()
        )
    }

    static func offlineIdentifier(for playerName: String) -> String {
        let digest = Insecure.MD5.hash(data: Data("OfflinePlayer:\(playerName)".utf8))
        var bytes = Array(digest)
        bytes[6] = (bytes[6] & 0x0f) | 0x30
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    var formattedIdentifier: String {
        let characters = Array(playerIdentifier)
        guard characters.count == 32 else { return playerIdentifier }
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return groups.map { String(characters[$0]) }.joined(separator: "-")
    }

    static func isValidPlayerName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard (3...16).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
