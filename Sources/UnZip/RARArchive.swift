import Foundation

enum RARArchive {
    static func list(url: URL) throws -> [ArchiveEntry] {
        if let lsar = Toolchain.lsar {
            if let entries = try? listWithLsar(lsar, url: url), !entries.isEmpty {
                return entries
            }
        }
        if let seven = Toolchain.sevenZip {
            if let entries = try? ExternalArchive.listWith7z(seven, url: url), !entries.isEmpty {
                return entries
            }
        }
        if let parsed = try? parseHeaders(url: url), !parsed.isEmpty {
            return parsed
        }
        if let unrar = Toolchain.unrar {
            return try listWithUnrar(unrar, url: url)
        }
        throw UnZipError.missingTool("unar")
    }

    static func extract(url: URL, destination: URL, entries: [ArchiveEntry]?, password: String?) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if let unar = Toolchain.unar {
            var args = ["-f", "-o", destination.path]
            if let password, !password.isEmpty {
                args.append(contentsOf: ["-p", password])
            }
            args.append(url.path)
            try ProcessRunner.runChecked(unar, arguments: args)
            return
        }
        if let seven = Toolchain.sevenZip {
            var args = ["x", "-y", "-o\(destination.path)"]
            if let password, !password.isEmpty {
                args.append("-p\(password)")
            }
            args.append(url.path)
            try ProcessRunner.runChecked(seven, arguments: args)
            return
        }
        if let unrar = Toolchain.unrar {
            var args = ["x", "-o+"]
            if let password, !password.isEmpty {
                args.append("-p\(password)")
            } else {
                args.append("-p-")
            }
            args.append(url.path)
            args.append(destination.path + "/")
            try ProcessRunner.runChecked(unrar, arguments: args)
            return
        }
        throw UnZipError.missingTool("unar")
    }

    static func extractData(url: URL, path: String, password: String?) throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("UnZip-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try extract(url: url, destination: temp, entries: nil, password: password)
        let candidate = temp.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try Data(contentsOf: candidate)
        }
        if let match = FileManager.default.enumerator(at: temp, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == URL(fileURLWithPath: path).lastPathComponent }) {
            return try Data(contentsOf: match)
        }
        throw UnZipError.failed("Could not preview \(path).")
    }

    private static func listWithLsar(_ lsar: String, url: URL) throws -> [ArchiveEntry] {
        let result = try ProcessRunner.runChecked(lsar, arguments: ["-j", url.path])
        guard let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let files = object["lsarContents"] as? [[String: Any]] else {
            throw UnZipError.failed("Could not parse archive listing.")
        }
        var entries: [ArchiveEntry] = []
        for file in files {
            let name = (file["XADFileName"] as? String) ?? ""
            guard !name.isEmpty else { continue }
            let isDir = (file["XADIsDirectory"] as? Bool) ?? name.hasSuffix("/")
            let size = int64(file["XADFileSize"]) ?? int64(file["UncompressedSize"]) ?? 0
            let packed = int64(file["XADCompressedSize"]) ?? 0
            let encrypted = (file["XADIsEncrypted"] as? Bool) ?? false
            entries.append(
                ArchiveEntry(
                    id: name,
                    path: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    name: URL(fileURLWithPath: name).lastPathComponent,
                    isDirectory: isDir,
                    compressedSize: packed,
                    uncompressedSize: size,
                    modified: nil,
                    encrypted: encrypted
                )
            )
        }
        return ensureDirectories(entries)
    }

    private static func listWithUnrar(_ unrar: String, url: URL) throws -> [ArchiveEntry] {
        let result = try ProcessRunner.runChecked(unrar, arguments: ["lb", url.path])
        return ensureDirectories(
            result.stdoutText.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }.map { path in
                ArchiveEntry(
                    id: path,
                    path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    isDirectory: path.hasSuffix("/"),
                    compressedSize: 0,
                    uncompressedSize: 0,
                    modified: nil,
                    encrypted: false
                )
            }
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        return nil
    }

    static func parseHeaders(url: URL) throws -> [ArchiveEntry] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if data.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]) {
            return try parseRAR5(data)
        }
        if data.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) {
            return parseRAR4(data)
        }
        throw UnZipError.failed("Not a RAR archive.")
    }

    private static func parseRAR4(_ data: Data) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var i = 7
        while i + 7 <= data.count {
            let type = data[i + 2]
            let flags = data.u16(i + 3)
            let size = Int(data.u16(i + 5))
            guard size >= 7, i + size <= data.count else { break }
            if type == 0x74 {
                var cursor = i + 7
                guard cursor + 25 <= data.count else { break }
                let packSize = Int64(data.u32(cursor)); cursor += 4
                let unpSize = Int64(data.u32(cursor)); cursor += 4
                cursor += 1 // host OS
                cursor += 4 // crc
                let ftime = data.u32(cursor); cursor += 4
                cursor += 1 // unp ver
                cursor += 1 // method
                let nameSize = Int(data.u16(cursor)); cursor += 2
                cursor += 4 // attr
                if flags & 0x100 != 0 { cursor += 8 }
                guard cursor + nameSize <= data.count else { break }
                let nameData = data.subdata(in: cursor..<(cursor + nameSize))
                let name = String(data: nameData, encoding: .utf8)
                    ?? String(data: nameData, encoding: .isoLatin1)
                    ?? "file"
                let path = name.replacingOccurrences(of: "\\", with: "/")
                entries.append(
                    ArchiveEntry(
                        id: path,
                        path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        isDirectory: (flags & 0xE0) == 0xE0 || path.hasSuffix("/"),
                        compressedSize: packSize,
                        uncompressedSize: unpSize,
                        modified: Date(timeIntervalSince1970: TimeInterval(ftime)),
                        encrypted: (flags & 0x04) != 0
                    )
                )
                i += size + Int(packSize)
                continue
            }
            var add = 0
            if flags & 0x8000 != 0, i + size + 4 <= data.count {
                add = Int(data.u32(i + size - 0)) 
            }
            // packed data size lives after header when flag 0x8000
            if flags & 0x8000 != 0, i + 11 <= data.count {
                // HEAD_SIZE already includes header; packed size is extra 4 at end of header for some blocks
            }
            i += size + add
            if type == 0x7B { break } // end
        }
        return ensureDirectories(entries)
    }

    private static func parseRAR5(_ data: Data) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var i = 8
        while i + 8 < data.count {
            i += 4 // crc
            guard let headerSize = readVInt(data, &i) else { break }
            let headerStart = i
            guard let type = readVInt(data, &i), let flags = readVInt(data, &i) else { break }
            var extraSize: UInt64 = 0
            var dataSize: UInt64 = 0
            if flags & 0x0001 != 0 { extraSize = readVInt(data, &i) ?? 0 }
            if flags & 0x0002 != 0 { dataSize = readVInt(data, &i) ?? 0 }
            if type == 2 || type == 3 {
                _ = readVInt(data, &i) // file flags
                let unpSize = readVInt(data, &i) ?? 0
                _ = readVInt(data, &i) // attribs
                if let nameLen = readVInt(data, &i) {
                    // skip optional mtime/crc depending on flags — locate name at remaining header
                    // Conservative: scan UTF-8 name of nameLen from current if it fits
                    let remaining = headerStart + Int(headerSize) - i
                    if nameLen > 0, Int(nameLen) <= remaining {
                        // There may be extra fields before the name. Try last nameLen bytes of header area.
                        let nameEnd = headerStart + Int(headerSize) - Int(extraSize)
                        let nameStart = nameEnd - Int(nameLen)
                        if nameStart >= i && nameStart < data.count {
                            let slice = data.subdata(in: nameStart..<min(nameEnd, data.count))
                            if let name = String(data: slice, encoding: .utf8), !name.isEmpty, name.contains(where: { $0.isLetter || $0 == "/" || $0 == "." }) {
                                let path = name.replacingOccurrences(of: "\\", with: "/")
                                entries.append(
                                    ArchiveEntry(
                                        id: path,
                                        path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                        name: URL(fileURLWithPath: path).lastPathComponent,
                                        isDirectory: type == 3 || path.hasSuffix("/"),
                                        compressedSize: Int64(dataSize),
                                        uncompressedSize: Int64(unpSize),
                                        modified: nil,
                                        encrypted: flags & 0x0004 != 0
                                    )
                                )
                            }
                        }
                    }
                }
            }
            i = headerStart + Int(headerSize) + Int(dataSize)
        }
        return ensureDirectories(entries)
    }

    private static func readVInt(_ data: Data, _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift = 0
        while index < data.count, shift <= 70 {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}

enum ExternalArchive {
    static func list(url: URL) throws -> [ArchiveEntry] {
        if let lsar = Toolchain.lsar, let entries = try? listWithLsar(lsar, url: url), !entries.isEmpty {
            return entries
        }
        if let seven = Toolchain.sevenZip, let entries = try? listWith7z(seven, url: url), !entries.isEmpty {
            return entries
        }
        if let entries = try? TARArchive.list(url: url, format: .tar), !entries.isEmpty {
            return entries
        }
        throw UnZipError.missingTool("unar")
    }

    static func extract(url: URL, destination: URL, password: String?) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if let unar = Toolchain.unar {
            var args = ["-f", "-o", destination.path]
            if let password, !password.isEmpty { args += ["-p", password] }
            args.append(url.path)
            try ProcessRunner.runChecked(unar, arguments: args)
            return
        }
        if let seven = Toolchain.sevenZip {
            var args = ["x", "-y", "-o\(destination.path)"]
            if let password, !password.isEmpty { args.append("-p\(password)") }
            args.append(url.path)
            try ProcessRunner.runChecked(seven, arguments: args)
            return
        }
        try ProcessRunner.runChecked(Toolchain.tar, arguments: ["-xvf", url.path, "-C", destination.path])
    }

    static func extractData(url: URL, path: String, password: String?) throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("UnZip-one-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try extract(url: url, destination: temp, password: password)
        let dest = temp.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: dest.path) {
            return try Data(contentsOf: dest)
        }
        throw UnZipError.failed("Could not read \(path).")
    }

    static func listWithLsar(_ lsar: String, url: URL) throws -> [ArchiveEntry] {
        let result = try ProcessRunner.runChecked(lsar, arguments: ["-j", url.path])
        guard let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let files = object["lsarContents"] as? [[String: Any]] else {
            throw UnZipError.failed("Could not parse archive listing.")
        }
        var entries: [ArchiveEntry] = []
        for file in files {
            let name = (file["XADFileName"] as? String) ?? ""
            guard !name.isEmpty else { continue }
            let isDir = (file["XADIsDirectory"] as? Bool) ?? name.hasSuffix("/")
            entries.append(
                ArchiveEntry(
                    id: name,
                    path: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    name: URL(fileURLWithPath: name).lastPathComponent,
                    isDirectory: isDir,
                    compressedSize: 0,
                    uncompressedSize: 0,
                    modified: nil,
                    encrypted: (file["XADIsEncrypted"] as? Bool) ?? false
                )
            )
        }
        return ensureDirectories(entries)
    }

    static func listWith7z(_ seven: String, url: URL) throws -> [ArchiveEntry] {
        let result = try ProcessRunner.runChecked(seven, arguments: ["l", "-slt", "-ba", url.path])
        var entries: [ArchiveEntry] = []
        var path = ""
        var size: Int64 = 0
        var packed: Int64 = 0
        var isDir = false
        var encrypted = false
        func flush() {
            guard !path.isEmpty else { return }
            entries.append(
                ArchiveEntry(
                    id: path,
                    path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    isDirectory: isDir,
                    compressedSize: packed,
                    uncompressedSize: size,
                    modified: nil,
                    encrypted: encrypted
                )
            )
            path = ""
            size = 0
            packed = 0
            isDir = false
            encrypted = false
        }
        for line in result.stdoutText.split(whereSeparator: \.isNewline).map(String.init) {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("Path = ") { path = String(line.dropFirst(7)) }
            else if line.hasPrefix("Size = ") { size = Int64(line.dropFirst(7)) ?? 0 }
            else if line.hasPrefix("Packed Size = ") { packed = Int64(line.dropFirst(14)) ?? 0 }
            else if line.hasPrefix("Attributes = ") { isDir = line.contains("D") }
            else if line.hasPrefix("Folder = ") { isDir = line.contains("+") }
            else if line.hasPrefix("Encrypted = ") { encrypted = line.contains("+") }
        }
        flush()
        return ensureDirectories(entries)
    }
}
