import CryptoKit
import Foundation

struct DownloadItem {
    let source: URL
    let destination: URL
    let sha1: String?
    let size: Int?
}

enum DownloadError: LocalizedError {
    case unexpectedStatus(Int, URL)
    case checksumMismatch(URL)
    case unknown(URL)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status, let address):
            return "Server returned status \(status) for \(address.lastPathComponent)"
        case .checksumMismatch(let address):
            return "Checksum mismatch for \(address.lastPathComponent)"
        case .unknown(let address):
            return "Download failed for \(address.lastPathComponent)"
        }
    }
}

final class FileDownloader: @unchecked Sendable {
    private let session: URLSession

    init(concurrency: Int = 16) {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = max(1, concurrency)
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func data(from address: URL) async throws -> Data {
        let (data, response) = try await session.data(from: address)
        try validate(response, address: address)
        return data
    }

    func download(_ item: DownloadItem) async throws {
        if isExistingFileValid(item) {
            return
        }
        let manager = FileManager.default
        try manager.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lastError: Error = DownloadError.unknown(item.source)
        for _ in 0..<3 {
            do {
                let (temporary, response) = try await session.download(from: item.source)
                try validate(response, address: item.source)
                if let expected = item.sha1, let actual = FileDownloader.sha1(of: temporary), actual.lowercased() != expected.lowercased() {
                    try? manager.removeItem(at: temporary)
                    throw DownloadError.checksumMismatch(item.source)
                }
                if manager.fileExists(atPath: item.destination.path) {
                    try manager.removeItem(at: item.destination)
                }
                try manager.moveItem(at: temporary, to: item.destination)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func downloadAll(_ items: [DownloadItem], concurrency: Int, progress: @escaping (Int, Int) -> Void) async throws {
        let total = items.count
        guard total > 0 else {
            progress(0, 0)
            return
        }
        var completed = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<min(max(1, concurrency), total) {
                if let next = iterator.next() {
                    group.addTask { try await self.download(next) }
                }
            }
            while try await group.next() != nil {
                completed += 1
                progress(completed, total)
                if let next = iterator.next() {
                    group.addTask { try await self.download(next) }
                }
            }
        }
    }

    private func isExistingFileValid(_ item: DownloadItem) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: item.destination.path) else { return false }
        if let size = item.size,
           let attributes = try? manager.attributesOfItem(atPath: item.destination.path),
           let existingSize = attributes[.size] as? NSNumber,
           existingSize.intValue != size {
            return false
        }
        if let expected = item.sha1 {
            return FileDownloader.sha1(of: item.destination)?.lowercased() == expected.lowercased()
        }
        return true
    }

    private func validate(_ response: URLResponse, address: URL) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.unexpectedStatus(http.statusCode, address)
        }
    }

    static func sha1(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        var finished = false
        while !finished {
            autoreleasepool {
                let chunk = handle.readData(ofLength: 1_048_576)
                if chunk.isEmpty {
                    finished = true
                } else {
                    hasher.update(data: chunk)
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
