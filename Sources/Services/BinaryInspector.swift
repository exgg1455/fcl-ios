import Foundation

enum BinaryPlatform: String {
    case iOS
    case iOSSimulator
    case macOS
    case universal
    case linux
    case unknown

    var title: String {
        switch self {
        case .iOS: return "iOS"
        case .iOSSimulator: return "iOS Simulator"
        case .macOS: return "macOS"
        case .universal: return "Universal"
        case .linux: return "Linux / Android"
        case .unknown: return "Unknown"
        }
    }

    var isUsableOnDevice: Bool {
        self == .iOS || self == .universal
    }
}

enum BinaryInspector {
    static func platform(of file: URL) -> BinaryPlatform {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unknown }
        defer { try? handle.close() }
        let bytes = [UInt8](handle.readData(ofLength: 65_536))
        guard bytes.count >= 32 else { return .unknown }
        let magic = readUnsignedInteger(bytes, at: 0)
        if bytes[0] == 0x7F && bytes[1] == 0x45 && bytes[2] == 0x4C && bytes[3] == 0x46 {
            return .linux
        }
        if magic == 0xBEBAFECA || magic == 0xBFBAFECA {
            return .universal
        }
        guard magic == 0xFEEDFACF else { return .unknown }
        let commandCount = Int(readUnsignedInteger(bytes, at: 16))
        var offset = 32
        for _ in 0..<commandCount {
            guard offset + 12 <= bytes.count else { break }
            let command = readUnsignedInteger(bytes, at: offset)
            let commandSize = Int(readUnsignedInteger(bytes, at: offset + 4))
            switch command {
            case 0x32:
                switch readUnsignedInteger(bytes, at: offset + 8) {
                case 1: return .macOS
                case 2: return .iOS
                case 7: return .iOSSimulator
                default: return .unknown
                }
            case 0x25:
                return .iOS
            case 0x24:
                return .macOS
            default:
                break
            }
            guard commandSize > 0 else { break }
            offset += commandSize
        }
        return .unknown
    }

    private static func readUnsignedInteger(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
