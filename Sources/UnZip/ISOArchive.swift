import Foundation

enum ISOArchive {
    static func list(url: URL) throws -> [ArchiveEntry] {
        if let native = try? parseISO(url: url), !native.isEmpty {
            return native
        }
        return try listByMounting(url: url)
    }

    static func extract(url: URL, destination: URL, entries: [ArchiveEntry]?) throws {
        do {
            try extractNative(url: url, destination: destination, entries: entries)
        } catch {
            try extractByMounting(url: url, destination: destination, entries: entries)
        }
    }

    static func extractData(url: URL, path: String) throws -> Data {
        if let data = try? readNativeFile(url: url, path: path) {
            return data
        }
        return try readByMounting(url: url, path: path)
    }

    // MARK: - Native ISO 9660 / Joliet

    private struct Volume {
        var blockSize: Int
        var rootLBA: UInt32
        var rootSize: UInt32
        var joliet: Bool
    }

    private static func parseISO(url: URL) throws -> [ArchiveEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let volume = try readVolume(handle: handle) else {
            throw UnZipError.failed("Not a valid ISO 9660 image.")
        }
        var entries: [ArchiveEntry] = []
        try walk(handle: handle, volume: volume, lba: volume.rootLBA, size: volume.rootSize, prefix: "", entries: &entries)
        return ensureDirectories(entries)
    }

    private static func readVolume(handle: FileHandle) throws -> Volume? {
        var joliet: Volume?
        var primary: Volume?
        for sector in 16..<32 {
            try handle.seek(toOffset: UInt64(sector * 2048))
            guard let data = try handle.read(upToCount: 2048), data.count == 2048 else { break }
            let type = data[0]
            if type == 255 { break }
            guard data.count > 190, String(bytes: data[1..<6], encoding: .ascii) == "CD001" else { continue }
            let blockSize = Int(data.u16(128))
            let root = data.subdata(in: 156..<190)
            let lba = root.u32(2)
            let size = root.u32(10)
            let volume = Volume(blockSize: blockSize == 0 ? 2048 : blockSize, rootLBA: lba, rootSize: size, joliet: type == 2)
            if type == 2, data.count > 90 {
                let escape = Array(data[88..<91])
                if escape == [0x25, 0x2F, 0x45] || escape == [0x25, 0x2F, 0x43] || escape == [0x25, 0x2F, 0x40] {
                    joliet = volume
                }
            } else if type == 1 {
                primary = volume
            }
        }
        return joliet ?? primary
    }

    private static func walk(
        handle: FileHandle,
        volume: Volume,
        lba: UInt32,
        size: UInt32,
        prefix: String,
        entries: inout [ArchiveEntry]
    ) throws {
        try handle.seek(toOffset: UInt64(lba) * UInt64(volume.blockSize))
        guard let blob = try handle.read(upToCount: Int(size)) else { return }
        var offset = 0
        while offset < blob.count {
            let recLen = Int(blob[offset])
            if recLen == 0 {
                offset = ((offset / volume.blockSize) + 1) * volume.blockSize
                continue
            }
            guard offset + recLen <= blob.count else { break }
            let rec = blob.subdata(in: offset..<(offset + recLen))
            let nameLen = Int(rec[32])
            let flags = rec[25]
            let isDir = (flags & 0x02) != 0
            let extent = rec.u32(2)
            let dataLen = rec.u32(10)
            if nameLen > 0, offset + 33 + nameLen <= blob.count {
                let raw = rec.subdata(in: 33..<(33 + nameLen))
                if !(nameLen == 1 && (raw[0] == 0 || raw[0] == 1)) {
                    let name = volume.joliet ? ucs2(raw) : isoName(raw)
                    if !name.isEmpty {
                        let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                        entries.append(
                            ArchiveEntry(
                                id: path,
                                path: path,
                                name: name,
                                isDirectory: isDir,
                                compressedSize: Int64(dataLen),
                                uncompressedSize: Int64(dataLen),
                                modified: isoDate(rec, 18),
                                encrypted: false
                            )
                        )
                        if isDir {
                            try walk(handle: handle, volume: volume, lba: extent, size: dataLen, prefix: path, entries: &entries)
                        }
                    }
                }
            }
            offset += recLen
        }
    }

    private static func extractNative(url: URL, destination: URL, entries: [ArchiveEntry]?) throws {
        let all = try parseISO(url: url)
        let wanted: [ArchiveEntry]
        if let entries, !entries.isEmpty {
            let prefixes = Set(entries.map(\.path))
            wanted = all.filter { item in
                prefixes.contains(item.path) || prefixes.contains(where: { item.path == $0 || item.path.hasPrefix($0 + "/") })
            }
        } else {
            wanted = all
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let volume = try readVolume(handle: handle) else { throw UnZipError.failed("Could not read ISO volume.") }
        for entry in wanted where !entry.isDirectory {
            let data = try readFile(handle: handle, volume: volume, path: entry.path, entries: all)
            let dest = destination.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
        }
    }

    private static func readNativeFile(url: URL, path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let volume = try readVolume(handle: handle) else { throw UnZipError.failed("Could not read ISO volume.") }
        let entries = try parseISO(url: url)
        return try readFile(handle: handle, volume: volume, path: path, entries: entries)
    }

    private static func readFile(handle: FileHandle, volume: Volume, path: String, entries: [ArchiveEntry]) throws -> Data {
        try handle.seek(toOffset: UInt64(volume.rootLBA) * UInt64(volume.blockSize))
        guard let found = try findRecord(handle: handle, volume: volume, lba: volume.rootLBA, size: volume.rootSize, remaining: path.split(separator: "/").map(String.init)) else {
            throw UnZipError.failed("Missing \(path) in ISO.")
        }
        try handle.seek(toOffset: UInt64(found.lba) * UInt64(volume.blockSize))
        return try handle.read(upToCount: Int(found.size)) ?? Data()
    }

    private static func findRecord(
        handle: FileHandle,
        volume: Volume,
        lba: UInt32,
        size: UInt32,
        remaining: [String]
    ) throws -> (lba: UInt32, size: UInt32)? {
        try handle.seek(toOffset: UInt64(lba) * UInt64(volume.blockSize))
        guard let blob = try handle.read(upToCount: Int(size)) else { return nil }
        var offset = 0
        while offset < blob.count {
            let recLen = Int(blob[offset])
            if recLen == 0 {
                offset = ((offset / volume.blockSize) + 1) * volume.blockSize
                continue
            }
            guard offset + recLen <= blob.count else { break }
            let rec = blob.subdata(in: offset..<(offset + recLen))
            let nameLen = Int(rec[32])
            let flags = rec[25]
            let extent = rec.u32(2)
            let dataLen = rec.u32(10)
            if nameLen > 0 {
                let raw = rec.subdata(in: 33..<(33 + nameLen))
                if !(nameLen == 1 && (raw[0] == 0 || raw[0] == 1)) {
                    let name = volume.joliet ? ucs2(raw) : isoName(raw)
                    if name.caseInsensitiveCompare(remaining[0]) == .orderedSame {
                        if remaining.count == 1 {
                            return (extent, dataLen)
                        }
                        if (flags & 0x02) != 0 {
                            return try findRecord(handle: handle, volume: volume, lba: extent, size: dataLen, remaining: Array(remaining.dropFirst()))
                        }
                    }
                }
            }
            offset += recLen
        }
        return nil
    }

    private static func isoName(_ data: Data) -> String {
        var text = String(bytes: data, encoding: .ascii) ?? ""
        if let semi = text.firstIndex(of: ";") {
            text = String(text[..<semi])
        }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func ucs2(_ data: Data) -> String {
        var scalars: [UInt16] = []
        var i = 0
        while i + 1 < data.count {
            scalars.append(UInt16(data[i]) << 8 | UInt16(data[i + 1]))
            i += 2
        }
        return String(utf16CodeUnits: scalars, count: scalars.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .replacingOccurrences(of: ";1", with: "")
    }

    private static func isoDate(_ data: Data, _ offset: Int) -> Date? {
        guard offset + 6 < data.count else { return nil }
        var comps = DateComponents()
        comps.year = Int(data[offset]) + 1900
        comps.month = Int(data[offset + 1])
        comps.day = Int(data[offset + 2])
        comps.hour = Int(data[offset + 3])
        comps.minute = Int(data[offset + 4])
        comps.second = Int(data[offset + 5])
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    // MARK: - hdiutil fallback (UDF / hybrid)

    private static func withMount<T>(url: URL, _ body: (URL) throws -> T) throws -> T {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("UnZip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            _ = try? ProcessRunner.run(Toolchain.hdiutil, arguments: ["detach", mount.path, "-quiet", "-force"])
            try? FileManager.default.removeItem(at: mount)
        }
        try ProcessRunner.runChecked(Toolchain.hdiutil, arguments: [
            "attach", url.path, "-readonly", "-nobrowse", "-mountpoint", mount.path
        ])
        return try body(mount)
    }

    private static func listByMounting(url: URL) throws -> [ArchiveEntry] {
        try withMount(url: url) { mount in
            walkFolder(mount, prefix: "")
        }
    }

    private static func extractByMounting(url: URL, destination: URL, entries: [ArchiveEntry]?) throws {
        try withMount(url: url) { mount in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if let entries, !entries.isEmpty {
                for entry in entries {
                    let source = mount.appendingPathComponent(entry.path)
                    let dest = destination.appendingPathComponent(entry.path)
                    if entry.isDirectory {
                        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                    } else if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: dest.path) {
                            try FileManager.default.removeItem(at: dest)
                        }
                        try FileManager.default.copyItem(at: source, to: dest)
                    }
                }
            } else {
                for item in try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil) {
                    let dest = destination.appendingPathComponent(item.lastPathComponent)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: item, to: dest)
                }
            }
        }
    }

    private static func readByMounting(url: URL, path: String) throws -> Data {
        try withMount(url: url) { mount in
            try Data(contentsOf: mount.appendingPathComponent(path))
        }
    }

    static func walkFolder(_ root: URL, prefix: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return entries
        }
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values?.isDirectory == true
            let path = prefix.isEmpty ? child.lastPathComponent : "\(prefix)/\(child.lastPathComponent)"
            entries.append(
                ArchiveEntry(
                    id: path,
                    path: path,
                    name: child.lastPathComponent,
                    isDirectory: isDir,
                    compressedSize: Int64(values?.fileSize ?? 0),
                    uncompressedSize: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate,
                    encrypted: false
                )
            )
            if isDir {
                entries.append(contentsOf: walkFolder(child, prefix: path))
            }
        }
        return entries
    }
}

enum DMGArchive {
    static func list(url: URL) throws -> [ArchiveEntry] {
        try ISOArchive.list(url: url)
    }

    static func extract(url: URL, destination: URL, entries: [ArchiveEntry]?) throws {
        try ISOArchive.extract(url: url, destination: destination, entries: entries)
    }

    static func extractData(url: URL, path: String) throws -> Data {
        try ISOArchive.extractData(url: url, path: path)
    }
}
