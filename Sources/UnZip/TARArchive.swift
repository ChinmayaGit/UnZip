import Foundation

enum TARArchive {
    static func list(url: URL, format: ArchiveFormat) throws -> [ArchiveEntry] {
        if format == .tar, let native = try? parseNative(url: url), !native.isEmpty {
            return native
        }
        let flags = tarFlags(for: format)
        let result = try ProcessRunner.runChecked(Toolchain.tar, arguments: ["-\(flags)tvf", url.path])
        return parseTarList(result.stdoutText)
    }

    static func extract(url: URL, destination: URL, entries: [ArchiveEntry]?, format: ArchiveFormat) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args = ["-\(tarFlags(for: format))xvf", url.path, "-C", destination.path]
        if let entries {
            let paths = entries.map(\.path).filter { !$0.isEmpty }
            if !paths.isEmpty {
                args.append(contentsOf: paths)
            }
        }
        try ProcessRunner.runChecked(Toolchain.tar, arguments: args)
    }

    static func extractData(url: URL, path: String, format: ArchiveFormat) throws -> Data {
        let result = try ProcessRunner.runChecked(Toolchain.tar, arguments: ["-\(tarFlags(for: format))xOf", url.path, path])
        return result.stdout
    }

    private static func tarFlags(for format: ArchiveFormat) -> String {
        switch format {
        case .tarGz, .gzip: return "z"
        case .tarBz2, .bzip2: return "j"
        case .tarXz, .xz: return "J"
        default: return ""
        }
    }

    private static func parseTarList(_ text: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        for line in text.split(whereSeparator: \.isNewline).map(String.init) where !line.isEmpty {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 6 else { continue }
            let perms = parts[0]
            let isDir = perms.hasPrefix("d") || parts.last?.hasSuffix("/") == true
            let size = Int64(parts[2]) ?? Int64(parts[4]) ?? 0
            var nameIndex = parts.count - 1
            if parts.count >= 9 {
                nameIndex = 8
            }
            // bsdtar: permissions links user size date time name
            let name: String
            if parts.count >= 8, parts[5].contains("-") {
                name = parts.dropFirst(7).joined(separator: " ")
            } else {
                name = parts[nameIndex]
            }
            let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !cleaned.isEmpty else { continue }
            var modified: Date?
            if parts.count >= 7 {
                modified = formatter.date(from: "\(parts[5]) \(parts[6])")
            }
            entries.append(
                ArchiveEntry(
                    id: cleaned,
                    path: cleaned,
                    name: URL(fileURLWithPath: cleaned).lastPathComponent,
                    isDirectory: isDir,
                    compressedSize: size,
                    uncompressedSize: size,
                    modified: modified,
                    encrypted: false
                )
            )
        }
        return ensureDirectories(entries)
    }

    static func parseNative(url: URL) throws -> [ArchiveEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var entries: [ArchiveEntry] = []
        while true {
            guard let header = try handle.read(upToCount: 512), header.count == 512 else { break }
            if header.allSatisfy({ $0 == 0 }) { break }
            let name = tarString(header, 0, 100)
            let prefix = tarString(header, 345, 155)
            let full = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let size = tarOctal(header, 124, 12)
            let mtime = tarOctal(header, 136, 12)
            let typeflag = header[156]
            let isDir = typeflag == UInt8(ascii: "5") || full.hasSuffix("/")
            let cleaned = full.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !cleaned.isEmpty {
                entries.append(
                    ArchiveEntry(
                        id: cleaned,
                        path: cleaned,
                        name: URL(fileURLWithPath: cleaned).lastPathComponent,
                        isDirectory: isDir,
                        compressedSize: size,
                        uncompressedSize: size,
                        modified: Date(timeIntervalSince1970: TimeInterval(mtime)),
                        encrypted: false
                    )
                )
            }
            let skip = Int((size + 511) & ~Int64(511))
            if skip > 0 {
                let current = try handle.offset()
                try handle.seek(toOffset: current + UInt64(skip))
            }
        }
        return ensureDirectories(entries)
    }

    private static func tarString(_ data: Data, _ start: Int, _ length: Int) -> String {
        let slice = data[start..<(start + length)]
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(bytes: slice[slice.startIndex..<end], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func tarOctal(_ data: Data, _ start: Int, _ length: Int) -> Int64 {
        let text = tarString(data, start, length).trimmingCharacters(in: .whitespaces)
        return Int64(text, radix: 8) ?? 0
    }
}

enum SingleFileArchive {
    static func list(url: URL, format: ArchiveFormat) -> [ArchiveEntry] {
        let original = url.deletingPathExtension().lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return [
            ArchiveEntry(
                id: original,
                path: original,
                name: original,
                isDirectory: false,
                compressedSize: size,
                uncompressedSize: 0,
                modified: nil,
                encrypted: false
            )
        ]
    }

    static func extract(url: URL, destination: URL, format: ArchiveFormat) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outName = url.deletingPathExtension().lastPathComponent
        let dest = destination.appendingPathComponent(outName)
        switch format {
        case .gzip:
            let result = try ProcessRunner.runChecked(Toolchain.gzip, arguments: ["-dc", url.path])
            try result.stdout.write(to: dest)
        case .bzip2:
            let result = try ProcessRunner.runChecked(Toolchain.bunzip2, arguments: ["-c", url.path])
            try result.stdout.write(to: dest)
        case .xz:
            guard let xz = Toolchain.xz else { throw UnZipError.missingTool("xz") }
            let result = try ProcessRunner.runChecked(xz, arguments: ["-dc", url.path])
            try result.stdout.write(to: dest)
        default:
            throw UnZipError.unsupportedFormat
        }
    }

    static func extractData(url: URL, format: ArchiveFormat) throws -> Data {
        switch format {
        case .gzip:
            return try ProcessRunner.runChecked(Toolchain.gzip, arguments: ["-dc", url.path]).stdout
        case .bzip2:
            return try ProcessRunner.runChecked(Toolchain.bunzip2, arguments: ["-c", url.path]).stdout
        case .xz:
            guard let xz = Toolchain.xz else { throw UnZipError.missingTool("xz") }
            return try ProcessRunner.runChecked(xz, arguments: ["-dc", url.path]).stdout
        default:
            throw UnZipError.unsupportedFormat
        }
    }
}
