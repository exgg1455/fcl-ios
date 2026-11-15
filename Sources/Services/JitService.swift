import Foundation
import UIKit

@_silgen_name("csops")
private func codeSigningOperations(_ processIdentifier: Int32, _ operation: UInt32, _ userAddress: UnsafeMutableRawPointer?, _ userSize: Int) -> Int32

enum JitService {
    private static let statusOperation: UInt32 = 0
    private static let debuggedFlag: UInt32 = 0x10000000

    static var isJitEnabled: Bool {
        var flags: UInt32 = 0
        let result = withUnsafeMutablePointer(to: &flags) { pointer in
            codeSigningOperations(getpid(), statusOperation, UnsafeMutableRawPointer(pointer), MemoryLayout<UInt32>.size)
        }
        return result == 0 && (flags & debuggedFlag) != 0
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.nxteam.foldcraftlauncher.test"
    }

    static var stikDebugAddress: URL? {
        var components = URLComponents()
        components.scheme = "stikjit"
        components.host = "enable-jit"
        components.queryItems = [URLQueryItem(name: "bundle-id", value: bundleIdentifier)]
        return components.url
    }

    @MainActor
    static func requestJitFromStikDebug(completion: @escaping (Bool) -> Void) {
        guard let address = stikDebugAddress else {
            completion(false)
            return
        }
        UIApplication.shared.open(address, options: [:], completionHandler: completion)
    }
}
