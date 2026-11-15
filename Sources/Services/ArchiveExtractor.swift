import Compression
import Foundation

enum ArchiveError: LocalizedError {
    case unreadable
    case unsupportedFormat(String)
    case corrupted(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The archive could not be read."
        case .unsupportedFormat(let detail):
            return "Unsupported archive format. \(detail)"
        case .corrupted(let detail):
            return "The archive is damaged: \(detail)"
        case .unsafePath(let path):
            return "The archive contains an unsafe path: \(path)"
        }
    }
}

enum ArchiveFormat {
    case tar
    case gzipTar
    case xzTar
    case zip
    case unknown
}

enum ArchiveExtractor {
    private static let bufferSize = 1_048_576

    static func detectFormat(of file: URL) -> ArchiveFormat {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unknown }
        defer { try? handle.close() }
        let bytes = [UInt8](handle.readData(ofLength: 512))
        if bytes.count >= 6 && bytes[0..<6].elementsEqual([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return .xzTar
        }
        if bytes.count >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B {
            return .gzipTar
        }
        if bytes.count >= 4 && bytes[0..<4].elementsEqual([0x50, 0x4B, 0x03, 0x04]) {
            return .zip
        }
        if bytes.count >= 262 && bytes[257..<262].elementsEqual(Array("ustar".utf8)) {
            return .tar
        }
        return .unknown
    }

    static func extract(_ archive: URL, to destination: URL, workingDirectory: URL, progress: @escaping (String, Double) -> Void) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try manager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let format = detectFormat(of: archive)
        switch format {
        case .tar:
            try extractTar(archive, to: destination) { progress("Extracting", $0) }
        case .xzTar, .gzipTar:
            let tarFile = workingDirectory.appendingPathComponent(UUID().uuidString + ".tar")
            defer { try? manager.removeItem(at: tarFile) }
            let headerLength = try (format == .gzipTar ? gzipHeaderLength(of: archive) : 0)
            let algorithm = format == .gzipTar ? COMPRESSION_ZLIB : COMPRESSION_LZMA
            try decompress(archive, to: tarFile, algorithm: algorithm, skipping: headerLength) { progress("Decompressing", $0) }
            try extractTar(tarFile, to: destination) { progress("Extracting", $0) }
        case .zip:
            let unpacked = workingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? manager.removeItem(at: unpacked) }
            try extractZip(archive, to: unpacked, workingDirectory: workingDirectory) { progress("Unpacking", $0) }
            try mergeUnpacked(unpacked, into: destination, workingDirectory: workingDirectory, progress: progress)
        case .unknown:
            throw ArchiveError.unsupportedFormat("Use a .zip, .tar, .tar.gz or .tar.xz file.")
        }
    }

    private static func gzipHeaderLength(of file: URL) throws -> Int {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw ArchiveError.unreadable }
        defer { try? handle.close() }
        let bytes = [UInt8](handle.readData(ofLength: 65_536))
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw ArchiveError.corrupted("invalid gzip header")
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw ArchiveError.corrupted("invalid gzip header") }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        if flags & 0x08 != 0 {
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 {
            offset += 2
        }
        guard offset < bytes.count else { throw ArchiveError.corrupted("invalid gzip header") }
        return offset
    }

    private static func decompress(_ source: URL, to destination: URL, algorithm: compression_algorithm, skipping headerLength: Int, length: Int64? = nil, progress: (Double) -> Void) throws {
        let manager = FileManager.default
        guard let input = try? FileHandle(forReadingFrom: source) else { throw ArchiveError.unreadable }
        defer { try? input.close() }
        let fileSize = ((try? manager.attributesOfItem(atPath: source.path)[.size]) as? NSNumber)?.int64Value ?? 1
        let totalSize = length.map { Int64(headerLength) + $0 } ?? fileSize
        if headerLength > 0 {
            input.seek(toFileOffset: UInt64(headerLength))
        }
        manager.createFile(atPath: destination.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: destination) else { throw ArchiveError.unreadable }
        defer { try? output.close() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw ArchiveError.corrupted("decoder could not start")
        }
        defer { compression_stream_destroy(stream) }

        let sourceBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            sourceBuffer.deallocate()
            destinationBuffer.deallocate()
        }

        stream.pointee.src_ptr = UnsafePointer(sourceBuffer)
        stream.pointee.src_size = 0
        stream.pointee.dst_ptr = destinationBuffer
        stream.pointee.dst_size = bufferSize

        var inputExhausted = false
        var bytesRead = Int64(headerLength)
        var finished = false
        var lastReported = -1

        while !finished {
            try autoreleasepool {
                if stream.pointee.src_size == 0 && !inputExhausted {
                    let remaining = totalSize - bytesRead
                    let chunk = remaining > 0 ? input.readData(ofLength: Int(min(Int64(bufferSize), remaining))) : Data()
                    if chunk.isEmpty {
                        inputExhausted = true
                    } else {
                        chunk.copyBytes(to: sourceBuffer, count: chunk.count)
                        stream.pointee.src_ptr = UnsafePointer(sourceBuffer)
                        stream.pointee.src_size = chunk.count
                        bytesRead += Int64(chunk.count)
                    }
                }
                let flags = inputExhausted ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(stream, flags)
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw ArchiveError.corrupted("decompression failed")
                }
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 {
                    output.write(Data(bytes: destinationBuffer, count: produced))
                }
                stream.pointee.dst_ptr = destinationBuffer
                stream.pointee.dst_size = bufferSize
                if status == COMPRESSION_STATUS_END {
                    finished = true
                } else if inputExhausted && produced == 0 && stream.pointee.src_size == 0 {
                    throw ArchiveError.corrupted("unexpected end of file")
                }
                let percent = Int(Double(bytesRead) / Double(max(totalSize, 1)) * 100)
                if percent != lastReported {
                    lastReported = percent
                    progress(min(1, Double(percent) / 100))
                }
            }
        }
    }

    private static func mergeUnpacked(_ unpacked: URL, into destination: URL, workingDirectory: URL, progress: @escaping (String, Double) -> Void) throws {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !isDirectory {
                let format = detectFormat(of: entry)
                if format == .tar || format == .xzTar || format == .gzipTar || format == .zip {
                    try extract(entry, to: destination, workingDirectory: workingDirectory, progress: progress)
                    continue
                }
            }
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            try? manager.removeItem(at: target)
            try manager.moveItem(at: entry, to: target)
        }
    }

    private static func extractZip(_ archive: URL, to destination: URL, workingDirectory: URL, progress: (Double) -> Void) throws {
        let manager = FileManager.default
        guard let handle = try? FileHandle(forReadingFrom: archive) else { throw ArchiveError.unreadable }
        defer { try? handle.close() }
        let fileSize = handle.seekToEndOfFile()
        let tailLength = min(fileSize, 65_557)
        handle.seek(toFileOffset: fileSize - tailLength)
        let tail = [UInt8](handle.readData(ofLength: Int(tailLength)))
        guard tail.count >= 22 else { throw ArchiveError.corrupted("zip file is too small") }
        var endIndex: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50 && tail[index + 1] == 0x4B && tail[index + 2] == 0x05 && tail[index + 3] == 0x06 {
                endIndex = index
                break
            }
            index -= 1
        }
        guard let end = endIndex else { throw ArchiveError.corrupted("zip directory not found") }
        let entryCount = Int(littleEndian16(tail, end + 10))
        let directorySize = UInt64(littleEndian32(tail, end + 12))
        let directoryOffset = UInt64(littleEndian32(tail, end + 16))
        if directoryOffset == 0xFFFFFFFF || entryCount == 0xFFFF {
            throw ArchiveError.unsupportedFormat("Zip64 files are not supported.")
        }
        handle.seek(toFileOffset: directoryOffset)
        let directory = [UInt8](handle.readData(ofLength: Int(directorySize)))
        var offset = 0
        for entryIndex in 0..<entryCount {
            guard offset + 46 <= directory.count,
                  littleEndian32(directory, offset) == 0x02014B50 else {
                throw ArchiveError.corrupted("invalid zip directory")
            }
            let method = littleEndian16(directory, offset + 10)
            let compressedSize = Int64(littleEndian32(directory, offset + 20))
            let nameLength = Int(littleEndian16(directory, offset + 28))
            let extraLength = Int(littleEndian16(directory, offset + 30))
            let commentLength = Int(littleEndian16(directory, offset + 32))
            let externalAttributes = littleEndian32(directory, offset + 38)
            let localOffset = UInt64(littleEndian32(directory, offset + 42))
            guard offset + 46 + nameLength <= directory.count else {
                throw ArchiveError.corrupted("invalid zip entry name")
            }
            let name = String(decoding: directory[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            let relativePath = try sanitize(name)
            if relativePath.isEmpty { continue }
            let target = destination.appendingPathComponent(relativePath)
            let unixMode = Int(externalAttributes >> 16)

            if name.hasSuffix("/") {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            handle.seek(toFileOffset: localOffset)
            let localHeader = [UInt8](handle.readData(ofLength: 30))
            guard localHeader.count == 30, littleEndian32(localHeader, 0) == 0x04034B50 else {
                throw ArchiveError.corrupted("invalid zip entry header")
            }
            let dataOffset = localOffset + 30 + UInt64(littleEndian16(localHeader, 26)) + UInt64(littleEndian16(localHeader, 28))

            try? manager.removeItem(at: target)
            switch method {
            case 0:
                manager.createFile(atPath: target.path, contents: nil)
                guard let output = try? FileHandle(forWritingTo: target) else { throw ArchiveError.unreadable }
                handle.seek(toFileOffset: dataOffset)
                var remaining = compressedSize
                while remaining > 0 {
                    try autoreleasepool {
                        let chunk = handle.readData(ofLength: Int(min(remaining, Int64(bufferSize))))
                        if chunk.isEmpty {
                            throw ArchiveError.corrupted("unexpected end of zip data")
                        }
                        output.write(chunk)
                        remaining -= Int64(chunk.count)
                    }
                }
                try? output.close()
            case 8:
                try decompress(archive, to: target, algorithm: COMPRESSION_ZLIB, skipping: Int(dataOffset), length: compressedSize) { _ in }
            default:
                throw ArchiveError.unsupportedFormat("Zip compression method \(method) is not supported.")
            }

            if unixMode & 0o170000 == 0o120000, let linkTarget = try? String(contentsOf: target, encoding: .utf8) {
                try? manager.removeItem(at: target)
                try manager.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
            } else if unixMode & 0o777 != 0 {
                try? manager.setAttributes([.posixPermissions: unixMode & 0o777], ofItemAtPath: target.path)
            }
            progress(Double(entryIndex + 1) / Double(max(entryCount, 1)))
        }
    }

    private static func littleEndian16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func littleEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func extractTar(_ tarFile: URL, to destination: URL, progress: (Double) -> Void) throws {
        let manager = FileManager.default
        guard let input = try? FileHandle(forReadingFrom: tarFile) else { throw ArchiveError.unreadable }
        defer { try? input.close() }
        let totalSize = ((try? manager.attributesOfItem(atPath: tarFile.path)[.size]) as? NSNumber)?.int64Value ?? 1
        var position: Int64 = 0
        var pendingLongName: String?
        var pendingLongLink: String?
        var pendingPaxPath: String?
        var pendingPaxLink: String?
        var hardLinks: [(String, String)] = []
        var lastReported = -1

        while true {
            let header = [UInt8](input.readData(ofLength: 512))
            position += Int64(header.count)
            if header.count < 512 || header.allSatisfy({ $0 == 0 }) {
                break
            }
            let size = parseNumber(header[124..<136])
            let type = header[156]
            let paddedSize = (size + 511) / 512 * 512

            if type == UInt8(ascii: "L") || type == UInt8(ascii: "K") || type == UInt8(ascii: "x") || type == UInt8(ascii: "g") {
                let data = input.readData(ofLength: Int(paddedSize))
                position += Int64(data.count)
                let content = data.prefix(Int(size))
                if type == UInt8(ascii: "L") {
                    pendingLongName = cString(content)
                } else if type == UInt8(ascii: "K") {
                    pendingLongLink = cString(content)
                } else if type == UInt8(ascii: "x") {
                    let records = parsePaxRecords(content)
                    pendingPaxPath = records["path"]
                    pendingPaxLink = records["linkpath"]
                }
                continue
            }

            var name = cString(Data(header[0..<100]))
            let magic = cString(Data(header[257..<263]))
            if magic.hasPrefix("ustar") {
                let prefix = cString(Data(header[345..<500]))
                if !prefix.isEmpty {
                    name = prefix + "/" + name
                }
            }
            if let longName = pendingPaxPath ?? pendingLongName {
                name = longName
            }
            var linkName = cString(Data(header[157..<257]))
            if let longLink = pendingPaxLink ?? pendingLongLink {
                linkName = longLink
            }
            pendingLongName = nil
            pendingLongLink = nil
            pendingPaxPath = nil
            pendingPaxLink = nil

            let mode = Int(parseNumber(header[100..<108]))
            let relativePath = try sanitize(name)
            let target = relativePath.isEmpty ? destination : destination.appendingPathComponent(relativePath)

            switch type {
            case UInt8(ascii: "5"):
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                skip(input, count: paddedSize)
            case UInt8(ascii: "2"):
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? manager.removeItem(at: target)
                try manager.createSymbolicLink(atPath: target.path, withDestinationPath: linkName)
                skip(input, count: paddedSize)
            case UInt8(ascii: "1"):
                hardLinks.append((relativePath, try sanitize(linkName)))
                skip(input, count: paddedSize)
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? manager.removeItem(at: target)
                manager.createFile(atPath: target.path, contents: nil)
                guard let output = try? FileHandle(forWritingTo: target) else { throw ArchiveError.unreadable }
                var remaining = size
                while remaining > 0 {
                    try autoreleasepool {
                        let chunk = input.readData(ofLength: Int(min(remaining, Int64(bufferSize))))
                        if chunk.isEmpty {
                            throw ArchiveError.corrupted("unexpected end of tar data")
                        }
                        output.write(chunk)
                        remaining -= Int64(chunk.count)
                    }
                }
                try? output.close()
                skip(input, count: paddedSize - size)
                let permissions = mode & 0o777
                try? manager.setAttributes([.posixPermissions: permissions == 0 ? 0o644 : permissions], ofItemAtPath: target.path)
            default:
                skip(input, count: paddedSize)
            }
            position += paddedSize

            let percent = Int(Double(position) / Double(max(totalSize, 1)) * 100)
            if percent != lastReported {
                lastReported = percent
                progress(min(1, Double(percent) / 100))
            }
        }

        for (linkPath, sourcePath) in hardLinks {
            let target = destination.appendingPathComponent(linkPath)
            let source = destination.appendingPathComponent(sourcePath)
            try? manager.removeItem(at: target)
            try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.copyItem(at: source, to: target)
        }
    }

    private static func skip(_ handle: FileHandle, count: Int64) {
        guard count > 0 else { return }
        handle.seek(toFileOffset: handle.offsetInFile + UInt64(count))
    }

    private static func sanitize(_ path: String) throws -> String {
        var components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        if components.contains("..") {
            throw ArchiveError.unsafePath(path)
        }
        if components.first == "" {
            components.removeFirst()
        }
        return components.joined(separator: "/")
    }

    private static func parseNumber(_ bytes: ArraySlice<UInt8>) -> Int64 {
        if let first = bytes.first, first & 0x80 != 0 {
            var value: Int64 = 0
            for (index, byte) in bytes.enumerated() {
                let part = index == 0 ? Int64(byte & 0x7F) : Int64(byte)
                value = (value << 8) | part
            }
            return value
        }
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return Int64(text, radix: 8) ?? 0
    }

    private static func cString(_ data: Data) -> String {
        let bytes = data.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parsePaxRecords(_ data: Data) -> [String: String] {
        var records: [String: String] = [:]
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let spaceIndex = line.firstIndex(of: " ") else { continue }
            let record = line[line.index(after: spaceIndex)...]
            guard let equalsIndex = record.firstIndex(of: "=") else { continue }
            let key = String(record[..<equalsIndex])
            let value = String(record[record.index(after: equalsIndex)...])
            records[key] = value
        }
        return records
    }
}
