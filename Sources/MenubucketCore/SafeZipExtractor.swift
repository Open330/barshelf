import Compression
import Foundation

/// Minimal, security-hardened zip reader for widget archives (URL-install v1).
///
/// Implemented in-process (central directory + stored/deflate entries via the
/// Compression framework) instead of shelling out to `unzip`/`ditto` so the
/// security policy is enforced *before* any bytes hit the filesystem:
/// - path traversal (`../`, absolute paths) rejected,
/// - symbolic links skipped,
/// - total extracted size capped (default 50 MB),
/// - encrypted / zip64 / exotic-compression archives rejected.
public enum SafeZipExtractor {
    public static let defaultMaxExtractedBytes = 50 * 1024 * 1024

    /// Extracts `zipData` into `destination` (created if needed).
    /// Returns the relative paths of the files written.
    @discardableResult
    public static func extract(
        zipData: Data,
        to destination: URL,
        maxExtractedBytes: Int = defaultMaxExtractedBytes
    ) throws -> [String] {
        let reader = ZipReader(data: zipData)
        let entries = try reader.centralDirectoryEntries()

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationPath = destination.standardizedFileURL.path

        var totalBytes = 0
        var written: [String] = []

        for entry in entries {
            // Symbolic links are ignored entirely (security contract).
            if entry.isSymlink { continue }

            let components = entry.name.split(separator: "/").map(String.init)
            guard !entry.name.hasPrefix("/"),
                  !entry.name.contains("\\"),
                  !components.isEmpty,
                  !components.contains(".."),
                  !components.contains("")
            else {
                throw ZipExtractionError.pathTraversal(entry.name)
            }

            var target = destination
            for component in components {
                target.appendPathComponent(component)
            }
            let targetPath = target.standardizedFileURL.path
            guard targetPath == destinationPath
                || targetPath.hasPrefix(destinationPath + "/")
            else {
                throw ZipExtractionError.pathTraversal(entry.name)
            }

            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            totalBytes += Int(entry.uncompressedSize)
            guard totalBytes <= maxExtractedBytes else {
                throw ZipExtractionError.extractionTooLarge(limitBytes: maxExtractedBytes)
            }

            let contents = try reader.contents(of: entry)
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: target, options: [.atomic])
            // zip strips POSIX permissions on many producers; exec widgets
            // ship shell scripts, so restore +x on shebang files.
            if contents.starts(with: Array("#!".utf8)) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
            written.append(components.joined(separator: "/"))
        }

        return written
    }
}

public enum ZipExtractionError: Error, Equatable, LocalizedError {
    case notAZipArchive
    case corruptArchive(String)
    case unsupportedFeature(String)
    case pathTraversal(String)
    case extractionTooLarge(limitBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return "the downloaded file is not a zip archive"
        case let .corruptArchive(detail):
            return "corrupt zip archive: \(detail)"
        case let .unsupportedFeature(detail):
            return "unsupported zip archive: \(detail)"
        case let .pathTraversal(name):
            return "zip entry escapes the extraction directory: \(name)"
        case let .extractionTooLarge(limit):
            return "archive expands beyond the \(limit / (1024 * 1024)) MB extraction limit"
        }
    }
}

// MARK: - Zip parsing

private struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
    let externalAttributes: UInt32

    var unixMode: UInt16 { UInt16(truncatingIfNeeded: externalAttributes >> 16) }
    var isSymlink: Bool { (unixMode & 0o170000) == 0o120000 }
    var isDirectory: Bool { name.hasSuffix("/") }
}

private struct ZipReader {
    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let centralSignature: UInt32 = 0x0201_4b50
    private static let localSignature: UInt32 = 0x0403_4b50
    private static let eocdSize = 22
    private static let maxCommentLength = 65_535

    let data: Data

    func centralDirectoryEntries() throws -> [ZipEntry] {
        guard data.count >= Self.eocdSize else {
            throw ZipExtractionError.notAZipArchive
        }

        // Locate End Of Central Directory (scan backwards over the comment).
        var eocdOffset = -1
        let scanFloor = max(0, data.count - Self.eocdSize - Self.maxCommentLength)
        var index = data.count - Self.eocdSize
        while index >= scanFloor {
            if try uint32(at: index) == Self.eocdSignature {
                eocdOffset = index
                break
            }
            index -= 1
        }
        guard eocdOffset >= 0 else {
            throw ZipExtractionError.notAZipArchive
        }

        let entryCount = try uint16(at: eocdOffset + 10)
        let centralOffset = try uint32(at: eocdOffset + 16)
        if entryCount == 0xFFFF || centralOffset == 0xFFFF_FFFF {
            throw ZipExtractionError.unsupportedFeature("zip64 archives are not supported")
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(entryCount))
        var cursor = Int(centralOffset)

        for _ in 0..<entryCount {
            guard try uint32(at: cursor) == Self.centralSignature else {
                throw ZipExtractionError.corruptArchive("central directory entry expected")
            }
            let flags = try uint16(at: cursor + 8)
            if flags & 0x1 != 0 {
                throw ZipExtractionError.unsupportedFeature("encrypted archives are not supported")
            }
            let method = try uint16(at: cursor + 10)
            let compressedSize = try uint32(at: cursor + 20)
            let uncompressedSize = try uint32(at: cursor + 24)
            let nameLength = Int(try uint16(at: cursor + 28))
            let extraLength = Int(try uint16(at: cursor + 30))
            let commentLength = Int(try uint16(at: cursor + 32))
            let externalAttributes = try uint32(at: cursor + 38)
            let localHeaderOffset = try uint32(at: cursor + 42)
            let name = try string(at: cursor + 46, length: nameLength)

            entries.append(ZipEntry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                externalAttributes: externalAttributes
            ))

            cursor += 46 + nameLength + extraLength + commentLength
        }

        return entries
    }

    func contents(of entry: ZipEntry) throws -> Data {
        let localOffset = Int(entry.localHeaderOffset)
        guard try uint32(at: localOffset) == Self.localSignature else {
            throw ZipExtractionError.corruptArchive("local header expected for \(entry.name)")
        }
        // Name/extra lengths in the local header may differ from the central
        // directory (e.g. extra fields added at streaming time) — use them.
        let nameLength = Int(try uint16(at: localOffset + 26))
        let extraLength = Int(try uint16(at: localOffset + 28))
        let dataStart = localOffset + 30 + nameLength + extraLength
        let raw = try slice(at: dataStart, length: Int(entry.compressedSize))

        switch entry.method {
        case 0: // stored
            guard raw.count == Int(entry.uncompressedSize) else {
                throw ZipExtractionError.corruptArchive("stored size mismatch for \(entry.name)")
            }
            return raw
        case 8: // deflate
            return try inflate(raw, expectedSize: Int(entry.uncompressedSize), name: entry.name)
        default:
            throw ZipExtractionError.unsupportedFeature(
                "compression method \(entry.method) (entry \(entry.name))"
            )
        }
    }

    /// Raw DEFLATE (RFC 1951) — Compression framework's `COMPRESSION_ZLIB`.
    private func inflate(_ input: Data, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        guard !input.isEmpty else {
            throw ZipExtractionError.corruptArchive("empty deflate stream for \(name)")
        }
        var output = Data(count: expectedSize)
        let decodedCount = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    dstBase, expectedSize,
                    srcBase, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == expectedSize else {
            throw ZipExtractionError.corruptArchive("deflate stream truncated for \(name)")
        }
        return output
    }

    // MARK: bounds-checked little-endian readers

    private func uint16(at offset: Int) throws -> UInt16 {
        let bytes = try slice(at: offset, length: 2)
        return UInt16(bytes[bytes.startIndex])
            | UInt16(bytes[bytes.startIndex + 1]) << 8
    }

    private func uint32(at offset: Int) throws -> UInt32 {
        let bytes = try slice(at: offset, length: 4)
        return UInt32(bytes[bytes.startIndex])
            | UInt32(bytes[bytes.startIndex + 1]) << 8
            | UInt32(bytes[bytes.startIndex + 2]) << 16
            | UInt32(bytes[bytes.startIndex + 3]) << 24
    }

    private func string(at offset: Int, length: Int) throws -> String {
        String(decoding: try slice(at: offset, length: length), as: UTF8.self)
    }

    private func slice(at offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            throw ZipExtractionError.corruptArchive("offset out of bounds")
        }
        let start = data.startIndex + offset
        return data[start..<(start + length)]
    }
}
