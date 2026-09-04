import Foundation

enum ZIPArchive {
    static func list(url: URL) throws -> [ArchiveEntry] {
        if let parsed = try? parseCentralDirectory(url: url), !parsed.isEmpty {
            return parsed
        }
        return try listWithUnzip(url: url)
    }

    static func extract(url: URL, destination: URL, entries: [ArchiveEntry]?, password: String?) throws {
        var args = ["-o"]
        if let password, !password.isEmpty {
            args.append(contentsOf: ["-P", password])
        }
        args.append(url.path)
        if let entries {
            let files = entries.filter { !$0.isDirectory }.map(\.path)
            if files.isEmpty { return }
            args.append(contentsOf: files)
        }
        args.append(contentsOf: ["-d", destination.path])
        let result = try ProcessRunner.run(Toolchain.unzip, arguments: args)
        if !result.succeeded {
            let text = result.stderrText + result.stdoutText
            if text.localizedCaseInsensitiveContains("password") {
                throw UnZipError.passwordRequired
            }
            throw UnZipError.failed(text.isEmpty ? "Could not extract ZIP." : text)
        }
    }

    static func extractData(url: URL, path: String, password: String?) throws -> Data {
        var args = ["-p"]
        if let password, !password.isEmpty {
            args.append(contentsOf: ["-P", password])
        }
        args.append(contentsOf: [url.path, path])
        let result = try ProcessRunner.run(Toolchain.unzip, arguments: args)
        if !result.succeeded {
            let text = result.stderrText
            if text.localizedCaseInsensitiveContains("password") {
                throw UnZipError.passwordRequired
            }
            throw UnZipError.failed(text.isEmpty ? "Could not read \(path)." : text)
        }
        return result.stdout
    }

    private static func listWithUnzip(url: URL) throws -> [ArchiveEntry] {
        let result = try ProcessRunner.run(Toolchain.unzip, arguments: ["-lZ1", url.path])
        if result.succeeded {
            let paths = result.stdoutText.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            if !paths.isEmpty {
                return paths.map { path in
                    let isDir = path.hasSuffix("/")
                    return ArchiveEntry(
                        id: path,
                        path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        isDirectory: isDir,
                        compressedSize: 0,
                        uncompressedSize: 0,
                        modified: nil,
                        encrypted: false
                    )
                }
            }
        }
        let listing = try ProcessRunner.runChecked(Toolchain.unzip, arguments: ["-l", url.path])
        return parseUnzipList(listing.stdoutText)
    }

    private static func parseUnzipList(_ text: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var started = false
        for line in lines {
            if line.contains("---------") {
                if started { break }
                started = true
                continue
            }
            guard started else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 4 else { continue }
            let size = Int64(parts[0]) ?? 0
            let name = parts.dropFirst(3).joined(separator: " ")
            let isDir = name.hasSuffix("/")
            entries.append(
                ArchiveEntry(
                    id: name,
                    path: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    name: URL(fileURLWithPath: name).lastPathComponent,
                    isDirectory: isDir,
                    compressedSize: size,
                    uncompressedSize: size,
                    modified: nil,
                    encrypted: false
                )
            )
        }
        return ensureDirectories(entries)
    }

    static func parseCentralDirectory(url: URL) throws -> [ArchiveEntry] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 22 else { throw UnZipError.failed("File is too small to be a ZIP.") }
        guard let eocd = findEOCD(in: data) else { throw UnZipError.failed("Not a valid ZIP archive.") }

        var offset = Int(eocd.cdOffset)
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(Int(eocd.totalEntries))

        for _ in 0..<eocd.totalEntries {
            guard offset + 46 <= data.count else { break }
            guard data[offset..<(offset + 4)] == Data([0x50, 0x4B, 0x01, 0x02]) else { break }
            let flags = data.u16(offset + 8)
            let method = data.u16(offset + 10)
            let dosTime = data.u16(offset + 12)
            let dosDate = data.u16(offset + 14)
            var compSize = Int64(data.u32(offset + 20))
            var uncompSize = Int64(data.u32(offset + 24))
            let nameLen = Int(data.u16(offset + 28))
            let extraLen = Int(data.u16(offset + 30))
            let commentLen = Int(data.u16(offset + 32))
            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else { break }
            let rawName = data.subdata(in: nameStart..<nameEnd)
            let extra = extraLen > 0 ? data.subdata(in: nameEnd..<(nameEnd + extraLen)) : Data()
            parseZip64Extra(extra, compressed: &compSize, uncompressed: &uncompSize)
            let name = String(data: rawName, encoding: .utf8)
                ?? String(data: rawName, encoding: .isoLatin1)
                ?? "untitled"
            let isDir = name.hasSuffix("/") || method == 0 && uncompSize == 0 && name.contains("/") && !name.split(separator: "/").last!.contains(".")
            let dir = name.hasSuffix("/")
            entries.append(
                ArchiveEntry(
                    id: name,
                    path: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    name: URL(fileURLWithPath: name).lastPathComponent,
                    isDirectory: dir || isDir && name.hasSuffix("/"),
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    modified: DOSDate.date(date: dosDate, time: dosTime),
                    encrypted: (flags & 1) == 1
                )
            )
            offset = nameEnd + extraLen + commentLen
        }
        return ensureDirectories(entries)
    }

    private static func findEOCD(in data: Data) -> (cdOffset: UInt64, totalEntries: UInt64)? {
        let maxScan = min(data.count, 22 + 65535)
        let start = data.count - maxScan
        if let range = data.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards, in: start..<data.count) {
            let i = range.lowerBound
            if i + 22 <= data.count {
                var entries = UInt64(data.u16(i + 10))
                var cdOffset = UInt64(data.u32(i + 16))
                if entries == 0xFFFF || cdOffset == 0xFFFF_FFFF,
                   let zip64 = findZIP64(in: data, before: i) {
                    entries = zip64.entries
                    cdOffset = zip64.offset
                }
                return (cdOffset, entries)
            }
        }
        return nil
    }

    private static func findZIP64(in data: Data, before end: Int) -> (offset: UInt64, entries: UInt64)? {
        guard let locator = data.range(of: Data([0x50, 0x4B, 0x06, 0x07]), options: .backwards, in: 0..<end) else {
            return nil
        }
        let loc = locator.lowerBound
        guard loc + 20 <= data.count else { return nil }
        let eocdOffset = data.u64(loc + 8)
        let i = Int(eocdOffset)
        guard i + 56 <= data.count, data[i..<(i + 4)] == Data([0x50, 0x4B, 0x06, 0x06]) else { return nil }
        return (data.u64(i + 48), data.u64(i + 32))
    }

    private static func parseZip64Extra(_ extra: Data, compressed: inout Int64, uncompressed: inout Int64) {
        var i = 0
        while i + 4 <= extra.count {
            let header = extra.u16(i)
            let size = Int(extra.u16(i + 2))
            let start = i + 4
            let end = start + size
            guard end <= extra.count else { break }
            if header == 0x0001 {
                var cursor = start
                if uncompressed == 0xFFFF_FFFF, cursor + 8 <= end {
                    uncompressed = Int64(bitPattern: extra.u64(cursor))
                    cursor += 8
                }
                if compressed == 0xFFFF_FFFF, cursor + 8 <= end {
                    compressed = Int64(bitPattern: extra.u64(cursor))
                }
            }
            i = end
        }
    }
}

enum DOSDate {
    static func date(date: UInt16, time: UInt16) -> Date? {
        var comps = DateComponents()
        comps.year = Int((date >> 9) & 0x7F) + 1980
        comps.month = Int((date >> 5) & 0x0F)
        comps.day = Int(date & 0x1F)
        comps.hour = Int((time >> 11) & 0x1F)
        comps.minute = Int((time >> 5) & 0x3F)
        comps.second = Int(time & 0x1F) * 2
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func u64(_ offset: Int) -> UInt64 {
        UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
    }
}

func isMetadataPath(_ path: String) -> Bool {
    let parts = path.split(separator: "/").map(String.init)
    return parts.contains(where: { part in
        part == "__MACOSX" || part == "PaxHeader" || part == ".DS_Store" || part.hasPrefix("._")
    })
}

func ensureDirectories(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
    var map: [String: ArchiveEntry] = [:]
    for entry in entries where !isMetadataPath(entry.path) {
        map[entry.path] = entry
        var parent = entry.parentPath
        while !parent.isEmpty {
            if map[parent] == nil {
                map[parent] = ArchiveEntry(
                    id: parent + "/",
                    path: parent,
                    name: URL(fileURLWithPath: parent).lastPathComponent,
                    isDirectory: true,
                    compressedSize: 0,
                    uncompressedSize: 0,
                    modified: nil,
                    encrypted: false
                )
            }
            if let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
            } else {
                parent = ""
            }
        }
    }
    return Array(map.values)
}
